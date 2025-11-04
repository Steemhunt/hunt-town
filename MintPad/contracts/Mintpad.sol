// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Mintpad is Ownable {
    // MARK: - Errors
    error Mintpad__InvalidParams(string param);
    error Mintpad__RollOverInProgress();
    error Mintpad__RollOverNotInProgress();
    error Mintpad__InsufficientVotingPoints();
    error Mintpad__NothingToClaim();
    error Mintpad__TooMuchLeftOver(uint256 actualHuntSpent);
    error Mintpad__TotalPointsUnderflow();

    // MARK: - Constants
    IERC20 private constant HUNT = IERC20(0x37f0c2915CeCC7e977183B8543Fc0864d03E064C);
    IMCV2_Bond public immutable BOND;

    // MARK: - State Variables
    uint256 public constant VOTE_EXPIRATION_DAYS = 30;
    uint256 public dayCounter;
    bool public isRollOverInProgress;

    // [day][user] => voting point remaining (Set by Owner daily, deducted on vote)
    mapping(uint256 => mapping(address => uint32)) public dailyUserVotingPoint;

    // [day] => DailyStats
    struct DailyStats {
        uint32 totalVotingPointGiven; // Total voting points allotted for the day
        uint32 totalVotingPointSpent; // Total voting points spent for the day
        uint24 totalHuntReward; // Total HUNT reward for the day (in Ether)
        uint80 totalHuntClaimed; // Total HUNT claimed for the day (in Wei)
        uint24 votingCount; // Number of votes for the day
        uint24 claimCount; // Number of claims for the day
    }
    mapping(uint256 => DailyStats) public dailyStats;

    // [day][user][token] => Voting points spent by the user on a specific token on that day
    mapping(uint256 => mapping(address => mapping(address => uint32))) public dailyUserTokenVotes;

    // [user][token] => The last day the user claimed rewards for this token
    mapping(address => mapping(address => uint256)) public userTokenLastClaimDay;

    // MARK: - Events
    event VotingPointsAdded(uint256 indexed day, uint256 updateCount, int256 indexed pointAdded);
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
    constructor(address bond) Ownable(msg.sender) {
        // TODO: Add a separate signer (hot key) for daily operations

        if (bond == address(0)) revert Mintpad__InvalidParams("bond");

        BOND = IMCV2_Bond(bond);

        // Pre-approve HUNT to Bond for minting
        HUNT.approve(bond, type(uint256).max);
    }

    // MARK: - Modifiers
    modifier _validChildToken(address token) {
        if (token == address(0)) revert Mintpad__InvalidParams("zero address");
        if (!BOND.exists(token)) revert Mintpad__InvalidParams("not child token");
        _;
    }

    modifier _whenNotRollingOver() {
        if (isRollOverInProgress) revert Mintpad__RollOverInProgress();
        _;
    }

    modifier _whenRollingOver() {
        if (!isRollOverInProgress) revert Mintpad__RollOverNotInProgress();
        _;
    }

    // MARK: - Admin Functions
    /**
     * @dev Starts the roll-over process.
     */
    function startRollOver() external onlyOwner {
        isRollOverInProgress = true;

        ++dayCounter;
    }

    /**
     * @dev Ends the roll-over process.
     */
    function endRollOver(uint24 totalHuntReward) external onlyOwner _whenRollingOver {
        dailyStats[dayCounter].totalHuntReward = totalHuntReward; // Set to the totalHuntReward for the day

        isRollOverInProgress = false;
    }

    /**
     * @dev Adds voting points for multiple users for the current day.
     * @param users List of user addresses.
     * @param votingPoints List of voting points to add for each user.
     */
    function addVotingPoints(
        address[] calldata users,
        uint32[] calldata votingPoints
    ) external onlyOwner _whenRollingOver {
        uint256 updateCount = users.length;
        if (updateCount != votingPoints.length) revert Mintpad__InvalidParams("length mismatch");

        uint256 day = dayCounter;
        uint256 totalPointAdded = 0;

        unchecked {
            for (uint256 i = 0; i < updateCount; ++i) {
                uint32 points = votingPoints[i];
                dailyUserVotingPoint[day][users[i]] += points;
                totalPointAdded += points;
            }
        }

        // Safe to cast to uint32 because totalPointAdded is always less than ~200M
        dailyStats[day].totalVotingPointGiven += uint32(totalPointAdded);

        emit VotingPointsAdded(day, updateCount, int256(totalPointAdded));
    }

    /**
     * @dev Sets the voting point for a user for the current day. (for new users added during the daily voting window)
     * @param user The address of the user to set the voting point for.
     * @param newVotingPoint The new voting point to set.
     */
    function setVotingPoint(address user, uint32 newVotingPoint) external onlyOwner _whenRollingOver {
        uint256 day = dayCounter;
        uint32 oldVotingPoint = dailyUserVotingPoint[day][user];

        // Gas optimization: Skip if no change
        if (oldVotingPoint == newVotingPoint) return;

        dailyUserVotingPoint[day][user] = newVotingPoint;

        // Bugfix: Update totalVotingPointGiven to reflect the delta
        DailyStats memory stats = dailyStats[day];
        if (newVotingPoint > oldVotingPoint) {
            stats.totalVotingPointGiven += (newVotingPoint - oldVotingPoint);
        } else {
            uint32 delta = oldVotingPoint - newVotingPoint;
            if (stats.totalVotingPointGiven < delta) revert Mintpad__TotalPointsUnderflow();
            stats.totalVotingPointGiven -= delta;
        }
        dailyStats[day] = stats;

        emit VotingPointsAdded(day, 1, int256(uint256(newVotingPoint)) - int256(uint256(oldVotingPoint)));
    }

    // MARK: - Admin Emergency Functions
    /**
     * @dev Sets the current day counter (for emergency troubleshooting only).
     * @param day The day to set.
     */
    function setDayCounter(uint256 day) external onlyOwner {
        dayCounter = day;
    }

    /**
     * @dev Refunds HUNT tokens to the owner (for emergency troubleshooting only).
     * @param amount The amount of HUNT to refund.
     */
    function refundHUNT(uint256 amount) external onlyOwner {
        if (amount == 0) revert Mintpad__InvalidParams("amount cannot be zero");
        if (amount > HUNT.balanceOf(address(this))) revert Mintpad__InvalidParams("insufficient balance");

        HUNT.transfer(msg.sender, amount);
    }

    // MARK: - Write Functions (User)
    /**
     * @dev Votes for a specific token using allotted voting points.
     * @param token The address of the child token to vote for.
     * @param voteAmount The amount of voting points to spend.
     */
    function vote(address token, uint32 voteAmount) external _whenNotRollingOver _validChildToken(token) {
        if (voteAmount == 0) revert Mintpad__InvalidParams("voteAmount");

        address user = msg.sender;
        uint256 day = dayCounter;

        // 1. Check user's remaining voting points and deduct
        uint32 remainingPoints = dailyUserVotingPoint[day][user];
        if (voteAmount > remainingPoints) {
            revert Mintpad__InsufficientVotingPoints();
        }

        unchecked {
            // 2. Update voting status - deduct from remaining points
            dailyUserVotingPoint[day][user] = remainingPoints - voteAmount;
            dailyUserTokenVotes[day][user][token] += voteAmount;

            // Gas optimization: Load struct to memory, modify, and write back once
            DailyStats memory stats = dailyStats[day];
            stats.totalVotingPointSpent += voteAmount;
            ++stats.votingCount;
            dailyStats[day] = stats;
        }

        emit Voted(day, user, token, voteAmount);
    }

    /**
     * @dev Claims mintable HUNT rewards for a specific token.
     * @param token The address of the child token to claim for.
     * @param tokensToMint The minimum amount of tokens to mint, estimated by the client (accounts for slippage).
     */
    function claim(
        address token,
        uint256 tokensToMint,
        uint256 donationBp
    ) external _whenNotRollingOver _validChildToken(token) returns (uint256 actualHuntSpent) {
        if (tokensToMint == 0) revert Mintpad__InvalidParams("tokensToMint must be greater than 0");

        address user = msg.sender;

        // 1. Calculate claimable HUNT amount using the view function logic
        (uint256 totalHuntToClaim, uint256 endDay) = _getClaimableHunt(user, token);

        if (totalHuntToClaim == 0) revert Mintpad__NothingToClaim();

        // 2. Update the last claimed day (prevents re-entrancy/double-claim)
        // This marks all rewards up to `endDay` as consumed.
        userTokenLastClaimDay[user][token] = endDay;

        // 3. Execute the mint via the BOND contract
        // We use `tokensToMint` as the desired token amount, and `totalHuntToClaim` as the `maxReserveAmount` (slippage protection).
        // The BOND.mint function will revert if the actual HUNT cost > totalHuntToClaim.
        actualHuntSpent = BOND.mint(token, tokensToMint, totalHuntToClaim, address(this));

        // NOTE: actualHuntSpent can be smaller than totalHuntToClaim if tokensToMint is capped below the mintable amount.
        // To avoid leaving too much unspent, revert if the leftover exceeds 2% of totalHuntToClaim.
        unchecked {
            // Safe: totalHuntToClaim * 98 cannot overflow uint256
            if (actualHuntSpent * 100 < totalHuntToClaim * 98) {
                revert Mintpad__TooMuchLeftOver(actualHuntSpent);
            }
        }

        // 4. Handle donations to the token creator
        if (donationBp > 0) {
            (address creator, , , , , ) = BOND.tokenBond(token);
            unchecked {
                // Safe: donationAmount <= tokensToMint
                uint256 donationAmount = (tokensToMint * donationBp) / 10000;
                IERC20(token).transfer(creator, donationAmount);
                IERC20(token).transfer(user, tokensToMint - donationAmount);
            }
        } else {
            IERC20(token).transfer(user, tokensToMint);
        }

        // 5. Update daily stats
        // Gas optimization: Load struct to memory, modify, and write back once
        unchecked {
            DailyStats memory stats = dailyStats[dayCounter];
            stats.totalHuntClaimed += uint80(actualHuntSpent);
            ++stats.claimCount;
            dailyStats[dayCounter] = stats;
        }

        emit Claimed(user, token, endDay, actualHuntSpent, tokensToMint, donationBp);
    }

    // MARK: - View Functions

    /**
     * @dev Calculates the total claimable HUNT for a user and token, and the end day of the claim period.
     * @param user The user's address.
     * @param token The token's address.
     * @return totalHuntToClaim The total HUNT amount claimable.
     * @return endDay The last day included in this calculation (i.e., yesterday).
     */
    function getClaimableHunt(
        address user,
        address token
    ) public view returns (uint256 totalHuntToClaim, uint256 endDay) {
        return _getClaimableHunt(user, token);
    }

    /**
     * @dev Internal helper function to consolidate calculation logic.
     * (This is what `claim` and `getClaimableHunt` both use)
     * @notice This function is private and contains the core calculation logic.
     * @return totalHuntToClaim The total HUNT amount claimable.
     * @return endDay The last day included in this calculation (i.e., yesterday).
     */
    function _getClaimableHunt(
        address user,
        address token
    ) private view returns (uint256 totalHuntToClaim, uint256 endDay) {
        uint256 currentDay = dayCounter;

        // 0. Cannot claim for the current day, only up to yesterday.
        if (currentDay == 0) return (0, 0); // No days have passed

        unchecked {
            endDay = currentDay - 1; // Safe: currentDay > 0

            // 1. Calculate the 30-day expiration floor
            uint256 expiryFloorDay = currentDay > VOTE_EXPIRATION_DAYS ? currentDay - VOTE_EXPIRATION_DAYS : 0;

            // 2. Get the last day this user-token pair was claimed
            uint256 lastClaimedDay = userTokenLastClaimDay[user][token];

            // 3. Determine the start day for calculation
            // max(lastClaimedDay + 1, expiryFloorDay)
            uint256 startDay = lastClaimedDay >= expiryFloorDay ? lastClaimedDay + 1 : expiryFloorDay;

            if (startDay > endDay) return (0, endDay); // Nothing to claim

            totalHuntToClaim = 0;

            // 4. Loop (max 30 times) to calculate rewards
            for (uint256 day = startDay; day <= endDay; ++day) {
                uint256 userVotes = dailyUserTokenVotes[day][user][token];
                if (userVotes == 0) continue;

                DailyStats memory dailyStat = dailyStats[day];
                uint256 totalVotes = dailyStat.totalVotingPointSpent;
                if (totalVotes == 0) continue;

                // NOTE: totalHuntReward unit is Ether, so we need to convert it to Wei by multiplying by 1e18
                // Safe: the multiplication cannot overflow in practice given reasonable vote amounts
                totalHuntToClaim += (userVotes * uint256(dailyStat.totalHuntReward) * 1e18) / totalVotes;
            }
        }

        return (totalHuntToClaim, endDay);
    }
}

// MARK: - Interfaces

/**
 * @title IMCV2_Bond (Interface)
 * @dev Minimal interface for the MCV2_Bond contract based on the provided source code.
 */
interface IMCV2_Bond {
    /**
     * @dev Checks if a token exists in the bond.
     */
    function exists(address token) external view returns (bool);

    /**
     * @dev Mint new tokens by depositing reserve tokens.
     * @return The actual reserveAmount (HUNT) spent.
     */
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
