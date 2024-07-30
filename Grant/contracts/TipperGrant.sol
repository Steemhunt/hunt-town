// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title TipperGrant
 * @author sebayaki (@if)
 * @notice This contract is used to distribute grants to Voters (Tip Givers)
 * @dev
 * - All voters (tipping participants) can claim some liquid HUNT based on their total tipping amount.
 * - The reward wallet and amount will be validated via MerkleProof, with only the Merkle root stored on the contract due to the potentially large number of tippers.
 */

contract TipperGrant is Ownable {
    using Strings for uint256;

    error InvalidSeasonId();
    error SeasonDataCannotBeUpdated();
    error TokenTransferFailed();
    error NotEnoughGrantBalance();
    error AlreadyClaimed();
    error InvalidMerkleProof();
    error InvalidDepositAmount();
    error InvalidWalletCount();
    error ClaimDeadlineReached();

    IERC20 public immutable HUNT;
    uint256 public constant CLAIM_DEADLINE = 4 weeks;

    constructor(address huntAddress) Ownable(msg.sender) {
        HUNT = IERC20(huntAddress);
    }

    struct Season {
        uint40 claimStartedAt;
        uint24 walletCount;
        uint24 claimedCount;
        uint112 totalGrantAmount;
        uint112 claimedGrantAmount;
        bytes32 merkleRoot;
        mapping(address => uint112) claimedAmount; // Track claimed amount per address
    }
    Season[] private seasons;

    event Deposit(address indexed user, uint256 huntAmount);
    event SetGrantData(uint256 indexed season, uint24 walletCount, bytes32 merkleRoot);
    event Claim(address indexed user, uint256 indexed season, uint112 huntAmount);
    event EmergencyWithdraw(address indexed user, uint256 huntAmount);

    function currentSeason() external view returns (uint256) {
        return seasons.length;
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

    modifier validSeasonId(uint256 seasonId) {
        if (seasonId >= seasons.length) revert InvalidSeasonId();
        _;
    }

    function setGrantData(
        uint256 seasonId,
        uint24 walletCount,
        uint112 totalGrant,
        bytes32 _merkleRoot
    ) external onlyOwner {
        Season storage season;
        if (seasonId == seasons.length) {
            seasons.push();
            season = seasons[seasonId];
        } else if (seasonId < seasons.length) {
            // overwrites existing season data, unless anyone has already claimed
            season = seasons[seasonId];
            if (season.claimedGrantAmount > 0) revert SeasonDataCannotBeUpdated();
        } else {
            revert InvalidSeasonId();
        }
        if (totalGrant == 0) revert InvalidDepositAmount();
        if (walletCount == 0) revert InvalidWalletCount();
        if (totalGrant > HUNT.balanceOf(address(this))) revert NotEnoughGrantBalance();

        season.walletCount = walletCount;
        season.totalGrantAmount = totalGrant;
        season.merkleRoot = _merkleRoot;
        season.claimStartedAt = uint40(block.timestamp);

        emit SetGrantData(seasonId, walletCount, _merkleRoot);
    }

    function claim(uint256 seasonId, uint112 amount, bytes32[] calldata merkleProof) external validSeasonId(seasonId) {
        Season storage season = seasons[seasonId];
        address msgSender = _msgSender();

        if (block.timestamp > season.claimStartedAt + CLAIM_DEADLINE) revert ClaimDeadlineReached();
        if (season.claimedAmount[msgSender] > 0) revert AlreadyClaimed();
        if (merkleProof.length == 0 || !_verify(season.merkleRoot, msgSender, amount, merkleProof))
            revert InvalidMerkleProof();

        season.claimedAmount[msgSender] = amount;
        season.claimedCount += 1;
        season.claimedGrantAmount += amount;
        if (!HUNT.transfer(msgSender, amount)) revert TokenTransferFailed();

        emit Claim(msgSender, seasonId, amount);
    }

    function isWhitelisted(
        uint256 seasonId,
        address wallet,
        uint112 amount,
        bytes32[] calldata merkleProof
    ) public view validSeasonId(seasonId) returns (bool) {
        Season storage season = seasons[seasonId];

        return _verify(season.merkleRoot, wallet, amount, merkleProof);
    }

    function _verify(
        bytes32 merkleRoot,
        address sender,
        uint112 amount,
        bytes32[] calldata merkleProof
    ) private pure returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(sender, uint256(amount).toString()));

        return MerkleProof.verify(merkleProof, merkleRoot, leaf);
    }

    // MARK: - Utility view functions
    function getSeasonStats(
        uint256 seasonId
    )
        public
        view
        validSeasonId(seasonId)
        returns (
            uint24 walletCount,
            uint24 claimedCount,
            uint112 totalGrant,
            uint112 claimedGrant,
            uint40 claimStartedAt
        )
    {
        Season storage season = seasons[seasonId];

        return (
            season.walletCount,
            season.claimedCount,
            season.totalGrantAmount,
            season.claimedGrantAmount,
            season.claimStartedAt
        );
    }

    function getClaimedAmount(uint256 seasonId, address wallet) public view validSeasonId(seasonId) returns (uint112) {
        return seasons[seasonId].claimedAmount[wallet];
    }
}
