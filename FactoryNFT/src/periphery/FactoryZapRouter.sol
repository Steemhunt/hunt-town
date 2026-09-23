// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { BalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { IFactoryNFT } from "../interfaces/IFactoryNFT.sol";

/// @notice Buys the exact HUNT needed to mint a fixed NFT quantity through a caller-supplied
/// forward V4 route. Unused input goes back to the payer; NFTs go directly to the receiver.
contract FactoryZapRouter is ReentrancyGuardTransient, IUnlockCallback {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    uint256 public constant MAX_ROUTE_HOPS = 3;

    IFactoryNFT public immutable factory;
    IPoolManager public immutable poolManager;
    IERC20 public immutable huntToken;
    bool private transient swapActive;

    struct SwapRequest {
        Currency input;
        uint256 huntOut;
        uint256 maxInput;
        PoolKey[] route;
    }

    struct BalanceSnapshot {
        uint256 native;
        uint256 input;
        uint256 hunt;
    }

    error InvalidAddress();
    error InvalidAmount();
    error DeadlineExpired();
    error InvalidMsgValue();
    error InvalidRoute();
    error InvalidPool(uint256 hop);
    error UnauthorizedCallback();
    error InexactTransfer();
    error InexactSwap();
    error ExcessiveInput(uint256 required, uint256 maximum);
    error InexactMint();
    error NativeRefundFailed();
    error UnexpectedBalance();

    event ZappedMint(
        address indexed payer,
        address indexed receiver,
        address indexed inputToken,
        uint256 quantity,
        uint256 inputSpent,
        uint256 huntSpent
    );

    constructor(IFactoryNFT factory_, IPoolManager poolManager_) {
        if (address(factory_).code.length == 0 || address(poolManager_).code.length == 0) {
            revert InvalidAddress();
        }
        IERC20 hunt = factory_.huntToken();
        if (address(hunt) == address(0) || address(hunt).code.length == 0) revert InvalidAddress();
        factory = factory_;
        poolManager = poolManager_;
        huntToken = hunt;
    }

    /// @param inputToken Zero denotes native ETH; otherwise an exact-transfer ERC20.
    /// @param route Forward input-to-HUNT route. Direct HUNT payments require an empty route.
    function zapMint(
        uint256 quantity,
        address inputToken,
        uint256 maxAmountIn,
        PoolKey[] calldata route,
        address receiver,
        uint256 deadline
    ) external payable nonReentrant returns (uint256 amountIn, uint256 huntIn) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (receiver == address(0) || receiver == address(this)) revert InvalidAddress();
        if (quantity == 0 || maxAmountIn == 0) revert InvalidAmount();
        if (msg.value != (inputToken == address(0) ? maxAmountIn : 0)) revert InvalidMsgValue();

        {
            Currency input = Currency.wrap(inputToken);
            bool direct = inputToken == address(huntToken);
            if (direct) {
                if (route.length != 0) revert InvalidRoute();
            } else {
                _validateRoute(input, route);
            }
            huntIn = factory.quoteMint(quantity);
            if (huntIn == 0) revert InvalidAmount();
            if (direct && huntIn > maxAmountIn) revert ExcessiveInput(huntIn, maxAmountIn);

            BalanceSnapshot memory baseline;
            baseline.native = address(this).balance - msg.value;
            baseline.input = input.isAddressZero() ? baseline.native : input.balanceOfSelf();
            baseline.hunt = huntToken.balanceOf(address(this));
            if (!input.isAddressZero()) {
                IERC20(inputToken).safeTransferFrom(msg.sender, address(this), maxAmountIn);
                if (input.balanceOfSelf() != baseline.input + maxAmountIn) {
                    revert InexactTransfer();
                }
            }

            if (direct) {
                amountIn = huntIn;
            } else {
                swapActive = true;
                amountIn = abi.decode(
                    poolManager.unlock(abi.encode(SwapRequest(input, huntIn, maxAmountIn, route))),
                    (uint256)
                );
                if (swapActive) revert UnauthorizedCallback();
                if (
                    input.balanceOfSelf() != baseline.input + maxAmountIn - amountIn
                        || huntToken.balanceOf(address(this)) != baseline.hunt + huntIn
                ) revert InexactSwap();
            }

            {
                uint256 huntBeforeMint = huntToken.balanceOf(address(this));
                huntToken.forceApprove(address(factory), huntIn);
                uint256 used = factory.mint(quantity, huntIn, receiver);
                huntToken.forceApprove(address(factory), 0);
                if (used != huntIn || huntToken.balanceOf(address(this)) != huntBeforeMint - huntIn)
                {
                    revert InexactMint();
                }
            }

            uint256 refund = maxAmountIn - amountIn;
            if (refund != 0) {
                if (input.isAddressZero()) {
                    (bool success,) = msg.sender.call{ value: refund }("");
                    if (!success) revert NativeRefundFailed();
                } else {
                    IERC20(inputToken).safeTransfer(msg.sender, refund);
                }
            }
            if (
                input.balanceOfSelf() != baseline.input
                    || huntToken.balanceOf(address(this)) != baseline.hunt
                    || address(this).balance != baseline.native
            ) revert UnexpectedBalance();
        }

        emit ZappedMint(msg.sender, receiver, inputToken, quantity, amountIn, huntIn);
    }

    /// @dev Reverse swaps leave intermediate currencies netted inside V4 flash accounting.
    /// Only the initial input is settled and the final HUNT output is withdrawn.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !swapActive) revert UnauthorizedCallback();
        swapActive = false;
        SwapRequest memory request = abi.decode(data, (SwapRequest));
        Currency output = Currency.wrap(address(huntToken));
        uint256 required = request.huntOut;
        for (uint256 i = request.route.length; i != 0;) {
            PoolKey memory key = request.route[--i];
            bool zeroForOne = output == key.currency1;
            BalanceDelta delta = poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: required.toInt256(),
                    sqrtPriceLimitX96: zeroForOne
                        ? TickMath.MIN_SQRT_PRICE + 1
                        : TickMath.MAX_SQRT_PRICE - 1
                }),
                bytes("")
            );
            int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
            int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
            if (inputDelta >= 0 || outputDelta <= 0 || int256(outputDelta).toUint256() != required)
            {
                revert InexactSwap();
            }
            required = (-int256(inputDelta)).toUint256();
            output = zeroForOne ? key.currency0 : key.currency1;
        }
        if (required > request.maxInput) revert ExcessiveInput(required, request.maxInput);

        poolManager.sync(request.input);
        uint256 settled;
        if (request.input.isAddressZero()) {
            settled = poolManager.settle{ value: required }();
        } else {
            IERC20(Currency.unwrap(request.input)).safeTransfer(address(poolManager), required);
            settled = poolManager.settle();
        }
        if (settled != required) revert InexactTransfer();
        poolManager.take(Currency.wrap(address(huntToken)), address(this), request.huntOut);
        return abi.encode(required);
    }

    function _validateRoute(Currency input, PoolKey[] calldata route) private view {
        uint256 length = route.length;
        if (length == 0 || length > MAX_ROUTE_HOPS) revert InvalidRoute();
        Currency[] memory currencies = new Currency[](length + 1);
        currencies[0] = input;
        for (uint256 i; i < length; ++i) {
            PoolKey memory key = route[i];
            if (
                address(key.hooks) != address(0) || LPFeeLibrary.isDynamicFee(key.fee)
                    || !LPFeeLibrary.isValid(key.fee) || key.fee == LPFeeLibrary.MAX_LP_FEE
                    || Currency.unwrap(key.currency0) >= Currency.unwrap(key.currency1)
                    || key.tickSpacing < TickMath.MIN_TICK_SPACING
                    || key.tickSpacing > TickMath.MAX_TICK_SPACING
            ) revert InvalidPool(i);
            (uint160 price,,,) = poolManager.getSlot0(key.toId());
            if (price == 0) revert InvalidPool(i);
            Currency current = currencies[i];
            Currency next;
            if (current == key.currency0) next = key.currency1;
            else if (current == key.currency1) next = key.currency0;
            else revert InvalidRoute();
            for (uint256 j; j <= i; ++j) {
                if (next == currencies[j]) revert InvalidRoute();
            }
            currencies[i + 1] = next;
        }
        if (!(currencies[length] == Currency.wrap(address(huntToken)))) revert InvalidRoute();
    }
}
