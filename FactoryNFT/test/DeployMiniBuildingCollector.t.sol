// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { DeployMiniBuildingCollector } from "../script/DeployMiniBuildingCollector.s.sol";
import { MiniBuildingCollector } from "../src/MiniBuildingCollector.sol";

contract DeployMiniBuildingCollectorTest is Test {
    function testDeploymentGuardsAndOwnerSignerWiring() public {
        DeployMiniBuildingCollector deployment = new DeployMiniBuildingCollector();
        // The constructor checks the existing token addresses for deployed code.
        vm.etch(deployment.BUILDING(), hex"00");
        vm.etch(deployment.HUNT(), hex"00");

        // DEPLOYER is process-global; keep it consistent with the other script tests.
        // Keep the collector-specific environment settings in this single test.
        address deployer = makeAddr("deployer");
        address owner = makeAddr("collector owner");
        address quoteSigner = makeAddr("quote signer");
        vm.setNonce(deployer, 42);
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.setEnv("COLLECTOR_OWNER", vm.toString(owner));
        vm.setEnv("COLLECTOR_QUOTE_SIGNER", vm.toString(quoteSigner));

        vm.chainId(1);
        vm.expectRevert("Base mainnet required");
        deployment.run();
        vm.chainId(8453);
        vm.setEnv("COLLECTOR_OWNER", vm.toString(address(0)));
        vm.expectRevert("Collector owner required");
        deployment.run();
        vm.setEnv("COLLECTOR_OWNER", vm.toString(owner));
        vm.setEnv("COLLECTOR_QUOTE_SIGNER", vm.toString(address(0)));
        vm.expectRevert("Quote signer required");
        deployment.run();
        vm.setEnv("COLLECTOR_QUOTE_SIGNER", vm.toString(quoteSigner));
        assertEq(vm.getNonce(deployer), 42);

        _checkMissingContract(deployment, deployer, deployment.BUILDING());
        _checkMissingContract(deployment, deployer, deployment.HUNT());

        MiniBuildingCollector collector = deployment.run();
        assertEq(address(collector), vm.computeCreateAddress(deployer, 42));
        assertEq(vm.getNonce(deployer), 43);
        assertEq(address(collector.building()), deployment.BUILDING());
        assertEq(address(collector.huntToken()), deployment.HUNT());
        assertEq(collector.owner(), owner);
        assertEq(collector.pendingOwner(), address(0));
        assertEq(collector.quoteSigner(), quoteSigner);
        assertEq(collector.MIGRATION_RECEIVER(), 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D);
    }

    function _checkMissingContract(
        DeployMiniBuildingCollector deployment,
        address deployer,
        address missing
    ) private {
        uint256 checkpoint = vm.snapshotState();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.etch(missing, hex"");
        vm.expectRevert(MiniBuildingCollector.InvalidAddress.selector);
        deployment.run();
        vm.stopBroadcast();
        assertEq(predicted.code.length, 0);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }
}
