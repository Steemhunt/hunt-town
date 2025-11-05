// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract Mintpad is Ownable {
    using SafeERC20 for IERC20;
    // MARK: - Errors
    error Mintpad__InvalidParams(string param);
    error Mintpad__InsufficientVotingPoints();
    error Mintpad__NothingToClaim();
    error Mintpad__ExcessiveLeftover(uint256 actualHuntSpent);
    error Mintpad__InvalidSignature();
    error Mintpad__AlreadyActivated();

    // MARK: - Constants
    IERC20 private constant HUNT = IERC20(0x37f0c2915CeCC7e977183B8543Fc0864d03E064C);
    IMCV2_Bond public constant BOND = IMCV2_Bond(0xc5a076cad94176c2996B32d8466Be1cE757FAa27);
    uint256 public constant VOTE_EXPIRATION_DAYS = 30;
    uint256 private constant SECONDS_PER_DAY = 86400;
    uint256 private constant MIN_CLAIM_EFFICIENCY_PERCENT = 98; // 98% minimum efficiency
    uint256 private immutable DEPLOYMENT_TIMESTAMP;

    // EIP-712 Domain
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant VOTING_POINT_TYPEHASH =
        keccak256("VotingPoint(address user,uint256 day,uint32 votingPoint)");
    bytes32 private immutable DOMAIN_SEPARATOR;

    // MARK: - State Variables
    address public signer;
    uint256 public dailyHuntReward; // Daily HUNT reward pool (in Wei)

    /// @dev Daily statistics for vote and claim tracking
    /// @notice All uint types are optimized for gas-efficient storage packing (256 bits total)
    struct DailyStats {
        uint32 totalVotingPointGiven; // Total voting points allocated for the day
        uint32 totalVotingPointSpent; // Total voting points spent for the day
        uint32 votingCount; // Number of vote transactions for the day
        uint32 claimCount; // Number of claim transactions for the day
        uint88 totalHuntClaimed; // Total HUNT claimed for the day (in Wei)
    }

    /// @notice Maps day => DailyStats
    mapping(uint256 => DailyStats) public dailyStats;

    /// @notice Maps day => user => remaining voting points
    /// @dev Activated by user with signature, deducted on vote
    mapping(uint256 => mapping(address => uint32)) public dailyUserVotingPoint;

    /// @notice Maps day => user => token => voting points spent
    mapping(uint256 => mapping(address => mapping(address => uint32))) public dailyUserTokenVotes;

    /// @notice Maps user => token => last day claimed
    /// @dev Tracks the last day rewards were claimed to prevent double-claiming
    mapping(address => mapping(address => uint256)) public userTokenLastClaimDay;

    // MARK: - Events
    event SignerAddressUpdated(address newSignerAddress);
    event DailyHuntRewardUpdated(uint256 newDailyHuntReward);
    event VotingPointActivated(uint256 indexed day, address indexed user, uint32 votingPoint);
    event Voted(uint256 indexed day, address indexed user, address indexed token, uint32 voteAmount);
    event Claimed(
        address indexed user,
        address indexed token,
        uint256 dayClaimedUpTo,
        uint256 actualHuntSpent,
        uint256 tokensMinted,
        uint256 indexed donationBp
    );

    // MARK: - Constructor
    /**
     * @notice Initializes the Mintpad contract
     * @param signerAddress Address authorized to sign voting point activations
     * @param initialDailyHuntReward Initial daily HUNT reward pool (in Wei)
     * @dev Sets deployment timestamp as day 0 and pre-approves HUNT for BOND contract
     */
    constructor(address signerAddress, uint256 initialDailyHuntReward) Ownable(msg.sender) {
        if (signerAddress == address(0)) revert Mintpad__InvalidParams("zero address");
        if (initialDailyHuntReward == 0) revert Mintpad__InvalidParams("dailyHuntReward cannot be zero");

        signer = signerAddress;
        dailyHuntReward = initialDailyHuntReward;
        DEPLOYMENT_TIMESTAMP = block.timestamp;

        // Initialize EIP-712 domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("Mintpad")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );

        // Pre-approve HUNT to BOND contract for gas-efficient minting
        HUNT.approve(address(BOND), type(uint256).max);
    }

    // MARK: - Modifiers
    modifier _validChildToken(address token) {
        if (token == address(0)) revert Mintpad__InvalidParams("zero address");
        if (!BOND.exists(token)) revert Mintpad__InvalidParams("not child token");
        _;
    }

    // MARK: - Admin Functions

    /**
     * @notice Updates the authorized signer address for voting point activations
     * @param newSignerAddress The new signer address
     * @dev Only callable by contract owner
     */
    function updateSignerAddress(address newSignerAddress) external onlyOwner {
        if (newSignerAddress == address(0)) revert Mintpad__InvalidParams("zero address");
        signer = newSignerAddress;
        emit SignerAddressUpdated(newSignerAddress);
    }

    /**
     * @notice Sets the daily HUNT reward pool amount
     * @param newDailyHuntReward The new daily HUNT reward pool (in Wei)
     * @dev Only callable by contract owner. Applies to future days, not retroactively.
     * NOTE: This change affects unclaimed rewards from past days! The reward calculation uses the
     * current dailyHuntReward value for ALL days when computing claims. If you lower the reward,
     * users who voted in the past but haven't claimed yet will receive less than they would have
     * received at the time they voted. Similarly, increasing the reward will give users more than
     * expected for their past votes.
     */
    function setDailyHuntReward(uint256 newDailyHuntReward) external onlyOwner {
        if (newDailyHuntReward == 0) revert Mintpad__InvalidParams("dailyHuntReward cannot be zero");
        dailyHuntReward = newDailyHuntReward;
        emit DailyHuntRewardUpdated(newDailyHuntReward);
    }

    /**
     * @notice Emergency function to refund HUNT tokens to the owner
     * @param amount The amount of HUNT to refund (in Wei)
     * @dev Only callable by contract owner. Use with caution as it affects contract balance
     */
    function refundHUNT(uint256 amount) external onlyOwner {
        if (amount == 0) revert Mintpad__InvalidParams("amount cannot be zero");
        if (amount > HUNT.balanceOf(address(this))) revert Mintpad__InvalidParams("insufficient balance");

        HUNT.safeTransfer(msg.sender, amount);
    }

    // MARK: - View Functions

    /**
     * @notice Returns the current day number since contract deployment
     * @return Current day (0 = deployment day, increments every 86400 seconds)
     * @dev Day boundaries are based on elapsed seconds, not UTC timezone
     * @dev Voting is allowed only on the current day; claims are available starting the next day
     */
    function getCurrentDay() public view returns (uint256) {
        return (block.timestamp - DEPLOYMENT_TIMESTAMP) / SECONDS_PER_DAY;
    }

    // MARK: - Write Functions (User)

    /**
     * @notice Activates daily voting points for the current day using a signed permit
     * @param votingPoint The amount of voting points to activate
     * @param signature The EIP-712 signature from the authorized signer
     * @dev Can only be called once per day per user. Requires valid signature from the signer address
     */
    function activateVotingPoint(uint32 votingPoint, bytes calldata signature) external {
        if (votingPoint == 0) revert Mintpad__InvalidParams("votingPoint cannot be zero");

        address user = msg.sender;
        uint256 day = getCurrentDay();

        // Ensure user hasn't already activated voting points for today
        if (dailyUserVotingPoint[day][user] > 0) {
            revert Mintpad__AlreadyActivated();
        }

        // Verify EIP-712 signature
        bytes32 structHash = keccak256(abi.encode(VOTING_POINT_TYPEHASH, user, day, votingPoint));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recoveredSigner = ECDSA.recover(digest, signature);

        if (recoveredSigner != signer) {
            revert Mintpad__InvalidSignature();
        }

        // Activate voting points for user
        dailyUserVotingPoint[day][user] = votingPoint;

        // Update daily statistics
        unchecked {
            // Safe: uint32 max is ~4.3B, daily total voting points cannot exceed HUNT total supply (198M)
            // controlled by off-chain signature system
            dailyStats[day].totalVotingPointGiven += votingPoint;
        }

        emit VotingPointActivated(day, user, votingPoint);
    }

    /**
     * @notice Votes for a specific token using allocated voting points
     * @param token The address of the child token to vote for
     * @param voteAmount The amount of voting points to spend
     * @dev Voting points must be activated first via activateVotingPoint()
     */
    function vote(address token, uint32 voteAmount) external _validChildToken(token) {
        if (voteAmount == 0) revert Mintpad__InvalidParams("voteAmount");

        address user = msg.sender;
        uint256 day = getCurrentDay();

        // Check user's remaining voting points
        uint32 remainingPoints = dailyUserVotingPoint[day][user];
        if (voteAmount > remainingPoints) {
            revert Mintpad__InsufficientVotingPoints();
        }

        unchecked {
            // Update user voting status
            dailyUserVotingPoint[day][user] = remainingPoints - voteAmount;
            dailyUserTokenVotes[day][user][token] += voteAmount;

            // Update daily stats (gas optimization: single SSTORE with explicit packing)
            DailyStats storage stats = dailyStats[day];
            stats.totalVotingPointSpent += voteAmount;
            stats.votingCount += 1;
        }

        emit Voted(day, user, token, voteAmount);
    }

    /**
     * @notice Claims accumulated HUNT rewards for a specific token and mints tokens
     * @param token The address of the child token to claim for
     * @param tokensToMint The desired amount of tokens to mint
     * @param donationBp Donation amount in basis points (0-10000, where 100 = 1%)
     * @return actualHuntSpent The actual amount of HUNT spent on minting
     * @dev Claims rewards from all unclaimed days up to yesterday (max 30 days).
     * NOTE: Reward calculation uses the CURRENT dailyHuntReward value for all past days.
     * If the owner changes the reward amount, your claimable rewards will change accordingly.
     */
    function claim(
        address token,
        uint256 tokensToMint,
        uint256 donationBp
    ) external _validChildToken(token) returns (uint256 actualHuntSpent) {
        if (tokensToMint == 0) revert Mintpad__InvalidParams("tokensToMint must be greater than 0");
        if (donationBp > 10000) revert Mintpad__InvalidParams("donationBp cannot exceed 10000");

        address user = msg.sender;

        // Calculate total claimable HUNT from all eligible days
        (uint256 totalHuntToClaim, uint256 endDay) = _getClaimableHunt(user, token);

        if (totalHuntToClaim == 0) revert Mintpad__NothingToClaim();

        // Update last claimed day before external calls (prevents double-claiming, follows CEI pattern)
        userTokenLastClaimDay[user][token] = endDay;

        // Execute mint through BOND contract with slippage protection
        actualHuntSpent = BOND.mint(token, tokensToMint, totalHuntToClaim, address(this));

        // Ensure claim efficiency: revert if more than 2% is left unused
        // This prevents users from claiming with inefficiently low tokensToMint values
        unchecked {
            // Safe: multiplication cannot overflow with reasonable values
            if (actualHuntSpent * 100 < totalHuntToClaim * MIN_CLAIM_EFFICIENCY_PERCENT) {
                revert Mintpad__ExcessiveLeftover(actualHuntSpent);
            }
        }

        // Transfer tokens to user (with optional creator donation)
        if (donationBp > 0) {
            (address creator, , , , , ) = BOND.tokenBond(token);
            unchecked {
                // Safe: donationAmount <= tokensToMint (donationBp validated <= 10000)
                uint256 donationAmount = (tokensToMint * donationBp) / 10000;
                IERC20(token).safeTransfer(creator, donationAmount);
                IERC20(token).safeTransfer(user, tokensToMint - donationAmount);
            }
        } else {
            IERC20(token).safeTransfer(user, tokensToMint);
        }

        // Update daily statistics (gas optimization: single SSTORE)
        unchecked {
            uint256 currentDay = getCurrentDay();
            DailyStats memory stats = dailyStats[currentDay];
            // Safe: uint88 max is ~3.09e26 wei, HUNT total supply is 198M (1.98e26 wei)
            // Daily claims cannot exceed total HUNT supply
            stats.totalHuntClaimed += uint88(actualHuntSpent);
            ++stats.claimCount;
            dailyStats[currentDay] = stats;
        }

        emit Claimed(user, token, endDay, actualHuntSpent, tokensToMint, donationBp);
    }

    // MARK: - Public View Functions

    /**
     * @notice Calculates the total claimable HUNT rewards for a user and token
     * @param user The user's address
     * @param token The token's address
     * @return totalHuntToClaim The total HUNT amount claimable (in Wei)
     * @return endDay The last day included in this calculation (yesterday)
     * @dev Aggregates rewards from all unclaimed days within the 30-day expiration window
     */
    function getClaimableHunt(
        address user,
        address token
    ) public view returns (uint256 totalHuntToClaim, uint256 endDay) {
        return _getClaimableHunt(user, token);
    }

    /**
     * @dev Internal helper to calculate claimable HUNT for a user-token pair.
     * Calculates rewards from unclaimed days within the 30-day expiration window.
     * NOTE: This function uses the CURRENT dailyHuntReward value for calculating ALL past days.
     * If the owner changes dailyHuntReward via setDailyHuntReward(), this will retroactively affect
     * all unclaimed rewards, even for votes cast when a different reward amount was in effect.
     * @param user The user's address
     * @param token The token's address
     * @return totalHuntToClaim The total HUNT amount claimable (in Wei)
     * @return endDay The last day included in this calculation (yesterday)
     */
    function _getClaimableHunt(
        address user,
        address token
    ) private view returns (uint256 totalHuntToClaim, uint256 endDay) {
        uint256 currentDay = getCurrentDay();

        // Cannot claim for the current day, only completed days (up to yesterday)
        if (currentDay == 0) return (0, 0);

        unchecked {
            endDay = currentDay - 1; // Safe: currentDay > 0

            // Calculate the 30-day expiration floor
            uint256 expiryFloorDay = currentDay > VOTE_EXPIRATION_DAYS ? currentDay - VOTE_EXPIRATION_DAYS : 0;

            // Get the last day this user claimed for this token
            uint256 lastClaimedDay = userTokenLastClaimDay[user][token];

            // Determine the start day for reward calculation
            uint256 startDay;
            if (lastClaimedDay == 0) {
                // First time claiming: start from expiry floor or day 0
                startDay = expiryFloorDay;
            } else {
                // Subsequent claim: start from day after last claim (within expiry window)
                startDay = lastClaimedDay >= expiryFloorDay ? lastClaimedDay + 1 : expiryFloorDay;
            }

            if (startDay > endDay) return (0, endDay); // Nothing to claim

            totalHuntToClaim = 0;

            // Accumulate rewards from all eligible days (max 30 iterations)
            // Gas cost: First SLOAD per slot costs 2100 gas, subsequent accesses cost 100 gas
            // Worst case: 30 days × 3 SLOADs = ~69,000 gas for loop (safe on Base chain)
            for (uint256 day = startDay; day <= endDay; ++day) {
                uint256 userVotes = dailyUserTokenVotes[day][user][token];
                if (userVotes == 0) continue;

                DailyStats memory dailyStat = dailyStats[day];
                uint256 totalVotes = dailyStat.totalVotingPointSpent;
                if (totalVotes == 0) continue;

                // Calculate proportional reward: (userVotes / totalVotes) * dailyReward
                // Uses CURRENT dailyHuntReward for all days - changes to dailyHuntReward
                // will retroactively affect unclaimed rewards from past days
                totalHuntToClaim += (userVotes * dailyHuntReward) / totalVotes;
            }
        }

        return (totalHuntToClaim, endDay);
    }
}

// MARK: - Interfaces

/**
 * @title IMCV2_Bond
 * @notice Interface for the MCV2_Bond bonding curve contract
 * @dev Minimal interface containing only the functions used by Mintpad
 */
interface IMCV2_Bond {
    function exists(address token) external view returns (bool);

    function mint(
        address token,
        uint256 tokensToMint,
        uint256 maxReserveAmount,
        address receiver
    ) external returns (uint256);

    function tokenBond(
        address token
    )
        external
        view
        returns (
            address creator,
            uint16 mintRoyalty,
            uint16 burnRoyalty,
            uint40 createdAt,
            address reserveToken,
            uint256 reserveBalance
        );
}
