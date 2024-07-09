// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract TipperGrant is Ownable {
    using Strings for uint256;

    error InvalidSeasonId();
    error SeasonDataAlreadyExists();
    error TokenTransferFailed();
    error NotEnoughGrantBalance();
    error NothingToClaim();
    error AlreadyClaimed();
    error InvalidMerkleProof();

    IERC20 public immutable HUNT;
    bytes32 public merkleRoot;

    constructor(address huntAddress) Ownable(msg.sender) {
        HUNT = IERC20(huntAddress);
    }

    struct Season {
        uint24 walletCount;
        uint112 totalGrantClaimed;
        uint112 totalGrant;
        mapping(address => uint112) claimedAmount; // Track claimed amount per address
    }
    mapping(uint256 => Season) private seasons;
    uint256 public lastSeason; // currentSeason = lastSeason + 1;

    event Deposit(address indexed user, uint256 huntAmount);
    event SetGrantData(uint256 indexed season, uint24 walletCount, bytes32 merkleRoot);
    event Claim(address indexed user, uint256 indexed season, uint256 huntAmount);
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

    function setGrantData(
        uint256 seasonId,
        uint24 walletCount,
        uint112 totalGrant,
        bytes32 _merkleRoot
    ) external onlyOwner {
        Season storage season = seasons[seasonId];

        if (season.walletCount != 0) revert SeasonDataAlreadyExists();
        if (seasonId < 1 || lastSeason != seasonId - 1) revert InvalidSeasonId();

        lastSeason = seasonId; // current season becomes the last season

        season.walletCount = walletCount;
        season.totalGrant = totalGrant;
        merkleRoot = _merkleRoot;

        if (totalGrant > HUNT.balanceOf(address(this))) revert NotEnoughGrantBalance();

        emit SetGrantData(seasonId, walletCount, _merkleRoot);
    }

    function claim(uint256 seasonId, uint256 maxAmount, bytes32[] calldata merkleProof) external {
        Season storage season = seasons[seasonId];
        address msgSender = _msgSender();

        if (season.claimedAmount[msgSender] > 0) revert AlreadyClaimed();
        if (!_verify(merkleProof, msgSender, maxAmount)) revert InvalidMerkleProof();

        season.claimedAmount[msgSender] = uint112(maxAmount);
        season.totalGrantClaimed += uint112(maxAmount);
        if (!HUNT.transfer(msgSender, maxAmount)) revert TokenTransferFailed();

        emit Claim(msgSender, seasonId, maxAmount);
    }

    function _verify(bytes32[] calldata merkleProof, address sender, uint256 maxAmount) private view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(sender, maxAmount.toString()));
        return MerkleProof.verify(merkleProof, merkleRoot, leaf);
    }

    // MARK: - Utility view functions
    function getSeasonStats(
        uint256 seasonId
    ) public view returns (uint24 walletCount, uint112 totalGrantClaimed, uint112 totalGrant) {
        Season storage season = seasons[seasonId];

        return (season.walletCount, season.totalGrantClaimed, season.totalGrant);
    }

    function getClaimedAmount(uint256 seasonId, address wallet) public view returns (uint112) {
        return seasons[seasonId].claimedAmount[wallet];
    }
}
