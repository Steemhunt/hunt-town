// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HuntTokenMock is ERC20, ERC20Burnable, Ownable {
    constructor() ERC20("TestHuntToken", "TEST_HUNT") {
        _mint(msg.sender, 198912688 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}