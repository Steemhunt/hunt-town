// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "solidity-bytes-utils/contracts/BytesLib.sol";

interface ITownHall {
    function mint(address to) external;
}

interface IWETH {
    function deposit() external payable;
    function withdraw(uint) external;
}

contract TownHallZap {
    using BytesLib for bytes;

    error TownHallZap__InvalidMintingCount();
    error TownHallZap__ZapIsNotRequiredForHUNT();
    error TownHallZap__InvalidETHSent();

    ITownHall public immutable townHall;
    IERC20 public immutable huntToken;
    ISwapRouter public immutable uniswapV3Router;
    IQuoter public immutable uniswapV3Quoter;

    address private constant WETH_CONTRACT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant UNISWAP_V3_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    uint24 private constant UNISWAP_FEE = 3000; // The fee of the token pool to consider for the pair

    uint256 public constant LOCK_UP_AMOUNT = 1e21; // 1,000 HUNT per NFT minting
    uint256 public constant MAX_MINTING_COUNT = 200;

    constructor(address townHall_, address huntToken_) {
        townHall = ITownHall(townHall_);
        huntToken = IERC20(huntToken_);
        uniswapV3Router = ISwapRouter(UNISWAP_V3_ROUTER);
        uniswapV3Quoter = IQuoter(UNISWAP_V3_QUOTER);
    }

    receive() external payable {}

    /**
     *  @notice Bulk minting interface for gas saving
     * (~25% reduced gas cost compared to multiple minting calls)
     */
    function mintBulk(address to, uint256 count) external {
        if (count < 1 || count > MAX_MINTING_COUNT) revert TownHallZap__InvalidMintingCount();

        uint256 totalHuntAmount = LOCK_UP_AMOUNT * count;
        huntToken.transferFrom(msg.sender, address(this), totalHuntAmount);
        huntToken.approve(address(townHall), totalHuntAmount);

        unchecked {
            for (uint256 i = 0; i < count; ++i) {
                townHall.mint(to);
            }
        }
    }

    function getOutputTokenFromPath(bytes calldata path) public pure returns (address lastAddres) {
        bytes memory lastSlice = path.slice(path.length - 20, 20);
        assembly {
          lastAddres := mload(add(lastSlice, 20))
        }
    }

    /**
     * @notice Estimate how many sourceToken required to mint Building NFTs
     * @dev In an ideal world, these quoter functions would be view functions,
     *   which would make them very easy to query on-chain with minimal gas costs.
     *   Instead, the V3 quoter contracts rely on state-changing calls designed to be reverted to return the desired data.
     *   To get around this difficulty, we can use the callStatic method provided by ethers.js.
     *   - Ref: https://docs.uniswap.org/sdk/v3/guides/creating-a-trade#using-callstatic-to-return-a-quote
     */
    function estimateAmountIn(address sourceToken, uint256 count) external returns (uint256 amountIn) {
        return uniswapV3Quoter.quoteExactOutputSingle({
            tokenIn: sourceToken,
            tokenOut: address(huntToken),
            fee: UNISWAP_FEE,
            amountOut: LOCK_UP_AMOUNT * count,
            sqrtPriceLimitX96: 0
        });
    }

    // @notice Convert sourceToken to HUNT and mint Building NFTs in one trasaction
    function convertAndMint(address sourceToken, address mintTo, uint256 count, uint256 amountInMaximum) external {
        if (sourceToken == address(huntToken)) revert TownHallZap__ZapIsNotRequiredForHUNT();
        if (count < 1 || count > MAX_MINTING_COUNT) revert TownHallZap__InvalidMintingCount();

        TransferHelper.safeTransferFrom(sourceToken, msg.sender, address(this), amountInMaximum);

        uint256 amountIn = _convertAndMint(sourceToken, mintTo, count, amountInMaximum);

        // For exact output swaps, the amountInMaximum may not have all been spent.
        // If the actual amount spent (amountIn) is less than the specified maximum amount,
        // we must refund the msg.sender and approve the uniswapV3Router to spend 0.
        if (amountIn < amountInMaximum) {
            TransferHelper.safeApprove(sourceToken, address(uniswapV3Router), 0);
            TransferHelper.safeTransfer(sourceToken, msg.sender, amountInMaximum - amountIn);
        }
    }

    function _convertAndMint(address sourceToken, address mintTo, uint256 count, uint256 amountInMaximum) private returns (uint256 amountIn) {
        uint256 lockUpAmount = LOCK_UP_AMOUNT * count;

        TransferHelper.safeApprove(sourceToken, address(uniswapV3Router), amountInMaximum);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: sourceToken,
            tokenOut: address(huntToken),
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: lockUpAmount,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        amountIn = uniswapV3Router.exactOutputSingle(params);

        huntToken.approve(address(townHall), lockUpAmount);

        if (count == 1) {
            townHall.mint(mintTo);
        } else {
            unchecked {
                for (uint256 i = 0; i < count; ++i) {
                    townHall.mint(mintTo);
                }
            }
        }
    }

    // @notice Convert ETH to HUNT and mint Building NFTs in one trasaction
    function convertETHAndMint(address mintTo, uint256 count, uint256 amountInMaximum) external payable {
        if (msg.value != amountInMaximum) revert TownHallZap__InvalidETHSent();
        if (count < 1 || count > MAX_MINTING_COUNT) revert TownHallZap__InvalidMintingCount();

        IWETH(WETH_CONTRACT).deposit{ value: msg.value }();

        uint256 amountIn = _convertAndMint(WETH_CONTRACT, mintTo, count, amountInMaximum);

        if (amountIn < amountInMaximum) {
            TransferHelper.safeApprove(WETH_CONTRACT, address(uniswapV3Router), 0);

            uint256 refundAMount = amountInMaximum - amountIn;
            IWETH(WETH_CONTRACT).withdraw(refundAMount);
            TransferHelper.safeTransferETH(msg.sender, refundAMount);
        }
    }
}
