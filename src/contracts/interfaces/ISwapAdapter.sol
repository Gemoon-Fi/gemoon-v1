// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title Swap adapter used by the Vault to convert USDG into reward assets.
/// @notice Price protection is the adapter's job: the Vault passes no minimum output, so the
///         adapter must derive one on-chain (e.g. from a TWAP) and revert below it.
interface ISwapAdapter {
    /// @notice Swaps `amountIn` of `tokenIn`, already transferred to the adapter, into `tokenOut`.
    /// @dev Must send the output to `recipient` and revert if the price is worse than the
    /// adapter's own bound. The Vault measures the output by its balance difference, not by the
    /// return value.
    /// @param tokenIn   Token sold.
    /// @param tokenOut  Token bought.
    /// @param amountIn  Amount of `tokenIn` held by the adapter for this swap.
    /// @param recipient Receiver of `tokenOut`.
    /// @return amountOut Output sent to `recipient`.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);
}
