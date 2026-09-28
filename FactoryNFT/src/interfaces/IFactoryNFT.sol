// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFactoryNFT {
    function huntToken() external view returns (IERC20);
    function quoteMint(uint256 amount) external view returns (uint256 huntIn);
    function mint(uint256 amount, uint256 maxHuntIn, address receiver)
        external
        returns (uint256 huntIn);
}
