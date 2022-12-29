// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

interface ITownHall {
    function mint(address to) external;
}

interface IUniswapRouter is ISwapRouter {
    function refundETH() external payable;
}

contract TownHallZap {
    ITownHall public townHall;
    IERC20 public huntToken;
    IUniswapRouter public uniswapV3Router;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint256 public constant LOCK_UP_AMOUNT = 1e21; // 1,000 HUNT per NFT minting

    constructor(address townHall_, address huntToken_, address _uniswapV3Router) {
        townHall = ITownHall(townHall_);
        huntToken = IERC20(huntToken_);
        uniswapV3Router = IUniswapRouter(_uniswapV3Router);
    }

    // @dev save ~25% gas on bulk minting
    function mintBulk(address to, uint256 count) external {
        uint256 totalHuntAmount = LOCK_UP_AMOUNT * count;
        huntToken.transferFrom(msg.sender, address(this), totalHuntAmount);
        huntToken.approve(address(townHall), totalHuntAmount);

        for (uint256 i = 0; i < count; i++) {
            townHall.mint(to);
        }
    }

    // exactInputSingle for ERC20
    function convertAndMint(address sourceToken, address mintTo, uint256 amountInMaximum) external {
        TransferHelper.safeTransferFrom(sourceToken, msg.sender, address(this), amountInMaximum);
        TransferHelper.safeApprove(sourceToken, address(uniswapV3Router), amountInMaximum);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: sourceToken,
            tokenOut: address(huntToken),
            fee: 3000,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountOut: LOCK_UP_AMOUNT,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        uniswapV3Router.exactOutputSingle(params);
        townHall.mint(mintTo);
    }

    // exactInputSingle for ETH
    function convertAndMintETH(address mintTo, uint256 amountInMaximum) external payable {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: WETH,
            tokenOut: address(huntToken),
            fee: 3000,
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
