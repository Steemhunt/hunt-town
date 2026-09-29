// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { MiniBuildingCollector } from "../src/MiniBuildingCollector.sol";
import { FactoryTestHunt } from "./mocks/FactoryNFTMocks.sol";

contract CollectorTestBuilding is ERC1155 {
    constructor() ERC1155("ipfs://test") { }

    function mint(address account, uint256 id, uint256 amount) external {
        _mint(account, id, amount, "");
    }
}

contract CollectorTestCustody is ERC1155Holder {
    MiniBuildingCollector public collector;
    bool public rejectTransfer;
    bool public quoteConsumedDuringCallback;
    bool public reentrySucceeded;
    bytes public reentryResult;
    bytes32 public quoteId;

    function configure(MiniBuildingCollector collector_, bytes32 quoteId_, bool reject_) external {
        collector = collector_;
        quoteId = quoteId_;
        rejectTransfer = reject_;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory)
        public
        override
        returns (bytes4)
    {
        quoteConsumedDuringCallback = collector.consumedQuotes(quoteId);
        MiniBuildingCollector.MigrationQuote memory quote;
        (reentrySucceeded, reentryResult) =
            address(collector).call(abi.encodeCall(MiniBuildingCollector.deposit, (quote, "")));
        return rejectTransfer ? bytes4(0) : this.onERC1155Received.selector;
    }
}

contract MiniBuildingCollectorTest is Test {
    uint256 internal constant SIGNER_KEY = 0x51A9;
    uint256 internal constant NEXT_SIGNER_KEY = 0x51AA;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    bytes32 internal constant QUOTE_ID = keccak256("migration quote");
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "MigrationQuote(bytes32 quoteId,address account,uint256 miniAmount,uint256 mintingCount,uint256 additionalHunt,uint256 deadline)"
    );
    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    MiniBuildingCollector internal collector;
    CollectorTestBuilding internal building;
    FactoryTestHunt internal hunt;
    address internal signer;
    address internal custody;

    function setUp() public {
        vm.chainId(8453);
        vm.warp(1_800_000_000);
        signer = vm.addr(SIGNER_KEY);
        building = new CollectorTestBuilding();
        hunt = new FactoryTestHunt();
        collector = new MiniBuildingCollector(building, hunt, address(this), signer);
        custody = collector.MIGRATION_RECEIVER();
        _fundAndApprove(ALICE, 100, 10_000 ether);
    }

    function testConfigurationAndIndependentTypedDataHash() public view {
        assertEq(address(collector.building()), address(building));
        assertEq(address(collector.huntToken()), address(hunt));
        assertEq(collector.owner(), address(this));
        assertEq(collector.quoteSigner(), signer);
        assertEq(collector.MINI_TOKEN_ID(), 0);
        assertEq(custody, 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D);
        assertFalse(collector.consumedQuotes(QUOTE_ID));
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        assertEq(collector.hashQuote(quote), _digest(quote, 8453, address(collector)));
    }

    function testConstructorRejectsInvalidConfiguration() public {
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        new MiniBuildingCollector(IERC1155(address(0)), hunt, address(this), signer);
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        new MiniBuildingCollector(IERC1155(ALICE), hunt, address(this), signer);
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        new MiniBuildingCollector(building, IERC20(address(0)), address(this), signer);
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        new MiniBuildingCollector(building, IERC20(ALICE), address(this), signer);
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        new MiniBuildingCollector(building, hunt, address(this), address(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new MiniBuildingCollector(building, hunt, address(0), signer);
    }

    function testDepositTransfersBothAssetsToCustodyAndEmitsQuote() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.expectEmit(address(collector));
        emit MiniBuildingCollector.Deposited(
            quote.quoteId, ALICE, quote.miniAmount, quote.mintingCount, quote.additionalHunt
        );
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
        assertEq(building.balanceOf(ALICE, 0), 100 - quote.miniAmount);
        assertEq(building.balanceOf(custody, 0), quote.miniAmount);
        assertEq(hunt.balanceOf(ALICE), 10_000 ether - quote.additionalHunt);
        assertEq(hunt.balanceOf(custody), quote.additionalHunt);
        assertEq(hunt.allowance(ALICE, address(collector)), 10_000 ether - quote.additionalHunt);
        assertEq(building.balanceOf(address(collector), 0), 0);
        assertEq(hunt.balanceOf(address(collector)), 0);
    }

    function testZeroTopUpDoesNotNeedHuntBalanceOrAllowance() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        quote.additionalHunt = 0;
        vm.startPrank(ALICE);
        hunt.transfer(BOB, hunt.balanceOf(ALICE));
        hunt.approve(address(collector), 0);
        vm.stopPrank();
        _deposit(quote);
        assertEq(hunt.balanceOf(custody), 0);
        assertEq(building.balanceOf(custody, 0), quote.miniAmount);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testQuoteIsValidAtDeadlineButNotAfter() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.warp(quote.deadline + 1);
        vm.expectRevert(MiniBuildingCollector.QuoteExpired.selector);
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
        vm.warp(quote.deadline);
        _deposit(quote);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testAnotherCallerCannotUseAnApprovedAccountsQuote() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.prank(ALICE);
        building.setApprovalForAll(BOB, true);
        vm.expectRevert(MiniBuildingCollector.UnauthorizedAccount.selector);
        vm.prank(BOB);
        collector.deposit(quote, signature);
        _assertUntouched();
    }

    function testReplayIsRejectedEvenWhenQuoteIdIsSignedForAnotherAccount() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        _deposit(quote);
        bytes memory signature = _sign(quote);
        vm.expectRevert(
            abi.encodeWithSelector(MiniBuildingCollector.QuoteAlreadyUsed.selector, QUOTE_ID)
        );
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _fundAndApprove(BOB, 100, 10_000 ether);
        quote.account = BOB;
        signature = _sign(quote);
        vm.expectRevert(
            abi.encodeWithSelector(MiniBuildingCollector.QuoteAlreadyUsed.selector, QUOTE_ID)
        );
        vm.prank(BOB);
        collector.deposit(quote, signature);
        assertEq(building.balanceOf(BOB, 0), 100);
        assertEq(hunt.balanceOf(BOB), 10_000 ether);
    }

    function testEveryQuoteFieldIsBoundByTheSignature() public {
        bytes memory signature = _sign(_quote());
        for (uint256 i; i < 6; ++i) {
            MiniBuildingCollector.MigrationQuote memory quote = _quote();
            if (i == 0) quote.quoteId = keccak256("changed quote");
            if (i == 1) quote.account = BOB;
            if (i == 2) quote.miniAmount += 1;
            if (i == 3) quote.mintingCount += 1;
            if (i == 4) quote.additionalHunt += 1;
            if (i == 5) quote.deadline += 1;
            vm.expectRevert(MiniBuildingCollector.InvalidSignature.selector);
            vm.prank(quote.account);
            collector.deposit(quote, signature);
        }
        _assertUntouched();
    }

    function testDomainPreventsCrossChainAndCrossContractReplay() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.chainId(1);
        assertEq(collector.hashQuote(quote), _digest(quote, 1, address(collector)));
        vm.expectRevert(MiniBuildingCollector.InvalidSignature.selector);
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        vm.chainId(8453);
        MiniBuildingCollector other =
            new MiniBuildingCollector(building, hunt, address(this), signer);
        vm.expectRevert(MiniBuildingCollector.InvalidSignature.selector);
        vm.prank(ALICE);
        other.deposit(quote, signature);
        _assertUntouched();
    }

    function testMalformedAndUnauthorizedSignaturesCannotConsumeQuote() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        vm.expectRevert();
        vm.prank(ALICE);
        collector.deposit(quote, hex"1234");
        bytes memory signature =
            _signature(NEXT_SIGNER_KEY, _digest(quote, 8453, address(collector)));
        vm.expectRevert(MiniBuildingCollector.InvalidSignature.selector);
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
    }

    function testInvalidQuoteFieldsAreRejected() public {
        for (uint256 i; i < 5; ++i) {
            MiniBuildingCollector.MigrationQuote memory quote = _quote();
            if (i == 0) quote.quoteId = bytes32(0);
            if (i == 1) quote.miniAmount = 0;
            if (i == 2) quote.mintingCount = 0;
            if (i == 3) quote.account = custody;
            if (i == 4) quote.account = address(collector);
            bytes memory signature = _sign(quote);
            vm.expectRevert(MiniBuildingCollector.InvalidQuote.selector);
            vm.prank(quote.account);
            collector.deposit(quote, signature);
        }
        _assertUntouched();
    }

    function testMissingMiniApprovalRollsBackAndAllowsRetry() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.prank(ALICE);
        building.setApprovalForAll(address(collector), false);
        vm.expectRevert();
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
        vm.prank(ALICE);
        building.setApprovalForAll(address(collector), true);
        _deposit(quote);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testInsufficientMiniBalanceDoesNotConsumeQuoteOrHunt() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        quote.miniAmount = 101;
        bytes memory signature = _sign(quote);
        vm.expectRevert();
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
    }

    function testMissingHuntAllowanceRollsBackMiniTransferAndAllowsRetry() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.prank(ALICE);
        hunt.approve(address(collector), quote.additionalHunt - 1);
        vm.expectRevert();
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
        vm.prank(ALICE);
        hunt.approve(address(collector), quote.additionalHunt);
        _deposit(quote);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testInsufficientHuntBalanceRollsBackMiniTransfer() public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        vm.prank(ALICE);
        hunt.transfer(BOB, 10_000 ether - quote.additionalHunt + 1);
        bytes memory signature = _sign(quote);
        vm.expectRevert();
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        assertFalse(collector.consumedQuotes(QUOTE_ID));
        assertEq(building.balanceOf(ALICE, 0), 100);
        assertEq(building.balanceOf(custody, 0), 0);
        assertEq(hunt.balanceOf(custody), 0);
        assertEq(hunt.balanceOf(ALICE), quote.additionalHunt - 1);
    }

    function testTransferFeeRevertsBothTransfersWithoutConsumingQuote() public {
        hunt.setTransferFee(true);
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.expectRevert(MiniBuildingCollector.InexactHuntTransfer.selector);
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
        hunt.setTransferFee(false);
        _deposit(quote);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testCustodyCallbackSeesConsumedQuoteAndCannotReenter() public {
        CollectorTestCustody receiver = _custody(false);
        _deposit(_quote());
        assertTrue(receiver.quoteConsumedDuringCallback());
        assertFalse(receiver.reentrySucceeded());
        assertEq(
            receiver.reentryResult(),
            abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector)
        );
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testRejectingCustodyRollsBackAndCanRetrySameQuote() public {
        CollectorTestCustody receiver = _custody(true);
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory signature = _sign(quote);
        vm.expectRevert();
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        _assertUntouched();
        receiver.configure(collector, QUOTE_ID, false);
        _deposit(quote);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testOnlyOwnerCanRotateSignerAndOldQuotesBecomeInvalid() public {
        address nextSigner = vm.addr(NEXT_SIGNER_KEY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        collector.setQuoteSigner(nextSigner);
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        collector.setQuoteSigner(address(0));
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        bytes memory oldSignature = _sign(quote);
        vm.expectEmit(address(collector));
        emit MiniBuildingCollector.QuoteSignerUpdated(signer, nextSigner);
        collector.setQuoteSigner(nextSigner);
        assertEq(collector.quoteSigner(), nextSigner);
        vm.expectRevert(MiniBuildingCollector.InvalidSignature.selector);
        vm.prank(ALICE);
        collector.deposit(quote, oldSignature);
        bytes memory signature =
            _signature(NEXT_SIGNER_KEY, _digest(quote, 8453, address(collector)));
        vm.prank(ALICE);
        collector.deposit(quote, signature);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function testOwnershipTransferRequiresAcceptance() public {
        collector.transferOwnership(BOB);
        assertEq(collector.owner(), address(this));
        assertEq(collector.pendingOwner(), BOB);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        collector.acceptOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BOB));
        vm.prank(BOB);
        collector.setQuoteSigner(BOB);
        vm.prank(BOB);
        collector.acceptOwnership();
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this))
        );
        collector.setQuoteSigner(ALICE);
        vm.prank(BOB);
        collector.setQuoteSigner(BOB);
        assertEq(collector.owner(), BOB);
        assertEq(collector.quoteSigner(), BOB);
    }

    function testFuzzDepositMatchesSignedAmountsAndPreservesExistingCustodyBalance(
        uint256 miniAmount,
        uint256 mintingCount,
        uint256 additionalHunt,
        uint256 existingHunt
    ) public {
        MiniBuildingCollector.MigrationQuote memory quote = _quote();
        quote.account = BOB;
        quote.miniAmount = bound(miniAmount, 1, 1_000_000);
        quote.mintingCount = bound(mintingCount, 1, 1_000_000);
        quote.additionalHunt = bound(additionalHunt, 0, 1_000_000 ether);
        existingHunt = bound(existingHunt, 0, 1_000_000 ether);
        _fundAndApprove(BOB, quote.miniAmount, quote.additionalHunt);
        hunt.mint(custody, existingHunt);
        _deposit(quote);
        assertEq(building.balanceOf(BOB, 0), 0);
        assertEq(building.balanceOf(custody, 0), quote.miniAmount);
        assertEq(hunt.balanceOf(BOB), 0);
        assertEq(hunt.balanceOf(custody), existingHunt + quote.additionalHunt);
        assertEq(hunt.balanceOf(address(collector)), 0);
        assertTrue(collector.consumedQuotes(QUOTE_ID));
    }

    function _quote() internal view returns (MiniBuildingCollector.MigrationQuote memory) {
        return MiniBuildingCollector.MigrationQuote({
            quoteId: QUOTE_ID,
            account: ALICE,
            miniAmount: 9,
            mintingCount: 1,
            additionalHunt: 100 ether,
            deadline: block.timestamp + 15 minutes
        });
    }

    function _fundAndApprove(address account, uint256 miniAmount, uint256 huntAmount) internal {
        building.mint(account, 0, miniAmount);
        hunt.mint(account, huntAmount);
        vm.startPrank(account);
        building.setApprovalForAll(address(collector), true);
        hunt.approve(address(collector), huntAmount);
        vm.stopPrank();
    }

    function _deposit(MiniBuildingCollector.MigrationQuote memory quote) internal {
        bytes memory signature = _sign(quote);
        vm.prank(quote.account);
        collector.deposit(quote, signature);
    }

    function _sign(MiniBuildingCollector.MigrationQuote memory quote)
        internal
        view
        returns (bytes memory)
    {
        return _signature(SIGNER_KEY, _digest(quote, block.chainid, address(collector)));
    }

    function _signature(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _digest(
        MiniBuildingCollector.MigrationQuote memory quote,
        uint256 chainId,
        address target
    ) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("MiniBuildingCollector"), keccak256("1"), chainId, target
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                quote.quoteId,
                quote.account,
                quote.miniAmount,
                quote.mintingCount,
                quote.additionalHunt,
                quote.deadline
            )
        );
        return keccak256(abi.encodePacked(hex"1901", domain, structHash));
    }

    function _assertUntouched() internal view {
        assertFalse(collector.consumedQuotes(QUOTE_ID));
        assertEq(building.balanceOf(ALICE, 0), 100);
        assertEq(building.balanceOf(custody, 0), 0);
        assertEq(hunt.balanceOf(ALICE), 10_000 ether);
        assertEq(hunt.balanceOf(custody), 0);
    }

    function _custody(bool rejectTransfer) internal returns (CollectorTestCustody receiver) {
        CollectorTestCustody implementation = new CollectorTestCustody();
        vm.etch(custody, address(implementation).code);
        receiver = CollectorTestCustody(custody);
        receiver.configure(collector, QUOTE_ID, rejectTransfer);
    }
}
