// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import { ERC1155Supply } from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import { ERC2981 } from "@openzeppelin/contracts/token/common/ERC2981.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

import { IFactoryNFT } from "./interfaces/IFactoryNFT.sol";
import { ICreatorToken, ITransferValidator } from "./interfaces/ICreatorToken.sol";

/// @notice Identical ERC1155 units backed directly by HUNT. Incoming HUNT raises NAV;
/// minting pays current NAV and redemption retains 5% for the remaining units.
contract FactoryNFT is
    ERC1155Supply,
    ERC2981,
    Ownable2Step,
    ReentrancyGuardTransient,
    IFactoryNFT,
    ICreatorToken
{
    using SafeERC20 for IERC20;

    uint256 public constant TOKEN_ID = 0;
    uint256 public constant INITIAL_NAV = 1_000 ether;
    uint256 public constant BURN_FEE_BPS = 500;
    uint96 public constant ROYALTY_BPS = 300;
    uint256 private constant BPS = 10_000;

    IERC20 public immutable huntToken;
    address public royaltyOperator;
    address private _transferValidator;

    error InvalidAddress();
    error InvalidAmount();
    error MinimumSupply();
    error MintPriceExceeded(uint256 required, uint256 maximum);
    error BurnProceedsTooLow(uint256 actual, uint256 minimum);
    error InexactHuntTransfer();
    error SupplyChanged(uint256 actual, uint256 expected);

    event Minted(address indexed payer, address indexed receiver, uint256 amount, uint256 huntIn);
    event Redeemed(address indexed holder, uint256 amount, uint256 huntOut, uint256 retainedFee);
    event Deposited(address indexed depositor, uint256 huntIn, uint256 supply);
    event RoyaltyOperatorUpdated(address indexed previousOperator, address indexed newOperator);

    /// @dev The deployer must preapprove this contract's predicted address for INITIAL_NAV.
    /// The seed is a normal unit; a global supply floor of one prevents an empty vault.
    constructor(
        IERC20 huntToken_,
        address initialOwner,
        address seedOwner,
        string memory uri_,
        address royaltyOperator_,
        address transferValidator_
    ) ERC1155(uri_) Ownable(initialOwner) {
        if (
            address(huntToken_).code.length == 0 || seedOwner == address(0)
                || seedOwner == address(this)
        ) revert InvalidAddress();
        huntToken = huntToken_;
        _setRoyaltyOperator(royaltyOperator_);
        _setTransferValidator(transferValidator_);
        _pullHunt(msg.sender, INITIAL_NAV);
        _mint(seedOwner, TOKEN_ID, 1, "");
        emit Minted(msg.sender, seedOwner, 1, INITIAL_NAV);
    }

    /// @notice Gross HUNT backing per unit, in HUNT's 18-decimal base units.
    function navPerNFT() public view returns (uint256) {
        return huntToken.balanceOf(address(this)) / totalSupply(TOKEN_ID);
    }

    /// @notice Uses full precision before rounding up, so minting cannot dilute backing.
    function quoteMint(uint256 amount) public view returns (uint256 huntIn) {
        if (amount == 0) revert InvalidAmount();
        return Math.mulDiv(
            huntToken.balanceOf(address(this)), amount, totalSupply(TOKEN_ID), Math.Rounding.Ceil
        );
    }

    /// @notice All units in one redemption use the same pre-redemption NAV.
    function quoteBurn(uint256 amount) public view returns (uint256 huntOut) {
        return Math.mulDiv(_grossRedemption(amount), BPS - BURN_FEE_BPS, BPS);
    }

    function mint(uint256 amount, uint256 maxHuntIn, address receiver)
        external
        nonReentrant
        returns (uint256 huntIn)
    {
        if (receiver == address(0) || receiver == address(this)) {
            revert InvalidAddress();
        }
        huntIn = quoteMint(amount);
        if (huntIn > maxHuntIn) revert MintPriceExceeded(huntIn, maxHuntIn);
        _pullHunt(msg.sender, huntIn);
        _mint(receiver, TOKEN_ID, amount, "");
        emit Minted(msg.sender, receiver, amount, huntIn);
    }

    /// @notice Only the caller's units may be redeemed; transfer approvals cannot redeem.
    function burn(uint256 amount, uint256 minHuntOut)
        external
        nonReentrant
        returns (uint256 huntOut)
    {
        uint256 gross = _grossRedemption(amount);
        huntOut = Math.mulDiv(gross, BPS - BURN_FEE_BPS, BPS);
        if (huntOut < minHuntOut) revert BurnProceedsTooLow(huntOut, minHuntOut);
        _burn(msg.sender, TOKEN_ID, amount);
        huntToken.safeTransfer(msg.sender, huntOut);
        emit Redeemed(msg.sender, amount, huntOut, gross - huntOut);
    }

    /// @notice Adds HUNT to the backing of every unit. Reverts if any unit was minted or
    /// burned after `expectedSupply` was read, so a pending deposit cannot be captured by a
    /// mint placed in front of it. A plain HUNT transfer also raises NAV but has no such guard.
    function deposit(uint256 amount, uint256 expectedSupply) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 supply = totalSupply(TOKEN_ID);
        if (supply != expectedSupply) revert SupplyChanged(supply, expectedSupply);
        _pullHunt(msg.sender, amount);
        emit Deposited(msg.sender, amount, supply);
    }

    function setURI(string calldata newURI) external onlyOwner {
        _setURI(newURI);
        emit URI(newURI, TOKEN_ID);
    }

    function setRoyaltyOperator(address newOperator) external onlyOwner {
        _setRoyaltyOperator(newOperator);
    }

    function getTransferValidator() external view returns (address) {
        return _transferValidator;
    }

    /// @notice Setting zero disables transfer validation. Does not change redemption rights.
    function setTransferValidator(address validator) external onlyOwner {
        _setTransferValidator(validator);
    }

    function getTransferValidationFunction() external pure returns (bytes4, bool) {
        return (ITransferValidator.validateTransfer.selector, false);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155, ERC2981)
        returns (bool)
    {
        return interfaceId == type(ICreatorToken).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 value,
        bytes memory data
    ) public override nonReentrant {
        super.safeTransferFrom(from, to, id, value, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values,
        bytes memory data
    ) public override nonReentrant {
        super.safeBatchTransferFrom(from, to, ids, values, data);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (ids.length != values.length) {
            revert ERC1155InvalidArrayLength(ids.length, values.length);
        }
        // Mint and redemption use the HUNT accounting above, independently of marketplace policy.
        if (from != address(0) && to != address(0) && _transferValidator != address(0)) {
            for (uint256 i; i < ids.length; ++i) {
                ITransferValidator(_transferValidator)
                    .validateTransfer(_msgSender(), from, to, ids[i], values[i]);
            }
        }
        super._update(from, to, ids, values);
    }

    function _grossRedemption(uint256 amount) private view returns (uint256) {
        if (amount == 0) revert InvalidAmount();
        uint256 supply = totalSupply(TOKEN_ID);
        if (amount >= supply) revert MinimumSupply();
        return Math.mulDiv(huntToken.balanceOf(address(this)), amount, supply);
    }

    function _pullHunt(address payer, uint256 amount) private {
        uint256 beforeBalance = huntToken.balanceOf(address(this));
        huntToken.safeTransferFrom(payer, address(this), amount);
        if (huntToken.balanceOf(address(this)) != beforeBalance + amount) {
            revert InexactHuntTransfer();
        }
    }

    function _setRoyaltyOperator(address newOperator) private {
        if (newOperator == address(0)) revert InvalidAddress();
        emit RoyaltyOperatorUpdated(royaltyOperator, newOperator);
        royaltyOperator = newOperator;
        _setDefaultRoyalty(newOperator, ROYALTY_BPS);
    }

    function _setTransferValidator(address validator) private {
        if (validator != address(0) && validator.code.length == 0) revert InvalidAddress();
        emit TransferValidatorUpdated(_transferValidator, validator);
        _transferValidator = validator;
    }
}
