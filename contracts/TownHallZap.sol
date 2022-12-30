// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

interface ITownHall {
    function mint(address to) external;
}

contract TownHallZap {
    ITownHall public immutable townHall;
    IERC20 public immutable huntToken;
    ISwapRouter public immutable uniswapV3Router;
    IQuoter public immutable uniswapV3Quoter;

    address private constant WETH_CONTRACT = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address private constant UNISWAP_V3_QUOTER = 0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6;
    uint24 private constant UNISWAP_FEE = 3000; // The fee of the token pool to consider for the pair

    uint256 public constant LOCK_UP_AMOUNT = 1e21; // 1,000 HUNT per NFT minting

    constructor(address townHall_, address huntToken_) {
        townHall = ITownHall(townHall_);
        huntToken = IERC20(huntToken_);
        uniswapV3Router = ISwapRouter(UNISWAP_V3_ROUTER);
        uniswapV3Quoter = IQuoter(UNISWAP_V3_QUOTER);
    }

    /**
     *  @notice Bulk minting interface for gas saving
     * (~25% reduced gas cost compared to multiple minting calls)
     */
    function mintBulk(address to, uint256 count) external {
        uint256 totalHuntAmount = LOCK_UP_AMOUNT * count;
        huntToken.transferFrom(msg.sender, address(this), totalHuntAmount);
        huntToken.approve(address(townHall), totalHuntAmount);

        for (uint256 i = 0; i < count; i++) {
            townHall.mint(to);
        }
    }

    /**
     * @notice Estimate how many sourceToken required to mint a Building NFT
     * @dev In an ideal world, these quoter functions would be view functions,
     *   which would make them very easy to query on-chain with minimal gas costs.
     *   Instead, the V3 quoter contracts rely on state-changing calls designed to be reverted to return the desired data.
     *   To get around this difficulty, we can use the callStatic method provided by ethers.js.
     *   - Ref: https://docs.uniswap.org/sdk/v3/guides/creating-a-trade#using-callstatic-to-return-a-quote
     */
    function estimateAmountIn(address sourceToken) external returns (uint256 amountIn) {
        return uniswapV3Quoter.quoteExactOutputSingle({
            tokenIn: sourceToken,
            tokenOut: address(huntToken),
            fee: UNISWAP_FEE,
            amountOut: LOCK_UP_AMOUNT,
            sqrtPriceLimitX96: 0
        });
    }

    // @notice Convert sourceToken to HUNT and mint Building NFT in one trasaction
    function convertAndMint(address sourceToken, address mintTo, uint256 amountInMaximum) external {
        TransferHelper.safeTransferFrom(sourceToken, msg.sender, address(this), amountInMaximum);
        TransferHelper.safeApprove(sourceToken, address(uniswapV3Router), amountInMaximum);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: sourceToken,
            tokenOut: address(huntToken),
            fee: UNISWAP_FEE,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: LOCK_UP_AMOUNT,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        uniswapV3Router.exactOutputSingle(params);

        huntToken.approve(address(townHall), LOCK_UP_AMOUNT);
        townHall.mint(mintTo);
    }

    // @notice Convert ETH to HUNT and mint Building NFT in one trasaction
    function convertAndMintETH(address mintTo, uint256 amountInMaximum) external payable {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: WETH_CONTRACT,
            tokenOut: address(huntToken),
            fee: UNISWAP_FEE,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: LOCK_UP_AMOUNT,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        uniswapV3Router.exactOutputSingle{value: msg.value}(params);
        townHall.mint(mintTo);
    }
}
