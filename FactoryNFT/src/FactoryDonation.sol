// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { FactoryNFT } from "./FactoryNFT.sol";

/// @notice Adds HUNT to the Factory vault and records the caller's public message.
/// @dev Messages are emitted in logs, not stored. This contract has no owner or withdrawals.
contract FactoryDonation is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_MESSAGE_BYTES = 280;

    FactoryNFT public immutable factory;
    IERC20 public immutable huntToken;

    error InvalidAddress();
    error InvalidAmount();
    error MessageTooLong(uint256 length);
    error InexactHuntTransfer();

    event Donated(address indexed donor, uint256 amount, string message);

    constructor(FactoryNFT factory_) {
        if (address(factory_).code.length == 0) revert InvalidAddress();
        IERC20 hunt = factory_.huntToken();
        if (address(hunt).code.length == 0) revert InvalidAddress();
        factory = factory_;
        huntToken = hunt;
        // Only the fixed Factory can spend this allowance, through its deposit function.
        hunt.forceApprove(address(factory_), type(uint256).max);
    }

    /// @param expectedSupply The NFT supply read before submitting the donation.
    /// @param message Optional public text, limited to 280 bytes (UTF-8 in the frontend).
    /// @dev FactoryNFT's supply guard and exact-transfer checks apply to the entire transaction.
    function donate(uint256 amount, uint256 expectedSupply, string calldata message)
        external
        nonReentrant
    {
        if (amount == 0) revert InvalidAmount();
        uint256 length = bytes(message).length;
        if (length > MAX_MESSAGE_BYTES) revert MessageTooLong(length);

        uint256 beforeBalance = huntToken.balanceOf(address(this));
        huntToken.safeTransferFrom(msg.sender, address(this), amount);
        // Existing dust must not subsidize a short incoming transfer.
        if (huntToken.balanceOf(address(this)) != beforeBalance + amount) {
            revert InexactHuntTransfer();
        }
        factory.deposit(amount, expectedSupply);
        emit Donated(msg.sender, amount, message);
    }
}
