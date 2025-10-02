// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.30;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Mintpad {
    error Mintpad__InvalidParams(string param);
    error Mintpad__NotEnoughHuntBalance();
    error Mintpad__InvalidSignature();
    error Mintpad__PermissionDenied();

    IERC20 private constant HUNT = IERC20(0x37f0c2915CeCC7e977183B8543Fc0864d03E064C);
    address public immutable SIGNER;
    IMCV2_Bond public immutable BOND;
    uint256 public MAX_MP_PER_MINT = 2000 ether; // 2000 HUNT per mint

    struct MintHistory {
        address user; // slot 0
        uint88 huntAmount; // slot 0
        uint40 timestamp; // slot 1
        address token; // slot 1
        uint128 totalTokensMinted; // slot 2
        uint128 tokensDonated; // slot 2
    }
    MintHistory[] public mintHistory;
    mapping(address => uint40) public userNonce;

    event Minted(
        address indexed user,
        uint88 huntAmount,
        address indexed token,
        uint40 timestamp,
        uint128 totalTokensMinted,
        uint128 tokensDonated
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

    function setMaxHuntPerMint(uint256 maxHuntPerMint) external {
        if (msg.sender != SIGNER) revert Mintpad__PermissionDenied();

        MAX_MP_PER_MINT = maxHuntPerMint;
    }

    function refundHUNT() external {
        if (msg.sender != SIGNER) revert Mintpad__PermissionDenied();

        HUNT.transfer(msg.sender, HUNT.balanceOf(address(this)));
    }

    // MARK: - Mint functions

    function mintWithHunt(
        address token,
        uint128 tokensToMint,
        uint88 maxHuntAmount,
        uint16 donationBp,
        bytes calldata signature
    ) external returns (uint88 huntAmount) {
        if (token == address(0)) revert Mintpad__InvalidParams("token");
        if (tokensToMint == 0) revert Mintpad__InvalidParams("tokensToMint");
        if (maxHuntAmount == 0) revert Mintpad__InvalidParams("maxHuntAmount");
        if (maxHuntAmount > MAX_MP_PER_MINT) revert Mintpad__InvalidParams("maxHuntAmount");
        if (donationBp > 10000) revert Mintpad__InvalidParams("donationBp");
        if (HUNT.balanceOf(address(this)) < maxHuntAmount) revert Mintpad__NotEnoughHuntBalance();

        address receiver = msg.sender;

        // Verify the signature
        bytes32 signedMessageHash = MessageHashUtils.toEthSignedMessageHash(
            getMessageHash(receiver, token, tokensToMint, maxHuntAmount, donationBp)
        );

        // Recover signer from signature
        // ECDSA.recover can revert with ECDSAInvalidSignature() | ECDSAInvalidSignatureLength() | ECDSAInvalidSignatureS()
        address signer = ECDSA.recover(signedMessageHash, signature);
        if (signer != SIGNER) revert Mintpad__InvalidSignature();

        // Mint and transfer tokens to the receiver and creator (donation)
        // Could revert with MCV2_Bond__TokenNotFound() | MCV2_Bond__SlippageLimitExceeded()
        // NOTE: Force cast to uint88 is safe here as maxHuntAmount is checked to be less than MAX_MP_PER_MINT
        uint128 tokensToDonated;
        if (donationBp > 0) {
            tokensToDonated = (tokensToMint * donationBp) / 10000;
            (address donationReceiver, , , , , ) = BOND.tokenBond(token);

            // NOTE: uint88 is guaranteed by totalSupply of HUNT token
            huntAmount = uint88(BOND.mint(token, tokensToMint - tokensToDonated, maxHuntAmount, receiver));
            huntAmount += uint88(BOND.mint(token, tokensToDonated, maxHuntAmount, donationReceiver));
        } else {
            huntAmount = uint88(BOND.mint(token, tokensToMint, maxHuntAmount, receiver));
        }
        assert(huntAmount <= maxHuntAmount); // is guaranteed by the bond contract

        MintHistory memory newHistory = MintHistory(
            receiver,
            huntAmount,
            uint40(block.timestamp),
            token,
            tokensToMint,
            tokensToDonated
        );
        mintHistory.push(newHistory);

        userNonce[receiver] += 1;

        emit Minted(receiver, huntAmount, token, uint40(block.timestamp), tokensToMint, tokensToDonated);
    }

    function getMessageHash(
        address user,
        address token,
        uint128 tokensToMint,
        uint88 maxHuntAmount,
        uint16 donationBp
    ) public view returns (bytes32) {
        uint256 nonce = userNonce[user];
        return keccak256(abi.encode(user, token, tokensToMint, maxHuntAmount, donationBp, nonce));
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

    function mint(
        address token,
        uint256 tokensToMint,
        uint256 maxReserveAmount,
        address receiver
    ) external returns (uint256);
}
