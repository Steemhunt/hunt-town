// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IMCV2_Bond {
    function mint(
        address token,
        uint256 tokensToMint,
        uint256 maxReserveAmount,
        address receiver
    ) external returns (uint256);
}

contract BuilderGrant is Ownable {
    // TODO: Trim unused
    error InvalidSeasonId();
    error InvalidRankersParams();
    error InvalidGrantAmount();
    error ClaimDeadlineReached();
    error DonationClaimDeadlineReached();
    error DonationNotClaimableYet();
    error SeasonDataIsNotUpdateable();
    error NotEnoughGrantBalance();
    error TokenTransferFailed();
    error InvalidRankingParam();
    error PermissionDenied();
    error NotARanker();
    error AlreadyClaimed();
    error DonationAlreadyClaimed();
    error InvalidClaimType();
    error MintBuildingsFailed();
    error NoDonationToClaim();

    uint256 public constant HUNT_PER_MINI_BUILDING = 100 ether; // 100 HUNT per Mini Building NFT minting

    uint256 public constant TOP3_CLAIM_DEADLINE = 1 weeks;
    uint256 public constant DONATION_CLAIM_DEADLINE = 4 weeks; // 2 - 4 weeks after TOP3_CLAIM_DEADLINE

    IERC20 public immutable HUNT;
    IMCV2_Bond public immutable BOND;
    address public immutable MINI_BUILDING_ADDRESS;

    struct Ranker {
        uint48 fid; // INFO: Farcaster ID
        address wallet;
        uint16 claimedAmount;
        bool[3] donationReceived;
    }

    struct Grant {
        uint8 claimedType; // 0: not claimed yet, 1: 100% self, 2: 50% donation, 3: 100% donation
        uint16 amount; // mini building count
    }

    struct Season {
        uint40 claimStartedAt; // INFO: Unix timestamp, max supported up to year 36,812
        uint16 totalClaimed; // total claimed mini building count for the season
        Grant[3] grants;
        Ranker[] rankers;
    }
    Season[] private seasons;

    event Deposit(address indexed depositor, uint256 huntAmount);
    event SetSeasonData(uint256 indexed seasonId, uint256 rankersCount, uint16[3] grantsAmount);
    event EmergencyWithdraw(address indexed withdrawer, uint256 huntAmount);
    event ClaimByTop3(
        address indexed claimer,
        uint256 indexed seasonId,
        uint256 ranking,
        uint8 claimType,
        uint16 countForSelf,
        uint16 countForDonation
    );
    event ClaimDonation(address indexed claimer, uint256 indexed seasonId, uint256 ranking, uint256 amount);

    constructor(address bond, address hunt, address miniBuilding) Ownable(msg.sender) {
        BOND = IMCV2_Bond(bond); // base: 0xc5a076cad94176c2996B32d8466Be1cE757FAa27
        HUNT = IERC20(hunt); // base: 0x37f0c2915CeCC7e977183B8543Fc0864d03E064C
        MINI_BUILDING_ADDRESS = miniBuilding; // base: 0x475f8E3eE5457f7B4AAca7E989D35418657AdF2a

        // gas saving - approve infinite HUNT to Bond for minting
        HUNT.approve(bond, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
    }

    function currentSeason() external view returns (uint256) {
        return seasons.length; // The last claimable season = length - 1
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

    function setSeasonData(
        uint256 seasonId,
        uint16[3] calldata grantsAmount,
        uint48[] calldata fids,
        address[] calldata wallets
    ) external onlyOwner {
        // Validate params
        if (fids.length != wallets.length) revert InvalidRankersParams();

        // Check if we have enough HUNT to mint all Mini Building NFTs
        if (
            HUNT.balanceOf(address(this)) <
            HUNT_PER_MINI_BUILDING * (grantsAmount[0] + grantsAmount[1] + grantsAmount[2])
        ) revert NotEnoughGrantBalance();

        // Check if there are enough ranker data is provided if the 1st ranker donates 100%
        // e.g. If the top grant is 10,000 HUNT, include up to 103 rankers to allow donations to ranks 4-203
        if (grantsAmount[0] > (fids.length - 3)) revert InvalidGrantAmount();

        // Check if the grants amount is even because they have 50% donation option
        if (grantsAmount[0] % 2 != 0 || grantsAmount[1] % 2 != 0 || grantsAmount[2] % 2 != 0)
            revert InvalidGrantAmount();

        Season storage season;
        // Overwriting the last season
        if (seasons.length > 0 && seasonId == seasons.length - 1) {
            season = seasons[seasonId];
            // can't overwrite the data of the season if anyone has claimed
            if (season.totalClaimed > 0) revert SeasonDataIsNotUpdateable();
            // Set new season
        } else if (seasonId == seasons.length) {
            seasons.push();
            season = seasons[seasonId];
        } else {
            revert InvalidSeasonId();
        }

        // Set grant data
        season.grants[0].amount = grantsAmount[0];
        season.grants[1].amount = grantsAmount[1];
        season.grants[2].amount = grantsAmount[2];
        season.claimStartedAt = uint40(block.timestamp);

        // Set rankers data
        delete season.rankers; // reset ranker data if exists
        for (uint256 i = 0; i < fids.length; ++i) {
            season.rankers.push(Ranker(fids[i], wallets[i], 0, [false, false, false]));
        }

        emit SetSeasonData(seasonId, fids.length, grantsAmount);
    }

    function getClaimableAmountByTop3(uint256 seasonId, uint256 ranking) public view returns (uint16) {
        // Only the top 3 rankers (index: 0, 1, 2) can claim
        if (ranking > 2) revert InvalidRankingParam();

        // Check claim deadline
        Season storage season = seasons[seasonId];
        if (season.claimStartedAt + TOP3_CLAIM_DEADLINE < block.timestamp) revert ClaimDeadlineReached();

        // Check if the grant has not been claimed yet
        if (season.grants[ranking].claimedType != 0) revert AlreadyClaimed();

        return season.grants[ranking].amount;
    }

    function claimByTop3(uint256 seasonId, uint256 ranking, uint8 claimType) external {
        // Basic validations are done here
        uint16 claimableAmount = getClaimableAmountByTop3(seasonId, ranking);

        Season storage season = seasons[seasonId];
        address msgSender = _msgSender();

        // Check msg.sender is the winner
        if (season.rankers[ranking].wallet != msgSender) revert PermissionDenied();

        // claimType - 0: not claimed yet, 1: 100% self, 2: 50% donation, 3: 100% donation
        uint16 amountForSelf;
        uint16 amountForDonation;
        if (claimType == 1) {
            // 100% self
            amountForSelf = claimableAmount;
        } else if (claimType == 2) {
            // 50% donation
            amountForSelf = amountForDonation = claimableAmount / 2;
        } else if (claimType == 3) {
            // 100% donation
            amountForDonation = claimableAmount;
        } else {
            revert InvalidClaimType();
        }

        // Set ranker claimed
        season.grants[ranking].claimedType = claimType;

        // Send Mini Buildings reward
        if (amountForSelf > 0) {
            season.rankers[ranking].claimedAmount += amountForSelf;
            season.totalClaimed += amountForSelf;
            if (!_mintBuildings(amountForSelf, msgSender)) revert MintBuildingsFailed();
        }

        if (amountForDonation > 0) {
            for (uint256 i = 3; i < amountForDonation + 3; ++i) {
                season.rankers[i].donationReceived[ranking] = true;
            }
        }

        emit ClaimByTop3(msgSender, seasonId, ranking, claimType, amountForSelf, amountForDonation);
    }

    function isDonationClaimableNow(uint256 seasonId) public view returns (bool) {
        Season storage season = seasons[seasonId];

        // If the donation claim deadline is passed, return false
        if (season.claimStartedAt + DONATION_CLAIM_DEADLINE < block.timestamp) revert DonationClaimDeadlineReached();

        // If the top 3 claim deadline is passed, return true
        if (season.claimStartedAt + TOP3_CLAIM_DEADLINE > block.timestamp) return true;

        // Even if the top 3 claim deadline is NOT passed, if all top 3 have already been decided, return true
        if (season.grants[0].claimedType > 0 && season.grants[1].claimedType > 0 && season.grants[2].claimedType > 0)
            return true;

        return false;
    }

    function claimableDonationAmount(uint256 seasonId, uint256 ranking) public view returns (uint16 claimableAmount) {
        Season storage season = seasons[seasonId];

        if (season.rankers[ranking].claimedAmount > 0) revert DonationAlreadyClaimed();
        if (!isDonationClaimableNow(seasonId)) revert DonationNotClaimableYet();

        bool[3] storage donationReceived = season.rankers[ranking].donationReceived;

        for (uint256 i = 0; i < 3; ++i) {
            if (donationReceived[i] == true) {
                ++claimableAmount;
            }
        }
    }

    function claimDonation(uint256 seasonId, uint256 ranking) external {
        uint16 claimableAmount = claimableDonationAmount(seasonId, ranking);
        if (claimableAmount == 0) revert NoDonationToClaim();

        Season storage season = seasons[seasonId];
        address msgSender = _msgSender();
        if (season.rankers[ranking].wallet != msgSender) revert PermissionDenied();

        season.rankers[ranking].claimedAmount += claimableAmount;
        season.totalClaimed += claimableAmount;
        if (!_mintBuildings(claimableAmount, msgSender)) revert MintBuildingsFailed();

        emit ClaimDonation(msgSender, seasonId, ranking, claimableAmount);
    }

    function _mintBuildings(uint256 count, address to) private returns (bool) {
        BOND.mint(MINI_BUILDING_ADDRESS, count, HUNT_PER_MINI_BUILDING * count, to);

        return true;
    }

    // MARK: - Utility view functions

    function getSeason(uint256 seasonId) external view returns (Season memory) {
        return seasons[seasonId];
    }

    function getRankingByWallet(uint256 seasonId, address wallet) external view returns (uint256) {
        Ranker[] storage rankers = seasons[seasonId].rankers;
        for (uint256 i = 0; i < rankers.length; ++i) {
            if (rankers[i].wallet == wallet) return i;
        }

        revert NotARanker();
    }

    function getRankingByFid(uint256 seasonId, uint48 fid) external view returns (uint256) {
        Ranker[] storage rankers = seasons[seasonId].rankers;
        for (uint256 i = 0; i < rankers.length; ++i) {
            if (rankers[i].fid == fid) return i;
        }

        revert NotARanker();
    }
}
