// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";

/// @notice Anti-snipe fee curve of the hook: 80% at pool creation, linear down to the base fee
/// over one minute, base fee afterwards.
/// @dev The hook can't be deployed with a plain `new`: BaseHook checks that the address carries
/// the permission bits, and the implementation disables initializers. `deployHook` mines a
/// CREATE2 salt for both the implementation and the proxy and initializes the proxy.
/// Nothing here calls the PoolManager, so its address is a dummy.
contract HookFeeMathTest is Test {
    uint256 constant BASE_FEE = 125;
    uint256 constant MAX_FEE = 8_000;
    uint256 constant CREATED_AT = 1_700_000_000;

    HookManager hook;

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
                feeBips: BASE_FEE,
                protocolFeeBips: 50
            })
        );

        vm.prank(controller);
        hook.notifyPoolCreated(meme, CREATED_AT);
    }

    function test_Constants_MaxFee80Percent_DecayOneMinute() external view {
        assertEq(hook.MAX_FEE_BIPS(), MAX_FEE);
        assertEq(hook.DYNAMIC_FEE_THRESHOLD(), 60);
    }

    function test_FeeBipsAt_AtCreation_ReturnsMax() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT), MAX_FEE);
    }

    function test_FeeBipsAt_BeforeCreation_ReturnsMax() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT - 1), MAX_FEE);
    }

    function test_FeeBipsAt_OneSecond_ReturnsMaxMinusOneStep() external view {
        // (8000 - 125) * 1 / 60 = 131.25 -> decay 131
        assertEq(hook.feeBipsAt(meme, CREATED_AT + 1), 7_869);
    }

    function test_FeeBipsAt_HalfMinute_ReturnsMidpoint() external view {
        // (8000 - 125) * 30 / 60 = 3937.5 -> decay 3937
        assertEq(hook.feeBipsAt(meme, CREATED_AT + 30), 4_063);
    }

    function test_FeeBipsAt_LastSecond_AboveBase() external view {
        // (8000 - 125) * 59 / 60 = 7743.75 -> decay 7743
        assertEq(hook.feeBipsAt(meme, CREATED_AT + 59), 257);
    }

    function test_FeeBipsAt_OneMinute_ReturnsBase() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT + 60), BASE_FEE);
    }

    function test_FeeBipsAt_LongAfter_ReturnsBase() external view {
        assertEq(hook.feeBipsAt(meme, CREATED_AT + 365 days), BASE_FEE);
    }

    function test_FeeBipsAt_UnknownPool_ReturnsBase() external {
        assertEq(hook.feeBipsAt(makeAddr("unknown"), CREATED_AT), BASE_FEE);
    }

    function test_CurrentFeeBips_FollowsBlockTimestamp() external {
        vm.warp(CREATED_AT);
        assertEq(hook.currentFeeBips(meme), MAX_FEE);
        vm.warp(CREATED_AT + 30);
        assertEq(hook.currentFeeBips(meme), 4_063);
        vm.warp(CREATED_AT + 60);
        assertEq(hook.currentFeeBips(meme), BASE_FEE);
    }

    function testFuzz_FeeBipsAt_AlwaysBetweenBaseAndMax(uint256 timestamp) external view {
        uint256 fee = hook.feeBipsAt(meme, timestamp);
        assertGe(fee, BASE_FEE);
        assertLe(fee, MAX_FEE);
    }

    function testFuzz_FeeBipsAt_NeverIncreasesOverTime(uint256 t1, uint256 t2) external view {
        t1 = bound(t1, 0, CREATED_AT + 2 minutes);
        t2 = bound(t2, t1, CREATED_AT + 2 minutes);
        assertGe(hook.feeBipsAt(meme, t1), hook.feeBipsAt(meme, t2));
    }

    function testFuzz_FeeBipsAt_InsideWindow_MatchesLinearFormula(uint256 elapsed) external view {
        elapsed = bound(elapsed, 0, 59);
        uint256 expected = MAX_FEE - ((MAX_FEE - BASE_FEE) * elapsed) / 60;
        assertEq(hook.feeBipsAt(meme, CREATED_AT + elapsed), expected);
    }
}
