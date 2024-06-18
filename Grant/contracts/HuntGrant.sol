// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ITownHall {
    function huntToken() external view returns (address);

    function mint(address to) external;
}

contract HuntGrant is Ownable {
    error InvalidSeasonId();
    error SeasonDataAlreadyExists();
    error NotEnoughGrantBalance();
    error TokenTransferFailed();
    error NotAWinner();
    error AlreadyClaimed();
    error InvalidClaimType();
    error MintBuildingsFailed();

    uint256 public constant LOCK_UP_AMOUNT = 1000 ether; // 1,000 HUNT per Building NFT minting
    IERC20 public immutable HUNT;
    ITownHall public immutable TOWN_HALL;

    constructor(address townHall) Ownable(msg.sender) {
        TOWN_HALL = ITownHall(townHall); // mainnet: 0xb09A1410cF4C49F92482F5cd2CbF19b638907193
        HUNT = IERC20(TOWN_HALL.huntToken());
        // gas saving - approve infinite HUNT to TownHall for minting
        HUNT.approve(townHall, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    }

    struct Season {
        uint256 grantDistributed;
        address[3] winners;
        uint256[3] maxGrantAmounts;
        uint8[3] claimedTypes; // 0: not claimed, 1: 100% Buildings, 2: 50% Buildings, 3: 100% HUNT
    }
    mapping(uint256 => Season) private seasons;
    uint256 public lastSeason; // currentSeason = lastSeason + 1;

    event Deposit(address indexed user, uint256 huntAmount);
    event SetWinners(uint256 indexed season, address[3] winners);
    event Claim(
        address indexed user,
        uint256 indexed season,
        uint8 ranking,
        uint8 claimType,
        uint8 buildingCount,
        uint256 huntAmount
    );
    event EmergencyWithdraw(address indexed user, uint256 huntAmount);

    function currentSeason() external view returns (uint256) {
        return lastSeason + 1;
    }

    function deposit(uint256 huntAmount) external {
        address msgSender = _msgSender();
        if (!HUNT.transferFrom(msgSender, address(this), huntAmount)) revert TokenTransferFailed();

        emit Deposit(msgSender, huntAmount);
    }

    function emergencyWithdraw() external onlyOwner {
        address msgSender = _msgSender();
        uint256 balance = HUNT.balanceOf(address(this));
        if (!HUNT.transfer(msgSender, balance)) revert TokenTransferFailed();

        emit EmergencyWithdraw(msgSender, balance);
    }

    function setWinners(
        uint256 seasonId,
        address[3] calldata winners,
        uint256[3] calldata maxGrantAmounts
    ) external onlyOwner {
        if (seasons[seasonId].winners[0] != address(0)) revert SeasonDataAlreadyExists();
        if (seasonId < 1 || lastSeason != seasonId - 1) revert InvalidSeasonId();

        lastSeason = seasonId; // curent season becomes last season

        uint256 totalGrantAmount = maxGrantAmounts[0] + maxGrantAmounts[1] + maxGrantAmounts[2];
        if (totalGrantAmount > HUNT.balanceOf(address(this))) revert NotEnoughGrantBalance();

        seasons[seasonId].winners = winners;
        seasons[seasonId].maxGrantAmounts = maxGrantAmounts;

        emit SetWinners(seasonId, winners);
    }

    function claim(uint256 seasonId, uint8 claimType) external {
        Season storage season = seasons[seasonId];

        address msgSender = _msgSender();
        uint8 ranking = 255;
        if (season.winners[0] == msgSender) {
            ranking = 0;
        } else if (season.winners[1] == msgSender) {
            ranking = 1;
        } else if (season.winners[2] == msgSender) {
            ranking = 2;
        } else {
            revert NotAWinner();
        }

        if (season.claimedTypes[ranking] != 0) revert AlreadyClaimed();

        // Claim Type 1: 100% Buildings, 2: 50% Buildings, 3: 100% HUNT
        uint256 grantAmount = season.maxGrantAmounts[ranking];
        uint8 buildingCount = 0;
        if (claimType == 1) {
            buildingCount = uint8(grantAmount / LOCK_UP_AMOUNT);
            grantAmount = 0;
        } else if (claimType == 2) {
            buildingCount = uint8((grantAmount / 2) / LOCK_UP_AMOUNT);
            grantAmount -= buildingCount * LOCK_UP_AMOUNT;
            grantAmount /= 2; // Liquid panalty: 50%
        } else if (claimType == 3) {
            buildingCount = 0;
            grantAmount /= 2; // Liquid panalty: 50%
        } else {
            revert InvalidClaimType();
        }

        season.claimedTypes[ranking] = claimType;

        if (buildingCount > 0) {
            if (!_mintBuildings(buildingCount)) revert MintBuildingsFailed();
        }

        if (grantAmount > 0) {
            if (!HUNT.transfer(msgSender, grantAmount)) revert TokenTransferFailed();
        }

        emit Claim(msgSender, seasonId, ranking, claimType, buildingCount, grantAmount);
    }

    function _mintBuildings(uint256 count) private returns (bool) {
        address msgSender = _msgSender();

        unchecked {
            for (uint256 i = 0; i < count; ++i) {
                TOWN_HALL.mint(msgSender);
            }
        }

        return true;
    }

    // MARK: - Utility view functions
    function getSeason(uint256 seasonId) public view returns (Season memory) {
        return seasons[seasonId];
    }
}
