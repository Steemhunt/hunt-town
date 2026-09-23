// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { DeployFactory } from "../script/DeployFactory.s.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryZapRouter } from "../src/periphery/FactoryZapRouter.sol";
import { FactoryTestHunt } from "./mocks/FactoryNFTMocks.sol";

/// @dev Fault injection for an interleaved deployer transaction. The extra approval
/// lets construction finish so the script's independent address check is exercised.
contract NonceShiftingHunt is FactoryTestHunt {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function approve(address spender, uint256 amount) public override returns (bool) {
        uint64 nextNonce = VM.getNonce(msg.sender) + 1;
        VM.setNonce(msg.sender, nextNonce);
        _approve(msg.sender, VM.computeCreateAddress(msg.sender, nextNonce), amount);
        return super.approve(spender, amount);
    }
}

contract DeployFactoryTest is Test {
    function testDeploymentGuardsAndFundedNonceSequence() public {
        DeployFactory deployment = new DeployFactory();
        FactoryTestHunt template = new FactoryTestHunt();
        vm.etch(deployment.HUNT(), address(template).code);
        // These addresses are only checked for deployed code during construction.
        vm.etch(deployment.POOL_MANAGER(), hex"00");
        vm.etch(deployment.TRANSFER_VALIDATOR(), hex"00");
        vm.chainId(1);

        address deployer = makeAddr("deployer");
        address owner = makeAddr("factory owner");
        address seedOwner = makeAddr("seed owner");
        string memory metadataURI = "ipfs://factory/{id}.json";
        vm.setNonce(deployer, 42);
        FactoryTestHunt hunt = FactoryTestHunt(deployment.HUNT());
        hunt.mint(deployer, 1_000 ether);
        vm.setEnv("DEPLOYER", vm.toString(deployer));
        vm.setEnv("FACTORY_OWNER", vm.toString(owner));
        vm.setEnv("SEED_OWNER", vm.toString(seedOwner));
        vm.setEnv("FACTORY_URI", metadataURI);

        // Environment cheatcodes are process-global. Keep all deployment configuration
        // cases in one test so parallel suites cannot race over these variables.
        _checkInvalidConfiguration(deployment, deployer, owner, seedOwner, metadataURI);
        _checkFailedApproval(deployment, deployer);
        _checkChangedNonce(deployment, deployer);

        (FactoryNFT factory, FactoryZapRouter zap) = deployment.run();

        assertEq(address(factory), vm.computeCreateAddress(deployer, 43));
        assertEq(address(zap), vm.computeCreateAddress(deployer, 44));
        assertEq(vm.getNonce(deployer), 45);
        assertEq(hunt.balanceOf(deployer), 0);
        assertEq(hunt.balanceOf(address(factory)), 1_000 ether);
        assertEq(hunt.allowance(deployer, address(factory)), 0);
        assertEq(factory.balanceOf(seedOwner, 0), 1);
        assertEq(factory.totalSupply(0), 1);
        assertEq(factory.navPerNFT(), 1_000 ether);
        assertEq(factory.owner(), owner);
        assertEq(factory.uri(0), metadataURI);
        assertEq(factory.royaltyOperator(), deployment.ROYALTY_OPERATOR());
        assertEq(factory.getTransferValidator(), deployment.TRANSFER_VALIDATOR());
        (address royaltyReceiver, uint256 royaltyAmount) = factory.royaltyInfo(0, 10_000);
        assertEq(royaltyReceiver, deployment.ROYALTY_OPERATOR());
        assertEq(royaltyAmount, 300);
        assertEq(address(zap.factory()), address(factory));
        assertEq(address(zap.huntToken()), deployment.HUNT());
        assertEq(address(zap.poolManager()), deployment.POOL_MANAGER());
    }

    function _checkInvalidConfiguration(
        DeployFactory deployment,
        address deployer,
        address owner,
        address seedOwner,
        string memory metadataURI
    ) private {
        vm.chainId(10);
        vm.expectRevert("Ethereum mainnet required");
        deployment.run();
        vm.chainId(1);
        vm.setEnv("FACTORY_OWNER", vm.toString(address(0)));
        vm.expectRevert("Owner addresses required");
        deployment.run();
        vm.setEnv("FACTORY_OWNER", vm.toString(owner));
        vm.setEnv("SEED_OWNER", vm.toString(address(0)));
        vm.expectRevert("Owner addresses required");
        deployment.run();
        vm.setEnv("SEED_OWNER", vm.toString(seedOwner));
        vm.setEnv("FACTORY_URI", "");
        vm.expectRevert("Metadata URI required");
        deployment.run();
        vm.setEnv("FACTORY_URI", metadataURI);
        assertEq(FactoryTestHunt(deployment.HUNT()).balanceOf(deployer), 1_000 ether);
        assertEq(vm.getNonce(deployer), 42);
    }

    function _checkFailedApproval(DeployFactory deployment, address deployer) private {
        uint256 checkpoint = vm.snapshotState();
        vm.mockCall(
            deployment.HUNT(),
            abi.encodeWithSignature(
                "approve(address,uint256)", vm.computeCreateAddress(deployer, 43), 1_000 ether
            ),
            abi.encode(false)
        );
        vm.expectRevert("Seed approval failed");
        deployment.run();
        vm.stopBroadcast();
        vm.clearMockedCalls();
        assertEq(FactoryTestHunt(deployment.HUNT()).balanceOf(deployer), 1_000 ether);
        assertEq(vm.computeCreateAddress(deployer, 43).code.length, 0);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }

    function _checkChangedNonce(DeployFactory deployment, address deployer) private {
        uint256 checkpoint = vm.snapshotState();
        NonceShiftingHunt template = new NonceShiftingHunt();
        vm.etch(deployment.HUNT(), address(template).code);
        vm.allowCheatcodes(deployment.HUNT());
        vm.expectRevert("Deployment nonce changed");
        deployment.run();
        vm.stopBroadcast();
        assertEq(vm.computeCreateAddress(deployer, 43).code.length, 0);
        assertEq(vm.computeCreateAddress(deployer, 44).code.length, 0);
        assertEq(FactoryTestHunt(deployment.HUNT()).balanceOf(deployer), 1_000 ether);
        assertTrue(vm.revertToStateAndDelete(checkpoint));
    }
}
