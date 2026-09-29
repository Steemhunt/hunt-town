// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    ReentrancyGuardTransient
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { IFactoryNFT } from "./interfaces/IFactoryNFT.sol";

/// @notice Exchanges legacy Buildings for Factory NFTs using team-funded HUNT.
/// @dev Base receipts are verified off-chain by the trusted operator, not by this contract.
contract BuildingMigrator is Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public constant MIGRATION_RECEIVER = 0x25bE2785504c36016aDEC2585F9e120eF6B2f64D;
    uint256 public constant BUILDING_VALUE = 1_000 ether;

    IFactoryNFT public immutable factory;
    IERC721 public immutable building;
    IERC20 public immutable huntToken;
    address public operator;
    mapping(uint256 => bool) public migratedBuildings;
    mapping(bytes32 => bool) public processedRequests;

    error InvalidAddress();
    error InvalidAmount();
    error InvalidRequestId();
    error UnauthorizedOperator();
    error AdditionalHuntExceeded(uint256 required, uint256 maximum);
    error MintPriceExceeded(uint256 required, uint256 maximum);
    error BuildingAlreadyMigrated(uint256 tokenId);
    error RequestAlreadyProcessed(bytes32 requestId);
    error InsufficientHunt(uint256 balance, uint256 required);

    event Migrated(
        address indexed account,
        uint256[] buildingIds,
        uint256 mintingCount,
        uint256 additionalHunt,
        uint256 huntIn
    );
    event OperatorMigrated(
        bytes32 indexed requestId, address indexed receiver, uint256 mintingCount, uint256 huntIn
    );
    event OperatorUpdated(address indexed previousOperator, address indexed newOperator);
    event HuntWithdrawn(uint256 amount);

    constructor(
        IFactoryNFT factory_,
        IERC721 building_,
        address initialOwner,
        address initialOperator
    ) Ownable(initialOwner) {
        if (address(factory_).code.length == 0 || address(building_).code.length == 0) {
            revert InvalidAddress();
        }
        IERC20 hunt = factory_.huntToken();
        if (address(hunt).code.length == 0) revert InvalidAddress();
        factory = factory_;
        building = building_;
        huntToken = hunt;
        operator = initialOperator;
        emit OperatorUpdated(address(0), initialOperator);
    }

    /// @notice Rounds the Building credit up to whole Factory units, as in the frontend.
    /// @dev Batch minting rounds once. Its actual cost can be a few wei below the
    /// single-unit quote times quantity; no top-up is due when credit covers it.
    function quoteMigration(uint256 buildingCount)
        public
        view
        returns (uint256 mintingCount, uint256 additionalHunt, uint256 huntIn)
    {
        if (buildingCount == 0) revert InvalidAmount();
        uint256 credit = buildingCount * BUILDING_VALUE;
        mintingCount = Math.ceilDiv(credit, factory.quoteMint(1));
        huntIn = factory.quoteMint(mintingCount);
        additionalHunt = huntIn > credit ? huntIn - credit : 0;
    }

    /// @notice The caller must own and approve every Building; lock age is irrelevant.
    /// User assets go to custody, while the full mint cost comes from this contract.
    function migrate(uint256[] calldata ids, uint256 maxAdditionalHunt)
        external
        nonReentrant
        returns (uint256 mintingCount, uint256 additionalHunt)
    {
        uint256 huntIn;
        (mintingCount, additionalHunt, huntIn) = quoteMigration(ids.length);
        if (additionalHunt > maxAdditionalHunt) {
            revert AdditionalHuntExceeded(additionalHunt, maxAdditionalHunt);
        }
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            if (migratedBuildings[id]) revert BuildingAlreadyMigrated(id);
            migratedBuildings[id] = true;
            building.safeTransferFrom(msg.sender, MIGRATION_RECEIVER, id);
        }
        if (additionalHunt != 0) {
            huntToken.safeTransferFrom(msg.sender, MIGRATION_RECEIVER, additionalHunt);
        }
        _mint(mintingCount, huntIn, msg.sender);
        emit Migrated(msg.sender, ids, mintingCount, additionalHunt, huntIn);
    }

    /// @notice Fulfills one confirmed Base receipt verified by the operator's worker.
    /// @param requestId Stable identifier for the Base receipt, reused on every retry.
    /// @param maxHuntIn Maximum treasury spend, including any NAV change since the Base quote.
    function migrateByOperator(
        uint256 mintingCount,
        address receiver,
        bytes32 requestId,
        uint256 maxHuntIn
    ) external nonReentrant returns (uint256 huntIn) {
        if (msg.sender != operator) revert UnauthorizedOperator();
        if (receiver == address(0) || receiver == address(this) || receiver == address(factory)) {
            revert InvalidAddress();
        }
        if (mintingCount == 0) revert InvalidAmount();
        if (requestId == bytes32(0)) revert InvalidRequestId();
        if (processedRequests[requestId]) revert RequestAlreadyProcessed(requestId);
        huntIn = factory.quoteMint(mintingCount);
        if (huntIn > maxHuntIn) revert MintPriceExceeded(huntIn, maxHuntIn);
        processedRequests[requestId] = true;
        _mint(mintingCount, huntIn, receiver);
        emit OperatorMigrated(requestId, receiver, mintingCount, huntIn);
    }

    /// @notice A zero operator disables Base fulfillment without affecting mainnet migration.
    function setOperator(address newOperator) external onlyOwner {
        emit OperatorUpdated(operator, newOperator);
        operator = newOperator;
    }

    /// @notice Returns unused team funding to the fixed migration custody wallet.
    function withdrawHunt(uint256 amount) external onlyOwner nonReentrant {
        huntToken.safeTransfer(MIGRATION_RECEIVER, amount);
        emit HuntWithdrawn(amount);
    }

    function _mint(uint256 mintingCount, uint256 huntIn, address receiver) private {
        uint256 balance = huntToken.balanceOf(address(this));
        if (balance < huntIn) revert InsufficientHunt(balance, huntIn);
        huntToken.forceApprove(address(factory), huntIn);
        factory.mint(mintingCount, huntIn, receiver);
        huntToken.forceApprove(address(factory), 0);
    }
}
