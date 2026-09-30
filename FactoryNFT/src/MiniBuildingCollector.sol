// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC1155 } from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @notice Collects a server-approved Mini Building migration payment on Base.
/// @dev Ethereum NAV, quote issuance, and Factory delivery are handled off-chain.
contract MiniBuildingCollector is Ownable2Step, EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public constant MIGRATION_RECEIVER = 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D;
    uint256 public constant MINI_TOKEN_ID = 0;
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "MigrationQuote(bytes32 quoteId,address account,uint256 miniAmount,uint256 mintingCount,uint256 additionalHunt,uint256 deadline)"
    );

    struct MigrationQuote {
        bytes32 quoteId;
        address account;
        uint256 miniAmount;
        uint256 mintingCount;
        uint256 additionalHunt;
        uint256 deadline;
    }

    IERC1155 public immutable building;
    IERC20 public immutable huntToken;
    address public quoteSigner;
    mapping(bytes32 => bool) public consumedQuotes;

    error InvalidAddress();
    error InvalidQuote();
    error UnauthorizedAccount();
    error QuoteExpired();
    error QuoteAlreadyUsed(bytes32 quoteId);
    error InvalidSignature();
    error InexactHuntTransfer();

    event Deposited(
        bytes32 indexed quoteId,
        address indexed account,
        uint256 miniAmount,
        uint256 mintingCount,
        uint256 additionalHunt
    );
    event QuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);

    constructor(
        IERC1155 building_,
        IERC20 huntToken_,
        address initialOwner,
        address initialQuoteSigner
    ) Ownable(initialOwner) EIP712("MiniBuildingCollector", "1") {
        if (address(building_).code.length == 0 || address(huntToken_).code.length == 0) {
            revert InvalidAddress();
        }
        building = building_;
        huntToken = huntToken_;
        _setQuoteSigner(initialQuoteSigner);
    }

    /// @notice Returns the EIP-712 digest, bound to this chain and collector.
    function hashQuote(MigrationQuote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(QUOTE_TYPEHASH, quote)));
    }

    /// @notice Sends both assets directly to custody or reverts the entire payment.
    /// @dev Approvals must exist before this call. The account is also the Ethereum recipient.
    function deposit(MigrationQuote calldata quote, bytes calldata signature)
        external
        nonReentrant
    {
        if (
            quote.quoteId == bytes32(0) || quote.miniAmount == 0 || quote.mintingCount == 0
                || quote.account == MIGRATION_RECEIVER || quote.account == address(this)
        ) revert InvalidQuote();
        if (msg.sender != quote.account) revert UnauthorizedAccount();
        if (block.timestamp > quote.deadline) revert QuoteExpired();
        if (consumedQuotes[quote.quoteId]) revert QuoteAlreadyUsed(quote.quoteId);
        if (ECDSA.recover(hashQuote(quote), signature) != quoteSigner) revert InvalidSignature();

        consumedQuotes[quote.quoteId] = true;
        building.safeTransferFrom(
            msg.sender, MIGRATION_RECEIVER, MINI_TOKEN_ID, quote.miniAmount, ""
        );
        if (quote.additionalHunt != 0) {
            uint256 beforeBalance = huntToken.balanceOf(MIGRATION_RECEIVER);
            huntToken.safeTransferFrom(msg.sender, MIGRATION_RECEIVER, quote.additionalHunt);
            if (huntToken.balanceOf(MIGRATION_RECEIVER) != beforeBalance + quote.additionalHunt) {
                revert InexactHuntTransfer();
            }
        }
        emit Deposited(
            quote.quoteId, quote.account, quote.miniAmount, quote.mintingCount, quote.additionalHunt
        );
    }

    /// @notice Rotating the signer invalidates unconsumed quotes signed by the previous key.
    function setQuoteSigner(address newSigner) external onlyOwner {
        _setQuoteSigner(newSigner);
    }

    function _setQuoteSigner(address newSigner) private {
        if (newSigner == address(0)) revert InvalidAddress();
        emit QuoteSignerUpdated(quoteSigner, newSigner);
        quoteSigner = newSigner;
    }
}
