// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { IFactoryNFT } from "../src/interfaces/IFactoryNFT.sol";
import { BuildingMigrator } from "../src/BuildingMigrator.sol";

/// @notice Deploys the migrator against the existing Ethereum contracts, without funding it.
contract DeployBuildingMigrator is Script {
    address public constant FACTORY = 0x961eA6C51c185958b1A11ad8335046988D1B5734;
    address public constant BUILDING = 0x0c9Bb1ffF512a5B4F01aCA6ad964Ec6D7fC60c96;

    function run() external returns (BuildingMigrator migrator) {
        require(block.chainid == 1, "Ethereum mainnet required");
        address deployer = vm.envAddress("DEPLOYER");
        address owner = vm.envAddress("MIGRATOR_OWNER");
        address operator = vm.envAddress("MIGRATOR_OPERATOR");
        require(owner != address(0), "Migrator owner required");

        vm.startBroadcast(deployer);
        migrator = new BuildingMigrator(IFactoryNFT(FACTORY), IERC721(BUILDING), owner, operator);
        vm.stopBroadcast();
    }
}
