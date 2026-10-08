// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryDonation } from "../src/FactoryDonation.sol";
import { FactoryNFTTestBase } from "./FactoryNFT.t.sol";

contract FactoryDonationTest is FactoryNFTTestBase {
    FactoryDonation private donation;

    function setUp() public override {
        super.setUp();
        donation = new FactoryDonation(factory);
    }

    function testConstructorUsesFactoryTokenAndApprovesOnlyFactory() public view {
        assertEq(address(donation.factory()), address(factory));
        assertEq(address(donation.huntToken()), address(hunt));
        assertEq(donation.MAX_MESSAGE_BYTES(), 280);
        assertEq(hunt.allowance(address(donation), address(factory)), type(uint256).max);
        assertEq(hunt.allowance(address(donation), ALICE), 0);
    }

    function testConstructorRejectsAddressesWithoutCode() public {
        vm.expectRevert(FactoryDonation.InvalidAddress.selector);
        new FactoryDonation(FactoryNFT(address(0)));
        vm.expectRevert(FactoryDonation.InvalidAddress.selector);
        new FactoryDonation(FactoryNFT(ALICE));
    }

    function testConstructorRejectsFactoryTokenWithoutCode() public {
        vm.mockCall(address(factory), abi.encodeCall(factory.huntToken, ()), abi.encode(ALICE));
        vm.expectRevert(FactoryDonation.InvalidAddress.selector);
        new FactoryDonation(factory);
    }

    function testConstructorRejectsFailedTokenApproval() public {
        vm.mockCall(
            address(hunt), abi.encodeWithSelector(IERC20.approve.selector), abi.encode(false)
        );
        vm.expectRevert(
            abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(hunt))
        );
        new FactoryDonation(factory);
    }

    function testDonationRecordsCallerAndRaisesNavWithoutIssuingNFTs() public {
        _mintFor(BOB, 9);
        _fundDonor(10_000 ether);
        assertEq(factory.balanceOf(ALICE, ID), 0);
        vm.expectEmit(address(factory));
        emit FactoryNFT.Deposited(address(donation), 10_000 ether, 10);
        vm.expectEmit(address(donation));
        emit FactoryDonation.Donated(ALICE, 10_000 ether, "For the next builders.");
        vm.prank(ALICE);
        donation.donate(10_000 ether, 10, "For the next builders.");
        assertEq(factory.totalSupply(ID), 10);
        assertEq(factory.navPerNFT(), 2_000 ether);
        assertEq(factory.balanceOf(ALICE, ID), 0);
        assertEq(hunt.balanceOf(ALICE), 0);
        assertEq(hunt.balanceOf(address(donation)), 0);
        assertEq(hunt.allowance(ALICE, address(donation)), 0);
    }

    function testDonationAcceptsEmptyMessage() public {
        _fundDonor(1);
        vm.expectEmit(address(donation));
        emit FactoryDonation.Donated(ALICE, 1, "");
        vm.prank(ALICE);
        donation.donate(1, 1, "");
        assertEq(hunt.balanceOf(address(factory)), SEED + 1);
    }

    function testDonationRejectsZeroAmount() public {
        vm.expectRevert(FactoryDonation.InvalidAmount.selector);
        donation.donate(0, 1, "");
    }

    function testFuzzDonationAcceptsBoundedMessages(uint96 amount_, uint16 length_) public {
        uint256 amount = bound(uint256(amount_), 1, 1_000_000 ether);
        uint256 length = bound(uint256(length_), 0, 280);
        string memory message = string(new bytes(length));
        _fundDonor(amount);
        vm.expectEmit(address(donation));
        emit FactoryDonation.Donated(ALICE, amount, message);
        vm.prank(ALICE);
        donation.donate(amount, 1, message);
        assertEq(hunt.balanceOf(address(factory)), SEED + amount);
        assertEq(hunt.balanceOf(address(donation)), 0);
    }

    function testFuzzDonationRejectsOversizedMessages(uint16 length_) public {
        uint256 length = bound(uint256(length_), 281, 1_024);
        vm.expectRevert(abi.encodeWithSelector(FactoryDonation.MessageTooLong.selector, length));
        donation.donate(1, 1, string(new bytes(length)));
    }

    function testMessageLimitAccepts280BytesAndRejects281() public {
        _fundDonor(2);
        vm.prank(ALICE);
        donation.donate(1, 1, string(new bytes(280)));
        vm.expectRevert(abi.encodeWithSelector(FactoryDonation.MessageTooLong.selector, 281));
        vm.prank(ALICE);
        donation.donate(1, 1, string(new bytes(281)));
        assertEq(hunt.balanceOf(ALICE), 1);
        assertEq(hunt.allowance(ALICE, address(donation)), 1);
    }

    function testMessageLimitCountsUtf8Bytes() public {
        bytes memory message;
        for (uint256 i; i < 93; ++i) {
            message = abi.encodePacked(message, unicode"€");
        }
        assertEq(message.length, 279);
        _fundDonor(2);
        vm.prank(ALICE);
        donation.donate(1, 1, string(message));
        message = abi.encodePacked(message, unicode"€");
        vm.expectRevert(abi.encodeWithSelector(FactoryDonation.MessageTooLong.selector, 282));
        vm.prank(ALICE);
        donation.donate(1, 1, string(message));
        assertEq(hunt.balanceOf(ALICE), 1);
        assertEq(hunt.allowance(ALICE, address(donation)), 1);
    }

    function testDonationRequiresCallerBalanceAndApproval() public {
        vm.prank(ALICE);
        hunt.approve(address(donation), 100 ether);
        vm.expectRevert();
        vm.prank(ALICE);
        donation.donate(100 ether, 1, "");
        assertEq(hunt.allowance(ALICE, address(donation)), 100 ether);
        hunt.mint(ALICE, 100 ether);
        vm.prank(ALICE);
        hunt.approve(address(donation), 99 ether);
        vm.expectRevert();
        vm.prank(ALICE);
        donation.donate(100 ether, 1, "");
        assertEq(hunt.balanceOf(ALICE), 100 ether);
        assertEq(hunt.balanceOf(address(factory)), SEED);
        assertEq(hunt.balanceOf(address(donation)), 0);
    }

    function testAnotherCallerCannotSpendDonorsApproval() public {
        _fundDonor(100 ether);
        vm.expectRevert();
        vm.prank(BOB);
        donation.donate(100 ether, 1, "For Alice.");
        assertEq(hunt.balanceOf(ALICE), 100 ether);
        assertEq(hunt.allowance(ALICE, address(donation)), 100 ether);
    }

    function testSupplyChangeRevertsAllTransfersAfterMintAndBurn() public {
        _fundDonor(100 ether);
        _mintFor(BOB, 1);
        vm.expectRevert(abi.encodeWithSelector(FactoryNFT.SupplyChanged.selector, 2, 1));
        vm.prank(ALICE);
        donation.donate(100 ether, 1, "");
        assertEq(hunt.balanceOf(address(factory)), 2 * SEED);
        vm.prank(BOB);
        factory.burn(1, 0);
        vm.expectRevert(abi.encodeWithSelector(FactoryNFT.SupplyChanged.selector, 1, 2));
        vm.prank(ALICE);
        donation.donate(100 ether, 2, "");
        assertEq(hunt.balanceOf(address(factory)), 1_050 ether);
        assertEq(hunt.balanceOf(ALICE), 100 ether);
        assertEq(hunt.allowance(ALICE, address(donation)), 100 ether);
        assertEq(hunt.balanceOf(address(donation)), 0);
    }

    function testDonationPreservesPreexistingDust() public {
        hunt.mint(address(donation), 42 ether);
        _fundDonor(100 ether);
        vm.prank(ALICE);
        donation.donate(100 ether, 1, "");
        assertEq(hunt.balanceOf(address(donation)), 42 ether);
        assertEq(hunt.balanceOf(address(factory)), SEED + 100 ether);
    }

    function testFirstTransferCannotUseDustToCoverATokenFee() public {
        hunt.mint(address(donation), 42 ether);
        _fundDonor(100 ether);
        hunt.setTransferFee(true);
        vm.expectRevert(FactoryDonation.InexactHuntTransfer.selector);
        vm.prank(ALICE);
        donation.donate(100 ether, 1, "");
        assertEq(hunt.balanceOf(address(donation)), 42 ether);
        assertEq(hunt.balanceOf(ALICE), 100 ether);
        assertEq(hunt.allowance(ALICE, address(donation)), 100 ether);
        assertEq(hunt.balanceOf(address(factory)), SEED);
    }

    function testInexactFactoryTransferRevertsFirstTransfer() public {
        _fundDonor(100 ether);
        vm.mockCall(
            address(hunt),
            abi.encodeCall(IERC20.transferFrom, (address(donation), address(factory), 100 ether)),
            abi.encode(true)
        );
        vm.expectRevert(FactoryNFT.InexactHuntTransfer.selector);
        vm.prank(ALICE);
        donation.donate(100 ether, 1, "");
        assertEq(hunt.balanceOf(ALICE), 100 ether);
        assertEq(hunt.allowance(ALICE, address(donation)), 100 ether);
        assertEq(hunt.balanceOf(address(donation)), 0);
        assertEq(hunt.balanceOf(address(factory)), SEED);
    }

    function testTokenCallbacksCannotReenterAndLaterDonationsStillWork() public {
        FactoryDonationCallbackToken token = new FactoryDonationCallbackToken();
        token.mint(address(this), SEED);
        bytes memory args =
            abi.encode(token, address(this), TEAM, "ipfs://factory/{id}.json", ROYALTY_OPERATOR);
        address predicted = vm.computeCreate2Address(
            bytes32(uint256(1)),
            keccak256(abi.encodePacked(type(FactoryNFT).creationCode, args)),
            address(this)
        );
        token.approve(predicted, SEED);
        FactoryNFT callbackFactory = new FactoryNFT{ salt: bytes32(uint256(1)) }(
            token, address(this), TEAM, "ipfs://factory/{id}.json", ROYALTY_OPERATOR
        );
        FactoryDonation callbackDonation = new FactoryDonation(callbackFactory);
        token.configure(callbackDonation);
        token.mint(ALICE, 200 ether);
        vm.startPrank(ALICE);
        token.approve(address(callbackDonation), 200 ether);
        callbackDonation.donate(100 ether, 1, "First.");
        assertFalse(token.reentrySucceeded());
        assertEq(token.reentryResult(), abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        callbackDonation.donate(100 ether, 1, "Second.");
        vm.stopPrank();
        assertEq(token.balanceOf(address(callbackFactory)), SEED + 200 ether);
        assertEq(token.balanceOf(address(callbackDonation)), 0);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function _fundDonor(uint256 amount) private {
        hunt.mint(ALICE, amount);
        vm.prank(ALICE);
        hunt.approve(address(donation), amount);
    }
}

contract FactoryDonationCallbackToken is ERC20 {
    FactoryDonation private donation;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor() ERC20("Callback HUNT", "HUNT") { }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function configure(FactoryDonation donation_) external {
        donation = donation_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (address(donation) != address(0)) {
            (reentrySucceeded, reentryResult) = address(donation)
                .call(abi.encodeCall(FactoryDonation.donate, (1, 1, "Reentrant.")));
        }
        return super.transferFrom(from, to, amount);
    }
}
