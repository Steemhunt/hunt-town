// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ProjectUpdates
 * @notice Allows token creators to post project updates by burning HUNT tokens
 * @dev Updates are stored in a single array with indices mapped per token for efficient lookups
 */
contract ProjectUpdates is Ownable {
    using SafeERC20 for IERC20;

    // MARK: - Errors
    error ProjectUpdates__InvalidParams(string param);
    error ProjectUpdates__NotTokenCreator();
    error ProjectUpdates__NotAuthorized();
    error ProjectUpdates__AlreadyAuthority();
    error ProjectUpdates__NotAuthority();

    // MARK: - Structs
    struct ProjectUpdate {
        address tokenAddress;
        string link;
    }

    // MARK: - Constants
    IERC20 private constant HUNT = IERC20(0x37f0c2915CeCC7e977183B8543Fc0864d03E064C);
    IMCV2_Bond public constant BOND = IMCV2_Bond(0xc5a076cad94176c2996B32d8466Be1cE757FAa27);
    address private constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // MARK: - State Variables
    uint256 public pricePerUpdate;
    /// @notice All project updates in historical order
    ProjectUpdate[] public projectUpdates;

    /// @notice Indices into projectUpdates array, grouped by token address
    mapping(address => uint256[]) private _tokenUpdateIndices;

    /// @notice Additional authorities per token who can post updates (besides the creator)
    mapping(address => address[]) private _tokenAuthorities;

    // MARK: - Events
    event PricePerUpdateChanged(uint256 newPricePerUpdate);
    event ProjectUpdatePosted(
        address indexed tokenAddress,
        address indexed creator,
        uint256 indexed updateIndex,
        string link
    );
    event AuthorityAdded(address indexed tokenAddress, address indexed authority);
    event AuthorityRemoved(address indexed tokenAddress, address indexed authority);

    // MARK: - Constructor
    /**
     * @notice Initializes the ProjectUpdates contract
     * @param initialPricePerUpdate Initial price in HUNT tokens (in Wei) required per update (0 for free updates)
     */
    constructor(uint256 initialPricePerUpdate) Ownable(msg.sender) {
        pricePerUpdate = initialPricePerUpdate;
    }

    // MARK: - Admin Functions

    /**
     * @notice Sets the price per update in HUNT tokens
     * @param newPricePerUpdate The new price per update (in Wei, 0 for free updates)
     * @dev Only callable by contract owner. Set to 0 for promotional free update periods.
     */
    function setPricePerUpdate(uint256 newPricePerUpdate) external onlyOwner {
        pricePerUpdate = newPricePerUpdate;
        emit PricePerUpdateChanged(newPricePerUpdate);
    }

    // MARK: - Authority Management Functions

    /**
     * @notice Adds an additional authority who can post updates for a token
     * @param tokenAddress The address of the token
     * @param authority The address to grant authority to
     * @dev Only the token creator can add authorities
     */
    function addAuthority(address tokenAddress, address authority) external {
        if (tokenAddress == address(0)) revert ProjectUpdates__InvalidParams("zero address");
        if (authority == address(0)) revert ProjectUpdates__InvalidParams("zero authority");

        // Verify caller is the token creator
        (address creator, , , , , ) = BOND.tokenBond(tokenAddress);
        if (msg.sender != creator) revert ProjectUpdates__NotTokenCreator();

        // Check if already an authority
        if (_isAuthority(tokenAddress, authority)) revert ProjectUpdates__AlreadyAuthority();

        _tokenAuthorities[tokenAddress].push(authority);

        emit AuthorityAdded(tokenAddress, authority);
    }

    /**
     * @notice Removes an authority from a token
     * @param tokenAddress The address of the token
     * @param authority The address to remove authority from
     * @dev Only the token creator can remove authorities
     */
    function removeAuthority(address tokenAddress, address authority) external {
        if (tokenAddress == address(0)) revert ProjectUpdates__InvalidParams("zero address");
        if (authority == address(0)) revert ProjectUpdates__InvalidParams("zero authority");

        // Verify caller is the token creator
        (address creator, , , , , ) = BOND.tokenBond(tokenAddress);
        if (msg.sender != creator) revert ProjectUpdates__NotTokenCreator();

        // Remove from array by finding and swapping with last element
        address[] storage authorities = _tokenAuthorities[tokenAddress];
        uint256 length = authorities.length;
        bool found = false;
        for (uint256 i = 0; i < length; ++i) {
            if (authorities[i] == authority) {
                authorities[i] = authorities[length - 1];
                authorities.pop();
                found = true;
                break;
            }
        }

        if (!found) revert ProjectUpdates__NotAuthority();

        emit AuthorityRemoved(tokenAddress, authority);
    }

    // MARK: - Write Functions

    /**
     * @notice Posts a project update for a token
     * @param tokenAddress The address of the token to post update for
     * @param link The link to the project update content
     * @dev Only the token creator or added authorities can post updates. Burns HUNT per update (skipped if price is 0).
     */
    function postUpdate(address tokenAddress, string calldata link) external {
        if (tokenAddress == address(0)) revert ProjectUpdates__InvalidParams("zero address");
        if (bytes(link).length == 0) revert ProjectUpdates__InvalidParams("empty link");

        // Verify caller is the token creator or an authority
        (address creator, , , , , ) = BOND.tokenBond(tokenAddress);
        if (msg.sender != creator && !_isAuthority(tokenAddress, msg.sender)) {
            revert ProjectUpdates__NotAuthorized();
        }

        // Burn HUNT by sending to dead address (skip if free updates enabled)
        if (pricePerUpdate > 0) {
            HUNT.safeTransferFrom(msg.sender, DEAD_ADDRESS, pricePerUpdate);
        }

        // Store update index before pushing
        uint256 updateIndex = projectUpdates.length;

        // Store the update
        projectUpdates.push(ProjectUpdate({tokenAddress: tokenAddress, link: link}));

        // Store index for token-specific lookup
        _tokenUpdateIndices[tokenAddress].push(updateIndex);

        emit ProjectUpdatePosted(tokenAddress, msg.sender, updateIndex, link);
    }

    // MARK: - View Functions

    /**
     * @notice Returns the list of authorities for a token
     * @param tokenAddress The token address to query
     * @return Array of authority addresses
     */
    function getAuthorities(address tokenAddress) external view returns (address[] memory) {
        return _tokenAuthorities[tokenAddress];
    }

    /**
     * @notice Checks if an address is an authority for a token
     * @param tokenAddress The token address to check
     * @param authority The address to check
     * @return True if the address is an authority for the token
     */
    function isAuthority(address tokenAddress, address authority) external view returns (bool) {
        return _isAuthority(tokenAddress, authority);
    }

    // MARK: - Internal Functions

    function _isAuthority(address tokenAddress, address authority) internal view returns (bool) {
        address[] storage authorities = _tokenAuthorities[tokenAddress];
        uint256 length = authorities.length;
        for (uint256 i = 0; i < length; ++i) {
            if (authorities[i] == authority) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Returns the total number of project updates
     * @return The length of the projectUpdates array
     */
    function getProjectUpdatesCount() external view returns (uint256) {
        return projectUpdates.length;
    }

    /**
     * @notice Returns the total number of project updates for a specific token
     * @param tokenAddress The token address to query
     * @return The length of updates for the given token
     */
    function getTokenProjectUpdatesCount(address tokenAddress) external view returns (uint256) {
        return _tokenUpdateIndices[tokenAddress].length;
    }

    /**
     * @notice Gets latest project updates with pagination (newest first)
     * @param offset Number of items to skip from the end
     * @param limit Maximum number of items to return
     * @return updates Array of ProjectUpdate structs in reverse chronological order
     */
    function getLatestUpdates(uint256 offset, uint256 limit) external view returns (ProjectUpdate[] memory updates) {
        uint256 length = projectUpdates.length;

        if (length == 0 || offset >= length) {
            return new ProjectUpdate[](0);
        }

        unchecked {
            uint256 available = length - offset;
            uint256 count = available < limit ? available : limit;

            updates = new ProjectUpdate[](count);
            uint256 startIndex = length - 1 - offset;

            for (uint256 i = 0; i < count; ++i) {
                updates[i] = projectUpdates[startIndex - i];
            }
        }
    }

    /**
     * @notice Gets latest project updates for a specific token with pagination (newest first)
     * @param tokenAddress The token address to filter by
     * @param offset Number of items to skip from the end
     * @param limit Maximum number of items to return
     * @return updates Array of ProjectUpdate structs in reverse chronological order
     */
    function getLatestProjectUpdates(
        address tokenAddress,
        uint256 offset,
        uint256 limit
    ) external view returns (ProjectUpdate[] memory updates) {
        uint256[] storage indices = _tokenUpdateIndices[tokenAddress];
        uint256 length = indices.length;

        if (length == 0 || offset >= length) {
            return new ProjectUpdate[](0);
        }

        unchecked {
            uint256 available = length - offset;
            uint256 count = available < limit ? available : limit;

            updates = new ProjectUpdate[](count);
            uint256 startIndex = length - 1 - offset;

            for (uint256 i = 0; i < count; ++i) {
                updates[i] = projectUpdates[indices[startIndex - i]];
            }
        }
    }
}

// MARK: - Interfaces

/**
 * @title IMCV2_Bond
 * @notice Interface for the MCV2_Bond bonding curve contract
 * @dev Minimal interface containing only the functions used by ProjectUpdates
 */
interface IMCV2_Bond {
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
