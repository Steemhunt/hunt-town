// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { IFactoryNFT } from "../src/interfaces/IFactoryNFT.sol";
import { BuildingMigrator } from "../src/BuildingMigrator.sol";

interface IMigrationForkBuilding is IERC721 {
    function nextId() external view returns (uint256);
}

interface IMigrationForkTownHall {
    function mint(address to) external;
    function unlockTime(uint256 tokenId) external view returns (uint256);
}

/// @notice Uses deployed Ethereum HUNT, Building, TownHall, and FactoryNFT contracts.
/// @dev Only test accounts receive local funding. No transactions are broadcast.
contract BuildingMigratorForkTest is Test {
    using SafeERC20 for IERC20;

    uint256 internal constant FORK_BLOCK = 26_073_640;
    address internal constant HUNT = 0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5;
    address internal constant FACTORY = 0x961eA6C51c185958b1A11ad8335046988D1B5734;
    address internal constant BUILDING = 0x0c9Bb1ffF512a5B4F01aCA6ad964Ec6D7fC60c96;
    address internal constant TOWN_HALL = 0xb09A1410cF4C49F92482F5cd2CbF19b638907193;
    address internal constant RECEIVER = 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D;
    uint256 internal constant BUILDING_VALUE = 1_000e18;

    struct Balances {
        uint256 factoryHunt;
        uint256 factorySupply;
        uint256 callerFactory;
        uint256 callerHunt;
        uint256 receiverHunt;
        uint256 townHallHunt;
        uint256 migratorHunt;
    }

    bool internal forkEnabled;
    IERC20 internal hunt;
    FactoryNFT internal factory;
    IMigrationForkBuilding internal building;
    IMigrationForkTownHall internal townHall;
    BuildingMigrator internal migrator;
    address internal alice = makeAddr("migration fork alice");
    address internal bob = makeAddr("migration fork bob");
    address internal operator = makeAddr("migration fork operator");

    modifier onMainnetFork() {
        vm.skip(!forkEnabled, "Set MAINNET_RPC_URL to run optional Ethereum migration fork tests");
        _;
    }

    function setUp() public {
        string memory rpcUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        // The older general MAINNET_FORK_BLOCK predates the deployed FactoryNFT.
        uint256 forkBlock = vm.envOr("MIGRATION_FORK_BLOCK", FORK_BLOCK);
        vm.createSelectFork(rpcUrl, forkBlock);
        forkEnabled = true;
        assertEq(block.chainid, 1, "Expected Ethereum mainnet");
        assertGe(block.number, FORK_BLOCK, "Migration fork must include FactoryNFT deployment");
        assertGt(FACTORY.code.length, 0, "FactoryNFT must be deployed");
        assertGt(BUILDING.code.length, 0, "Building must be deployed");
        assertGt(TOWN_HALL.code.length, 0, "TownHall must be deployed");
        assertEq(RECEIVER.code.length, 0, "Pinned migration custody fixture is an EOA");

        hunt = IERC20(HUNT);
        factory = FactoryNFT(FACTORY);
        building = IMigrationForkBuilding(BUILDING);
        townHall = IMigrationForkTownHall(TOWN_HALL);
        assertEq(address(factory.huntToken()), HUNT);
        assertEq(factory.quoteMint(1), BUILDING_VALUE, "Pinned Factory starts at 1,000 HUNT NAV");
        migrator = new BuildingMigrator(
            IFactoryNFT(FACTORY), IERC721(BUILDING), address(this), operator
        );
        assertEq(migrator.MIGRATION_RECEIVER(), RECEIVER);
    }

    function testForkExistingUnlockedBuildingMigratesAtInitialNav() public onMainnetFork {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        address holder = building.ownerOf(ids[0]);
        assertEq(
            holder.code.length, 0, "Existing Building owner must accept direct Factory delivery"
        );
        assertLe(townHall.unlockTime(ids[0]), block.timestamp);
        (uint256 quantity, uint256 additional, uint256 cost) = migrator.quoteMigration(1);
        assertEq(quantity, 1);
        assertEq(additional, 0);
        assertEq(cost, BUILDING_VALUE);
        _fundMigrator(cost + 17);
        vm.prank(holder);
        building.approve(address(migrator), ids[0]);
        Balances memory before = _balances(holder);

        vm.prank(holder);
        (uint256 minted, uint256 paid) = migrator.migrate(ids, 0);

        assertEq(minted, quantity);
        assertEq(paid, additional);
        _assertMigration(ids, holder, minted, paid, cost, before);
        assertEq(hunt.balanceOf(address(migrator)), 17, "Prefunding surplus remains available");
        assertEq(building.getApproved(ids[0]), address(0));
    }

    function testForkTenFreshLockedBuildingsMintNineAtHigherNav() public onMainnetFork {
        uint256[] memory ids = _freshBuildings(10);
        _raiseNav(1_200e18);
        (uint256 quantity, uint256 additional, uint256 cost) = migrator.quoteMigration(10);
        assertEq(quantity, 9);
        assertEq(additional, 800e18);
        assertEq(cost, 10_800e18);
        _fundMigrator(cost + 17);
        _approveTopUp(additional);
        Balances memory before = _balances(alice);

        vm.prank(alice);
        (uint256 minted, uint256 paid) = migrator.migrate(ids, additional);

        assertEq(minted, quantity);
        assertEq(paid, additional);
        _assertMigration(ids, alice, minted, paid, cost, before);
        assertEq(factory.navPerNFT(), 1_200e18);
        assertEq(hunt.allowance(alice, address(migrator)), 0);
        for (uint256 i; i < ids.length; ++i) {
            assertGt(
                townHall.unlockTime(ids[i]), block.timestamp, "Transferred Buildings stay locked"
            );
        }
    }

    function testForkAdditionalHuntLimitRevertsEveryAssetChange() public onMainnetFork {
        uint256[] memory ids = _freshBuildings(10);
        _raiseNav(1_200e18);
        _fundMigrator(10_800e18);
        _approveTopUp(800e18);
        Balances memory before = _balances(alice);

        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.AdditionalHuntExceeded.selector, 800e18, 799e18)
        );
        vm.prank(alice);
        migrator.migrate(ids, 799e18);

        _assertRollback(ids, alice, before);
        assertEq(hunt.allowance(alice, address(migrator)), 800e18);
    }

    function testForkTopUpCannotSubstituteForFullMintPrefunding() public onMainnetFork {
        uint256[] memory ids = _freshBuildings(1);
        _raiseNav(1_200e18);
        _fundMigrator(1_000e18);
        _approveTopUp(200e18);
        Balances memory before = _balances(alice);

        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.InsufficientHunt.selector, 1_000e18, 1_200e18)
        );
        vm.prank(alice);
        migrator.migrate(ids, 200e18);

        _assertRollback(ids, alice, before);
        assertEq(hunt.allowance(alice, address(migrator)), 200e18);
    }

    function testForkOperatorFailuresRemainRetryableAndSuccessCannotReplay() public onMainnetFork {
        bytes32 requestId = keccak256("migration fork Base fulfillment request");
        uint256 cost = factory.quoteMint(2);
        vm.expectRevert(BuildingMigrator.UnauthorizedOperator.selector);
        vm.prank(alice);
        migrator.migrateByOperator(2, bob, requestId, cost);
        assertFalse(migrator.processedRequests(requestId));

        vm.expectRevert(abi.encodeWithSelector(BuildingMigrator.InsufficientHunt.selector, 0, cost));
        vm.prank(operator);
        migrator.migrateByOperator(2, bob, requestId, cost);
        assertFalse(migrator.processedRequests(requestId));

        _fundMigrator(cost);
        Balances memory before = _balances(bob);
        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.MintPriceExceeded.selector, cost, cost - 1)
        );
        vm.prank(operator);
        migrator.migrateByOperator(2, bob, requestId, cost - 1);
        assertFalse(migrator.processedRequests(requestId));
        assertEq(hunt.balanceOf(address(migrator)), cost);
        assertEq(factory.balanceOf(bob, 0), before.callerFactory);

        vm.prank(operator);
        assertEq(migrator.migrateByOperator(2, bob, requestId, cost), cost);
        assertTrue(migrator.processedRequests(requestId));
        assertEq(hunt.balanceOf(address(migrator)), 0);
        assertEq(hunt.balanceOf(FACTORY), before.factoryHunt + cost);
        assertEq(factory.totalSupply(0), before.factorySupply + 2);
        assertEq(factory.balanceOf(bob, 0), before.callerFactory + 2);
        assertEq(hunt.balanceOf(RECEIVER), before.receiverHunt);
        assertEq(hunt.balanceOf(bob), before.callerHunt);
        assertEq(hunt.balanceOf(TOWN_HALL), before.townHallHunt);

        vm.expectRevert(
            abi.encodeWithSelector(BuildingMigrator.RequestAlreadyProcessed.selector, requestId)
        );
        vm.prank(operator);
        migrator.migrateByOperator(2, bob, requestId, cost);
        assertEq(factory.balanceOf(bob, 0), before.callerFactory + 2);
        assertEq(hunt.balanceOf(FACTORY), before.factoryHunt + cost);
    }

    function _freshBuildings(uint256 count) private returns (uint256[] memory ids) {
        ids = new uint256[](count);
        uint256 nextId = building.nextId();
        deal(HUNT, alice, count * BUILDING_VALUE);
        vm.startPrank(alice);
        hunt.forceApprove(TOWN_HALL, count * BUILDING_VALUE);
        for (uint256 i; i < count; ++i) {
            ids[i] = nextId + i;
            townHall.mint(alice);
            assertEq(building.ownerOf(ids[i]), alice);
            assertGt(townHall.unlockTime(ids[i]), block.timestamp);
        }
        building.setApprovalForAll(address(migrator), true);
        vm.stopPrank();
    }

    function _raiseNav(uint256 nav) private {
        uint256 targetBalance = nav * factory.totalSupply(0);
        uint256 donation = targetBalance - hunt.balanceOf(FACTORY);
        deal(HUNT, address(this), donation);
        hunt.safeTransfer(FACTORY, donation);
        assertEq(factory.navPerNFT(), nav);
    }

    function _fundMigrator(uint256 amount) private {
        deal(HUNT, address(this), amount);
        hunt.safeTransfer(address(migrator), amount);
    }

    function _approveTopUp(uint256 amount) private {
        deal(HUNT, alice, amount);
        vm.prank(alice);
        hunt.forceApprove(address(migrator), amount);
    }

    function _balances(address caller) private view returns (Balances memory) {
        return Balances({
            factoryHunt: hunt.balanceOf(FACTORY),
            factorySupply: factory.totalSupply(0),
            callerFactory: factory.balanceOf(caller, 0),
            callerHunt: hunt.balanceOf(caller),
            receiverHunt: hunt.balanceOf(RECEIVER),
            townHallHunt: hunt.balanceOf(TOWN_HALL),
            migratorHunt: hunt.balanceOf(address(migrator))
        });
    }

    function _assertMigration(
        uint256[] memory ids,
        address caller,
        uint256 quantity,
        uint256 additional,
        uint256 cost,
        Balances memory before
    ) private view {
        assertEq(hunt.balanceOf(FACTORY), before.factoryHunt + cost);
        assertEq(factory.totalSupply(0), before.factorySupply + quantity);
        assertEq(factory.balanceOf(caller, 0), before.callerFactory + quantity);
        assertEq(hunt.balanceOf(caller), before.callerHunt - additional);
        assertEq(hunt.balanceOf(RECEIVER), before.receiverHunt + additional);
        assertEq(hunt.balanceOf(TOWN_HALL), before.townHallHunt);
        assertEq(hunt.balanceOf(address(migrator)), before.migratorHunt - cost);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(building.ownerOf(ids[i]), RECEIVER);
            assertTrue(migrator.migratedBuildings(ids[i]));
        }
    }

    function _assertRollback(uint256[] memory ids, address caller, Balances memory before)
        private
        view
    {
        assertEq(hunt.balanceOf(FACTORY), before.factoryHunt);
        assertEq(factory.totalSupply(0), before.factorySupply);
        assertEq(factory.balanceOf(caller, 0), before.callerFactory);
        assertEq(hunt.balanceOf(caller), before.callerHunt);
        assertEq(hunt.balanceOf(RECEIVER), before.receiverHunt);
        assertEq(hunt.balanceOf(TOWN_HALL), before.townHallHunt);
        assertEq(hunt.balanceOf(address(migrator)), before.migratorHunt);
        for (uint256 i; i < ids.length; ++i) {
            assertEq(building.ownerOf(ids[i]), caller);
            assertFalse(migrator.migratedBuildings(ids[i]));
        }
    }
}
