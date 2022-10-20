// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

// @custom:security-contact admin@hunt.town
contract Building is ERC721, ERC721Enumerable, Ownable {
    error Building__NotOwnerOrApproved();

    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;

    constructor() ERC721("HUNT Building", "BUILDING") {}

    function safeMint(address to) external onlyOwner returns(uint256 tokenId) {
        tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();

        _safeMint(to, tokenId);
    }

    function nextId() external view returns (uint256) {
        return _tokenIdCounter.current();
    }

    /**
     * @dev Burns `tokenId`.
     *
     * Requirements:
     * - Allow only the contract owner (Townhall contract) to burn the building NFT
     *   to prevent users accidentally burn NFT without unlocking HUNT tokens in it.
     * - The caller must own `tokenId` or be an approved operator.
     */
    function burn(uint256 tokenId, address msgSender) external onlyOwner {
        if(!_isApprovedOrOwner(msgSender, tokenId)) revert Building__NotOwnerOrApproved();

        _burn(tokenId);
    }

    function _baseURI() internal view virtual override returns (string memory) {
        // TODO: Create API endpoint
        // ref: https://collective.proof.xyz/token-metadata/proof-pass/metadata.json?tokenId=0
        return "https://hunt.town/token-metadata/building.json?tokenId=";
    }

    // The following functions are overrides required by Solidity.

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override(ERC721, ERC721Enumerable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}