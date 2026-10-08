// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { FactoryNFT } from "../src/FactoryNFT.sol";
import { FactoryDonation } from "../src/FactoryDonation.sol";

/// @notice Deploys the donation contract against the existing Ethereum Factory NFT.
/// @dev The deployer needs ETH for gas but no HUNT. No private key is read by this script.
contract DeployFactoryDonation is Script {
    address public constant FACTORY = 0x961eA6C51c185958b1A11ad8335046988D1B5734;

    function run() external returns (FactoryDonation donation) {
        require(block.chainid == 1, "Ethereum mainnet required");
        address deployer = vm.envAddress("DEPLOYER");

        vm.startBroadcast(deployer);
        donation = new FactoryDonation(FactoryNFT(FACTORY));
        vm.stopBroadcast();
    }
}
