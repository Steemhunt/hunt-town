// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { IFactoryNFT } from "../src/interfaces/IFactoryNFT.sol";
import { BuildingMigrator } from "../src/BuildingMigrator.sol";
import { FactoryNFTTestBase } from "./FactoryNFT.t.sol";
import {
    MigratorTestBuilding,
    MigratorTestReceiver,
    MigratorTestCustody
} from "./mocks/BuildingMigratorMocks.sol";

contract BuildingMigratorTest is FactoryNFTTestBase {
    address internal constant OPERATOR = address(0x0BEE);
    uint256 internal constant FUNDING = 1_000_000 ether;
    bytes32 internal constant REQUEST = keccak256("Base receipt");
    BuildingMigrator internal migrator;
    MigratorTestBuilding internal building;
    address internal custody;

    function setUp() public override {
        super.setUp();
        building = new MigratorTestBuilding();
        migrator = new BuildingMigrator(factory, building, address(this), OPERATOR);
        custody = migrator.MIGRATION_RECEIVER();
        hunt.mint(address(migrator), FUNDING);
    }

    function testConfigurationAndZeroQuote() public {
        assertEq(address(migrator.factory()), address(factory));
        assertEq(address(migrator.building()), address(building));
        assertEq(address(migrator.huntToken()), address(hunt));
        assertEq(migrator.owner(), address(this));
        assertEq(migrator.operator(), OPERATOR);
        assertEq(migrator.BUILDING_VALUE(), SEED);
        assertEq(custody, 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D);
        vm.expectRevert(BuildingMigrator.InvalidAmount.selector);
        migrator.quoteMigration(0);
        vm.expectRevert(BuildingMigrator.InvalidAmount.selector);
        migrator.migrate(new uint256[](0), 0);
    }

    function testConstructorRejectsInvalidContractsAndOwner() public {
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        new BuildingMigrator(IFactoryNFT(ALICE), building, address(this), OPERATOR);
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        new BuildingMigrator(factory, IERC721(ALICE), address(this), OPERATOR);
        vm.mockCall(address(factory), abi.encodeCall(IFactoryNFT.huntToken, ()), abi.encode(ALICE));
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        new BuildingMigrator(factory, building, address(this), OPERATOR);
        vm.clearMockedCalls();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BuildingMigrator(factory, building, address(0), OPERATOR);
    }

    function testMigrationAtInitialNavNeedsNoHuntFromUser() public {
        uint256[] memory ids = _buildings(ALICE, 2);
        vm.expectEmit(address(migrator));
        emit BuildingMigrator.Migrated(ALICE, ids, 2, 0, 2 * SEED);
        vm.prank(ALICE);
        (uint256 count, uint256 additional) = migrator.migrate(ids, 0);
        assertEq(count, 2);
        assertEq(additional, 0);
        _assertMigrated(ALICE, ids, 2, 0, 2 * SEED);
    }

    function testTenBuildingsAtTwelveHundredMintNineWithEightHundredTopUp() public {
        _donate(200 ether);
        uint256[] memory ids = _buildings(ALICE, 10);
        _approveTopUp(ALICE, 1_000 ether);
        (uint256 count, uint256 additional, uint256 cost) = migrator.quoteMigration(10);
        assertEq(count, 9);
        assertEq(additional, 800 ether);
        assertEq(cost, 10_800 ether);
        vm.prank(ALICE);
        migrator.migrate(ids, 1_000 ether);
        _assertMigrated(ALICE, ids, count, additional, cost);
        assertEq(hunt.balanceOf(ALICE), 200 ether);
        assertEq(hunt.allowance(ALICE, address(migrator)), 200 ether);
        assertEq(factory.navPerNFT(), 1_200 ether);
    }

    function testExactCreditMultipleHasNoTopUp() public {
        _donate(1_000 ether);
        uint256[] memory ids = _buildings(ALICE, 2);
        vm.prank(ALICE);
        (uint256 count, uint256 additional) = migrator.migrate(ids, 0);
        assertEq(count, 1);
        assertEq(additional, 0);
        _assertMigrated(ALICE, ids, 1, 0, 2_000 ether);
    }

    function testBatchRoundingUsesActualCostAndDoesNotUnderflowBelowCredit() public {
        _mintFor(BOB, 2);
        // Three units have backing one wei below 3 * 1,250 HUNT.
        _donate(750 ether - 1);
        uint256[] memory ids = _buildings(ALICE, 5);
        assertEq(factory.quoteMint(1), 1_250 ether);
        (uint256 count, uint256 additional, uint256 cost) = migrator.quoteMigration(5);
        assertEq(count, 4);
        assertEq(cost, 5_000 ether - 1);
        assertEq(additional, 0);
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        assertEq(hunt.balanceOf(address(migrator)), FUNDING - cost);
        assertEq(factory.balanceOf(ALICE, 0), count);
    }

    function testBatchRoundingDoesNotOverchargeSingleUnitQuoteTimesQuantity() public {
        _mintFor(BOB, 2);
        _donate(1);
        uint256[] memory ids = _buildings(ALICE, 2);
        _approveTopUp(ALICE, 2);
        (uint256 count, uint256 additional, uint256 cost) = migrator.quoteMigration(2);
        assertEq(count, 2);
        assertEq(additional, 1);
        assertEq(cost, 2 * SEED + 1);
        vm.prank(ALICE);
        migrator.migrate(ids, additional);
        assertEq(hunt.balanceOf(ALICE), 1);
        assertEq(hunt.balanceOf(custody), 1);
    }

    function testTopUpCeilingUsesCurrentNavAndLeavesAssetsUntouched() public {
        uint256[] memory ids = _buildings(ALICE, 1);
        _approveTopUp(ALICE, 200 ether);
        _donate(200 ether);
        vm.expectRevert(
            abi.encodeWithSelector(
                BuildingMigrator.AdditionalHuntExceeded.selector, 200 ether, 199 ether
            )
        );
        vm.prank(ALICE);
        migrator.migrate(ids, 199 ether);
        _assertUnchanged(ALICE, ids);
        assertEq(hunt.balanceOf(ALICE), 200 ether);
    }

    function testInsufficientPrefundingCannotBeCoveredByTheUserTopUp() public {
        uint256[] memory ids = _buildings(ALICE, 1);
        _approveTopUp(ALICE, 200 ether);
        _donate(200 ether);
        deal(address(hunt), address(migrator), SEED);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.InsufficientHunt.selector, SEED, 1_200 ether)
        );
        vm.prank(ALICE);
        migrator.migrate(ids, 200 ether);
        assertEq(building.ownerOf(0), ALICE);
        assertFalse(migrator.migratedBuildings(0));
        assertEq(hunt.balanceOf(ALICE), 200 ether);
        assertEq(hunt.balanceOf(custody), 0);
        assertEq(hunt.balanceOf(address(migrator)), SEED);
    }

    function testDuplicateAndAlreadyMigratedIdsCannotSpendFundingAgain() public {
        uint256[] memory ids = _buildings(ALICE, 2);
        ids[1] = ids[0];
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.BuildingAlreadyMigrated.selector, 0)
        );
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        assertFalse(migrator.migratedBuildings(0));
        assertEq(building.ownerOf(0), ALICE);
        ids = _oneId(0);
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        vm.prank(custody);
        building.transferFrom(custody, ALICE, 0);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.BuildingAlreadyMigrated.selector, 0)
        );
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        assertEq(hunt.balanceOf(address(migrator)), FUNDING - SEED);
        assertEq(factory.balanceOf(ALICE, 0), 1);
    }

    function testApprovalDoesNotLetAnotherCallerMigrateTheOwnersBuilding() public {
        uint256[] memory ids = _buildings(ALICE, 1);
        vm.prank(ALICE);
        building.setApprovalForAll(BOB, true);
        vm.expectRevert();
        vm.prank(BOB);
        migrator.migrate(ids, 0);
        _assertUnchanged(ALICE, ids);
    }

    function testMissingNftApprovalOrNonexistentIdRollsBackEarlierTransfers() public {
        uint256[] memory ids = _buildings(ALICE, 2);
        vm.prank(ALICE);
        building.setApprovalForAll(address(migrator), false);
        vm.expectRevert();
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        _assertUnchanged(ALICE, ids);
        vm.prank(ALICE);
        building.setApprovalForAll(address(migrator), true);
        ids[1] = 99;
        vm.expectRevert();
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        assertEq(building.ownerOf(0), ALICE);
        assertFalse(migrator.migratedBuildings(0));
        assertFalse(migrator.migratedBuildings(99));
    }

    function testMissingTopUpAllowanceOrBalanceRevertsNftTransfers() public {
        uint256[] memory ids = _buildings(ALICE, 1);
        _donate(200 ether);
        hunt.mint(ALICE, 200 ether);
        vm.expectRevert();
        vm.prank(ALICE);
        migrator.migrate(ids, 200 ether);
        _assertUnchanged(ALICE, ids);
        vm.prank(ALICE);
        hunt.approve(address(migrator), 200 ether);
        deal(address(hunt), ALICE, 199 ether);
        vm.expectRevert();
        vm.prank(ALICE);
        migrator.migrate(ids, 200 ether);
        _assertUnchanged(ALICE, ids);
    }

    function testFactoryReceiverCanRejectWithoutLosingLegacyAssetsOrFunding() public {
        MigratorTestReceiver receiver = new MigratorTestReceiver();
        receiver.configure(migrator, true);
        uint256[] memory ids = _buildings(address(receiver), 1);
        _donate(200 ether);
        hunt.mint(address(receiver), 200 ether);
        vm.expectRevert();
        receiver.migrate(ids, 200 ether);
        _assertUnchanged(address(receiver), ids);
        assertEq(hunt.balanceOf(address(receiver)), 200 ether);
    }

    function testBothMigrationEntrypointsRejectReentryFromMintCallbacks() public {
        MigratorTestReceiver receiver = new MigratorTestReceiver();
        receiver.configure(migrator, false);
        migrator.setOperator(address(receiver));
        uint256[] memory ids = _buildings(address(receiver), 1);
        receiver.migrate(ids, 0);
        assertFalse(receiver.reentrySucceeded());
        assertFalse(receiver.operatorReentrySucceeded());
        bytes memory expected = abi.encodeWithSelector(
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector
        );
        assertEq(receiver.reentryResult(), expected);
        assertEq(receiver.operatorReentryResult(), expected);
        assertFalse(migrator.processedRequests(keccak256("nested receipt")));
        assertEq(factory.balanceOf(address(receiver), 0), 1);
    }

    function testCustodyCallbackCannotIncreaseNavAfterQuoteWithoutReverting() public {
        MigratorTestCustody template = new MigratorTestCustody();
        vm.etch(custody, address(template).code);
        MigratorTestCustody(custody).configure(factory, hunt, 100 ether);
        hunt.mint(custody, 100 ether);
        uint256[] memory ids = _buildings(ALICE, 1);
        vm.expectRevert(
            abi.encodeWithSelector(FactoryNFT.MintPriceExceeded.selector, 1_100 ether, SEED)
        );
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        assertEq(building.ownerOf(0), ALICE);
        assertFalse(migrator.migratedBuildings(0));
        assertEq(hunt.balanceOf(custody), 100 ether);
        assertEq(hunt.balanceOf(address(migrator)), FUNDING);
        assertEq(factory.navPerNFT(), SEED);
    }

    function testOperatorFulfillsOnceForTheChosenReceiverWithoutAssetsFromThem() public {
        _donate(200 ether);
        vm.expectEmit(address(migrator));
        emit BuildingMigrator.OperatorMigrated(REQUEST, ALICE, 3, 3_600 ether);
        vm.prank(OPERATOR);
        assertEq(migrator.migrateByOperator(3, ALICE, REQUEST, 3_600 ether), 3_600 ether);
        assertTrue(migrator.processedRequests(REQUEST));
        assertEq(factory.balanceOf(ALICE, 0), 3);
        assertEq(hunt.balanceOf(ALICE), 0);
        assertEq(hunt.balanceOf(custody), 0);
        assertEq(hunt.balanceOf(address(migrator)), FUNDING - 3_600 ether);
        assertEq(hunt.allowance(address(migrator), address(factory)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.RequestAlreadyProcessed.selector, REQUEST)
        );
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, BOB, REQUEST, SEED);
        assertEq(factory.balanceOf(BOB, 0), 0);
    }

    function testOperatorAuthorizationAndInvalidRequests() public {
        vm.expectRevert(BuildingMigrator.UnauthorizedOperator.selector);
        migrator.migrateByOperator(1, ALICE, REQUEST, SEED);
        vm.expectRevert(BuildingMigrator.UnauthorizedOperator.selector);
        vm.prank(ALICE);
        migrator.migrateByOperator(1, ALICE, REQUEST, SEED);
        vm.startPrank(OPERATOR);
        vm.expectRevert(BuildingMigrator.InvalidAmount.selector);
        migrator.migrateByOperator(0, ALICE, REQUEST, SEED);
        vm.expectRevert(BuildingMigrator.InvalidRequestId.selector);
        migrator.migrateByOperator(1, ALICE, bytes32(0), SEED);
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        migrator.migrateByOperator(1, address(0), REQUEST, SEED);
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        migrator.migrateByOperator(1, address(migrator), REQUEST, SEED);
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        migrator.migrateByOperator(1, address(factory), REQUEST, SEED);
        vm.stopPrank();
        assertFalse(migrator.processedRequests(REQUEST));
    }

    function testOperatorRequestsRemainRetryableAfterFailure() public {
        _donate(200 ether);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.MintPriceExceeded.selector, 1_200 ether, SEED)
        );
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, ALICE, REQUEST, SEED);
        assertFalse(migrator.processedRequests(REQUEST));
        deal(address(hunt), address(migrator), 0);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.InsufficientHunt.selector, 0, 1_200 ether)
        );
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, ALICE, REQUEST, 1_200 ether);
        assertFalse(migrator.processedRequests(REQUEST));
        hunt.mint(address(migrator), 1_200 ether);
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, ALICE, REQUEST, 1_200 ether);
        assertTrue(migrator.processedRequests(REQUEST));
        assertEq(factory.balanceOf(ALICE, 0), 1);
    }

    function testRejectedOperatorMintRollsBackTheRequestAndCanBeRetried() public {
        MigratorTestReceiver receiver = new MigratorTestReceiver();
        receiver.configure(migrator, true);
        vm.expectRevert();
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, address(receiver), REQUEST, SEED);
        assertFalse(migrator.processedRequests(REQUEST));
        assertEq(hunt.balanceOf(address(migrator)), FUNDING);
        receiver.configure(migrator, false);
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, address(receiver), REQUEST, SEED);
        assertTrue(migrator.processedRequests(REQUEST));
        assertEq(factory.balanceOf(address(receiver), 0), 1);
        assertFalse(receiver.reentrySucceeded());
    }

    function testOwnerCanRotateOrDisableOperatorWithoutResettingReceipts() public {
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, ALICE, REQUEST, SEED);
        vm.expectEmit(address(migrator));
        emit BuildingMigrator.OperatorUpdated(OPERATOR, BOB);
        migrator.setOperator(BOB);
        vm.expectRevert(BuildingMigrator.UnauthorizedOperator.selector);
        vm.prank(OPERATOR);
        migrator.migrateByOperator(1, ALICE, keccak256("second"), SEED);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.RequestAlreadyProcessed.selector, REQUEST)
        );
        vm.prank(BOB);
        migrator.migrateByOperator(1, ALICE, REQUEST, SEED);
        migrator.setOperator(address(0));
        vm.expectRevert(BuildingMigrator.UnauthorizedOperator.selector);
        vm.prank(BOB);
        migrator.migrateByOperator(1, ALICE, keccak256("second"), SEED);
        uint256[] memory ids = _buildings(ALICE, 1);
        vm.prank(ALICE);
        migrator.migrate(ids, 0);
        assertEq(factory.balanceOf(ALICE, 0), 2);
    }

    function testReserveWithdrawalsGoOnlyToCustodyAndAdminRequiresOwner() public {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, OPERATOR)
        );
        vm.prank(OPERATOR);
        migrator.withdrawHunt(1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        vm.prank(ALICE);
        migrator.setOperator(ALICE);
        vm.expectEmit(address(migrator));
        emit BuildingMigrator.HuntWithdrawn(FUNDING);
        migrator.withdrawHunt(FUNDING);
        assertEq(hunt.balanceOf(custody), FUNDING);
        assertEq(hunt.balanceOf(address(migrator)), 0);
        migrator.transferOwnership(BOB);
        assertEq(migrator.owner(), address(this));
        vm.prank(BOB);
        migrator.acceptOwnership();
        vm.prank(BOB);
        migrator.setOperator(ALICE);
        assertEq(migrator.owner(), BOB);
        assertEq(migrator.operator(), ALICE);
    }

    function testFuzzMigrationConservesFundingAndCredit(uint8 rawCount, uint96 rawDonation) public {
        uint256 buildingCount = bound(uint256(rawCount), 1, 40);
        _donate(bound(uint256(rawDonation), 0, 100_000 ether));
        uint256[] memory ids = _buildings(ALICE, buildingCount);
        uint256 singlePrice = factory.quoteMint(1);
        (uint256 count, uint256 additional, uint256 cost) = migrator.quoteMigration(buildingCount);
        assertEq(count, (buildingCount * SEED + singlePrice - 1) / singlePrice);
        assertEq(cost, factory.quoteMint(count));
        assertEq(cost, buildingCount * SEED + additional);
        _approveTopUp(ALICE, additional);
        uint256 vaultBefore = hunt.balanceOf(address(factory));
        vm.prank(ALICE);
        migrator.migrate(ids, additional);
        _assertMigrated(ALICE, ids, count, additional, cost);
        assertEq(hunt.balanceOf(address(factory)), vaultBefore + cost);
        assertEq(hunt.balanceOf(ALICE), 0);
    }

    function _buildings(address account, uint256 count) internal returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = i;
            building.mint(account, i);
        }
        vm.prank(account);
        building.setApprovalForAll(address(migrator), true);
    }

    function _approveTopUp(address account, uint256 amount) internal {
        hunt.mint(account, amount);
        vm.prank(account);
        hunt.approve(address(migrator), amount);
    }

    function _oneId(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function _assertMigrated(
        address account,
        uint256[] memory ids,
        uint256 count,
        uint256 additional,
        uint256 cost
    ) internal view {
        for (uint256 i; i < ids.length; ++i) {
            assertEq(building.ownerOf(ids[i]), custody);
            assertTrue(migrator.migratedBuildings(ids[i]));
        }
        assertEq(factory.balanceOf(account, 0), count);
        assertEq(hunt.balanceOf(custody), additional);
        assertEq(hunt.balanceOf(address(migrator)), FUNDING - cost);
        assertEq(hunt.allowance(address(migrator), address(factory)), 0);
    }

    function _assertUnchanged(address account, uint256[] memory ids) internal view {
        for (uint256 i; i < ids.length; ++i) {
            assertEq(building.ownerOf(ids[i]), account);
            assertFalse(migrator.migratedBuildings(ids[i]));
        }
        assertEq(hunt.balanceOf(address(migrator)), FUNDING);
        assertEq(hunt.balanceOf(custody), 0);
        assertEq(factory.balanceOf(account, 0), 0);
        assertEq(hunt.allowance(address(migrator), address(factory)), 0);
    }
}
