// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalRouter, IAllowanceTransfer, IHooks, PoolKey, ExactInputSingleParams, QuoteExactSingleParams, IV4Quoter, IMCV2_Bond, IMCV2_BondPeriphery, Commands, Actions, ActionConstants} from "./Interfaces.sol";

/**
 * @title ZapUniV4MCV2
 * @notice Zap contract to mint HUNT-backed tokens on Mint Club V2 using various input tokens
 * @dev Supports HUNT (direct), MT, USDC, and ETH as input tokens via Uniswap V4 swaps
 */
contract ZapUniV4MCV2 {
    using SafeERC20 for IERC20;

    // ============ Token Addresses (Base Mainnet) ============
    address public constant HUNT = 0x37f0c2915CeCC7e977183B8543Fc0864d03E064C;
    address public constant MT = 0xFf45161474C39cB00699070Dd49582e417b57a7E;
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant ETH_ADDRESS = address(0);

    // ============ Uniswap V4 Pool Parameters (0.3% fee) ============
    uint24 public constant POOL_FEE = 3000;
    int24 public constant TICK_SPACING = 60;

    // ============ External Contracts (Base Mainnet) ============
    IUniversalRouter public constant UNIVERSAL_ROUTER = IUniversalRouter(0x6fF5693b99212Da76ad316178A184AB56D299b43);
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    IV4Quoter public constant QUOTER = IV4Quoter(0x0d5e0F971ED27FBfF6c2837bf31316121532048D);
    IMCV2_Bond public constant BOND = IMCV2_Bond(0xc5a076cad94176c2996B32d8466Be1cE757FAa27);
    IMCV2_BondPeriphery public constant BOND_PERIPHERY =
        IMCV2_BondPeriphery(0x492C412369Db76C9cdD9939e6C521579301473a3);

    // ============ Errors ============
    error ZapUniV4MCV2__UnsupportedToken();
    error ZapUniV4MCV2__InvalidAmount();
    error ZapUniV4MCV2__SlippageExceeded();
    error ZapUniV4MCV2__InsufficientHUNTReceived();
    error ZapUniV4MCV2__InvalidETHAmount();

    // ============ Events ============
    event Minted(
        address indexed user,
        address indexed fromToken,
        address indexed huntChildToken,
        uint256 huntChildAmount,
        uint256 fromTokenUsed,
        uint256 huntUsed
    );

    event MintedReverse(
        address indexed user,
        address indexed fromToken,
        address indexed huntChildToken,
        uint256 huntChildAmount,
        uint256 fromTokenUsed,
        uint256 huntUsed
    );

    // ============ Constructor ============
    constructor() {
        // Approve HUNT for Bond and BondPeriphery contracts
        IERC20(HUNT).approve(address(BOND), type(uint256).max);
        IERC20(HUNT).approve(address(BOND_PERIPHERY), type(uint256).max);

        // Setup Permit2 approvals for swap input tokens
        _setupPermit2Approval(MT);
        _setupPermit2Approval(USDC);
    }

    receive() external payable {}

    // ============ External Functions ============

    /**
     * @notice Mint exact amount of HUNT-backed tokens using various input tokens
     * @param fromToken Input token (HUNT, MT, USDC, or address(0) for ETH)
     * @param huntChildToken The HUNT-backed token to mint
     * @param huntChildAmount Exact amount of child tokens to mint
     * @param maxFromTokenAmount Maximum fromToken to spend (slippage protection)
     * @return fromTokenUsed Actual fromToken spent
     */
    function mint(
        address fromToken,
        address huntChildToken,
        uint256 huntChildAmount,
        uint256 maxFromTokenAmount
    ) external payable returns (uint256 fromTokenUsed) {
        if (huntChildAmount == 0) revert ZapUniV4MCV2__InvalidAmount();

        (uint256 huntRequired, uint256 royalty) = BOND.getReserveForToken(huntChildToken, huntChildAmount);
        uint256 totalHuntRequired = huntRequired + royalty;

        if (fromToken == HUNT) {
            if (totalHuntRequired > maxFromTokenAmount) revert ZapUniV4MCV2__SlippageExceeded();
            IERC20(HUNT).safeTransferFrom(msg.sender, address(this), totalHuntRequired);
            fromTokenUsed = totalHuntRequired;
        } else {
            _validateAndTransferInput(fromToken, maxFromTokenAmount);
            uint256 huntReceived = _executeV4Swap(fromToken, maxFromTokenAmount);
            if (huntReceived < totalHuntRequired) revert ZapUniV4MCV2__InsufficientHUNTReceived();
            fromTokenUsed = maxFromTokenAmount;
        }

        uint256 huntUsed;
        try BOND.mint(huntChildToken, huntChildAmount, totalHuntRequired, msg.sender) returns (uint256 actualHuntUsed) {
            huntUsed = actualHuntUsed;
        } catch {
            revert ZapUniV4MCV2__SlippageExceeded();
        }
        _refundHUNT();

        emit Minted(msg.sender, fromToken, huntChildToken, huntChildAmount, fromTokenUsed, huntUsed);
    }

    /**
     * @notice Mint HUNT-backed tokens by specifying exact input amount
     * @param fromToken Input token (HUNT, MT, USDC, or address(0) for ETH)
     * @param huntChildToken The HUNT-backed token to mint
     * @param fromTokenAmount Exact fromToken to spend
     * @param minHuntChildAmount Minimum child tokens to receive (slippage protection)
     * @return huntChildAmount Actual child tokens minted
     */
    function mintReverse(
        address fromToken,
        address huntChildToken,
        uint256 fromTokenAmount,
        uint256 minHuntChildAmount
    ) external payable returns (uint256 huntChildAmount) {
        if (fromTokenAmount == 0) revert ZapUniV4MCV2__InvalidAmount();

        uint256 huntAmount;
        if (fromToken == HUNT) {
            IERC20(HUNT).safeTransferFrom(msg.sender, address(this), fromTokenAmount);
            huntAmount = fromTokenAmount;
        } else {
            _validateAndTransferInput(fromToken, fromTokenAmount);
            huntAmount = _executeV4Swap(fromToken, fromTokenAmount);
        }

        try BOND_PERIPHERY.mintWithReserveAmount(huntChildToken, huntAmount, minHuntChildAmount, msg.sender) returns (
            uint256 minted
        ) {
            huntChildAmount = minted;
        } catch {
            revert ZapUniV4MCV2__SlippageExceeded();
        }

        _refundHUNT();

        emit MintedReverse(msg.sender, fromToken, huntChildToken, huntChildAmount, fromTokenAmount, huntAmount);
    }

    // ============ Estimation Functions (for frontend) ============

    /**
     * @notice Estimate fromToken amount needed to mint exact huntChildAmount
     * @dev Call via staticcall - reverts with result for swap quotes
     * @param fromToken Input token (HUNT, MT, USDC, or address(0) for ETH)
     * @param huntChildToken The HUNT-backed token to mint
     * @param huntChildAmount Exact amount of child tokens to mint
     * @return fromTokenAmount Estimated fromToken needed
     * @return totalHuntRequired Total HUNT needed (reserve + royalty)
     */
    function estimateMint(
        address fromToken,
        address huntChildToken,
        uint256 huntChildAmount
    ) external returns (uint256 fromTokenAmount, uint256 totalHuntRequired) {
        (uint256 huntRequired, uint256 royalty) = BOND.getReserveForToken(huntChildToken, huntChildAmount);
        totalHuntRequired = huntRequired + royalty;

        if (fromToken == HUNT) {
            fromTokenAmount = totalHuntRequired;
        } else {
            // Use Quoter to estimate swap input needed for exact HUNT output
            (fromTokenAmount, ) = QUOTER.quoteExactOutputSingle(
                _buildQuoteParams(fromToken, uint128(totalHuntRequired))
            );
        }
    }

    /**
     * @notice Estimate huntChildAmount received for exact fromTokenAmount
     * @dev Call via staticcall - reverts with result for swap quotes
     * @param fromToken Input token (HUNT, MT, USDC, or address(0) for ETH)
     * @param huntChildToken The HUNT-backed token to mint
     * @param fromTokenAmount Exact fromToken to spend
     * @return huntChildAmount Estimated child tokens to receive
     * @return huntAmount HUNT amount after swap (or direct if fromToken is HUNT)
     */
    function estimateMintReverse(
        address fromToken,
        address huntChildToken,
        uint256 fromTokenAmount
    ) external returns (uint256 huntChildAmount, uint256 huntAmount) {
        if (fromToken == HUNT) {
            huntAmount = fromTokenAmount;
        } else {
            // Use Quoter to estimate HUNT output from swap
            (huntAmount, ) = QUOTER.quoteExactInputSingle(_buildQuoteParams(fromToken, uint128(fromTokenAmount)));
        }

        (huntChildAmount, ) = BOND_PERIPHERY.getTokensForReserve(huntChildToken, huntAmount, false);
    }

    /**
     * @notice Build QuoteExactSingleParams for the given token
     */
    function _buildQuoteParams(address fromToken, uint128 amount) private pure returns (QuoteExactSingleParams memory) {
        (address currency0, address currency1, bool zeroForOne) = fromToken == ETH_ADDRESS
            ? (ETH_ADDRESS, HUNT, true)
            : (HUNT, fromToken, false);

        return
            QuoteExactSingleParams({
                poolKey: PoolKey({
                    currency0: currency0,
                    currency1: currency1,
                    fee: POOL_FEE,
                    tickSpacing: TICK_SPACING,
                    hooks: IHooks(address(0))
                }),
                zeroForOne: zeroForOne,
                exactAmount: amount,
                hookData: bytes("")
            });
    }

    // ============ Internal Functions ============

    function _setupPermit2Approval(address token) private {
        IERC20(token).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(token, address(UNIVERSAL_ROUTER), type(uint160).max, type(uint48).max);
    }

    /**
     * @notice Validate token and transfer input (ETH via msg.value, ERC20 via transferFrom)
     */
    function _validateAndTransferInput(address fromToken, uint256 amount) private {
        if (fromToken == ETH_ADDRESS) {
            if (msg.value != amount) revert ZapUniV4MCV2__InvalidETHAmount();
        } else if (fromToken == MT || fromToken == USDC) {
            IERC20(fromToken).safeTransferFrom(msg.sender, address(this), amount);
        } else {
            revert ZapUniV4MCV2__UnsupportedToken();
        }
    }

    /**
     * @notice Execute V4 swap to HUNT
     * @dev Pool configs: ETH/HUNT (zeroForOne=true), HUNT/USDC & HUNT/MT (zeroForOne=false)
     */
    function _executeV4Swap(address fromToken, uint256 amountIn) private returns (uint256 huntReceived) {
        uint256 huntBefore = IERC20(HUNT).balanceOf(address(this));

        (address currency0, address currency1, bool zeroForOne) = fromToken == ETH_ADDRESS
            ? (ETH_ADDRESS, HUNT, true)
            : (HUNT, fromToken, false);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _buildV4SwapInput(currency0, currency1, zeroForOne, uint128(amountIn));

        if (fromToken == ETH_ADDRESS) {
            UNIVERSAL_ROUTER.execute{value: amountIn}(commands, inputs, block.timestamp);
        } else {
            UNIVERSAL_ROUTER.execute(commands, inputs, block.timestamp);
        }

        huntReceived = IERC20(HUNT).balanceOf(address(this)) - huntBefore;
    }

    function _refundHUNT() private {
        uint256 balance = IERC20(HUNT).balanceOf(address(this));
        if (balance > 0) {
            IERC20(HUNT).safeTransfer(msg.sender, balance);
        }
    }

    /**
     * @notice Build V4 swap input for exact input single swap
     */
    function _buildV4SwapInput(
        address currency0,
        address currency1,
        bool zeroForOne,
        uint128 amountIn
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE)
        );

        bytes[] memory params = new bytes[](3);

        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        (address settleToken, address takeToken) = zeroForOne ? (currency0, currency1) : (currency1, currency0);

        params[0] = abi.encode(
            ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: bytes("")
            })
        );
        params[1] = abi.encode(settleToken, amountIn);
        params[2] = abi.encode(takeToken, address(this), ActionConstants.OPEN_DELTA);

        return abi.encode(actions, params);
    }
}
