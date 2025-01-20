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

/**
 * @title BuilderGrantV2
 * @author sebayaki.eth
 * @notice This contract is used to distribute grants (in the form of Mini Building NFTs) to up to 90 selected Builders
 *         (reward receivers). Unlike the previous version:
 *         - The concept of “donation” is removed entirely.
 *         - The admin can specify up to 90 recipients and how many Mini Building NFTs each should receive.
 */
contract BuilderGrantV2 is Ownable {
    // ----------------------------------------
    //               ERRORS
    // ----------------------------------------
    error InvalidSeasonId();
    error InvalidRankersParams();
    error SeasonDataIsNotUpdateable();
    error NotEnoughGrantBalance();
    error TokenTransferFailed();
    error NotARanker();
    error NothingToClaim();
    error AlreadyClaimed();
    error ClaimDeadlineReached();

    // ----------------------------------------
    //          CONSTANTS & IMMUTABLES
    // ----------------------------------------

    /// @notice 100 HUNT per 1 Mini Building NFT
    uint256 public constant HUNT_PER_MINI_BUILDING = 100 ether;
    uint256 public constant CLAIM_DEADLINE = 4 weeks;

    /// @notice The ERC20 token (e.g. HUNT) used to back each Mini Building NFT
    IERC20 public immutable HUNT;

    /// @notice The Bond (IMCV2_Bond) contract used for minting Mini Building NFTs
    IMCV2_Bond public immutable BOND;

    /// @notice The actual address of the Mini Building NFT
    address public immutable MINI_BUILDING_ADDRESS;

    // ----------------------------------------
    //               STRUCTS
    // ----------------------------------------

    /**
     * @dev Ranker (reward receiver) data
     * @param fid Farcaster ID
     * @param wallet The wallet address that can claim reward
     * @param totalReward How many Mini Buildings this ranker can claim in total
     * @param isClaimed Whether the reward has been claimed
     */
    struct Ranker {
        uint48 fid;
        address wallet;
        uint16 totalReward;
        bool isClaimed;
    }

    /**
     * @dev Season data
     * @param totalClaimed   The total number of Mini Buildings claimed by rankers in this season
     * @param rankers        List of ranker data
     */
    struct Season {
        uint40 claimStartedAt; // INFO: Unix timestamp, max supported up to year 36,812
        uint16 totalClaimed; // total claimed mini building count for the season
        Ranker[] rankers;
    }

    // ----------------------------------------
    //           STORAGE VARIABLES
    // ----------------------------------------

    /// @notice List of all seasons. `seasons.length` = total number of seasons so far.
    Season[] private seasons;

    // ----------------------------------------
    //                EVENTS
    // ----------------------------------------

    event Deposit(address indexed depositor, uint256 huntAmount);
    event SetSeasonData(uint256 indexed seasonId, uint256 rankersCount);
    event EmergencyWithdraw(address indexed withdrawer, uint256 huntAmount);
    event ClaimReward(address indexed claimer, uint256 indexed seasonId, uint256 ranking, uint16 amount);

    // ----------------------------------------
    //              CONSTRUCTOR
    // ----------------------------------------

    constructor(address bond, address hunt, address miniBuilding) Ownable(msg.sender) {
        BOND = IMCV2_Bond(bond);
        HUNT = IERC20(hunt);
        MINI_BUILDING_ADDRESS = miniBuilding;

        // Approve an infinite allowance of HUNT to Bond for minting
        HUNT.approve(bond, type(uint256).max);
    }

    // ----------------------------------------
    //                MODIFIERS
    // ----------------------------------------

    modifier validSeasonId(uint256 seasonId) {
        if (seasonId >= seasons.length) revert InvalidSeasonId();
        _;
    }

    // ----------------------------------------
    //         PUBLIC / EXTERNAL API
    // ----------------------------------------

    /**
     * @notice Returns the current season count (the next season ID is `currentSeason()`).
     */
    function currentSeason() external view returns (uint256) {
        return seasons.length;
    }

    /**
     * @notice Deposits HUNT into this contract, which will be used to back minted Mini Buildings.
     */
    function deposit(uint256 huntAmount) external {
        address msgSender = _msgSender();
        if (!HUNT.transferFrom(msgSender, address(this), huntAmount)) revert TokenTransferFailed();
        emit Deposit(msgSender, huntAmount);
    }

    /**
     * @notice Withdraws all HUNT in an emergency scenario.
     *         This does not affect already minted NFTs, only HUNT that remains un-utilized in the contract.
     */
    function emergencyWithdraw() external onlyOwner {
        address msgSender = _msgSender();
        uint256 balance = HUNT.balanceOf(address(this));
        if (!HUNT.transfer(msgSender, balance)) revert TokenTransferFailed();

        emit EmergencyWithdraw(msgSender, balance);
    }

    /**
     * @notice Creates or updates a season’s data.
     *         If `seasonId == seasons.length`, it creates a new season;
     *         otherwise it updates the last season if no one has claimed yet.
     *
     * @param seasonId      The season ID to create or update
     * @param fids          Array of Farcaster IDs for each ranker
     * @param wallets       The corresponding wallet addresses for each ranker
     * @param rewardAmounts The number of Mini Building NFTs each ranker can claim
     *
     * Requirements:
     * - `fids.length` == `wallets.length` == `rewardAmounts.length`
     * - The sum of all `rewardAmounts` (converted to HUNT needed) must be <= HUNT balance in the contract.
     * - Maximum rankers length is limited to 90.
     * - If updating an existing season, no one should have claimed from that season yet.
     */
    function setSeasonData(
        uint256 seasonId,
        uint48[] calldata fids,
        address[] calldata wallets,
        uint16[] calldata rewardAmounts
    ) external onlyOwner {
        // Validate params
        uint256 len = fids.length;
        if (len == 0 || len != wallets.length || len != rewardAmounts.length) {
            revert InvalidRankersParams();
        }
        // Optional: Limit max ranker count to 93 (top 3 x 31 days)
        if (len > 93) revert InvalidRankersParams();

        // Check if we have enough HUNT to mint all needed Mini Building NFTs
        uint256 totalNeeded;
        for (uint256 i = 0; i < len; ++i) {
            if (rewardAmounts[i] == 0) revert InvalidRankersParams();

            totalNeeded += rewardAmounts[i];
        }

        // Validate seasonId
        if (seasonId > seasons.length) revert InvalidSeasonId();

        if (seasonId == seasons.length) {
            // Create new season
            seasons.push();
        } else {
            // Update existing season
            if (seasons[seasonId].totalClaimed > 0) revert SeasonDataIsNotUpdateable();
            delete seasons[seasonId].rankers;
        }

        if (HUNT.balanceOf(address(this)) < (totalNeeded * HUNT_PER_MINI_BUILDING)) {
            revert NotEnoughGrantBalance();
        }

        // Get or create season
        Season storage season = seasons[seasonId];
        season.claimStartedAt = uint40(block.timestamp);

        // Add new rankers
        for (uint256 i = 0; i < len; i++) {
            season.rankers.push(
                Ranker({fid: fids[i], wallet: wallets[i], totalReward: rewardAmounts[i], isClaimed: false})
            );
        }

        emit SetSeasonData(seasonId, len);
    }

    /**
     * @notice Claims all unclaimed Mini Building NFTs for a given ranker in a given season.
     *         The ranker can only claim once. If they have previously claimed, this reverts.
     *
     * @param seasonId The season index.
     */
    function claimReward(uint256 seasonId) external validSeasonId(seasonId) {
        address msgSender = _msgSender();

        // Find the ranking index by wallet
        uint256 ranking = getRankingByWallet(seasonId, msgSender);

        Season storage season = seasons[seasonId];

        // Check if the claim deadline is passed
        if (season.claimStartedAt + CLAIM_DEADLINE < block.timestamp) revert ClaimDeadlineReached();

        Ranker storage ranker = season.rankers[ranking];

        if (ranker.totalReward == 0) revert NothingToClaim();
        if (ranker.isClaimed) revert AlreadyClaimed();

        // Mark as claimed
        ranker.isClaimed = true;
        season.totalClaimed += ranker.totalReward;

        // Mint the NFT
        _mintBuildings(ranker.totalReward, msgSender);

        emit ClaimReward(msgSender, seasonId, ranking, ranker.totalReward);
    }

    // ----------------------------------------
    //           INTERNAL FUNCTIONS
    // ----------------------------------------

    /**
     * @dev Mints the requested number of Mini Building NFTs to `to`.
     */
    function _mintBuildings(uint256 count, address to) private {
        // Will revert if the Bond contract fails
        BOND.mint(MINI_BUILDING_ADDRESS, count, HUNT_PER_MINI_BUILDING * count, to);
    }

    // ----------------------------------------
    //           VIEW / UTILITY FUNCTIONS
    // ----------------------------------------

    /**
     * @notice Returns a full Season struct.
     * @param seasonId The season ID
     */
    function getSeason(uint256 seasonId) external view validSeasonId(seasonId) returns (Season memory) {
        return seasons[seasonId];
    }

    /**
     * @notice Returns how many rankers in a given season.
     * @param seasonId The season ID
     */
    function getRankersCount(uint256 seasonId) external view validSeasonId(seasonId) returns (uint256) {
        return seasons[seasonId].rankers.length;
    }

    /**
     * @notice Returns the ranker at a given `index` in a season.
     */
    function getRankerAt(
        uint256 seasonId,
        uint256 index
    ) external view validSeasonId(seasonId) returns (Ranker memory) {
        return seasons[seasonId].rankers[index];
    }

    /**
     * @notice Returns the rank (index) in `season.rankers` for a given wallet, or reverts if none found.
     */
    function getRankingByWallet(
        uint256 seasonId,
        address wallet
    ) public view validSeasonId(seasonId) returns (uint256) {
        Ranker[] storage rankers = seasons[seasonId].rankers;
        for (uint256 i = 0; i < rankers.length; ++i) {
            if (rankers[i].wallet == wallet) return i;
        }
        revert NotARanker();
    }

    /**
     * @notice Returns the rank (index) in `season.rankers` for a given fid, or reverts if none found.
     */
    function getRankingByFid(uint256 seasonId, uint48 fid) external view validSeasonId(seasonId) returns (uint256) {
        Ranker[] storage rankers = seasons[seasonId].rankers;
        for (uint256 i = 0; i < rankers.length; ++i) {
            if (rankers[i].fid == fid) return i;
        }
        revert NotARanker();
    }
}
