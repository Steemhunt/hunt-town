// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { MiniBuildingCollector } from "../src/MiniBuildingCollector.sol";

/// @notice Deploys the signed-quote collector against the existing Base token contracts.
contract DeployMiniBuildingCollector is Script {
    address public constant BUILDING = 0x475f8E3eE5457f7B4AAca7E989D35418657AdF2a;
    address public constant HUNT = 0x37f0c2915CeCC7e977183B8543Fc0864d03E064C;

    function run() external returns (MiniBuildingCollector collector) {
        require(block.chainid == 8453, "Base mainnet required");
        address deployer = vm.envAddress("DEPLOYER");
        address owner = vm.envAddress("COLLECTOR_OWNER");
        address quoteSigner = vm.envAddress("COLLECTOR_QUOTE_SIGNER");
        require(owner != address(0), "Collector owner required");
        require(quoteSigner != address(0), "Quote signer required");

        vm.startBroadcast(deployer);
        collector = new MiniBuildingCollector(IERC1155(BUILDING), IERC20(HUNT), owner, quoteSigner);
        vm.stopBroadcast();
    }
}
