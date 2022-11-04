// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./Building.sol";

contract TownHall {
    error TownHall__LockUpPeroidStillLeft();

    using SafeERC20 for IERC20;

    Building public building;
    IERC20 public huntToken;

    uint256 public constant LOCK_UP_AMOUNT = 1e21; // 1,000 HUNT per NFT minting
    // uint256 public constant LOCK_UP_DURATION = 31536000; // 365 days in seconds

    // TEMP: for testing
    uint256 public constant LOCK_UP_DURATION = 600; // 10 minutes

    mapping (uint256 => uint256) public buildingMintedAt;

    constructor(address building_, address huntToken_) {
        building = Building(building_);
        huntToken = IERC20(huntToken_);
    }

    /**
     * @dev Mint a new building NFT with a lock-up of HUNT tokens for 1 year
     */
    function mint() external {
        huntToken.safeTransferFrom(msg.sender, address(this), LOCK_UP_AMOUNT);
        uint256 tokenId = building.safeMint(msg.sender);

        buildingMintedAt[tokenId] = block.timestamp;
    }

    /**
     * @dev Burn a existing building NFT and refund locked-up HUNT Tokens
     */
    function burn(uint256 tokenId) external {
        if (block.timestamp < unlockTime(tokenId)) revert TownHall__LockUpPeroidStillLeft();

        // Check approvals and burn the building NFT
        building.burn(tokenId, msg.sender);

        // Refund locked-up HUNT tokens
        huntToken.safeTransfer(msg.sender, LOCK_UP_AMOUNT);
    }

    function unlockTime(uint256 tokenId) public view returns (uint256) {
        return buildingMintedAt[tokenId] + LOCK_UP_DURATION;
    }
}
