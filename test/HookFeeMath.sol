// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {IHookManager} from "../src/contracts/interfaces/IHookManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @notice Fee curve of the hook: 80% at pool creation, linear down to the fee the creator chose
/// over `DYNAMIC_FEE_THRESHOLD`, that fee afterwards. Creator fee bounds. Fallback fee bounds.
/// @dev The hook can't be deployed with a plain `new`: BaseHook checks that the address carries
/// the permission bits. `deployHook` mines a CREATE2 salt and passes the config to the constructor.
/// Nothing here calls the PoolManager, so its address is a dummy.
contract HookFeeMathTest is Test {
    uint256 constant FALLBACK_FEE = 125;
    uint256 constant MEME_FEE = 500; // 5%, chosen by the creator
    uint256 constant MAX_FEE = 8_000;
    uint256 constant CREATED_AT = 1_700_000_000;

    HookManager hook;
    uint256 window;

    address controller = makeAddr("controller");
    address meme = makeAddr("meme");

    function setUp() external {
        DeployGemoon script = new DeployGemoon();
        hook = script.deployHook(
            address(script),
            GemoonDeployBase.HookDeployParams({
                poolManager: makeAddr("poolManager"),
                pairToken: makeAddr("usdg"),
                vault: makeAddr("vault"),
                controller: controller,
                feeBips: FALLBACK_FEE
            })
        );
        window = hook.DYNAMIC_FEE_THRESHOLD();

        // The hook records the window start itself when the pool is initialized; the
        // controller sets the fee in the same block.
        vm.warp(CREATED_AT);
        _initPool(meme);
        vm.prank(controller);
        hook.notifyPoolCreated(meme, MEME_FEE);
    }

    /// @dev What the PoolManager does on `initialize`.
    function _initPool(address meme_) internal {
        PoolKey memory key = PoolKey(
            Currency.wrap(meme_), hook.pairToken(), 0, 60, IHooks(address(hook))
        );
        vm.prank(address(hook.poolManager()));
        hook.afterInitialize(controller, key, 0, 0);
    }

    function _expected(uint256 elapsed) internal view returns (uint256) {
        return MAX_FEE - ((MAX_FEE - MEME_FEE) * elapsed) / window;
    }

    // ---------------------------------------------------------------------------------------------
    // Curve
    // ---------------------------------------------------------------------------------------------

    function test_Constants_MaxFee80Percent_MemeFeeBounds1To5Percent() external view {
        assertEq(hook.MAX_FEE_BIPS(), MAX_FEE);
        assertEq(hook.MIN_MEME_FEE_BIPS(), 100);
        assertEq(hook.MAX_MEME_FEE_BIPS(), 500);
        assertGt(window, 1, "window spans several seconds");
    }

    function test_FeeBipsAt_AtCreation_ReturnsMax() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT), MAX_FEE);
    }

    function test_FeeBipsAt_BeforeCreation_ReturnsMax() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT - 1), MAX_FEE);
    }

    function test_FeeBipsAt_OneSecond_BelowMax() external view {
        uint256 fee = hook.feeBipsAt(meme, CREATED_AT + 1);
        assertEq(fee, _expected(1));
        assertLt(fee, MAX_FEE);
    }

    function test_FeeBipsAt_HalfWindow_ReturnsMidpoint() external view {
        // exact midpoint between 80% and 5% when the window is even
        assertEq(hook.feeBipsAt(meme, CREATED_AT + window / 2), _expected(window / 2));
        if (window % 2 == 0) assertEq(_expected(window / 2), 4_250);
    }

    function test_FeeBipsAt_LastSecond_AboveMemeFee() external view {
        uint256 fee = hook.feeBipsAt(meme, CREATED_AT + window - 1);
        assertEq(fee, _expected(window - 1));
        assertGt(fee, MEME_FEE);
    }

    function test_FeeBipsAt_WindowEnd_ReturnsMemeFee() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT + window), MEME_FEE);
    }

    function test_FeeBipsAt_LongAfter_ReturnsMemeFee() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT + 365 days), MEME_FEE);
    }

    function test_FeeBipsAt_UnknownPool_ReturnsFallbackFee() external {
        assertEq(hook.feeBipsAt(makeAddr("unknown"), CREATED_AT), FALLBACK_FEE);
        assertEq(hook.baseFeeBips(makeAddr("unknown")), FALLBACK_FEE);
    }

    function test_CurrentFeeBips_FollowsBlockTimestamp() external {
        vm.warp(CREATED_AT);
        assertEq(hook.currentFeeBips(meme), MAX_FEE);
        vm.warp(CREATED_AT + window / 2);
        assertEq(hook.currentFeeBips(meme), _expected(window / 2));
        vm.warp(CREATED_AT + window);
        assertEq(hook.currentFeeBips(meme), MEME_FEE);
    }

    function testFuzz_FeeBipsAt_AlwaysBetweenMemeFeeAndMax(uint256 timestamp) external view {
        uint256 fee = hook.feeBipsAt(meme, timestamp);
        assertGe(fee, MEME_FEE);
        assertLe(fee, MAX_FEE);
    }

    function testFuzz_FeeBipsAt_NeverIncreasesOverTime(uint256 t1, uint256 t2) external view {
        t1 = bound(t1, 0, CREATED_AT + 2 * window);
        t2 = bound(t2, t1, CREATED_AT + 2 * window);
        assertGe(hook.feeBipsAt(meme, t1), hook.feeBipsAt(meme, t2));
    }

    function testFuzz_FeeBipsAt_InsideWindow_MatchesLinearFormula(uint256 elapsed) external view {
        elapsed = bound(elapsed, 0, window - 1);
        assertEq(hook.feeBipsAt(meme, CREATED_AT + elapsed), _expected(elapsed));
    }

    // ---------------------------------------------------------------------------------------------
    // Meme fee chosen by the creator
    // ---------------------------------------------------------------------------------------------

    function test_NotifyPoolCreated_StoresMemeFeeAndEmits() external {
        address other = makeAddr("other");
        _initPool(other);
        vm.expectEmit(address(hook));
        emit IHookManager.MemeFeeConfigured(other, 300, CREATED_AT);
        vm.prank(controller);
        hook.notifyPoolCreated(other, 300);

        assertEq(hook.memeFeeBips(other), 300);
        assertEq(hook.baseFeeBips(other), 300);
    }

    function test_NotifyPoolCreated_FeeBelowOnePercent_Revert() external {
        _initPool(makeAddr("other"));
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, 99));
        hook.notifyPoolCreated(makeAddr("other"), 99);
    }

    function test_NotifyPoolCreated_FeeAboveFivePercent_Revert() external {
        _initPool(makeAddr("other"));
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, 501));
        hook.notifyPoolCreated(makeAddr("other"), 501);
    }

    function testFuzz_NotifyPoolCreated_FeeInBounds_BecomesBaseFee(uint256 feeBips) external {
        feeBips = bound(feeBips, 100, 500);
        address other = makeAddr("other");
        _initPool(other);
        vm.prank(controller);
        hook.notifyPoolCreated(other, feeBips);

        assertEq(hook.feeBipsAt(other, CREATED_AT + window), feeBips);
    }

    function testFuzz_NotifyPoolCreated_FeeOutOfBounds_Revert(uint256 feeBips) external {
        vm.assume(feeBips < 100 || feeBips > 500);
        _initPool(makeAddr("other"));
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, feeBips));
        hook.notifyPoolCreated(makeAddr("other"), feeBips);
    }

    // ---------------------------------------------------------------------------------------------
    // Fallback fee: bips of the swap, at most MAX_FEE_BIPS. The hook keeps no protocol share: the
    // vault splits every fee.
    // ---------------------------------------------------------------------------------------------

    function _deployHookWithFee(DeployGemoon script, uint256 feeBips)
        internal
        returns (HookManager)
    {
        return script.deployHook(
            address(script),
            GemoonDeployBase.HookDeployParams({
                poolManager: makeAddr("poolManager"),
                pairToken: makeAddr("usdg"),
                vault: makeAddr("vault"),
                controller: controller,
                feeBips: feeBips
            })
        );
    }

    function test_Constructor_FallbackFeeAboveMax_Revert() external {
        DeployGemoon script = new DeployGemoon();
        vm.expectRevert(IHookManager.InvalidFeeBips.selector);
        _deployHookWithFee(script, MAX_FEE + 1);
    }

    /// @dev Any fallback fee from 0 to `MAX_FEE_BIPS` is accepted and stored as is.
    function testFuzz_Constructor_FallbackFeeUpToMax_Accepted(uint256 feeBips) external {
        feeBips = bound(feeBips, 0, MAX_FEE);
        assertEq(_deployHookWithFee(new DeployGemoon(), feeBips).TOTAL_FEE_BIPS(), feeBips);
    }
}
