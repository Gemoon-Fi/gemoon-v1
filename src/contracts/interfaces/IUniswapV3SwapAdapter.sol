// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISwapAdapter} from "./ISwapAdapter.sol";

/// @title Uniswap V3 swap adapter of the Gemoon vault.
/// @notice Sells the vault's USDG for a reward asset in one Uniswap V3 pool per asset, with the
///         minimum output derived on-chain from the pool's TWAP. See the implementation for the
///         pricing formula.
interface IUniswapV3SwapAdapter is ISwapAdapter {
    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    /// @notice Swap route of one reward asset.
    /// @param pool           USDG/asset pool of the factory.
    /// @param fee            Fee tier of `pool`, in hundredths of a bip.
    /// @param maxSlippageBps Tolerated deviation from the TWAP quote, in bps.
    struct Route {
        address pool;
        uint24 fee;
        uint16 maxSlippageBps;
    }

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotVault();
    error NotPool(address caller);
    error UnexpectedTokenIn(address tokenIn);
    error InvalidAsset(address asset);
    error RouteNotSet(address asset);
    error PoolNotFound(address asset, uint24 fee);
    error SlippageTooHigh(uint16 maxSlippageBps);
    error InvalidTwapWindow(uint32 window);
    error InsufficientOutput(address asset, uint256 amountOut, uint256 minAmountOut);
    error PartialFill(address asset, uint256 amountIn, uint256 amountSpent);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice Route of `asset` set or replaced.
    event RouteSet(address indexed asset, address indexed pool, uint24 fee, uint16 maxSlippageBps);
    /// @notice Route of `asset` removed, swaps into it revert afterwards.
    event RouteRemoved(address indexed asset);
    /// @notice TWAP window changed, in seconds.
    event TwapWindowUpdated(uint32 window);
    /// @notice One conversion swap. `amountIn / amountOut` is the executed price,
    ///         `amountIn / twapOut` the TWAP price net of the pool fee, both in USDG per asset.
    /// @param asset        Reward asset bought.
    /// @param amountIn     USDG sold.
    /// @param amountOut    Asset received by the vault.
    /// @param twapOut      Asset the TWAP quote expected for `amountIn`, net of the pool fee.
    /// @param minAmountOut Output below which the swap would have reverted.
    event Swapped(
        address indexed asset,
        uint256 amountIn,
        uint256 amountOut,
        uint256 twapOut,
        uint256 minAmountOut
    );
    /// @notice Leftover `token` sent to `to` by the owner.
    event Swept(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Admin (owner)
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets or replaces the route of `asset`.
    /// @dev Reverts with the pool's own error (e.g. "OLD") if the pool cannot serve the current
    /// TWAP window yet, so a route never points at a pool with too little observation history.
    /// @param asset          Reward asset bought through this route.
    /// @param fee            Fee tier of the USDG/asset pool to use.
    /// @param maxSlippageBps Tolerated deviation from the TWAP quote, at most MAX_SLIPPAGE_BPS.
    function setRoute(address asset, uint24 fee, uint16 maxSlippageBps) external;

    /// @notice Removes the route of `asset`; swaps into it revert afterwards.
    function removeRoute(address asset) external;

    /// @notice Sets the TWAP window used for every quote, within [MIN_TWAP_WINDOW, MAX_TWAP_WINDOW].
    function setTwapWindow(uint32 window) external;

    /// @notice Sends the whole balance of `token` to `to`. The adapter holds no funds between
    ///         swaps, so anything here is dust of a partially filled swap or a mistaken transfer.
    function sweep(address token, address to) external;

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Route of `asset`, pool zero if none.
    function routeOf(address asset) external view returns (Route memory);

    /// @notice Current TWAP window in seconds.
    function twapWindow() external view returns (uint32);

    /// @notice Expected output of selling `amountIn` USDG for `asset` at the route's TWAP, net of
    ///         the pool fee. The swap's minimum output is this minus `maxSlippageBps`.
    function quote(address asset, uint256 amountIn) external view returns (uint256);

    /// @notice Minimum output `swap` would accept for `amountIn` of USDG into `asset` right now.
    function minAmountOut(address asset, uint256 amountIn) external view returns (uint256);
}
