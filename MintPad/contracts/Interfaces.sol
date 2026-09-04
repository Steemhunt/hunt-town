// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// ============ Uniswap V4 Interfaces ============

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IHooks {}

/// @notice One hop of a Uniswap V4 swap path. `intermediateCurrency` is the currency on the far side of the hop.
struct PathKey {
    address intermediateCurrency;
    uint24 fee;
    int24 tickSpacing;
    IHooks hooks;
    bytes hookData;
}

struct ExactInputParams {
    address currencyIn;
    PathKey[] path;
    uint128 amountIn;
    uint128 amountOutMinimum;
}

struct ExactOutputParams {
    address currencyOut;
    PathKey[] path;
    uint128 amountOut;
    uint128 amountInMaximum;
}

struct QuoteExactParams {
    address exactCurrency;
    PathKey[] path;
    uint128 exactAmount;
}

interface IV4Quoter {
    /// @notice Returns the output amount for a given exact input swap along the path
    /// @dev These functions are not view because they revert with the result - call via staticcall
    function quoteExactInput(QuoteExactParams memory params) external returns (uint256 amountOut, uint256 gasEstimate);

    /// @notice Returns the input amount for a given exact output swap along the path
    function quoteExactOutput(QuoteExactParams memory params) external returns (uint256 amountIn, uint256 gasEstimate);
}

// ============ Mint Club V2 Interfaces ============

interface IMCV2_Bond {
    function mint(
        address token,
        uint256 tokensToMint,
        uint256 maxReserveAmount,
        address receiver
    ) external returns (uint256);

    function getReserveForToken(
        address token,
        uint256 tokensToMint
    ) external view returns (uint256 reserveAmount, uint256 royalty);
}

interface IMCV2_BondPeriphery {
    function mintWithReserveAmount(
        address token,
        uint256 reserveAmount,
        uint256 minTokensToMint,
        address receiver
    ) external returns (uint256 tokensMinted);

    function getTokensForReserve(
        address tokenAddress,
        uint256 reserveAmount,
        bool useCeilDivision
    ) external view returns (uint256 tokensToMint, address reserveAddress);
}

// ============ Constants ============

library Commands {
    uint256 constant SWEEP = 0x04;
    uint256 constant V4_SWAP = 0x10;
}

library Actions {
    uint256 constant SWAP_EXACT_IN = 0x07;
    uint256 constant SWAP_EXACT_OUT = 0x09;
    uint256 constant SETTLE = 0x0b;
    uint256 constant SETTLE_ALL = 0x0c;
    uint256 constant TAKE = 0x0e;
    uint256 constant TAKE_ALL = 0x0f;
}

library ActionConstants {
    uint256 constant OPEN_DELTA = 0;
}
