// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ITownHall {
  function mint(address to) external;
}

contract TownHallZap {
    ITownHall public townHall;
    IERC20 public huntToken;

    uint256 public constant LOCK_UP_AMOUNT = 1e21; // 1,000 HUNT per NFT minting

    constructor(address townHall_, address huntToken_) {
        townHall = ITownHall(townHall_);
        huntToken = IERC20(huntToken_);
    }

    // @dev save ~25% gas on bulk minting
    function mintBulk(address to, uint256 count) external {
        uint256 totalHuntAmount = LOCK_UP_AMOUNT * count;
        huntToken.transferFrom(msg.sender, address(this), totalHuntAmount);
        huntToken.approve(address(townHall), totalHuntAmount);

        for (uint256 i = 0; i < count; i++) {
            townHall.mint(to);
        }
    }
}
