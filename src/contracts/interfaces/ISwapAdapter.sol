// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Swap adapter used by the Vault to convert USDG into reward assets.
interface ISwapAdapter {
    /// @notice Swaps `amountIn` of `tokenIn`, already transferred to the adapter, into `tokenOut`.
    /// @dev Must send the output to `recipient` and revert if it is below `minAmountOut`.
    /// The Vault measures the output by its own balance difference, not by the return value.
    /// @param tokenIn      Token sold.
    /// @param tokenOut     Token bought.
    /// @param amountIn     Amount of `tokenIn` held by the adapter for this swap.
    /// @param minAmountOut Minimum acceptable output.
    /// @param recipient    Receiver of `tokenOut`.
    /// @return amountOut   Output sent to `recipient`.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        address recipient
    ) external returns (uint256 amountOut);
}
