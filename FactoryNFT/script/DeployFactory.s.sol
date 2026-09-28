// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryZapRouter } from "../src/periphery/FactoryZapRouter.sol";

/// @notice Ethereum deployment with a funded seed and the approved royalty recipient.
/// @dev Use an unlocked account or a Foundry keystore; no private key is read by this script.
contract DeployFactory is Script {
    address public constant HUNT = 0x9AAb071B4129B083B01cB5A0Cb513Ce7ecA26fa5;
    address public constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant ROYALTY_OPERATOR = 0xdd15e36BEf873Ca3ceC9411c98878734576aDfb2;

    function run() external returns (FactoryNFT factory, FactoryZapRouter zap) {
        require(block.chainid == 1, "Ethereum mainnet required");
        address deployer = vm.envAddress("DEPLOYER");
        address owner = vm.envAddress("FACTORY_OWNER");
        address seedOwner = vm.envAddress("SEED_OWNER");
        string memory metadataURI = vm.envString("FACTORY_URI");
        require(owner != address(0) && seedOwner != address(0), "Owner addresses required");
        require(bytes(metadataURI).length != 0, "Metadata URI required");

        // The ERC20 approval transaction consumes one EOA nonce before CREATE.
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        vm.startBroadcast(deployer);
        require(IERC20(HUNT).approve(predicted, 1_000 ether), "Seed approval failed");
        factory = new FactoryNFT(IERC20(HUNT), owner, seedOwner, metadataURI, ROYALTY_OPERATOR);
        require(address(factory) == predicted, "Deployment nonce changed");
        zap = new FactoryZapRouter(factory, IPoolManager(POOL_MANAGER));
        vm.stopBroadcast();
    }
}
