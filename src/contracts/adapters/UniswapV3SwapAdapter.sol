// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {
    IUniswapV3SwapCallback
} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";

import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {IUniswapV3SwapAdapter} from "../interfaces/IUniswapV3SwapAdapter.sol";

/// @title Uniswap V3 swap adapter with on-chain TWAP price protection.
/// @notice Sells the vault's USDG for a reward asset in one Uniswap V3 pool per asset. The minimum
///         output is derived from the pool's own TWAP, so conversions need no off-chain quote:
///
///           expected = quoteAtTwapTick(amountIn * (1e6 - poolFee) / 1e6)
///           minOut   = expected * (BPS - maxSlippageBps) / BPS
///
///         `maxSlippageBps` is therefore the tolerated deviation from the TWAP net of the pool fee.
/// @dev Routes (pool, fee tier, tolerance) are set by the owner per asset; the pool comes from the
/// factory, never from calldata. Only the vault can swap, only the route's pool can call back.
/// The pool must keep enough observation cardinality for `twapWindow`, otherwise `observe` reverts
/// ("OLD") and the vault's conversion fails until `increaseObservationCardinalityNext` is called.
/// Not upgradeable on purpose: the vault replaces adapters through `Vault.setSwapAdapter`.
contract UniswapV3SwapAdapter is IUniswapV3SwapAdapter, IUniswapV3SwapCallback, Ownable2Step {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------------------------------

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_DENOMINATOR = 1e6;
    /// @notice Hard cap of `maxSlippageBps`, so no route can be set to swap without protection.
    uint16 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint32 public constant MIN_TWAP_WINDOW = 1 minutes;
    uint32 public constant MAX_TWAP_WINDOW = 1 hours;

    IUniswapV3Factory public immutable i_factory;
    address public immutable i_vault;
    address public immutable i_usdg;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    uint32 private s_twapWindow;
    mapping(address asset => Route) private s_routes;

    // ---------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------

    /// @param owner_      Admin of the routes (Ownable2Step, set directly).
    /// @param factory_    Uniswap V3 factory the pools are looked up in.
    /// @param vault_      The only caller of `swap`.
    /// @param usdg_       Token the vault sells, must be the vault's USDG.
    /// @param twapWindow_ TWAP window in seconds, within [MIN_TWAP_WINDOW, MAX_TWAP_WINDOW].
    constructor(
        address owner_,
        address factory_,
        address vault_,
        address usdg_,
        uint32 twapWindow_
    ) Ownable(owner_) {
        if (factory_ == address(0) || vault_ == address(0) || usdg_ == address(0)) {
            revert ZeroAddress();
        }
        i_factory = IUniswapV3Factory(factory_);
        i_vault = vault_;
        i_usdg = usdg_;
        _setTwapWindow(twapWindow_);
    }

    // ---------------------------------------------------------------------------------------------
    // Swap
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc ISwapAdapter
    /// @dev Only vault. Exact input against the route's pool with the extreme price limit; the
    /// output is checked against the TWAP-derived minimum after the swap.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut) {
        if (msg.sender != i_vault) revert NotVault();
        if (tokenIn != i_usdg) revert UnexpectedTokenIn(tokenIn);
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();
        Route memory route = s_routes[tokenOut];
        if (route.pool == address(0)) revert RouteNotSet(tokenOut);

        bool zeroForOne = tokenIn < tokenOut;
        uint256 twapOut = _expectedOut(route, amountIn, zeroForOne);
        uint256 minOut = Math.mulDiv(twapOut, BPS - route.maxSlippageBps, BPS);

        (int256 amount0, int256 amount1) = IUniswapV3Pool(route.pool).swap(
            recipient,
            zeroForOne,
            SafeCast.toInt256(amountIn),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1,
            abi.encode(tokenOut)
        );
        (int256 inDelta, int256 outDelta) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        // The pool ran out of liquidity before the price limit: the rest would be stranded here.
        if (inDelta != int256(amountIn)) {
            revert PartialFill(tokenOut, amountIn, inDelta > 0 ? uint256(inDelta) : 0);
        }
        amountOut = outDelta < 0 ? uint256(-outDelta) : 0;
        if (amountOut < minOut) revert InsufficientOutput(tokenOut, amountOut, minOut);

        emit Swapped(tokenOut, amountIn, amountOut, twapOut, minOut);
    }

    /// @inheritdoc IUniswapV3SwapCallback
    /// @dev Pays the input owed to the pool. A pool can only call this while this contract's own
    /// `swap` is in flight, and only the pool of the route encoded in `data` is accepted.
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        address asset = abi.decode(data, (address));
        address pool = s_routes[asset].pool;
        if (pool == address(0) || msg.sender != pool) revert NotPool(msg.sender);

        int256 owed = amount0Delta > 0 ? amount0Delta : amount1Delta;
        if (owed > 0) IERC20(i_usdg).safeTransfer(pool, uint256(owed));
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IUniswapV3SwapAdapter
    function setRoute(address asset, uint24 fee, uint16 maxSlippageBps) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (asset == i_usdg) revert InvalidAsset(asset);
        if (maxSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh(maxSlippageBps);
        address pool = i_factory.getPool(i_usdg, asset, fee);
        if (pool == address(0)) revert PoolNotFound(asset, fee);
        _twapTick(pool);

        s_routes[asset] = Route({pool: pool, fee: fee, maxSlippageBps: maxSlippageBps});
        emit RouteSet(asset, pool, fee, maxSlippageBps);
    }

    /// @inheritdoc IUniswapV3SwapAdapter
    function removeRoute(address asset) external onlyOwner {
        if (s_routes[asset].pool == address(0)) revert RouteNotSet(asset);
        delete s_routes[asset];
        emit RouteRemoved(asset);
    }

    /// @inheritdoc IUniswapV3SwapAdapter
    function setTwapWindow(uint32 window) external onlyOwner {
        _setTwapWindow(window);
    }

    /// @inheritdoc IUniswapV3SwapAdapter
    function sweep(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IUniswapV3SwapAdapter
    function routeOf(address asset) external view returns (Route memory) {
        return s_routes[asset];
    }

    /// @inheritdoc IUniswapV3SwapAdapter
    function twapWindow() external view returns (uint32) {
        return s_twapWindow;
    }

    /// @inheritdoc IUniswapV3SwapAdapter
    function quote(address asset, uint256 amountIn) external view returns (uint256) {
        Route memory route = s_routes[asset];
        if (route.pool == address(0)) revert RouteNotSet(asset);
        return _expectedOut(route, amountIn, i_usdg < asset);
    }

    /// @inheritdoc IUniswapV3SwapAdapter
    function minAmountOut(address asset, uint256 amountIn) external view returns (uint256) {
        Route memory route = s_routes[asset];
        if (route.pool == address(0)) revert RouteNotSet(asset);
        return Math.mulDiv(
            _expectedOut(route, amountIn, i_usdg < asset),
            BPS - route.maxSlippageBps,
            BPS
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _setTwapWindow(uint32 window) internal {
        if (window < MIN_TWAP_WINDOW || window > MAX_TWAP_WINDOW) {
            revert InvalidTwapWindow(window);
        }
        s_twapWindow = window;
        emit TwapWindowUpdated(window);
    }

    /// @dev TWAP quote of `amountIn` net of the pool fee, in the asset of `route`.
    function _expectedOut(
        Route memory route,
        uint256 amountIn,
        bool zeroForOne
    ) internal view returns (uint256) {
        uint256 amountInAfterFee = Math.mulDiv(amountIn, FEE_DENOMINATOR - route.fee, FEE_DENOMINATOR);
        return _quoteAtTick(_twapTick(route.pool), amountInAfterFee, zeroForOne);
    }

    /// @dev Arithmetic mean tick of `pool` over `s_twapWindow`, as in Uniswap's OracleLibrary.
    function _twapTick(address pool) internal view returns (int24 tick) {
        uint32 window = s_twapWindow;
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = window;
        secondsAgos[1] = 0;
        (int56[] memory tickCumulatives, ) = IUniswapV3Pool(pool).observe(secondsAgos);

        int56 delta = tickCumulatives[1] - tickCumulatives[0];
        int56 windowInt = int56(uint56(window));
        tick = int24(delta / windowInt);
        // Round toward negative infinity.
        if (delta < 0 && (delta % windowInt != 0)) tick--;
    }

    /// @dev Output of `amountIn` of one pool token in the other at `tick`, as in
    /// OracleLibrary.getQuoteAtTick. `zeroForOne`: input is token0.
    function _quoteAtTick(
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) internal pure returns (uint256) {
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            return
                zeroForOne
                    ? Math.mulDiv(amountIn, ratioX192, 1 << 192)
                    : Math.mulDiv(amountIn, 1 << 192, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return
            zeroForOne
                ? Math.mulDiv(amountIn, ratioX128, 1 << 128)
                : Math.mulDiv(amountIn, 1 << 128, ratioX128);
    }
}
