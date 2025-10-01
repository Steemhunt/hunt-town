// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Mintpad {
    error Mintpad__InvalidParams(string param);
    error Mintpad__NotEnoughHUNTBalance();
    error Mintpad__InvalidSignature();
    error Mintpad__PermissionDenied();

    IERC20 private constant HUNT = IERC20(0x37f0c2915CeCC7e977183B8543Fc0864d03E064C);
    address public immutable SIGNER;
    IMCV2_Bond public immutable BOND;
    uint256 public MAX_MP_PER_MINT = 2000 ether; // 2000 HUNT per mint

    struct MintHistory {
        address user;
        address token;
        uint128 tokensToMint;
        uint88 mpAmount;
        uint40 timestamp;
    }
    MintHistory[] public mintHistory;
    mapping(address => uint40) public userNonce;

    event MintWithMp(
        address indexed user,
        address indexed token,
        uint128 tokensToMint,
        uint88 mpAmount,
        uint40 timestamp
    );

    constructor(address signer, address bond) {
        if (signer == address(0)) revert Mintpad__InvalidParams("signer");
        if (bond == address(0)) revert Mintpad__InvalidParams("bond");

        SIGNER = signer;
        BOND = IMCV2_Bond(bond);

        // Pre-approve HUNT to Bond for minting
        HUNT.approve(bond, type(uint256).max);
    }

    // MARK: - Admin functions

    function setMaxMpPerMint(uint256 maxMpPerMint) external {
        if (msg.sender != SIGNER) revert Mintpad__PermissionDenied();

        MAX_MP_PER_MINT = maxMpPerMint;
    }

    function refundHUNT() external {
        if (msg.sender != SIGNER) revert Mintpad__PermissionDenied();

        HUNT.transfer(msg.sender, HUNT.balanceOf(address(this)));
    }

    // MARK: - Mint functions

    function mintWithMp(
        address token,
        uint128 tokensToMint,
        uint88 maxMpAmount,
        bytes calldata signature
    ) external returns (uint88 mpAmount) {
        if (token == address(0)) revert Mintpad__InvalidParams("token");
        if (tokensToMint == 0) revert Mintpad__InvalidParams("tokensToMint");
        if (maxMpAmount == 0) revert Mintpad__InvalidParams("maxMpAmount");
        if (maxMpAmount > MAX_MP_PER_MINT) revert Mintpad__InvalidParams("maxMpAmount");
        if (HUNT.balanceOf(address(this)) < maxMpAmount) revert Mintpad__NotEnoughHUNTBalance();

        address receiver = msg.sender;

        // Verify the signature
        bytes32 signedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            getMessageHash(receiver, token, tokensToMint, maxMpAmount)
        );

        // Recover signer from signature
        // ECDSA.recover can revert with ECDSAInvalidSignature() | ECDSAInvalidSignatureLength() | ECDSAInvalidSignatureS()
        address signer = ECDSA.recover(signedMessageHash, signature);
        if (signer != SIGNER) revert Mintpad__InvalidSignature();

        // Mint and transfer tokens to the receiver
        // Could revert with MCV2_Bond__TokenNotFound() | MCV2_Bond__SlippageLimitExceeded()
        // NOTE: Force cast to uint88 is safe here as maxMpAmount is checked to be less than MAX_MP_PER_MINT
        mpAmount = uint88(BOND.mint(token, tokensToMint, maxMpAmount, receiver));
        assert(mpAmount <= maxMpAmount); // is guaranteed by the bond contract

        MintHistory memory newHistory = MintHistory(receiver, token, tokensToMint, mpAmount, uint40(block.timestamp));
        mintHistory.push(newHistory);

        userNonce[receiver] += 1;

        emit MintWithMp(receiver, token, tokensToMint, mpAmount, uint40(block.timestamp));
    }

    function getMessageHash(
        address user,
        address token,
        uint256 tokensToMint,
        uint256 maxMpAmount
    ) public view returns (bytes32) {
        uint256 nonce = userNonce[user];
        return keccak256(abi.encode(user, token, tokensToMint, maxMpAmount, nonce));
    }

    // MARK: - View functions

    function getMintHistory(uint256 startIndex, uint256 endIndex) external view returns (MintHistory[] memory history) {
        if (startIndex > endIndex) revert Mintpad__InvalidParams("startIndex > endIndex");
        if (mintHistory.length == 0 || startIndex >= mintHistory.length) return new MintHistory[](0);

        endIndex = endIndex >= mintHistory.length ? mintHistory.length - 1 : endIndex;

        uint256 arrayLength = endIndex - startIndex + 1;
        history = new MintHistory[](arrayLength);

        unchecked {
            for (uint256 i = 0; i < arrayLength; ++i) {
                history[i] = mintHistory[startIndex + i];
            }
        }
    }

    function getMintHistoryCount() external view returns (uint256) {
        return mintHistory.length;
    }

    function get24hAgoHistoryIndex() external view returns (uint256) {
        uint256 length = mintHistory.length;
        if (length == 0) return 0;

        unchecked {
            uint256 timeAt24hAgo = block.timestamp - 86400;

            for (uint256 i = length; i > 0; --i) {
                uint256 index = i - 1;
                if (mintHistory[index].timestamp < timeAt24hAgo) {
                    return index + 1;
                }
            }
        }
        return 0;
    }
}

interface IMCV2_Bond {
    function mint(
        address token,
        uint256 tokensToMint,
        uint256 maxReserveAmount,
        address receiver
    ) external returns (uint256);
}
