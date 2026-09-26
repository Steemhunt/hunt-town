// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { FactoryNFT } from "../../src/FactoryNFT.sol";
import { FactoryNFTTestBase } from "../FactoryNFT.t.sol";
import { FactoryTestHunt } from "../mocks/FactoryNFTMocks.sol";

contract FactoryNFTInvariantHandler is Test {
    FactoryNFT public immutable factory;
    FactoryTestHunt public immutable hunt;
    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];

    uint256 public huntDeposited = 1_000e18;
    uint256 public huntRedeemed;
    uint256 public unitsMinted;
    uint256 public unitsBurned;

    constructor(FactoryNFT factory_, FactoryTestHunt hunt_) {
        factory = factory_;
        hunt = hunt_;
    }

    function mint(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 amount = bound(amountSeed, 1, 25);
        uint256 oldVault = hunt.balanceOf(address(factory));
        uint256 oldSupply = factory.totalSupply(0);
        uint256 cost = factory.quoteMint(amount);
        hunt.mint(actor, cost);
        vm.startPrank(actor);
        hunt.approve(address(factory), cost);
        uint256 paid = factory.mint(amount, cost, actor);
        vm.stopPrank();
        assertEq(paid, cost);
        huntDeposited += paid;
        unitsMinted += amount;
        _assertNavDidNotDecrease(oldVault, oldSupply);
    }

    function redeem(uint256 actorSeed, uint256 amountSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = factory.balanceOf(actor, 0);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 oldVault = hunt.balanceOf(address(factory));
        uint256 oldSupply = factory.totalSupply(0);
        uint256 expected = factory.quoteBurn(amount);
        vm.prank(actor);
        uint256 received = factory.burn(amount, expected);
        assertEq(received, expected);
        huntRedeemed += received;
        unitsBurned += amount;
        _assertNavDidNotDecrease(oldVault, oldSupply);
    }

    function deposit(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1_000_000e18);
        uint256 oldVault = hunt.balanceOf(address(factory));
        uint256 oldSupply = factory.totalSupply(0);
        hunt.mint(address(this), amount);
        hunt.approve(address(factory), amount);
        factory.deposit(amount, oldSupply);
        huntDeposited += amount;
        _assertNavDidNotDecrease(oldVault, oldSupply);
    }

    function donate(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 1_000_000e18);
        uint256 oldVault = hunt.balanceOf(address(factory));
        uint256 oldSupply = factory.totalSupply(0);
        hunt.mint(address(this), amount);
        hunt.transfer(address(factory), amount);
        huntDeposited += amount;
        _assertNavDidNotDecrease(oldVault, oldSupply);
    }

    function transferUnits(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = factory.balanceOf(from, 0);
        if (balance == 0) return;
        uint256 amount = bound(amountSeed, 1, balance);
        uint256 oldVault = hunt.balanceOf(address(factory));
        uint256 oldSupply = factory.totalSupply(0);
        vm.prank(from);
        factory.safeTransferFrom(from, to, 0, amount, "");
        assertEq(hunt.balanceOf(address(factory)), oldVault);
        assertEq(factory.totalSupply(0), oldSupply);
    }

    function _assertNavDidNotDecrease(uint256 oldVault, uint256 oldSupply) private view {
        assertGe(
            hunt.balanceOf(address(factory)) * oldSupply,
            oldVault * factory.totalSupply(0),
            "Backing per NFT decreased"
        );
    }
}

contract FactoryNFTInvariantTest is FactoryNFTTestBase {
    FactoryNFTInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new FactoryNFTInvariantHandler(factory, hunt);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = FactoryNFTInvariantHandler.mint.selector;
        selectors[1] = FactoryNFTInvariantHandler.redeem.selector;
        selectors[2] = FactoryNFTInvariantHandler.deposit.selector;
        selectors[3] = FactoryNFTInvariantHandler.donate.selector;
        selectors[4] = FactoryNFTInvariantHandler.transferUnits.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
        targetContract(address(handler));
    }

    function invariantHuntAccountingConservesAllDepositsAndRedemptions() public view {
        assertEq(hunt.balanceOf(address(factory)), handler.huntDeposited() - handler.huntRedeemed());
    }

    function invariantSupplyMatchesIssuanceAndAllHolderBalances() public view {
        uint256 supply = factory.totalSupply(0);
        assertEq(supply, 1 + handler.unitsMinted() - handler.unitsBurned());
        assertEq(factory.totalSupply(), supply);
        uint256 held = factory.balanceOf(TEAM, 0);
        for (uint256 i; i < 3; ++i) {
            held += factory.balanceOf(handler.actors(i), 0);
        }
        assertEq(held, supply);
    }

    function invariantSeedKeepsTheVaultNonempty() public view {
        assertEq(factory.balanceOf(TEAM, 0), 1);
        assertGe(factory.totalSupply(0), 1);
        assertGe(hunt.balanceOf(address(factory)), SEED * factory.totalSupply(0));
        assertGe(factory.navPerNFT(), SEED);
    }
}
