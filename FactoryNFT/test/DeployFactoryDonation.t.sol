// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { DeployFactoryDonation } from "../script/DeployFactoryDonation.s.sol";
import { FactoryDonation } from "../src/FactoryDonation.sol";
import { FactoryTestHunt } from "./mocks/FactoryNFTMocks.sol";

contract DeployDonationFactoryStub {
    IERC20 public immutable huntToken;

    constructor(IERC20 hunt) {
        huntToken = hunt;
    }
}

contract DeployFactoryDonationTest is Test {
    address private constant HUNT = 0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5;

    function testDeploymentGuardsAndUnfundedNonceSequence() public {
        DeployFactoryDonation deployment = new DeployFactoryDonation();
        FactoryTestHunt huntTemplate = new FactoryTestHunt();
        vm.etch(HUNT, address(huntTemplate).code);
        FactoryTestHunt hunt = FactoryTestHunt(HUNT);
        DeployDonationFactoryStub factoryTemplate = new DeployDonationFactoryStub(hunt);
        vm.etch(deployment.FACTORY(), address(factoryTemplate).code);

        // DEPLOYER is process-global; keep it consistent with the other script tests.
        address deployer = makeAddr("deployer");
        vm.setNonce(deployer, 42);
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.chainId(10);
        vm.expectRevert("Ethereum mainnet required");
        deployment.run();
        vm.chainId(1);
        assertEq(vm.getNonce(deployer), 42);

        _checkMissingContract(deployment, deployer, deployment.FACTORY());
        _checkMissingContract(deployment, deployer, HUNT);
        _checkFailedApproval(deployment, deployer);

        FactoryDonation donation = deployment.run();
        assertEq(address(donation), vm.computeCreateAddress(deployer, 42));
        // Approval from the new contract is internal to CREATE, not a second EOA transaction.
        assertEq(vm.getNonce(deployer), 43);
        assertEq(address(donation.factory()), deployment.FACTORY());
        assertEq(address(donation.huntToken()), HUNT);
        assertEq(donation.MAX_MESSAGE_BYTES(), 280);
        assertEq(hunt.balanceOf(deployer), 0);
        assertEq(hunt.balanceOf(address(donation)), 0);
        assertEq(hunt.allowance(deployer, deployment.FACTORY()), 0);
        assertEq(hunt.allowance(address(donation), deployment.FACTORY()), type(uint256).max);
    }

    function _checkMissingContract(
        DeployFactoryDonation deployment,
        address deployer,
        address missing
    ) private {
        uint256 checkpoint = vm.snapshotState();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.etch(missing, hex"");
        vm.expectRevert(FactoryDonation.InvalidAddress.selector);
        deployment.run();
        vm.stopBroadcast();
        assertEq(predicted.code.length, 0);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }

    function _checkFailedApproval(DeployFactoryDonation deployment, address deployer) private {
        uint256 checkpoint = vm.snapshotState();
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
        vm.mockCall(HUNT, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, HUNT));
        deployment.run();
        vm.stopBroadcast();
        vm.clearMockedCalls();
        assertEq(predicted.code.length, 0);
        assertEq(FactoryTestHunt(HUNT).allowance(predicted, deployment.FACTORY()), 0);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }
}
