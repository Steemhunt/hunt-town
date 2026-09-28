// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { PoolManager } from "@uniswap/v4-core/src/PoolManager.sol";

/// @dev Builds the canonical manager with its required compiler for vm.deployCode tests.
contract PoolManagerArtifact is PoolManager {
    constructor(address owner) PoolManager(owner) { }
}
