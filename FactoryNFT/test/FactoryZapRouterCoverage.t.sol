// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IUnlockCallback } from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { BalanceDelta, toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";

import { IFactoryNFT } from "../src/interfaces/IFactoryNFT.sol";
import { FactoryZapRouter } from "../src/periphery/FactoryZapRouter.sol";

/// @dev Test-only forced balance change; created and destroyed in the same transaction.
contract ZapCoverageForcedEther {
    constructor(address recipient) payable {
        selfdestruct(payable(recipient));
    }
}

/// @dev Refund faults model hostile tokens/callbacks, not normal ERC20 behavior.
contract ZapCoverageToken is ERC20 {
    enum RefundFault {
        None,
        RetainInput,
        DonateHunt,
        ForceEther
    }

    address public refundRecipient;
    ZapCoverageToken public hunt;
    RefundFault public refundFault;

    constructor() ERC20("Coverage token", "COVER") { }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function configureRefund(address recipient, ZapCoverageToken hunt_, RefundFault fault)
        external
    {
        refundRecipient = recipient;
        hunt = hunt_;
        refundFault = fault;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == refundRecipient) {
            if (refundFault == RefundFault.RetainInput) return super.transfer(to, amount - 1);
            if (refundFault == RefundFault.DonateHunt) hunt.mint(msg.sender, 1);
            if (refundFault == RefundFault.ForceEther) {
                new ZapCoverageForcedEther{ value: 1 }(msg.sender);
            }
        }
        return super.transfer(to, amount);
    }
}

contract ZapCoverageFactory is IFactoryNFT {
    IERC20 public immutable huntToken;
    uint256 public price = 1_000e18;
    bool public shortPull;
    uint256 public minted;

    constructor(IERC20 hunt_) {
        huntToken = hunt_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setShortPull() external {
        shortPull = true;
    }

    function quoteMint(uint256 quantity) public view returns (uint256) {
        return price * quantity;
    }

    function mint(uint256 quantity, uint256, address) external returns (uint256 cost) {
        cost = quoteMint(quantity);
        require(huntToken.transferFrom(msg.sender, address(this), cost - (shortPull ? 1 : 0)));
        minted += quantity;
    }
}

/// @dev Fault injection only: this intentionally omits V4 invariants to exercise router guards.
/// Actual PoolManager integration is covered separately in FactoryZapRouter.t.sol.
contract ZapCoverageManager {
    enum Fault {
        None,
        MissingCallback,
        WrongInputDelta,
        ZeroOutputDelta,
        ShortOutputDelta,
        ShortSettle,
        ShortTake,
        WrongReturn
    }

    Fault public fault;
    Currency private input;
    uint256 private balanceAtSync;
    uint256 public constant COST = 1_000e18;

    function setFault(Fault fault_) external {
        fault = fault_;
    }

    function extsload(bytes32) external pure returns (bytes32) {
        return bytes32(uint256(1 << 96));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        if (fault == Fault.MissingCallback) return abi.encode(uint256(0));
        bytes memory result = IUnlockCallback(msg.sender).unlockCallback(data);
        if (fault == Fault.WrongReturn) return abi.encode(abi.decode(result, (uint256)) + 1);
        return result;
    }

    function swap(PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        view
        returns (BalanceDelta)
    {
        int128 spent = fault == Fault.WrongInputDelta ? int128(0) : -int128(uint128(COST));
        int128 output = int128(params.amountSpecified);
        if (fault == Fault.ZeroOutputDelta) output = 0;
        if (fault == Fault.ShortOutputDelta) --output;
        return params.zeroForOne ? toBalanceDelta(spent, output) : toBalanceDelta(output, spent);
    }

    function sync(Currency currency) external {
        input = currency;
        balanceAtSync = currency.balanceOfSelf();
    }

    function settle() external payable returns (uint256 amount) {
        amount = input.isAddressZero() ? msg.value : input.balanceOfSelf() - balanceAtSync;
        if (fault == Fault.ShortSettle) --amount;
    }

    function take(Currency currency, address receiver, uint256 amount) external {
        if (fault == Fault.ShortTake) --amount;
        require(IERC20(Currency.unwrap(currency)).transfer(receiver, amount));
    }
}

contract FactoryZapRouterCoverageTest is Test {
    ZapCoverageToken private hunt;
    ZapCoverageToken private input;
    ZapCoverageFactory private factory;
    ZapCoverageManager private manager;
    FactoryZapRouter private router;
    address private payer = makeAddr("coverage payer");
    address private receiver = makeAddr("coverage receiver");
    uint256 private constant COST = 1_000e18;
    uint256 private constant MAX_INPUT = 1_100e18;

    function setUp() public {
        hunt = new ZapCoverageToken();
        input = new ZapCoverageToken();
        factory = new ZapCoverageFactory(hunt);
        manager = new ZapCoverageManager();
        router = new FactoryZapRouter(factory, IPoolManager(address(manager)));
        hunt.mint(address(manager), 100 * COST);
        input.mint(payer, MAX_INPUT);
        vm.prank(payer);
        input.approve(address(router), MAX_INPUT);
        vm.deal(payer, MAX_INPUT);
    }

    function testConstructorRejectsMissingContractsAndInvalidHunt() public {
        vm.expectRevert(FactoryZapRouter.InvalidAddress.selector);
        new FactoryZapRouter(IFactoryNFT(address(0)), IPoolManager(address(manager)));
        vm.expectRevert(FactoryZapRouter.InvalidAddress.selector);
        new FactoryZapRouter(factory, IPoolManager(address(0)));
        ZapCoverageFactory noHunt = new ZapCoverageFactory(IERC20(address(0)));
        vm.expectRevert(FactoryZapRouter.InvalidAddress.selector);
        new FactoryZapRouter(noHunt, IPoolManager(address(manager)));
        ZapCoverageFactory eoaHunt = new ZapCoverageFactory(IERC20(payer));
        vm.expectRevert(FactoryZapRouter.InvalidAddress.selector);
        new FactoryZapRouter(eoaHunt, IPoolManager(address(manager)));
    }

    function testRejectsBothInvalidReceiversAndBothZeroAmounts() public {
        PoolKey[] memory route = _route(address(input));
        vm.expectRevert(FactoryZapRouter.InvalidAddress.selector);
        router.zapMint(1, address(input), MAX_INPUT, route, address(0), block.timestamp);
        vm.expectRevert(FactoryZapRouter.InvalidAddress.selector);
        router.zapMint(1, address(input), MAX_INPUT, route, address(router), block.timestamp);
        vm.expectRevert(FactoryZapRouter.InvalidAmount.selector);
        router.zapMint(0, address(input), MAX_INPUT, route, receiver, block.timestamp);
        vm.expectRevert(FactoryZapRouter.InvalidAmount.selector);
        router.zapMint(1, address(input), 0, route, receiver, block.timestamp);
    }

    function testRejectsUnexpectedEtherWithErc20AndIncorrectNativeAmount() public {
        vm.deal(address(this), 2);
        vm.expectRevert(FactoryZapRouter.InvalidMsgValue.selector);
        router.zapMint{ value: 1 }(
            1, address(input), MAX_INPUT, _route(address(input)), receiver, block.timestamp
        );
        vm.expectRevert(FactoryZapRouter.InvalidMsgValue.selector);
        router.zapMint{ value: 1 }(
            1, address(0), MAX_INPUT, _route(address(0)), receiver, block.timestamp
        );
    }

    function testRejectsZeroFactoryQuoteAndInsufficientDirectMaximum() public {
        factory.setPrice(0);
        vm.expectRevert(FactoryZapRouter.InvalidAmount.selector);
        router.zapMint(1, address(hunt), MAX_INPUT, new PoolKey[](0), receiver, block.timestamp);
        factory.setPrice(COST);
        vm.expectRevert(
            abi.encodeWithSelector(FactoryZapRouter.ExcessiveInput.selector, COST, COST - 1)
        );
        router.zapMint(1, address(hunt), COST - 1, new PoolKey[](0), receiver, block.timestamp);
    }

    function testRejectsOutOfRangeFeeMaximumFeeAndExcessiveTickSpacing() public {
        PoolKey[] memory route = _route(address(input));
        route[0].fee = LPFeeLibrary.MAX_LP_FEE + 1;
        _expectInvalidPool(route);
        route[0].fee = LPFeeLibrary.MAX_LP_FEE;
        _expectInvalidPool(route);
        route[0].fee = 3_000;
        route[0].tickSpacing = TickMath.MAX_TICK_SPACING + 1;
        _expectInvalidPool(route);
    }

    function testFaultInjectionRejectsMissingUnlockCallback() public {
        _expectManagerFault(
            ZapCoverageManager.Fault.MissingCallback, FactoryZapRouter.UnauthorizedCallback.selector
        );
    }

    function testFaultInjectionRejectsEveryInvalidSwapDeltaShape() public {
        _expectManagerFault(
            ZapCoverageManager.Fault.WrongInputDelta, FactoryZapRouter.InexactSwap.selector
        );
        _expectManagerFault(
            ZapCoverageManager.Fault.ZeroOutputDelta, FactoryZapRouter.InexactSwap.selector
        );
        _expectManagerFault(
            ZapCoverageManager.Fault.ShortOutputDelta, FactoryZapRouter.InexactSwap.selector
        );
    }

    function testFaultInjectionRejectsInexactSettlement() public {
        _expectManagerFault(
            ZapCoverageManager.Fault.ShortSettle, FactoryZapRouter.InexactTransfer.selector
        );
    }

    function testFaultInjectionRejectsWrongReturnedInputAndMissingOutput() public {
        _expectManagerFault(
            ZapCoverageManager.Fault.WrongReturn, FactoryZapRouter.InexactSwap.selector
        );
        _expectManagerFault(
            ZapCoverageManager.Fault.ShortTake, FactoryZapRouter.InexactSwap.selector
        );
    }

    function testFaultInjectionRejectsCorrectMintReportWithIncorrectActualPull() public {
        factory.setShortPull();
        vm.expectRevert(FactoryZapRouter.InexactMint.selector);
        _zap();
        _assertRollback();
    }

    function testFaultInjectionRejectsRefundInputHuntAndNativeBalanceChanges() public {
        vm.deal(address(input), 1);
        for (uint256 i = 1; i <= uint256(ZapCoverageToken.RefundFault.ForceEther); ++i) {
            input.configureRefund(payer, hunt, ZapCoverageToken.RefundFault(i));
            vm.expectRevert(FactoryZapRouter.UnexpectedBalance.selector);
            _zap();
            _assertRollback();
        }
    }

    function testExactNativeInputNeedsNoRefund() public {
        uint256 beforeBalance = payer.balance;
        vm.prank(payer);
        (uint256 spent, uint256 huntSpent) = router.zapMint{ value: COST }(
            1, address(0), COST, _route(address(0)), receiver, block.timestamp
        );
        assertEq(spent, COST);
        assertEq(huntSpent, COST);
        assertEq(payer.balance, beforeBalance - COST);
        assertEq(factory.minted(), 1);
        assertEq(address(router).balance, 0);
        assertEq(hunt.allowance(address(router), address(factory)), 0);
    }

    function _expectManagerFault(ZapCoverageManager.Fault fault, bytes4 errorSelector) private {
        manager.setFault(fault);
        vm.expectRevert(errorSelector);
        _zap();
        _assertRollback();
    }

    function _expectInvalidPool(PoolKey[] memory route) private {
        vm.expectRevert(abi.encodeWithSelector(FactoryZapRouter.InvalidPool.selector, uint256(0)));
        router.zapMint(1, address(input), MAX_INPUT, route, receiver, block.timestamp);
    }

    function _zap() private {
        vm.prank(payer);
        router.zapMint(
            1, address(input), MAX_INPUT, _route(address(input)), receiver, block.timestamp
        );
    }

    function _assertRollback() private view {
        assertEq(input.balanceOf(payer), MAX_INPUT);
        assertEq(input.balanceOf(address(router)), 0);
        assertEq(hunt.balanceOf(address(router)), 0);
        assertEq(hunt.balanceOf(address(factory)), 0);
        assertEq(hunt.allowance(address(router), address(factory)), 0);
        assertEq(factory.minted(), 0);
        assertEq(address(router).balance, 0);
    }

    function _route(address inputAddress) private view returns (PoolKey[] memory route) {
        route = new PoolKey[](1);
        (address token0, address token1) = inputAddress < address(hunt)
            ? (inputAddress, address(hunt))
            : (address(hunt), inputAddress);
        route[0] =
            PoolKey(Currency.wrap(token0), Currency.wrap(token1), 3_000, 60, IHooks(address(0)));
    }
}
