// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { IERC2981 } from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryTestHunt, FactoryTestReceiver } from "./mocks/FactoryNFTMocks.sol";

abstract contract FactoryNFTTestBase is Test {
    uint256 internal constant ID = 0;
    uint256 internal constant SEED = 1_000e18;
    address internal constant TEAM = address(0x5EED);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ROYALTY_OPERATOR = address(0xFEE);

    FactoryTestHunt internal hunt;
    FactoryNFT internal factory;

    function setUp() public virtual {
        hunt = new FactoryTestHunt();
        hunt.mint(address(this), SEED);
        factory = _deployFunded(hunt, TEAM);
    }

    function _deployFunded(FactoryTestHunt token, address seedOwner)
        internal
        returns (FactoryNFT deployed)
    {
        address predicted = _predictFactory(token, seedOwner, bytes32(0));
        token.approve(predicted, SEED);
        deployed = _deployUnchecked(token, seedOwner, bytes32(0));
        assertEq(address(deployed), predicted);
    }

    function _predictFactory(FactoryTestHunt token, address seedOwner, bytes32 salt)
        internal
        view
        returns (address)
    {
        bytes memory args = abi.encode(
            IERC20(address(token)),
            address(this),
            seedOwner,
            "ipfs://factory/{id}.json",
            ROYALTY_OPERATOR
        );
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(FactoryNFT).creationCode, args));
        return vm.computeCreate2Address(salt, initCodeHash, address(this));
    }

    function _deployUnchecked(FactoryTestHunt token, address seedOwner, bytes32 salt)
        internal
        returns (FactoryNFT)
    {
        return new FactoryNFT{ salt: salt }(
            IERC20(address(token)),
            address(this),
            seedOwner,
            "ipfs://factory/{id}.json",
            ROYALTY_OPERATOR
        );
    }

    function _mintFor(address account, uint256 amount) internal returns (uint256 cost) {
        cost = factory.quoteMint(amount);
        hunt.mint(account, cost);
        vm.startPrank(account);
        hunt.approve(address(factory), cost);
        assertEq(factory.mint(amount, cost, account), cost);
        vm.stopPrank();
    }

    function _donate(uint256 amount) internal {
        hunt.mint(address(this), amount);
        hunt.transfer(address(factory), amount);
    }
}

contract FactoryNFTEconomicsTest is FactoryNFTTestBase {
    function testConstructorCreatesExactlyOneFundedSeed() public view {
        assertEq(hunt.balanceOf(address(factory)), SEED);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(factory.totalSupply(), 1);
        assertEq(factory.balanceOf(TEAM, ID), 1);
        assertEq(factory.navPerNFT(), SEED);
        assertEq(factory.owner(), address(this));
    }

    function testConstructorRevertsWithoutSeedApproval() public {
        hunt.mint(address(this), SEED);
        vm.expectRevert();
        _deployUnchecked(hunt, TEAM, bytes32(uint256(1)));
    }

    function testConstructorRevertsWithoutSeedFunding() public {
        address predicted = _predictFactory(hunt, TEAM, bytes32(uint256(1)));
        hunt.approve(predicted, SEED);
        vm.expectRevert();
        _deployUnchecked(hunt, TEAM, bytes32(uint256(1)));
    }

    function testConstructorRejectsUnderfundedSeedTransfer() public {
        hunt.mint(address(this), SEED);
        hunt.setTransferFee(true);
        address predicted = _predictFactory(hunt, TEAM, bytes32(uint256(1)));
        hunt.approve(predicted, SEED);
        vm.expectRevert(FactoryNFT.InexactHuntTransfer.selector);
        _deployUnchecked(hunt, TEAM, bytes32(uint256(1)));
        assertEq(hunt.balanceOf(address(this)), SEED);
    }

    function testMintUsesCurrentBackingAndDoesNotClaimPastDonationsForFree() public {
        _donate(100e18);
        assertEq(factory.quoteMint(2), 2_200e18);
        _mintFor(ALICE, 2);
        assertEq(factory.balanceOf(ALICE, ID), 2);
        assertEq(factory.totalSupply(ID), 3);
        assertEq(hunt.balanceOf(address(factory)), 3_300e18);
        assertEq(factory.navPerNFT(), 1_100e18);
    }

    function testMintCanSendUnitsToAnotherReceiver() public {
        hunt.mint(ALICE, SEED);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), SEED);
        factory.mint(1, SEED, BOB);
        vm.stopPrank();
        assertEq(factory.balanceOf(ALICE, ID), 0);
        assertEq(factory.balanceOf(BOB, ID), 1);
        assertEq(hunt.balanceOf(ALICE), 0);
    }

    function testDepositRaisesNavForTheExpectedSupply() public {
        _mintFor(ALICE, 9);
        hunt.mint(address(this), 10_000e18);
        hunt.approve(address(factory), 10_000e18);
        vm.expectEmit(address(factory));
        emit FactoryNFT.Deposited(address(this), 10_000e18, 10);
        factory.deposit(10_000e18, 10);
        assertEq(hunt.balanceOf(address(this)), 0);
        assertEq(hunt.balanceOf(address(factory)), 20_000e18);
        assertEq(factory.navPerNFT(), 2_000e18);
        assertEq(factory.totalSupply(ID), 10);
    }

    function testDepositRevertsAfterAFrontRunningMintOrBurn() public {
        hunt.mint(address(this), 10_000e18);
        hunt.approve(address(factory), 10_000e18);
        uint256 expected = factory.totalSupply(ID);
        // Alice mints in front of the pending deposit hoping to redeem a share of it.
        uint256 paid = _mintFor(ALICE, 3);
        vm.expectRevert(abi.encodeWithSelector(FactoryNFT.SupplyChanged.selector, 4, expected));
        factory.deposit(10_000e18, expected);
        vm.prank(ALICE);
        assertLt(factory.burn(3, 0), paid);

        // A burn between the read and the deposit is rejected the same way.
        vm.expectRevert(abi.encodeWithSelector(FactoryNFT.SupplyChanged.selector, 1, 4));
        factory.deposit(10_000e18, 4);
        assertEq(hunt.balanceOf(address(this)), 10_000e18);
        assertEq(hunt.allowance(address(this), address(factory)), 10_000e18);
    }

    function testDepositRejectsZeroAmountAndUnderfundedTransfer() public {
        vm.expectRevert(FactoryNFT.InvalidAmount.selector);
        factory.deposit(0, 1);
        hunt.mint(address(this), 100e18);
        hunt.approve(address(factory), 100e18);
        hunt.setTransferFee(true);
        vm.expectRevert(FactoryNFT.InexactHuntTransfer.selector);
        factory.deposit(100e18, 1);
        assertEq(hunt.balanceOf(address(factory)), SEED);
    }

    function testDirectDonationChangesNavImmediately() public {
        _mintFor(ALICE, 9);
        _donate(123_456_789);
        assertEq(factory.navPerNFT(), SEED + 12_345_678);
        assertEq(factory.quoteMint(1), SEED + 12_345_679);
    }

    function testMintRoundsTotalCostUpRatherThanPerUnitCost() public {
        _mintFor(ALICE, 2);
        _donate(1);
        assertEq(factory.quoteMint(1), SEED + 1);
        assertEq(factory.quoteMint(2), 2 * SEED + 1);
        _mintFor(BOB, 2);
        assertEq(hunt.balanceOf(address(factory)), 5 * SEED + 2);
        assertEq(factory.totalSupply(ID), 5);
    }

    function testMintRevertsWhenDonationExceedsMaximumPrice() public {
        uint256 oldPrice = factory.quoteMint(1);
        hunt.mint(ALICE, oldPrice);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), oldPrice);
        vm.stopPrank();
        _donate(1);
        vm.prank(ALICE);
        vm.expectRevert();
        factory.mint(1, oldPrice, ALICE);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(hunt.balanceOf(ALICE), oldPrice);
    }

    function testMintRejectsFeeOnTransferWithoutIssuingUnbackedUnits() public {
        hunt.mint(ALICE, SEED);
        hunt.setTransferFee(true);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), SEED);
        vm.expectRevert();
        factory.mint(1, SEED, ALICE);
        vm.stopPrank();
        assertEq(factory.totalSupply(ID), 1);
        assertEq(hunt.balanceOf(address(factory)), SEED);
        assertEq(hunt.balanceOf(ALICE), SEED);
    }

    function testBurnPaysNinetyFivePercentAndKeepsFeeInBacking() public {
        _mintFor(ALICE, 1);
        vm.prank(ALICE);
        assertEq(factory.burn(1, 950e18), 950e18);
        assertEq(hunt.balanceOf(ALICE), 950e18);
        assertEq(hunt.balanceOf(address(factory)), 1_050e18);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(factory.navPerNFT(), 1_050e18);
    }

    function testRevenueMintAndBurnNumericalExample() public {
        _mintFor(ALICE, 99);
        _donate(10_000e18);
        assertEq(factory.navPerNFT(), 1_100e18);
        _mintFor(BOB, 1);
        assertEq(hunt.balanceOf(address(factory)), 111_100e18);
        vm.prank(BOB);
        assertEq(factory.burn(1, 0), 1_045e18);
        assertEq(hunt.balanceOf(address(factory)), 110_055e18);
        assertEq(factory.totalSupply(ID), 100);
        assertEq(factory.navPerNFT(), 1_100.55e18);
    }

    function testBurnRoundsPayoutDown() public {
        _mintFor(ALICE, 2);
        _donate(4);
        uint256 gross = 2 * SEED + 2;
        uint256 expected = gross * 9_500 / 10_000;
        assertEq(factory.quoteBurn(2), expected);
        vm.prank(ALICE);
        factory.burn(2, expected);
        assertEq(hunt.balanceOf(ALICE), expected);
        assertEq(hunt.balanceOf(address(factory)), 3 * SEED + 4 - expected);
    }

    function testBurnRevertsBelowMinimumOutputWithoutChangingSupply() public {
        _mintFor(ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert();
        factory.burn(1, 950e18 + 1);
        assertEq(factory.balanceOf(ALICE, ID), 1);
        assertEq(factory.totalSupply(ID), 2);
        assertEq(hunt.balanceOf(address(factory)), 2 * SEED);
    }

    function testLastUnitCannotBeBurned() public {
        vm.prank(TEAM);
        vm.expectRevert();
        factory.burn(1, 0);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(hunt.balanceOf(address(factory)), SEED);
    }

    function testEveryPublicUnitCanExitWhileSeedRemains() public {
        _mintFor(ALICE, 37);
        vm.prank(ALICE);
        factory.burn(37, 0);
        assertEq(factory.balanceOf(ALICE, ID), 0);
        assertEq(factory.balanceOf(TEAM, ID), 1);
        assertEq(factory.totalSupply(ID), 1);
    }

    function testBurnRequiresCallerToOwnUnitsDespiteOperatorApproval() public {
        _mintFor(ALICE, 2);
        vm.prank(ALICE);
        factory.setApprovalForAll(BOB, true);
        vm.prank(BOB);
        vm.expectRevert();
        factory.burn(1, 0);
        assertEq(factory.balanceOf(ALICE, ID), 2);
    }

    function testZeroQuantityMintAndBurnRevert() public {
        vm.expectRevert();
        factory.mint(0, 0, ALICE);
        vm.expectRevert();
        factory.burn(0, 0);
    }

    function testBulkBurnUsesOneSnapshotAndSequentialBurnRecapturesSomeFees() public {
        _mintFor(ALICE, 2);
        uint256 bulkQuote = factory.quoteBurn(2);
        assertEq(bulkQuote, 1_900e18);
        vm.startPrank(ALICE);
        uint256 first = factory.burn(1, 0);
        uint256 second = factory.burn(1, 0);
        vm.stopPrank();
        assertEq(first, 950e18);
        assertEq(second, 973.75e18);
        assertEq(first + second, 1_923.75e18);
        assertGt(first + second, bulkQuote);
        assertEq(hunt.balanceOf(address(factory)), 1_076.25e18);
    }

    function testFuzzMintDonationAndBurnConserveHunt(
        uint16 rawAmount,
        uint96 rawDonation,
        uint16 rawBurn
    ) public {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000);
        uint256 donation = bound(uint256(rawDonation), 0, 1_000_000e18);
        _mintFor(ALICE, amount);
        _donate(donation);
        uint256 supplyBefore = factory.totalSupply(ID);
        uint256 vaultBefore = hunt.balanceOf(address(factory));
        uint256 burnAmount = bound(uint256(rawBurn), 1, amount);
        uint256 expected = (vaultBefore * burnAmount / supplyBefore) * 9_500 / 10_000;
        vm.prank(ALICE);
        uint256 paid = factory.burn(burnAmount, expected);
        uint256 supplyAfter = factory.totalSupply(ID);
        uint256 vaultAfter = hunt.balanceOf(address(factory));
        assertEq(paid, expected);
        assertEq(vaultAfter + paid, vaultBefore);
        assertEq(supplyAfter + burnAmount, supplyBefore);
        assertGe(vaultAfter * supplyBefore, vaultBefore * supplyAfter);
        assertEq(factory.balanceOf(TEAM, ID), 1);
    }

    function testFuzzMintNeverDilutesExistingBacking(
        uint16 rawSupply,
        uint16 rawAmount,
        uint96 rawDonation
    ) public {
        _mintFor(ALICE, bound(uint256(rawSupply), 1, 1_000));
        _donate(bound(uint256(rawDonation), 0, 1_000_000e18));
        uint256 supplyBefore = factory.totalSupply(ID);
        uint256 vaultBefore = hunt.balanceOf(address(factory));
        uint256 amount = bound(uint256(rawAmount), 1, 1_000);
        uint256 expectedCost = (vaultBefore * amount + supplyBefore - 1) / supplyBefore;
        assertEq(factory.quoteMint(amount), expectedCost);
        _mintFor(BOB, amount);
        assertGe(
            hunt.balanceOf(address(factory)) * supplyBefore, vaultBefore * factory.totalSupply(ID)
        );
    }
}

contract FactoryNFTIntegrationTest is FactoryNFTTestBase {
    function testRoyaltyUsesFixedThreePercentAndConfiguredReceiver() public view {
        (address receiver, uint256 royalty) = factory.royaltyInfo(ID, 10_000e18);
        assertEq(receiver, ROYALTY_OPERATOR);
        assertEq(royalty, 300e18);
        assertTrue(factory.supportsInterface(type(IERC1155).interfaceId));
        assertTrue(factory.supportsInterface(type(IERC2981).interfaceId));
    }

    function testOnlyOwnerCanChangeRoyaltyOperatorOrMetadata() public {
        vm.startPrank(ALICE);
        vm.expectRevert();
        factory.setRoyaltyOperator(BOB);
        vm.expectRevert();
        factory.setURI("ipfs://unauthorized");
        vm.stopPrank();
        factory.setRoyaltyOperator(BOB);
        factory.setURI("ipfs://updated/{id}.json");
        assertEq(factory.royaltyOperator(), BOB);
        (address receiver, uint256 amount) = factory.royaltyInfo(ID, 100e18);
        assertEq(receiver, BOB);
        assertEq(amount, 3e18);
        assertEq(factory.uri(ID), "ipfs://updated/{id}.json");
    }

    function testOwnershipTransferRequiresAcceptance() public {
        factory.transferOwnership(ALICE);
        assertEq(factory.owner(), address(this));
        assertEq(factory.pendingOwner(), ALICE);
        vm.prank(BOB);
        vm.expectRevert();
        factory.acceptOwnership();
        vm.prank(ALICE);
        factory.acceptOwnership();
        assertEq(factory.owner(), ALICE);
        vm.expectRevert();
        factory.setURI("ipfs://former-owner");
    }

    function testRejectingReceiverRollsBackPaymentAndSupply() public {
        FactoryTestReceiver receiver = new FactoryTestReceiver();
        receiver.configure(factory, hunt, true, false);
        hunt.mint(ALICE, SEED);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), SEED);
        vm.expectRevert();
        factory.mint(1, SEED, address(receiver));
        vm.stopPrank();
        assertEq(hunt.balanceOf(ALICE), SEED);
        assertEq(hunt.balanceOf(address(factory)), SEED);
        assertEq(factory.totalSupply(ID), 1);
        assertEq(factory.balanceOf(address(receiver), ID), 0);
    }

    function testMintCallbackCannotReenterMintOrBurn() public {
        FactoryTestReceiver receiver = new FactoryTestReceiver();
        receiver.configure(factory, hunt, false, true);
        hunt.mint(address(receiver), 2 * SEED);
        hunt.mint(ALICE, SEED);
        vm.startPrank(ALICE);
        hunt.approve(address(factory), SEED);
        factory.mint(1, SEED, address(receiver));
        vm.stopPrank();
        assertFalse(receiver.mintReentrySucceeded());
        assertFalse(receiver.burnReentrySucceeded());
        bytes memory expected = abi.encodeWithSignature("ReentrancyGuardReentrantCall()");
        assertEq(receiver.mintReentryResult(), expected);
        assertEq(receiver.burnReentryResult(), expected);
        assertEq(factory.balanceOf(address(receiver), ID), 1);
        assertEq(factory.totalSupply(ID), 2);
        assertEq(hunt.balanceOf(address(factory)), 2 * SEED);
    }
}
