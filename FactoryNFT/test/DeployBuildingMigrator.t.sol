// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DeployBuildingMigrator } from "../script/DeployBuildingMigrator.s.sol";
import { BuildingMigrator } from "../src/BuildingMigrator.sol";
import { FactoryTestHunt } from "./mocks/FactoryNFTMocks.sol";

contract DeployMigratorFactoryStub {
    IERC20 public immutable huntToken;

    constructor(IERC20 hunt) {
        huntToken = hunt;
    }
}

contract DeployBuildingMigratorTest is Test {
    function testDeploymentGuardsAndOwnerOperatorWiring() public {
        DeployBuildingMigrator deployment = new DeployBuildingMigrator();
        FactoryTestHunt hunt = new FactoryTestHunt();
        DeployMigratorFactoryStub template = new DeployMigratorFactoryStub(hunt);
        vm.etch(deployment.FACTORY(), address(template).code);
        // Deployment only checks that the existing Building address has code.
        vm.etch(deployment.BUILDING(), hex"00");

        // DEPLOYER is process-global; use the same value as DeployFactoryTest.
        // Keep the unique migrator environment configuration in this single test.
        address deployer = makeAddr("deployer");
        address owner = makeAddr("migrator owner");
        address operator = makeAddr("migrator operator");
        vm.setNonce(deployer, 42);
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.setEnv("MIGRATOR_OWNER", vm.toString(owner));
        vm.setEnv("MIGRATOR_OPERATOR", vm.toString(operator));

        vm.chainId(10);
        vm.expectRevert("Ethereum mainnet required");
        deployment.run();
        vm.chainId(1);
        vm.setEnv("MIGRATOR_OWNER", vm.toString(address(0)));
        vm.expectRevert("Migrator owner required");
        deployment.run();
        vm.setEnv("MIGRATOR_OWNER", vm.toString(owner));
        assertEq(vm.getNonce(deployer), 42);

        _checkMissingContract(deployment, deployer, deployment.FACTORY());
        _checkMissingContract(deployment, deployer, deployment.BUILDING());
        _checkMissingContract(deployment, deployer, address(hunt));

        BuildingMigrator migrator = deployment.run();
        assertEq(address(migrator), vm.computeCreateAddress(deployer, 42));
        assertEq(vm.getNonce(deployer), 43);
        _assertConfiguration(migrator, deployment, hunt, owner, operator);

        vm.setEnv("MIGRATOR_OPERATOR", vm.toString(address(0)));
        BuildingMigrator disabled = deployment.run();
        assertEq(address(disabled), vm.computeCreateAddress(deployer, 43));
        assertEq(vm.getNonce(deployer), 44);
        _assertConfiguration(disabled, deployment, hunt, owner, address(0));
    }

    function _checkMissingContract(
        DeployBuildingMigrator deployment,
        address deployer,
        address missing
    ) private {
        uint256 checkpoint = vm.snapshotState();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.etch(missing, hex"");
        vm.expectRevert(BuildingMigrator.InvalidAddress.selector);
        deployment.run();
        vm.stopBroadcast();
        assertEq(predicted.code.length, 0);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }

    function _assertConfiguration(
        BuildingMigrator migrator,
        DeployBuildingMigrator deployment,
        IERC20 hunt,
        address owner,
        address operator
    ) private view {
        assertEq(address(migrator.factory()), deployment.FACTORY());
        assertEq(address(migrator.building()), deployment.BUILDING());
        assertEq(address(migrator.huntToken()), address(hunt));
        assertEq(migrator.owner(), owner);
        assertEq(migrator.pendingOwner(), address(0));
        assertEq(migrator.operator(), operator);
        assertEq(hunt.balanceOf(address(migrator)), 0);
        assertEq(hunt.allowance(address(migrator), deployment.FACTORY()), 0);
    }
}
