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
    function convertAndMint(address sourceToken, uint256 amountIn, uint24 _fee, address mintTo) external {
        require(sourceToken != address(0), "sourceToken not address(0)");
        require(mintTo.code.length == 0, "mintTo is not user");
        require(IERC20(sourceToken).balanceOf(msg.sender) >= amountIn, "not enough sourceToken balance");

        TransferHelper.safeTransferFrom(sourceToken, msg.sender, address(this), amountIn);
        TransferHelper.safeApprove(sourceToken, address(uniswapV3Router), amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: sourceToken,
            tokenOut: address(huntToken),
            fee: _fee,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapV3Router.exactInputSingle(params);
        require(amountOut > LOCK_UP_AMOUNT, "not enough huntToken for 1townhall nft");

        //refund remain sourceToken
        TransferHelper.safeTransferFrom(sourceToken, address(this), msg.sender, amountIn - amountOut);

        townHall.mint(mintTo);
    }

    // exactInputSingle for ETH
    function convertAndMintETH(address mintTo, uint24 _fee) external payable {
        require(msg.value > 0, "Must pass non 0 ETH amount");
        require(mintTo.code.length == 0, "mintTo is not user");
        require(address(this).balance >= msg.value, "not enough eth balance");

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: address(huntToken),
            fee: _fee,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: msg.value,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = uniswapV3Router.exactInputSingle{value: msg.value}(params);
        require(amountOut > LOCK_UP_AMOUNT, "not enough huntToken for 1townhall nft");

        //refund remain eth
        uniswapV3Router.refundETH();
        (bool success, ) = msg.sender.call{value: address(this).balance}("");
        require(success, "refund failed");

        townHall.mint(mintTo);
    }
}
