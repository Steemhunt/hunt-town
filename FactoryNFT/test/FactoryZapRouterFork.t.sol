// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryZapRouter } from "../src/periphery/FactoryZapRouter.sol";

/// @dev Models an unsolicited ETH transfer without editing the router's balance or code.
contract ForkForcedEther {
    constructor(address recipient) payable {
        selfdestruct(payable(recipient));
    }
}

/// @notice Real Ethereum tokens and initialized Uniswap V4 pools at a fixed block.
/// @dev Only user funding uses deal. Pool state and deployed token code are never replaced.
contract FactoryZapRouterForkTest is Test {
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint256 internal constant MAINNET_BLOCK = 26_039_501;
    address internal constant HUNT = 0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IPoolManager internal constant MANAGER =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    address internal constant VALIDATOR = 0xA000027A9B2802E1ddf7000061001e5c005A0000;
    uint256 internal constant INITIAL_NAV = 1_000e18;
    uint256 internal constant DONATION = 123.323e18;
    uint256 internal constant NAV = INITIAL_NAV + DONATION;

    bool internal forkEnabled;
    FactoryNFT internal factory;
    FactoryZapRouter internal router;
    address internal payer = makeAddr("fork payer");
    address internal receiver = makeAddr("fork receiver");
    address internal seedOwner = makeAddr("fork seed owner");
    PoolKey internal huntEth;
    PoolKey internal usdcEth;
    PoolKey internal usdtEth;
    PoolKey internal daiUsdc;

    modifier onMainnetFork() {
        vm.skip(!forkEnabled, "Set MAINNET_RPC_URL to run optional Ethereum fork tests");
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl, MAINNET_BLOCK);
        forkEnabled = true;
        assertEq(block.chainid, 1, "Expected Ethereum mainnet");
        assertEq(block.number, MAINNET_BLOCK);

        // At this block the live hookless native ETH/HUNT pool is 1% / spacing 200.
        // The initially assumed 0.3% / spacing 60 pool is not initialized.
        huntEth = _key(address(0), HUNT, 10_000, 200);
        usdcEth = _key(address(0), USDC, 500, 10);
        usdtEth = _key(address(0), USDT, 500, 10);
        daiUsdc = _key(DAI, USDC, 100, 1);

        deal(HUNT, address(this), NAV);
        bytes32 salt = keccak256("real mainnet factory zap tests");
        bytes memory constructorArgs = abi.encode(
            IERC20(HUNT), address(this), seedOwner, "ipfs://factory/{id}.json", receiver, VALIDATOR
        );
        address predicted = vm.computeCreate2Address(
            salt,
            keccak256(abi.encodePacked(type(FactoryNFT).creationCode, constructorArgs)),
            address(this)
        );
        IERC20(HUNT).forceApprove(predicted, INITIAL_NAV);
        factory = new FactoryNFT{ salt: salt }(
            IERC20(HUNT), address(this), seedOwner, "ipfs://factory/{id}.json", receiver, VALIDATOR
        );
        assertEq(address(factory), predicted);
        IERC20(HUNT).safeTransfer(address(factory), DONATION);
        router = new FactoryZapRouter(factory, MANAGER);
        assertEq(factory.navPerNFT(), NAV);
    }

    function testForkPoolFixturesAreInitializedAndLiquid() public onMainnetFork {
        _assertPool(huntEth, 0x74a8c26c919ecb7cdb81ceb87ec9582ef66bcd7dea454bc67158ae2cc545d190);
        _assertPool(usdcEth, 0x21c67e77068de97969ba93d4aab21826d33ca12bb9f565d8496e8fda8a82ca27);
        _assertPool(usdtEth, 0x72331fcb696b0151904c03584b66dc8365bc63f8a144d89a773384e3a579ca73);
        _assertPool(daiUsdc, 0xd967702f17f83d907b36e66c9a62eb50ac327432c581d5b273a76519692434be);
        (uint160 absentPrice,,,) = MANAGER.getSlot0(_key(address(0), HUNT, 3_000, 60).toId());
        assertEq(absentPrice, 0, "Do not substitute the assumed 0.3% pool for the live pool");
    }

    function testForkNativeEthMintsAtCurrentNavAndRefundsPayer() public onMainnetFork {
        uint256 maxInput = 1 ether;
        deal(payer, maxInput);
        uint256 managerEth = address(MANAGER).balance;
        uint256 managerHunt = IERC20(HUNT).balanceOf(address(MANAGER));
        vm.prank(payer);
        (uint256 spent, uint256 huntIn) = router.zapMint{ value: maxInput }(
            2, address(0), maxInput, _route(address(0)), receiver, block.timestamp
        );
        assertGt(spent, 0);
        assertLt(spent, maxInput);
        assertEq(payer.balance, maxInput - spent);
        assertEq(receiver.balance, 0, "Only the payer receives the refund");
        assertEq(address(MANAGER).balance, managerEth + spent);
        assertEq(IERC20(HUNT).balanceOf(address(MANAGER)), managerHunt - huntIn);
        assertEq(IERC20(HUNT).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        _assertMint(huntIn);
    }

    function testForkUsdcViaNativeEthMintsAndRefunds() public onMainnetFork {
        _mintWithToken(USDC, _route(USDC), 1_000e6);
    }

    function testForkUsdtNoReturnTransfersViaNativeEthMintsAndRefunds() public onMainnetFork {
        _mintWithToken(USDT, _route(USDT), 1_000e6);
    }

    function testForkDaiViaUsdcAndNativeEthMintsAndRefunds() public onMainnetFork {
        _mintWithToken(DAI, _route(DAI), 1_000e18);
    }

    function testForkDirectHuntMintsWithoutTouchingPools() public onMainnetFork {
        uint256 maxInput = 3_000e18;
        deal(HUNT, payer, maxInput);
        bytes32 poolBefore = _poolState(huntEth);
        uint256 managerHunt = IERC20(HUNT).balanceOf(address(MANAGER));
        vm.startPrank(payer);
        IERC20(HUNT).forceApprove(address(router), maxInput);
        (uint256 spent, uint256 huntIn) =
            router.zapMint(2, HUNT, maxInput, new PoolKey[](0), receiver, block.timestamp);
        vm.stopPrank();
        assertEq(spent, 2 * NAV);
        assertEq(IERC20(HUNT).balanceOf(payer), maxInput - spent);
        assertEq(IERC20(HUNT).balanceOf(receiver), 0);
        assertEq(IERC20(HUNT).balanceOf(address(MANAGER)), managerHunt);
        assertEq(IERC20(HUNT).balanceOf(address(router)), 0);
        assertEq(IERC20(HUNT).allowance(payer, address(router)), 0);
        assertEq(_poolState(huntEth), poolBefore);
        _assertMint(huntIn);
    }

    function testForkUsdcSwapPreservesDonatedTokenAndForcedEthDust() public onMainnetFork {
        deal(HUNT, address(this), 23);
        deal(USDC, address(this), 17);
        deal(address(this), 31);
        IERC20(HUNT).safeTransfer(address(router), 23);
        IERC20(USDC).safeTransfer(address(router), 17);
        new ForkForcedEther{ value: 31 }(address(router));
        _mintWithToken(USDC, _route(USDC), 1_000e6);
        assertEq(IERC20(HUNT).balanceOf(address(router)), 23);
        assertEq(IERC20(USDC).balanceOf(address(router)), 17);
        assertEq(address(router).balance, 31);
    }

    function testForkInsufficientUsdcLimitRollsBackEveryHopAndAllowance() public onMainnetFork {
        deal(USDC, payer, 1);
        vm.prank(payer);
        IERC20(USDC).forceApprove(address(router), 1);
        bytes32 huntBefore = _poolState(huntEth);
        bytes32 usdcBefore = _poolState(usdcEth);
        uint256 managerUsdc = IERC20(USDC).balanceOf(address(MANAGER));
        uint256 managerHunt = IERC20(HUNT).balanceOf(address(MANAGER));
        vm.expectPartialRevert(FactoryZapRouter.ExcessiveInput.selector);
        vm.prank(payer);
        router.zapMint(2, USDC, 1, _route(USDC), receiver, block.timestamp);
        assertEq(IERC20(USDC).balanceOf(payer), 1);
        assertEq(IERC20(USDC).allowance(payer, address(router)), 1);
        assertEq(IERC20(USDC).balanceOf(address(MANAGER)), managerUsdc);
        assertEq(IERC20(HUNT).balanceOf(address(MANAGER)), managerHunt);
        assertEq(IERC20(USDC).balanceOf(address(router)), 0);
        assertEq(IERC20(HUNT).balanceOf(address(router)), 0);
        assertEq(_poolState(huntEth), huntBefore);
        assertEq(_poolState(usdcEth), usdcBefore);
        assertEq(factory.totalSupply(0), 1);
        assertEq(factory.balanceOf(receiver, 0), 0);
        assertEq(IERC20(HUNT).balanceOf(address(factory)), NAV);
    }

    function testForkInsufficientEthLimitRollsBackPoolAndPayment() public onMainnetFork {
        deal(payer, 1);
        bytes32 poolBefore = _poolState(huntEth);
        uint256 managerEth = address(MANAGER).balance;
        vm.expectPartialRevert(FactoryZapRouter.ExcessiveInput.selector);
        vm.prank(payer);
        router.zapMint{ value: 1 }(2, address(0), 1, _route(address(0)), receiver, block.timestamp);
        assertEq(payer.balance, 1);
        assertEq(address(router).balance, 0);
        assertEq(address(MANAGER).balance, managerEth);
        assertEq(_poolState(huntEth), poolBefore);
        assertEq(factory.totalSupply(0), 1);
        assertEq(IERC20(HUNT).balanceOf(address(factory)), NAV);
    }

    function _mintWithToken(address input, PoolKey[] memory route, uint256 maxInput) private {
        IERC20 token = IERC20(input);
        deal(input, payer, maxInput);
        uint256 routerInput = token.balanceOf(address(router));
        uint256 routerHunt = IERC20(HUNT).balanceOf(address(router));
        uint256 routerEth = address(router).balance;
        uint256 managerEth = address(MANAGER).balance;
        uint256 managerInput = token.balanceOf(address(MANAGER));
        uint256 managerHunt = IERC20(HUNT).balanceOf(address(MANAGER));
        vm.startPrank(payer);
        token.forceApprove(address(router), maxInput);
        (uint256 spent, uint256 huntIn) =
            router.zapMint(2, input, maxInput, route, receiver, block.timestamp);
        vm.stopPrank();
        assertGt(spent, 0);
        assertLt(spent, maxInput);
        assertEq(token.balanceOf(payer), maxInput - spent);
        assertEq(token.balanceOf(receiver), 0, "Only the payer receives the refund");
        assertEq(token.balanceOf(address(MANAGER)), managerInput + spent);
        assertEq(IERC20(HUNT).balanceOf(address(MANAGER)), managerHunt - huntIn);
        assertEq(address(MANAGER).balance, managerEth, "Intermediate native ETH nets inside V4");
        assertEq(token.balanceOf(address(router)), routerInput);
        assertEq(IERC20(HUNT).balanceOf(address(router)), routerHunt);
        assertEq(address(router).balance, routerEth);
        assertEq(token.allowance(payer, address(router)), 0);
        assertEq(token.allowance(address(router), address(MANAGER)), 0);
        _assertMint(huntIn);
    }

    function _assertMint(uint256 huntIn) private view {
        assertEq(huntIn, 2 * NAV);
        assertEq(factory.balanceOf(receiver, 0), 2);
        assertEq(factory.balanceOf(seedOwner, 0), 1);
        assertEq(factory.totalSupply(0), 3);
        assertEq(IERC20(HUNT).balanceOf(address(factory)), 3 * NAV);
        assertEq(IERC20(HUNT).balanceOf(receiver), 0);
        assertEq(factory.navPerNFT(), NAV, "Minting must not dilute existing backing");
        assertEq(IERC20(HUNT).allowance(address(router), address(factory)), 0);
    }

    function _assertPool(PoolKey memory key, bytes32 expectedId) private view {
        PoolId poolId = key.toId();
        assertEq(PoolId.unwrap(poolId), expectedId);
        (uint160 price,,, uint24 fee) = MANAGER.getSlot0(poolId);
        assertGt(price, 0);
        assertEq(fee, key.fee);
        assertGt(MANAGER.getLiquidity(poolId), 0);
    }

    function _poolState(PoolKey memory key) private view returns (bytes32) {
        bytes32 slot = keccak256(abi.encode(key.toId(), uint256(6)));
        return keccak256(abi.encode(MANAGER.extsload(slot, 4)));
    }

    function _route(address input) private view returns (PoolKey[] memory route) {
        route = new PoolKey[](input == address(0) ? 1 : input == DAI ? 3 : 2);
        if (input == DAI) {
            route[0] = daiUsdc;
            route[1] = usdcEth;
        } else if (input == USDC) {
            route[0] = usdcEth;
        } else if (input == USDT) {
            route[0] = usdtEth;
        }
        route[route.length - 1] = huntEth;
    }

    function _key(address a, address b, uint24 fee, int24 tickSpacing)
        private
        pure
        returns (PoolKey memory)
    {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(address(0)));
    }
}
