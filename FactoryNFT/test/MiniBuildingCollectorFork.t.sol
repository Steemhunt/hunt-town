// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { MiniBuildingCollector } from "../src/MiniBuildingCollector.sol";

/// @notice Exercises deployed Base Mini Building and HUNT transfers on a pinned fork.
/// @dev Only local test accounts are funded with storage cheatcodes; nothing is broadcast.
contract MiniBuildingCollectorForkTest is Test {
    uint256 internal constant FORK_BLOCK = 51_941_900;
    address internal constant BUILDING = 0x475f8E3eE5457f7B4AAca7E989D35418657AdF2a;
    address internal constant HUNT = 0x37f0c2915CeCC7e977183B8543Fc0864d03E064C;
    address internal constant CUSTODY = 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D;

    bool internal forkEnabled;
    MiniBuildingCollector internal collector;
    IERC1155 internal building;
    IERC20 internal hunt;
    address internal alice;
    uint256 internal signerKey;

    modifier onBaseFork() {
        vm.skip(!forkEnabled, "Set BASE_RPC_URL to run optional Base collector fork tests");
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        forkEnabled = true;
        assertEq(block.chainid, 8453, "Expected Base mainnet");
        assertGt(BUILDING.code.length, 0);
        assertGt(HUNT.code.length, 0);
        assertEq(CUSTODY.code.length, 0, "Pinned custody fixture is an EOA");
        address signer;
        (signer, signerKey) = makeAddrAndKey("collector fork quote signer");
        alice = makeAddr("collector fork alice");
        building = IERC1155(BUILDING);
        hunt = IERC20(HUNT);
        collector = new MiniBuildingCollector(building, hunt, address(this), signer);
        dealERC1155(BUILDING, alice, 0, 9);
        deal(HUNT, alice, 100 ether);
        vm.prank(alice);
        building.setApprovalForAll(address(collector), true);
    }

    function testForkSignedDepositMovesBothAssetsToCustodyAndCannotReplay() public onBaseFork {
        MiniBuildingCollector.MigrationQuote memory quote = _quote(100 ether);
        bytes memory signature = _sign(quote);
        uint256 minisBefore = building.balanceOf(CUSTODY, 0);
        uint256 huntBefore = hunt.balanceOf(CUSTODY);
        vm.prank(alice);
        hunt.approve(address(collector), quote.additionalHunt);
        vm.expectEmit(address(collector));
        emit MiniBuildingCollector.Deposited(quote.quoteId, alice, 9, 1, 100 ether);
        vm.prank(alice);
        collector.deposit(quote, signature);
        assertEq(building.balanceOf(CUSTODY, 0), minisBefore + 9);
        assertEq(hunt.balanceOf(CUSTODY), huntBefore + 100 ether);
        assertEq(building.balanceOf(alice, 0), 0);
        assertEq(hunt.balanceOf(alice), 0);
        assertEq(hunt.allowance(alice, address(collector)), 0);
        _assertCollectorEmpty();
        assertTrue(collector.consumedQuotes(quote.quoteId));
        vm.expectRevert(
            abi.encodeWithSelector(MiniBuildingCollector.QuoteAlreadyUsed.selector, quote.quoteId)
        );
        vm.prank(alice);
        collector.deposit(quote, signature);
    }

    function testForkZeroTopUpNeedsNoHuntApproval() public onBaseFork {
        MiniBuildingCollector.MigrationQuote memory quote = _quote(0);
        bytes memory signature = _sign(quote);
        uint256 minisBefore = building.balanceOf(CUSTODY, 0);
        uint256 huntBefore = hunt.balanceOf(CUSTODY);
        vm.prank(alice);
        collector.deposit(quote, signature);
        assertEq(building.balanceOf(CUSTODY, 0), minisBefore + 9);
        assertEq(hunt.balanceOf(CUSTODY), huntBefore);
        assertEq(building.balanceOf(alice, 0), 0);
        assertEq(hunt.balanceOf(alice), 100 ether);
        assertEq(hunt.allowance(alice, address(collector)), 0);
        assertTrue(collector.consumedQuotes(quote.quoteId));
        _assertCollectorEmpty();
    }

    function testForkFailedHuntPaymentRollsBackMiniTransferAndCanRetry() public onBaseFork {
        MiniBuildingCollector.MigrationQuote memory quote = _quote(100 ether);
        bytes memory signature = _sign(quote);
        uint256 minisBefore = building.balanceOf(CUSTODY, 0);
        uint256 huntBefore = hunt.balanceOf(CUSTODY);
        vm.expectRevert();
        vm.prank(alice);
        collector.deposit(quote, signature);
        assertEq(building.balanceOf(CUSTODY, 0), minisBefore);
        assertEq(hunt.balanceOf(CUSTODY), huntBefore);
        assertEq(building.balanceOf(alice, 0), 9);
        assertEq(hunt.balanceOf(alice), 100 ether);
        assertFalse(collector.consumedQuotes(quote.quoteId));
        vm.prank(alice);
        hunt.approve(address(collector), 100 ether);
        vm.prank(alice);
        collector.deposit(quote, signature);
        assertTrue(collector.consumedQuotes(quote.quoteId));
        assertEq(building.balanceOf(CUSTODY, 0), minisBefore + 9);
        assertEq(hunt.balanceOf(CUSTODY), huntBefore + 100 ether);
        _assertCollectorEmpty();
    }

    function _quote(uint256 topUp)
        private
        view
        returns (MiniBuildingCollector.MigrationQuote memory)
    {
        return MiniBuildingCollector.MigrationQuote({
            quoteId: keccak256("collector fork quote"),
            account: alice,
            miniAmount: 9,
            mintingCount: 1,
            additionalHunt: topUp,
            deadline: block.timestamp + 15 minutes
        });
    }

    function _sign(MiniBuildingCollector.MigrationQuote memory quote)
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, collector.hashQuote(quote));
        return abi.encodePacked(r, s, v);
    }

    function _assertCollectorEmpty() private view {
        assertEq(building.balanceOf(address(collector), 0), 0);
        assertEq(hunt.balanceOf(address(collector)), 0);
    }
}
