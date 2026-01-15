// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract HuntDrop is EIP712 {
    using SafeERC20 for IERC20;

    error HuntDrop__InvalidParams(string param);
    error HuntDrop__InvalidSignature();
    error HuntDrop__InsufficientBalance();
    error HuntDrop__PermissionDenied();
    error HuntDrop__SignatureExpired();

    // EIP-712 type hash for Claim struct
    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(address receiver,uint256 amount,uint256 nonce,uint256 deadline)");

    IERC20 public constant HUNT = IERC20(0x37f0c2915CeCC7e977183B8543Fc0864d03E064C);
    address public immutable SIGNER;

    mapping(address => uint256) public userNonce;

    event Claimed(address indexed user, uint88 claimedAmount, uint40 timestamp);

    constructor(address signer) EIP712("HuntDrop", "1") {
        if (signer == address(0)) revert HuntDrop__InvalidParams("signer");
        SIGNER = signer;
    }

    // MARK: - Admin functions

    function withdraw(uint256 amount) external {
        if (msg.sender != SIGNER) revert HuntDrop__PermissionDenied();
        if (amount == 0) revert HuntDrop__InvalidParams("amount");
        if (HUNT.balanceOf(address(this)) < amount) revert HuntDrop__InsufficientBalance();

        HUNT.safeTransfer(SIGNER, amount);
    }

    // MARK: - Claim functions

    /**
     * @notice Claim airdrop tokens. The signature must be for msg.sender.
     * @param amount The amount of tokens to claim
     * @param deadline The timestamp after which the signature is no longer valid
     * @param signature EIP-712 signed message containing (msg.sender, amount, nonce, deadline)
     */
    function claimAirdrop(uint256 amount, uint256 deadline, bytes calldata signature) external {
        if (amount == 0) revert HuntDrop__InvalidParams("amount");
        if (block.timestamp > deadline) revert HuntDrop__SignatureExpired();

        // Verify the EIP-712 signature - msg.sender must be the intended receiver
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, msg.sender, amount, userNonce[msg.sender], deadline));
        bytes32 digest = _hashTypedDataV4(structHash);

        address signer = ECDSA.recover(digest, signature);
        if (signer != SIGNER) revert HuntDrop__InvalidSignature();

        // Update nonce to prevent replay attacks
        userNonce[msg.sender] += 1;

        // Transfer tokens to msg.sender (who is the verified receiver)
        HUNT.safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, uint88(amount), uint40(block.timestamp));
    }

    /**
     * @notice Get the EIP-712 struct hash for a claim (for off-chain signature generation)
     * @param receiver The address that will receive the tokens
     * @param amount The amount of tokens to claim
     * @param deadline The timestamp after which the signature is no longer valid
     * @return The struct hash to be signed
     */
    function getStructHash(address receiver, uint256 amount, uint256 deadline) public view returns (bytes32) {
        return keccak256(abi.encode(CLAIM_TYPEHASH, receiver, amount, userNonce[receiver], deadline));
    }

    /**
     * @notice Get the full EIP-712 digest for a claim (for off-chain signature verification)
     * @param receiver The address that will receive the tokens
     * @param amount The amount of tokens to claim
     * @param deadline The timestamp after which the signature is no longer valid
     * @return The digest to be signed
     */
    function getDigest(address receiver, uint256 amount, uint256 deadline) external view returns (bytes32) {
        return _hashTypedDataV4(getStructHash(receiver, amount, deadline));
    }

    /**
     * @notice Returns the domain separator used in the encoding of the signature
     */
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
