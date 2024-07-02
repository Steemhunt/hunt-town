// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract TipperGrant is Ownable {
    error InvalidSeasonId();
    error SeasonDataAlreadyExists();
    error TokenTransferFailed();
    error NotEnoughGrantBalance();
    error InvalidGrantParams();
    error NothingToClaim();
    error AlreadyClaimed();

    IERC20 public immutable HUNT;

    constructor(address huntAddress) Ownable(msg.sender) {
        HUNT = IERC20(huntAddress);
    }

    struct Grant {
        uint64 fid;
        bool claimed;
        uint112 amount;
    }
    struct Season {
        uint24 walletCount;
        uint112 totalGrantClaimed;
        uint112 totalGrant;
        mapping(address => Grant) walletGrants;
    }
    mapping(uint256 => Season) private seasons;
    uint256 public lastSeason; // currentSeason = lastSeason + 1;

    event Deposit(address indexed user, uint256 huntAmount);
    event SetGrantData(uint256 indexed season, uint24 walletCount);
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
        uint64[] calldata fids,
        address[] calldata wallets,
        uint112[] calldata grantAmounts
    ) external onlyOwner {
        Season storage season = seasons[seasonId];

        if (season.walletCount != 0) revert SeasonDataAlreadyExists();
        if (seasonId < 1 || lastSeason != seasonId - 1) revert InvalidSeasonId();
        if (fids.length != wallets.length || fids.length != grantAmounts.length) revert InvalidGrantParams();

        lastSeason = seasonId; // curent season becomes the last season

        uint256 length = wallets.length;
        season.walletCount = uint24(length);

        uint256 totalGrantAmount = 0;
        unchecked {
            for (uint256 i = 0; i < length; ++i) {
                totalGrantAmount += grantAmounts[i];
                season.walletGrants[wallets[i]] = Grant({fid: fids[i], claimed: false, amount: grantAmounts[i]});
            }
        }
        if (totalGrantAmount > HUNT.balanceOf(address(this))) revert NotEnoughGrantBalance();
        season.totalGrant = uint112(totalGrantAmount);

        emit SetGrantData(seasonId, season.walletCount);
    }

    function claim(uint256 seasonId) external {
        Season storage season = seasons[seasonId];

        address msgSender = _msgSender();

        Grant storage walletGrant = season.walletGrants[msgSender];

        if (walletGrant.amount == 0) revert NothingToClaim();
        if (walletGrant.claimed) revert AlreadyClaimed();

        walletGrant.claimed = true;
        season.totalGrantClaimed += walletGrant.amount;
        if (!HUNT.transfer(msgSender, walletGrant.amount)) revert TokenTransferFailed();

        emit Claim(msgSender, seasonId, walletGrant.amount);
    }

    // MARK: - Utility view functions
    function getSeasonStats(
        uint256 seasonId
    ) public view returns (uint24 walletCount, uint112 totalGrantClaimed, uint112 totalGrant) {
        Season storage season = seasons[seasonId];

        return (season.walletCount, season.totalGrantClaimed, season.totalGrant);
    }

    function getWalletGrant(
        uint256 seasonId,
        address wallet
    ) public view returns (uint64 fid, bool claimed, uint112 amount) {
        Grant storage grant = seasons[seasonId].walletGrants[wallet];

        return (grant.fid, grant.claimed, grant.amount);
    }
}
