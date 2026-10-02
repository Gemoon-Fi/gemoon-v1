// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {
    IUniswapV3SwapCallback
} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";

import {
    UniswapV3SwapAdapter
} from "../src/contracts/adapters/UniswapV3SwapAdapter.sol";
import {IUniswapV3SwapAdapter} from "../src/contracts/interfaces/IUniswapV3SwapAdapter.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {AssetConfig} from "../src/contracts/interfaces/IVault.sol";
import {MockToken} from "./VaultTest.sol";

/// @dev Pool with a settable TWAP tick (served by `observe`) and spot tick (used by `swap`).
/// No fee and no price impact: a swap pays exactly the spot quote of the whole input.
contract MockV3Pool {
    address public immutable token0;
    address public immutable token1;
    int24 public twapTick;
    int24 public spotTick;
    bool public observeReverts;
    /// @dev Share of the input the pool consumes, simulates running out of liquidity.
    uint256 public fillBps = 10_000;

    constructor(address a, address b) {
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function setTicks(int24 twap, int24 spot) external {
        twapTick = twap;
        spotTick = spot;
    }

    function setObserveReverts(bool reverts) external {
        observeReverts = reverts;
    }

    function setFillBps(uint256 bps) external {
        fillBps = bps;
    }

    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory liquidityCumulatives
        )
    {
        require(!observeReverts, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        liquidityCumulatives = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            // Constant tick over the whole history, cumulative relative to now.
            tickCumulatives[i] =
                -int56(twapTick) *
                int56(uint56(secondsAgos[i]));
        }
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = (uint256(amountSpecified) * fillBps) / 10_000;
        uint256 amountOut = quoteAtTick(spotTick, amountIn, zeroForOne);
        (address tokenIn, address tokenOut) = zeroForOne
            ? (token0, token1)
            : (token1, token0);
        (amount0, amount1) = zeroForOne
            ? (int256(amountIn), -int256(amountOut))
            : (-int256(amountOut), int256(amountIn));

        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(
            amount0,
            amount1,
            data
        );
        require(
            IERC20(tokenIn).balanceOf(address(this)) - before >= amountIn,
            "IIA"
        );
        MockToken(tokenOut).mint(recipient, amountOut);
    }

    function quoteAtTick(
        int24 tick,
        uint256 amountIn,
        bool zeroForOne
    ) public pure returns (uint256) {
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

contract MockV3Factory {
    mapping(bytes32 => address) private pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[_key(a, b, fee)] = pool;
    }

    function getPool(
        address a,
        address b,
        uint24 fee
    ) external view returns (address) {
        return pools[_key(a, b, fee)];
    }

    function _key(
        address a,
        address b,
        uint24 fee
    ) internal pure returns (bytes32) {
        (a, b) = a < b ? (a, b) : (b, a);
        return keccak256(abi.encode(a, b, fee));
    }
}

contract UniswapV3SwapAdapterTest is Test {
    uint24 constant FEE = 3000; // 0.3%
    uint16 constant SLIPPAGE_BPS = 100; // 1%
    uint32 constant WINDOW = 600;
    uint256 constant AMOUNT = 1_000e6;

    MockToken usdg;
    MockToken assetHigh; // sorts above USDG: USDG is token0, swap is zeroForOne
    MockToken assetLow; // sorts below USDG: USDG is token1, swap is oneForZero
    MockV3Factory factory;
    MockV3Pool poolHigh;
    MockV3Pool poolLow;
    UniswapV3SwapAdapter adapter;

    address owner = makeAddr("owner");
    address vault = makeAddr("vault");
    address alice = makeAddr("alice");

    function setUp() external {
        usdg = new MockToken("USDG", 6);
        // Both swap directions must be covered, so find an asset on each side of USDG.
        while (
            address(assetLow) == address(0) || address(assetHigh) == address(0)
        ) {
            MockToken t = new MockToken("ASSET", 18);
            if (address(t) < address(usdg)) {
                if (address(assetLow) == address(0)) assetLow = t;
            } else if (address(assetHigh) == address(0)) {
                assetHigh = t;
            }
        }
        factory = new MockV3Factory();
        poolHigh = new MockV3Pool(address(usdg), address(assetHigh));
        poolLow = new MockV3Pool(address(usdg), address(assetLow));
        factory.setPool(
            address(usdg),
            address(assetHigh),
            FEE,
            address(poolHigh)
        );
        factory.setPool(
            address(usdg),
            address(assetLow),
            FEE,
            address(poolLow)
        );

        adapter = new UniswapV3SwapAdapter(
            owner,
            address(factory),
            vault,
            address(usdg),
            WINDOW
        );
        vm.startPrank(owner);
        adapter.setRoute(address(assetHigh), FEE, SLIPPAGE_BPS);
        adapter.setRoute(address(assetLow), FEE, SLIPPAGE_BPS);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _swap(
        MockToken asset,
        uint256 amountIn
    ) internal returns (uint256) {
        usdg.mint(address(adapter), amountIn);
        vm.prank(vault);
        return adapter.swap(address(usdg), address(asset), amountIn, alice);
    }

    /// @dev Tick shift that makes the spot price worse for the USDG seller by `ticks`.
    function _worse(MockV3Pool pool, int24 ticks) internal {
        // USDG as token0: output = in * price, lower tick is worse. As token1: the opposite.
        pool.setTicks(0, pool.token0() == address(usdg) ? -ticks : ticks);
    }

    // ------------------------------------------------------------------ construction / admin

    function test_Constructor_ZeroAddress_Reverts() external {
        vm.expectRevert(IUniswapV3SwapAdapter.ZeroAddress.selector);
        new UniswapV3SwapAdapter(
            owner,
            address(0),
            vault,
            address(usdg),
            WINDOW
        );
        vm.expectRevert(IUniswapV3SwapAdapter.ZeroAddress.selector);
        new UniswapV3SwapAdapter(
            owner,
            address(factory),
            address(0),
            address(usdg),
            WINDOW
        );
        vm.expectRevert(IUniswapV3SwapAdapter.ZeroAddress.selector);
        new UniswapV3SwapAdapter(
            owner,
            address(factory),
            vault,
            address(0),
            WINDOW
        );
    }

    function test_Constructor_WindowOutOfBounds_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.InvalidTwapWindow.selector,
                59
            )
        );
        new UniswapV3SwapAdapter(
            owner,
            address(factory),
            vault,
            address(usdg),
            59
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.InvalidTwapWindow.selector,
                3601
            )
        );
        new UniswapV3SwapAdapter(
            owner,
            address(factory),
            vault,
            address(usdg),
            3601
        );
    }

    function test_Constructor_SetsOwnerDirectly() external view {
        assertEq(adapter.owner(), owner);
        assertEq(adapter.pendingOwner(), address(0));
        assertEq(adapter.i_vault(), vault);
        assertEq(adapter.i_usdg(), address(usdg));
        assertEq(adapter.twapWindow(), WINDOW);
    }

    function test_SetRoute_NotOwner_Reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        adapter.setRoute(address(assetHigh), FEE, SLIPPAGE_BPS);
    }

    function test_SetRoute_PoolNotFound_Reverts() external {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.PoolNotFound.selector,
                address(assetHigh),
                500
            )
        );
        adapter.setRoute(address(assetHigh), 500, SLIPPAGE_BPS);
    }

    function test_SetRoute_SlippageAboveCap_Reverts() external {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.SlippageTooHigh.selector,
                501
            )
        );
        adapter.setRoute(address(assetHigh), FEE, 501);
    }

    function test_SetRoute_Usdg_Reverts() external {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.InvalidAsset.selector,
                address(usdg)
            )
        );
        adapter.setRoute(address(usdg), FEE, SLIPPAGE_BPS);
    }

    function test_SetRoute_PoolCannotServeWindow_Reverts() external {
        poolHigh.setObserveReverts(true);
        vm.prank(owner);
        vm.expectRevert(bytes("OLD"));
        adapter.setRoute(address(assetHigh), FEE, SLIPPAGE_BPS);
    }

    function test_SetRoute_StoresAndEmits() external {
        vm.expectEmit(true, true, true, true);
        emit IUniswapV3SwapAdapter.RouteSet(
            address(assetHigh),
            address(poolHigh),
            FEE,
            250
        );
        vm.prank(owner);
        adapter.setRoute(address(assetHigh), FEE, 250);

        IUniswapV3SwapAdapter.Route memory route = adapter.routeOf(
            address(assetHigh)
        );
        assertEq(route.pool, address(poolHigh));
        assertEq(route.fee, FEE);
        assertEq(route.maxSlippageBps, 250);
    }

    function test_RemoveRoute_SwapRevertsAfterwards() external {
        vm.prank(owner);
        adapter.removeRoute(address(assetHigh));
        assertEq(adapter.routeOf(address(assetHigh)).pool, address(0));

        usdg.mint(address(adapter), AMOUNT);
        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.RouteNotSet.selector,
                address(assetHigh)
            )
        );
        adapter.swap(address(usdg), address(assetHigh), AMOUNT, alice);
    }

    function test_SetTwapWindow_OutOfBounds_Reverts() external {
        vm.startPrank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.InvalidTwapWindow.selector,
                0
            )
        );
        adapter.setTwapWindow(0);
        adapter.setTwapWindow(3600);
        assertEq(adapter.twapWindow(), 3600);
        vm.stopPrank();
    }

    function test_Sweep_SendsWholeBalance() external {
        usdg.mint(address(adapter), 7e6);
        vm.prank(owner);
        adapter.sweep(address(usdg), alice);
        assertEq(usdg.balanceOf(alice), 7e6);
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    // ------------------------------------------------------------------ swap guards

    function test_Swap_NotVault_Reverts() external {
        usdg.mint(address(adapter), AMOUNT);
        vm.prank(alice);
        vm.expectRevert(IUniswapV3SwapAdapter.NotVault.selector);
        adapter.swap(address(usdg), address(assetHigh), AMOUNT, alice);
    }

    function test_Swap_WrongTokenIn_Reverts() external {
        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.UnexpectedTokenIn.selector,
                address(assetLow)
            )
        );
        adapter.swap(address(assetLow), address(assetHigh), AMOUNT, alice);
    }

    function test_Swap_ZeroAmount_Reverts() external {
        vm.prank(vault);
        vm.expectRevert(IUniswapV3SwapAdapter.ZeroAmount.selector);
        adapter.swap(address(usdg), address(assetHigh), 0, alice);
    }

    function test_Swap_ObserveReverts_Bubbles() external {
        poolHigh.setObserveReverts(true);
        usdg.mint(address(adapter), AMOUNT);
        vm.prank(vault);
        vm.expectRevert(bytes("OLD"));
        adapter.swap(address(usdg), address(assetHigh), AMOUNT, alice);
    }

    function test_Callback_NotRoutePool_Reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IUniswapV3SwapAdapter.NotPool.selector, alice)
        );
        adapter.uniswapV3SwapCallback(1, 0, abi.encode(address(assetHigh)));

        // A route pool of another asset is not accepted either.
        vm.prank(address(poolLow));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.NotPool.selector,
                address(poolLow)
            )
        );
        adapter.uniswapV3SwapCallback(1, 0, abi.encode(address(assetHigh)));
    }

    // ------------------------------------------------------------------ swap pricing

    function test_Swap_SpotEqualsTwap_PaysSpotQuote_BothDirections() external {
        uint256 outHigh = _swap(assetHigh, AMOUNT);
        assertEq(outHigh, poolHigh.quoteAtTick(0, AMOUNT, true));
        assertEq(assetHigh.balanceOf(alice), outHigh);
        assertGe(outHigh, adapter.minAmountOut(address(assetHigh), AMOUNT));

        uint256 outLow = _swap(assetLow, AMOUNT);
        assertEq(outLow, poolLow.quoteAtTick(0, AMOUNT, false));
        assertEq(assetLow.balanceOf(alice), outLow);
        assertGe(outLow, adapter.minAmountOut(address(assetLow), AMOUNT));

        assertEq(
            usdg.balanceOf(address(adapter)),
            0,
            "input fully paid to the pools"
        );
        assertEq(usdg.balanceOf(address(poolHigh)), AMOUNT);
        assertEq(usdg.balanceOf(address(poolLow)), AMOUNT);
    }

    function test_Quote_NetOfPoolFee() external view {
        // tick 0: 1 unit in = 1 unit out before the 0.3% fee.
        assertEq(
            adapter.quote(address(assetHigh), AMOUNT),
            (AMOUNT * (1e6 - FEE)) / 1e6
        );
        // 1% tolerance on top of that.
        assertEq(
            adapter.minAmountOut(address(assetHigh), AMOUNT),
            (((AMOUNT * (1e6 - FEE)) / 1e6) * (10_000 - SLIPPAGE_BPS)) / 10_000
        );
    }

    function test_Swap_SpotWithinTolerance_Succeeds() external {
        _worse(poolHigh, 50); // ~0.5% worse than TWAP, inside fee + 1%
        _worse(poolLow, 50);
        assertGe(
            _swap(assetHigh, AMOUNT),
            adapter.minAmountOut(address(assetHigh), AMOUNT)
        );
        assertGe(
            _swap(assetLow, AMOUNT),
            adapter.minAmountOut(address(assetLow), AMOUNT)
        );
    }

    function test_Swap_SpotBeyondTolerance_Reverts() external {
        _worse(poolHigh, 200); // ~2% worse than TWAP, beyond fee + 1%
        _worse(poolLow, 200);
        usdg.mint(address(adapter), 2 * AMOUNT);

        vm.startPrank(vault);
        vm.expectPartialRevert(
            IUniswapV3SwapAdapter.InsufficientOutput.selector
        );
        adapter.swap(address(usdg), address(assetHigh), AMOUNT, alice);
        vm.expectPartialRevert(
            IUniswapV3SwapAdapter.InsufficientOutput.selector
        );
        adapter.swap(address(usdg), address(assetLow), AMOUNT, alice);
        vm.stopPrank();
    }

    function test_Swap_PartialFill_Reverts() external {
        // 99.9% filled at the TWAP price would clear the output bound but strand 0.1% of the
        // input in the adapter.
        poolHigh.setFillBps(9_990);
        usdg.mint(address(adapter), AMOUNT);
        vm.prank(vault);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniswapV3SwapAdapter.PartialFill.selector,
                address(assetHigh),
                AMOUNT,
                (AMOUNT * 9_990) / 10_000
            )
        );
        adapter.swap(address(usdg), address(assetHigh), AMOUNT, alice);
    }

    function test_Swap_SpotBetterThanTwap_Succeeds() external {
        _worse(poolHigh, -500); // 5% better
        uint256 out = _swap(assetHigh, AMOUNT);
        assertGt(out, AMOUNT);
    }

    /// @dev At any price level, a spot equal to the TWAP always clears the bound and the whole
    /// input is paid to the pool.
    function testFuzz_Swap_SpotEqualsTwap_ClearsBound(
        int24 tick,
        uint96 amountIn
    ) external {
        tick = int24(bound(tick, -300_000, 300_000));
        amountIn = uint96(bound(amountIn, 1, type(uint96).max));
        poolHigh.setTicks(tick, tick);
        poolLow.setTicks(tick, tick);

        uint256 outHigh = _swap(assetHigh, amountIn);
        assertGe(outHigh, adapter.minAmountOut(address(assetHigh), amountIn));
        uint256 outLow = _swap(assetLow, amountIn);
        assertGe(outLow, adapter.minAmountOut(address(assetLow), amountIn));
        assertEq(usdg.balanceOf(address(adapter)), 0);
    }

    /// @dev The swap succeeds exactly when the spot output meets the TWAP-derived bound.
    function testFuzz_Swap_AcceptsIffSpotMeetsBound(
        int24 shift,
        uint96 amountIn
    ) external {
        shift = int24(bound(shift, -2_000, 2_000));
        amountIn = uint96(bound(amountIn, 1e6, type(uint96).max));
        poolHigh.setTicks(0, shift);

        uint256 spotOut = poolHigh.quoteAtTick(shift, amountIn, true);
        uint256 minOut = adapter.minAmountOut(address(assetHigh), amountIn);

        usdg.mint(address(adapter), amountIn);
        vm.prank(vault);
        if (spotOut >= minOut) {
            assertEq(
                adapter.swap(
                    address(usdg),
                    address(assetHigh),
                    amountIn,
                    alice
                ),
                spotOut
            );
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IUniswapV3SwapAdapter.InsufficientOutput.selector,
                    address(assetHigh),
                    spotOut,
                    minOut
                )
            );
            adapter.swap(address(usdg), address(assetHigh), amountIn, alice);
        }
    }

    // ------------------------------------------------------------------ vault integration

    function test_Vault_ConvertFees_ThroughAdapter_BooksAssets() external {
        address controller = makeAddr("controller");
        address hook = makeAddr("hook");
        address creator = makeAddr("creator");
        MockToken meme = new MockToken("MEME", 18);

        Vault realVault = Vault(
            address(
                new TransparentUpgradeableProxy(
                    address(new Vault()),
                    owner,
                    abi.encodeCall(Vault.initialize, (owner, address(usdg)))
                )
            )
        );
        UniswapV3SwapAdapter realAdapter = new UniswapV3SwapAdapter(
            owner,
            address(factory),
            address(realVault),
            address(usdg),
            WINDOW
        );
        vm.startPrank(owner);
        realAdapter.setRoute(address(assetHigh), FEE, SLIPPAGE_BPS);
        realAdapter.setRoute(address(assetLow), FEE, SLIPPAGE_BPS);
        realVault.setController(controller);
        realVault.setHook(hook);
        realVault.setSwapAdapter(address(realAdapter));
        realVault.setAssetAllowed(address(assetHigh), true);
        realVault.setAssetAllowed(address(assetLow), true);
        realVault.setConversionThreshold(100e6);
        vm.stopPrank();

        AssetConfig[] memory assets = new AssetConfig[](2);
        assets[0] = AssetConfig({token: address(assetHigh), weightBps: 6_000});
        assets[1] = AssetConfig({token: address(assetLow), weightBps: 4_000});
        vm.prank(controller);
        realVault.registerVault(address(meme), creator, assets);

        // Threshold reached inside notifyFees: the epoch converts through the adapter.
        usdg.mint(address(realVault), 100e6);
        vm.prank(hook);
        realVault.notifyFees(address(meme), 100e6);

        assertEq(realVault.vaultInfo(address(meme)).epoch, 1);
        assertEq(usdg.balanceOf(address(realVault)), 0);
        assertEq(
            assetHigh.balanceOf(address(realVault)),
            60e6,
            "tick 0: 1:1 units"
        );
        assertEq(assetLow.balanceOf(address(realVault)), 40e6);
        (, uint256[] memory creatorAmounts) = realVault.creatorAccrued(
            address(meme)
        );
        assertEq(creatorAmounts[0], 60e6, "nobody stakes: all to the creator");
        assertEq(creatorAmounts[1], 40e6);

        // A stale oracle makes the next automatic conversion fail without breaking the credit.
        poolHigh.setObserveReverts(true);
        usdg.mint(address(realVault), 100e6);
        vm.prank(hook);
        realVault.notifyFees(address(meme), 100e6);
        assertEq(realVault.vaultInfo(address(meme)).epoch, 1);
        assertEq(realVault.pendingUSDG(address(meme)), 100e6);
        assertEq(
            realVault.vaultInfo(address(meme)).lastConversionFailure,
            block.timestamp
        );
    }
}
