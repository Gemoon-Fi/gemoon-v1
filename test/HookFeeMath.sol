// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {IHookManager} from "../src/contracts/interfaces/IHookManager.sol";

/// @notice Fee curve of the hook: 80% at pool creation, linear down to the fee the creator chose
/// over `DYNAMIC_FEE_THRESHOLD`, that fee afterwards. Creator fee bounds. Protocol share bounds.
/// @dev The hook can't be deployed with a plain `new`: BaseHook checks that the address carries
/// the permission bits, and the implementation disables initializers. `deployHook` mines a
/// CREATE2 salt for both the implementation and the proxy and initializes the proxy.
/// Nothing here calls the PoolManager, so its address is a dummy.
contract HookFeeMathTest is Test {
    uint256 constant FALLBACK_FEE = 125;
    uint256 constant MEME_FEE = 1_000; // 10%, chosen by the creator
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
                owner: makeAddr("owner"),
                proxyAdminOwner: makeAddr("proxyAdminOwner"),
                poolManager: makeAddr("poolManager"),
                pairToken: makeAddr("usdg"),
                protocolRecipient: makeAddr("protocolRecipient"),
                vault: makeAddr("vault"),
                controller: controller,
                feeBips: FALLBACK_FEE,
                protocolShareBips: 3_000
            })
        );
        window = hook.DYNAMIC_FEE_THRESHOLD();

        vm.prank(controller);
        hook.notifyPoolCreated(meme, CREATED_AT, MEME_FEE);
    }

    function _expected(uint256 elapsed) internal view returns (uint256) {
        return MAX_FEE - ((MAX_FEE - MEME_FEE) * elapsed) / window;
    }

    // ---------------------------------------------------------------------------------------------
    // Curve
    // ---------------------------------------------------------------------------------------------

    function test_Constants_MaxFee80Percent_MemeFeeBounds1To10Percent() external view {
        assertEq(hook.MAX_FEE_BIPS(), MAX_FEE);
        assertEq(hook.MIN_MEME_FEE_BIPS(), 100);
        assertEq(hook.MAX_MEME_FEE_BIPS(), 1_000);
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
        // exact midpoint between 80% and 10% when the window is even
        assertEq(hook.feeBipsAt(meme, CREATED_AT + window / 2), _expected(window / 2));
        if (window % 2 == 0) assertEq(_expected(window / 2), 4_500);
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
        vm.expectEmit(address(hook));
        emit IHookManager.MemeFeeConfigured(other, 300, CREATED_AT);
        vm.prank(controller);
        hook.notifyPoolCreated(other, CREATED_AT, 300);

        assertEq(hook.memeFeeBips(other), 300);
        assertEq(hook.baseFeeBips(other), 300);
    }

    function test_NotifyPoolCreated_FeeBelowOnePercent_Revert() external {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, 99));
        hook.notifyPoolCreated(makeAddr("other"), CREATED_AT, 99);
    }

    function test_NotifyPoolCreated_FeeAboveTenPercent_Revert() external {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, 1_001));
        hook.notifyPoolCreated(makeAddr("other"), CREATED_AT, 1_001);
    }

    function testFuzz_NotifyPoolCreated_FeeInBounds_BecomesBaseFee(uint256 feeBips) external {
        feeBips = bound(feeBips, 100, 1_000);
        address other = makeAddr("other");
        vm.prank(controller);
        hook.notifyPoolCreated(other, CREATED_AT, feeBips);

        assertEq(hook.feeBipsAt(other, CREATED_AT + window), feeBips);
    }

    function testFuzz_NotifyPoolCreated_FeeOutOfBounds_Revert(uint256 feeBips) external {
        vm.assume(feeBips < 100 || feeBips > 1_000);
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, feeBips));
        hook.notifyPoolCreated(makeAddr("other"), CREATED_AT, feeBips);
    }

    // ---------------------------------------------------------------------------------------------
    // Protocol share: bips of the fee, at most 100%
    // ---------------------------------------------------------------------------------------------

    function _deployHookWithShare(uint256 protocolShareBips) internal returns (HookManager) {
        return _deployHookWithShare(new DeployGemoon(), protocolShareBips);
    }

    function _deployHookWithShare(DeployGemoon script, uint256 protocolShareBips)
        internal
        returns (HookManager)
    {
        return script.deployHook(
            address(script),
            GemoonDeployBase.HookDeployParams({
                owner: makeAddr("owner"),
                proxyAdminOwner: makeAddr("proxyAdminOwner"),
                poolManager: makeAddr("poolManager"),
                pairToken: makeAddr("usdg"),
                protocolRecipient: makeAddr("protocolRecipient"),
                vault: makeAddr("vault"),
                controller: controller,
                feeBips: FALLBACK_FEE,
                protocolShareBips: protocolShareBips
            })
        );
    }

    function test_Initialize_ProtocolShare_StoredInBipsOfFee() external view {
        assertEq(hook.PROTOCOL_SHARE_BIPS(), 3_000);
    }

    function test_Initialize_ProtocolShareAboveHundredPercent_Revert() external {
        DeployGemoon script = new DeployGemoon();
        vm.expectRevert(IHookManager.InvalidFeeBips.selector);
        _deployHookWithShare(script, 10_001);
    }

    /// @dev Any share from 0 to 100% of the fee is accepted, whatever the fallback fee.
    function testFuzz_Initialize_ProtocolShareUpToHundredPercent_Accepted(uint256 share)
        external
    {
        share = bound(share, 0, 10_000);
        assertEq(_deployHookWithShare(share).PROTOCOL_SHARE_BIPS(), share);
    }
}
