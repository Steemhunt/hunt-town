// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC1155Receiver } from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { TickMath } from "@uniswap/v4-core/src/libraries/TickMath.sol";
import { LPFeeLibrary } from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { FactoryZapRouter } from "../src/periphery/FactoryZapRouter.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { IFactoryNFT } from "../src/interfaces/IFactoryNFT.sol";

contract ZapTestToken is ERC20 {
    bool public taxed;
    bool public noReturn;
    uint8 private immutable tokenDecimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function setNoReturn(bool value) external {
        noReturn = value;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool result = super.transfer(to, amount);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return result;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return result;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (taxed && from != address(0) && to != address(0)) {
            uint256 fee = amount / 100;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract ZapMintTarget is IFactoryNFT {
    using SafeERC20 for IERC20;
    IERC20 public immutable huntToken;
    mapping(address => uint256) public minted;
    bool public rejectMint;
    bool public misreportMint;

    constructor(IERC20 hunt_) {
        huntToken = hunt_;
    }

    function quoteMint(uint256 amount) public pure returns (uint256) {
        return amount * 1_000e18;
    }

    function setRejectMint(bool value) external {
        rejectMint = value;
    }

    function setMisreportMint(bool value) external {
        misreportMint = value;
    }

    function mint(uint256 amount, uint256 maxHuntIn, address receiver) external returns (uint256) {
        require(!rejectMint, "Mint rejected");
        uint256 cost = quoteMint(amount);
        require(cost <= maxHuntIn, "Maximum exceeded");
        huntToken.safeTransferFrom(msg.sender, address(this), cost);
        minted[receiver] += amount;
        if (receiver.code.length != 0) {
            require(
                IERC1155Receiver(receiver).onERC1155Received(msg.sender, address(0), 0, amount, "")
                    == IERC1155Receiver.onERC1155Received.selector,
                "Receiver rejected"
            );
        }
        return misreportMint ? cost + 1 : cost;
    }
}

contract ZapCallbackReceiver {
    FactoryZapRouter public immutable router;
    address public immutable hunt;
    bool public reject;
    bool public attempted;
    bool public reentered;

    constructor(FactoryZapRouter router_, address hunt_) {
        router = router_;
        hunt = hunt_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        returns (bytes4)
    {
        require(!reject, "Receiver rejected");
        attempted = true;
        PoolKey[] memory route = new PoolKey[](0);
        (reentered,) = address(router)
            .call(
                abi.encodeCall(
                    router.zapMint, (1, hunt, 1_000e18, route, address(this), block.timestamp)
                )
            );
        return IERC1155Receiver.onERC1155Received.selector;
    }
}

contract ZapRejectingPayer {
    function mint(FactoryZapRouter router, PoolKey[] calldata route, address receiver)
        external
        payable
    {
        router.zapMint{ value: msg.value }(
            1, address(0), msg.value, route, receiver, block.timestamp
        );
    }
}

contract FactoryZapRouterTest is Test {
    IPoolManager internal manager;
    PoolModifyLiquidityTest internal liquidityRouter;
    ZapTestToken internal hunt;
    ZapTestToken internal usdc;
    ZapTestToken internal usdt;
    ZapTestToken internal dai;
    ZapMintTarget internal factory;
    FactoryZapRouter internal router;
    address internal payer = makeAddr("payer");
    address internal receiver = makeAddr("receiver");
    PoolKey internal huntEth;
    PoolKey internal usdcEth;
    PoolKey internal usdtEth;
    PoolKey internal daiEth;

    receive() external payable { }

    function setUp() public {
        manager = IPoolManager(
            vm.deployCode("PoolManagerArtifact.sol:PoolManagerArtifact", abi.encode(address(this)))
        );
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        hunt = new ZapTestToken("HUNT", 18);
        usdc = new ZapTestToken("USDC", 6);
        usdt = new ZapTestToken("USDT", 6);
        dai = new ZapTestToken("DAI", 18);
        factory = new ZapMintTarget(hunt);
        router = new FactoryZapRouter(factory, manager);
        huntEth = _pool(address(0), address(hunt), -887220, 887220, 1e27);
        usdcEth = _pool(address(0), address(usdc), -887220, 887220, 1e27);
        usdtEth = _pool(address(0), address(usdt), -887220, 887220, 1e27);
        daiEth = _pool(address(0), address(dai), -887220, 887220, 1e27);
        vm.deal(payer, 1e27);
    }

    function testNativeExactOutputRefundsPayerAndMintsToReceiver() public {
        uint256 before = payer.balance;
        vm.prank(payer);
        (uint256 spent, uint256 cost) = router.zapMint{ value: 1_100e18 }(
            1, address(0), 1_100e18, _single(huntEth), receiver, block.timestamp
        );
        assertGt(spent, 1_000e18);
        assertLt(spent, 1_100e18);
        assertEq(cost, 1_000e18);
        assertEq(payer.balance, before - spent);
        _assertMint(1);
    }

    function testStableRoutesUseNativeIntermediateWithoutWeth() public {
        _assertStableMint(usdc, usdcEth);
        usdt.setNoReturn(true);
        _assertStableMint(usdt, usdtEth);
        _assertStableMint(dai, daiEth);
        _assertMint(3);
    }

    function testDirectHuntBypassesSwapAndRefundsExcess() public {
        _fund(hunt, 2_500e18);
        vm.prank(payer);
        (uint256 spent, uint256 cost) = router.zapMint(
            2, address(hunt), 2_500e18, new PoolKey[](0), receiver, block.timestamp
        );
        assertEq(spent, 2_000e18);
        assertEq(cost, spent);
        assertEq(hunt.balanceOf(payer), 500e18);
        _assertMint(2);
    }

    function testRealFactoryMintsAtIncreasedNavThroughNativeIntermediate() public {
        address seedOwner = makeAddr("seed owner");
        bytes32 salt = keccak256("Router integration factory");
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(FactoryNFT).creationCode,
                abi.encode(
                    hunt, address(this), seedOwner, "ipfs://factory/{id}.json", payer, address(0)
                )
            )
        );
        address predicted = vm.computeCreate2Address(salt, initCodeHash, address(this));
        hunt.approve(predicted, 1_000e18);
        FactoryNFT realFactory = new FactoryNFT{ salt: salt }(
            hunt, address(this), seedOwner, "ipfs://factory/{id}.json", payer, address(0)
        );
        FactoryZapRouter realRouter = new FactoryZapRouter(realFactory, manager);
        hunt.mint(address(realFactory), 123e18);
        uint256 cost = realFactory.quoteMint(2);
        assertEq(cost, 2_246e18);
        usdc.mint(payer, 2_500e18);
        vm.startPrank(payer);
        usdc.approve(address(realRouter), 2_500e18);
        (uint256 spent, uint256 huntSpent) = realRouter.zapMint(
            2, address(usdc), 2_500e18, _stableRoute(usdcEth), receiver, block.timestamp
        );
        vm.stopPrank();
        assertEq(huntSpent, cost);
        assertEq(realFactory.balanceOf(receiver, 0), 2);
        assertEq(realFactory.balanceOf(address(realRouter), 0), 0);
        assertEq(realFactory.totalSupply(0), 3);
        assertEq(realFactory.navPerNFT(), 1_123e18);
        assertEq(usdc.balanceOf(payer), 2_500e18 - spent);
        assertEq(usdc.balanceOf(address(realRouter)), 0);
        assertEq(hunt.balanceOf(address(realRouter)), 0);
        assertEq(hunt.allowance(address(realRouter), address(realFactory)), 0);
    }

    function testThreeHopsAndBothPoolDirections() public {
        PoolKey memory stablePair = _pool(address(usdc), address(dai), -887220, 887220, 1e27);
        PoolKey[] memory route = new PoolKey[](3);
        route[0] = stablePair;
        route[1] = daiEth;
        route[2] = huntEth;
        _fund(usdc, 1_100e18);
        vm.prank(payer);
        (uint256 spent,) =
            router.zapMint(1, address(usdc), 1_100e18, route, receiver, block.timestamp);
        assertEq(usdc.balanceOf(payer), 1_100e18 - spent);
        assertEq(dai.balanceOf(address(router)), 0);
        _assertMint(1);
    }

    function testPreservesDonatedTokensAndForcedEth() public {
        usdc.mint(address(router), 7e18);
        hunt.mint(address(router), 8e18);
        dai.mint(address(router), 9e18);
        vm.deal(address(router), 10e18);
        _assertStableMint(usdc, usdcEth);
        assertEq(usdc.balanceOf(address(router)), 7e18);
        assertEq(hunt.balanceOf(address(router)), 8e18);
        assertEq(dai.balanceOf(address(router)), 9e18);
        assertEq(address(router).balance, 10e18);
        assertEq(hunt.allowance(address(router), address(factory)), 0);
    }

    function testInsufficientMaximumRollsBackFundingAndPoolState() public {
        _fund(usdc, 1_000e18);
        vm.expectPartialRevert(FactoryZapRouter.ExcessiveInput.selector);
        vm.prank(payer);
        router.zapMint(1, address(usdc), 1_000e18, _stableRoute(usdcEth), receiver, block.timestamp);
        assertEq(usdc.balanceOf(payer), 1_000e18);
        _assertMint(0);
        _assertStableMint(usdc, usdcEth);
    }

    function testPartialOutputReverts() public {
        ZapTestToken thin = new ZapTestToken("THIN", 18);
        PoolKey memory thinPool = _pool(address(thin), address(hunt), -60, 60, 1e12);
        _fund(thin, 1_100e18);
        vm.expectRevert(FactoryZapRouter.InexactSwap.selector);
        vm.prank(payer);
        router.zapMint(1, address(thin), 1_100e18, _single(thinPool), receiver, block.timestamp);
        assertEq(thin.balanceOf(payer), 1_100e18);
        _assertMint(0);
    }

    function testRejectsTaxedInputAndTaxedHuntOutput() public {
        _fund(usdc, 1_100e18);
        usdc.setTaxed(true);
        vm.expectRevert(FactoryZapRouter.InexactTransfer.selector);
        vm.prank(payer);
        router.zapMint(1, address(usdc), 1_100e18, _stableRoute(usdcEth), receiver, block.timestamp);
        usdc.setTaxed(false);
        hunt.setTaxed(true);
        vm.expectRevert(FactoryZapRouter.InexactSwap.selector);
        vm.prank(payer);
        router.zapMint(1, address(usdc), 1_100e18, _stableRoute(usdcEth), receiver, block.timestamp);
        assertEq(usdc.balanceOf(payer), 1_100e18);
        _assertMint(0);
    }

    function testMintFailureAndMisreportedConsumptionRollBackSwap() public {
        _fund(usdc, 1_100e18);
        factory.setRejectMint(true);
        vm.expectRevert("Mint rejected");
        vm.prank(payer);
        router.zapMint(1, address(usdc), 1_100e18, _stableRoute(usdcEth), receiver, block.timestamp);
        factory.setRejectMint(false);
        factory.setMisreportMint(true);
        vm.expectRevert(FactoryZapRouter.InexactMint.selector);
        vm.prank(payer);
        router.zapMint(1, address(usdc), 1_100e18, _stableRoute(usdcEth), receiver, block.timestamp);
        assertEq(usdc.balanceOf(payer), 1_100e18);
        _assertMint(0);
    }

    function testReceiverCallbackCannotReenter() public {
        ZapCallbackReceiver callback = new ZapCallbackReceiver(router, address(hunt));
        _fund(hunt, 1_000e18);
        vm.prank(payer);
        router.zapMint(
            1, address(hunt), 1_000e18, new PoolKey[](0), address(callback), block.timestamp
        );
        assertTrue(callback.attempted());
        assertFalse(callback.reentered());
        assertEq(factory.minted(address(callback)), 1);
    }

    function testRejectedReceiverAndNativeRefundRollBack() public {
        ZapCallbackReceiver callback = new ZapCallbackReceiver(router, address(hunt));
        callback.setReject(true);
        vm.expectRevert("Receiver rejected");
        vm.prank(payer);
        router.zapMint{ value: 1_100e18 }(
            1, address(0), 1_100e18, _single(huntEth), address(callback), block.timestamp
        );
        ZapRejectingPayer rejectingPayer = new ZapRejectingPayer();
        vm.expectRevert(FactoryZapRouter.NativeRefundFailed.selector);
        rejectingPayer.mint{ value: 1_100e18 }(router, _single(huntEth), receiver);
        _assertMint(0);
    }

    function testRejectsExpiredDeadlineInvalidValueAndCallback() public {
        vm.warp(100);
        vm.expectRevert(FactoryZapRouter.DeadlineExpired.selector);
        router.zapMint(1, address(hunt), 1_000e18, new PoolKey[](0), receiver, 99);
        vm.expectRevert(FactoryZapRouter.InvalidMsgValue.selector);
        router.zapMint(1, address(0), 1_000e18, _single(huntEth), receiver, 100);
        vm.expectRevert(FactoryZapRouter.UnauthorizedCallback.selector);
        router.unlockCallback("");
        vm.expectRevert(FactoryZapRouter.UnauthorizedCallback.selector);
        vm.prank(address(manager));
        router.unlockCallback("");
    }

    function testRejectsHookedDynamicUninitializedAndInvalidPools() public {
        PoolKey[] memory route = _single(huntEth);
        route[0].hooks = IHooks(address(1));
        _expectInvalidNativePool(route);
        route[0] = huntEth;
        route[0].fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        _expectInvalidNativePool(route);
        route[0] = huntEth;
        route[0].fee = 500;
        _expectInvalidNativePool(route);
        route[0] = huntEth;
        route[0].tickSpacing = 0;
        _expectInvalidNativePool(route);
        route[0] = huntEth;
        route[0].currency0 = route[0].currency1;
        _expectInvalidNativePool(route);
    }

    function testRejectsDisconnectedWrongEndCyclicAndOverlongRoutes() public {
        _fund(usdc, 1_100e18);
        PoolKey[] memory route = _single(huntEth);
        _expectInvalidStableRoute(route);
        route = _single(usdcEth);
        _expectInvalidStableRoute(route);
        route = new PoolKey[](3);
        route[0] = usdcEth;
        route[1] = usdcEth;
        route[2] = huntEth;
        _expectInvalidStableRoute(route);
        _expectInvalidStableRoute(new PoolKey[](4));
        _expectInvalidStableRoute(new PoolKey[](0));
        vm.expectRevert(FactoryZapRouter.InvalidRoute.selector);
        router.zapMint(1, address(hunt), 1_000e18, _single(huntEth), receiver, block.timestamp);
    }

    function testFuzzDirectHuntPreservesDust(uint32 quantitySeed, uint96 refundSeed) public {
        uint256 quantity = bound(quantitySeed, 1, 100);
        uint256 cost = factory.quoteMint(quantity);
        uint256 refund = uint256(refundSeed);
        hunt.mint(address(router), 77);
        _fund(hunt, cost + refund);
        vm.prank(payer);
        router.zapMint(
            quantity, address(hunt), cost + refund, new PoolKey[](0), receiver, block.timestamp
        );
        assertEq(factory.minted(receiver), quantity);
        assertEq(hunt.balanceOf(payer), refund);
        assertEq(hunt.balanceOf(address(router)), 77);
        assertEq(hunt.allowance(address(router), address(factory)), 0);
    }

    function _assertStableMint(ZapTestToken token, PoolKey memory first) private {
        uint256 before = token.balanceOf(payer);
        _fund(token, 1_100e18);
        vm.prank(payer);
        (uint256 spent, uint256 cost) = router.zapMint(
            1, address(token), 1_100e18, _stableRoute(first), receiver, block.timestamp
        );
        assertEq(cost, 1_000e18);
        assertGt(spent, cost);
        assertLt(spent, 1_100e18);
        assertEq(token.balanceOf(payer), before + 1_100e18 - spent);
        assertEq(token.allowance(address(router), address(manager)), 0);
    }

    function _assertMint(uint256 quantity) private view {
        assertEq(factory.minted(receiver), quantity);
        assertEq(hunt.balanceOf(address(factory)), quantity * 1_000e18);
        assertEq(hunt.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        assertEq(hunt.allowance(address(router), address(factory)), 0);
    }

    function _fund(ZapTestToken token, uint256 amount) private {
        token.mint(payer, amount);
        vm.prank(payer);
        token.approve(address(router), amount);
    }

    function _single(PoolKey memory key) private pure returns (PoolKey[] memory route) {
        route = new PoolKey[](1);
        route[0] = key;
    }

    function _stableRoute(PoolKey memory first) private view returns (PoolKey[] memory route) {
        route = new PoolKey[](2);
        route[0] = first;
        route[1] = huntEth;
    }

    function _expectInvalidNativePool(PoolKey[] memory route) private {
        vm.expectPartialRevert(FactoryZapRouter.InvalidPool.selector);
        router.zapMint{ value: 1_100e18 }(1, address(0), 1_100e18, route, receiver, block.timestamp);
    }

    function _expectInvalidStableRoute(PoolKey[] memory route) private {
        vm.expectRevert(FactoryZapRouter.InvalidRoute.selector);
        vm.prank(payer);
        router.zapMint(1, address(usdc), 1_100e18, route, receiver, block.timestamp);
    }

    function _pool(address a, address b, int24 lower, int24 upper, int256 liquidity)
        private
        returns (PoolKey memory key)
    {
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        key = PoolKey(Currency.wrap(token0), Currency.wrap(token1), 3_000, 60, IHooks(address(0)));
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        vm.deal(address(this), 1e32);
        if (token0 != address(0)) {
            ZapTestToken(token0).mint(address(this), 1e32);
            IERC20(token0).approve(address(liquidityRouter), type(uint256).max);
        }
        ZapTestToken(token1).mint(address(this), 1e32);
        IERC20(token1).approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity{ value: token0 == address(0) ? 1e30 : 0 }(
            key, ModifyLiquidityParams(lower, upper, liquidity, bytes32(0)), bytes("")
        );
    }
}
