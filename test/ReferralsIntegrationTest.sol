// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap-v4-core/PoolManager.sol";
import {PoolSwapTest} from "@uniswap-v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap-v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {PositionManager} from "@uniswap-v4-periphery/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap-v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap-v4-periphery/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {Upgrades} from "@oz-upgrades/Upgrades.sol";
import {
    DeployGemoon,
    GemoonDeployBase,
    WireReferrals,
    ProxyReferralsUpgrade
} from "../script/GemoonDeploy.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {IHookManager} from "../src/contracts/interfaces/IHookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {GmoonReferrals} from "../src/contracts/Referrals.sol";
import {IReferrals, IProtocolFeeReceiver} from "../src/contracts/interfaces/IReferrals.sol";
import {AssetConfig} from "../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig, DevBuyConfig, RewardsConfig, TICK_SPACING
} from "../src/contracts/interfaces/IGemoon.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../src/contracts/interfaces/IToken.sol";
import {MintableToken} from "./mocks/MintableToken.sol";

/// @dev Next Referrals version, to exercise the reinitialize path of the upgrade script.
contract GmoonReferralsV2 is GmoonReferrals {
    function getVersion() public pure override returns (uint64) {
        return REFERRALS_VERSION + 1;
    }
}

/// @notice End-to-end: real PoolManager and PositionManager, Gemoon deployed by the deploy script,
/// Referrals deployed and wired by the referrals scripts, Memes deployed through the controller
/// and traded, fees flowing hook -> vault (splits) -> referrals -> referrer / protocol.
contract ReferralsIntegrationTest is Test {
    uint256 constant PAIR_UNIT = 1e6;
    uint256 constant PROTOCOL_SHARE = 2_500;
    uint256 constant REF_SHARE = 2_500;
    uint256 constant FEE_BIPS = 125;

    MintableToken usdg;
    PoolManager poolManager;
    PositionManager positionManager;
    PoolSwapTest swapRouter;

    DeployGemoon script;
    WireReferrals wire;
    ProxyReferralsUpgrade upgradeScript;
    Vault vault;
    HookManager hook;
    GemoonController controller;
    GmoonReferrals referrals;

    address refOwner = makeAddr("refOwner");
    address alice = makeAddr("alice"); // referrer
    address bob = makeAddr("bob"); // referred creator
    address carol = makeAddr("carol"); // creator without a referrer
    address trader = makeAddr("trader");

    function setUp() external {
        usdg = new MintableToken("USDG", 6);
        poolManager = new PoolManager(address(this));
        IAllowanceTransfer permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        positionManager = new PositionManager(
            poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        swapRouter = new PoolSwapTest(poolManager);

        script = new DeployGemoon();
        wire = new WireReferrals();
        upgradeScript = new ProxyReferralsUpgrade();
        address[] memory assets = new address[](1);
        assets[0] = address(usdg);
        // `wire` owns controller, vault and referrals, as the broadcaster of `make wire-referrals`
        // would.
        DeployGemoon.Deployment memory d = script.deployAll(
            address(script),
            address(script),
            DeployGemoon.Params({
                owner: address(wire),
                proxyAdminOwner: makeAddr("proxyAdminOwner"),
                poolManager: address(poolManager),
                positionManager: address(positionManager),
                permit2: address(permit2),
                usdg: address(usdg),
                protocolRecipient: makeAddr("oldProtocolRecipient"),
                feeBips: FEE_BIPS,
                protocolShareBps: PROTOCOL_SHARE,
                conversionThreshold: 0,
                swapAdapter: address(0),
                allowedAssets: assets
            })
        );
        vault = d.vault;
        hook = d.hook;
        controller = d.controller;
        vm.prank(address(wire));
        vault.acceptOwnership();

        referrals = script.deployReferrals(
            GemoonDeployBase.ReferralsDeployParams({
                owner: address(wire),
                proxyAdminOwner: address(upgradeScript),
                pairToken: address(usdg),
                controller: address(controller),
                hook: address(hook),
                refShareBips: REF_SHARE
            })
        );
        wire.wireReferrals(controller, vault, referrals);
        vm.prank(address(wire));
        referrals.transferOwnership(refOwner);
        vm.prank(refOwner);
        referrals.acceptOwnership();

        vm.prank(alice);
        referrals.registerCode("alice");
        vm.prank(bob);
        referrals.useCode("alice");
    }

    // ------------------------------------------------------------------ helpers

    function _config() internal view returns (DeployConfig memory) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: msg.sender, removable: true});
        AssetConfig[] memory assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 10_000});
        return DeployConfig({
            tokenConfig: TokenConfig({
                imgUrl: "ipfs://meme",
                description: "test meme",
                socialMedia: SocialMedia({farcaster: "", twitter: "", telegram: "", website: ""}),
                name: "Meme",
                symbol: "MEME",
                admins: admins
            }),
            rewardsConfig: RewardsConfig({
                swapFeeBips: FEE_BIPS, creatorAddress: msg.sender, rewardRecipient: address(0)
            }),
            vaultAssets: assets,
            vaultCreatorShareBps: 1_000,
            devBuy: DevBuyConfig({memeAmount: 0, maxPairIn: 0})
        });
    }

    /// @dev Deploys a Meme as `creator` and moves past the anti-snipe window.
    function _deployMeme(address creator) internal returns (address token) {
        vm.prank(creator);
        token = controller.deployToken(_config());
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());
    }

    function _buy(address token, uint256 usdgIn) internal {
        usdg.mint(trader, usdgIn);
        (address token0, address token1) =
            token < address(usdg) ? (token, address(usdg)) : (address(usdg), token);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        bool zeroForOne = token0 == address(usdg);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(usdgIn),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function _fee(uint256 usdgIn) internal pure returns (uint256) {
        return (usdgIn * FEE_BIPS) / 10_000;
    }

    /// @dev Protocol part of one payout of `fee`, rounded down like `Vault.notifyFees`.
    function _protocol(uint256 fee) internal pure returns (uint256) {
        return (fee * PROTOCOL_SHARE) / 10_000;
    }

    // ------------------------------------------------------------------ wiring

    function test_WireReferrals_Valid_EverythingPointsAtReferrals() external view {
        script.checkReferralsWiring(controller, vault, referrals);
        assertEq(vault.protocolRecipient(), address(referrals));
        assertEq(referrals.vault(), address(vault));
        assertEq(address(controller.referrals()), address(referrals));
    }

    function test_CheckReferralsWiring_VaultPaysElsewhere_Reverts() external {
        vm.prank(address(wire));
        vault.setProtocolRecipient(makeAddr("elsewhere"));
        vm.expectRevert(
            abi.encodeWithSelector(
                GemoonDeployBase.WiringMismatch.selector, "vault.protocolRecipient"
            )
        );
        script.checkReferralsWiring(controller, vault, referrals);
    }

    function test_CheckReferralsWiring_ReferralsPointAtOtherVault_Reverts() external {
        vm.prank(refOwner);
        referrals.setVault(makeAddr("otherVault"));
        vm.expectRevert(
            abi.encodeWithSelector(GemoonDeployBase.WiringMismatch.selector, "referrals.vault")
        );
        script.checkReferralsWiring(controller, vault, referrals);
    }

    function test_SetReferrals_NotOwner_Reverts() external {
        vm.expectRevert();
        vm.prank(alice);
        controller.setReferrals(address(0));
    }

    // ------------------------------------------------------------------ fee flow

    function test_DeployToken_ReferredCreator_MemeAttributedToReferrer() external {
        address token = _deployMeme(bob);
        assertEq(referrals.memeReferrer(token), alice);
    }

    function test_Swap_ReferredMeme_ReferrerEarnsRefShareOfProtocolFee() external {
        address token = _deployMeme(bob);
        // first buy stays accrued (the PoolManager holds no pair token yet), the second pays both
        _buy(token, 1_000 * PAIR_UNIT);
        _buy(token, 400 * PAIR_UNIT);

        uint256 toProtocol = _protocol(_fee(1_000 * PAIR_UNIT) + _fee(400 * PAIR_UNIT));
        uint256 toReferrer = (toProtocol * REF_SHARE) / 10_000;
        assertEq(hook.pendingFees(token), 0, "paid out");
        assertEq(usdg.balanceOf(address(referrals)), toProtocol, "protocol share arrived");
        assertEq(referrals.pendingOf(alice), toReferrer, "referrer credit");
        assertEq(referrals.protocolBalance(), toProtocol - toReferrer, "protocol part");

        vm.prank(alice);
        referrals.claim();
        assertEq(usdg.balanceOf(alice), toReferrer);

        address treasury = makeAddr("treasury");
        vm.prank(refOwner);
        referrals.withdrawProtocolFees(treasury);
        assertEq(usdg.balanceOf(treasury), toProtocol - toReferrer);
        assertEq(usdg.balanceOf(address(referrals)), 0);
    }

    function test_Swap_MemeWithoutReferrer_AllToProtocol() external {
        address token = _deployMeme(carol);
        _buy(token, 1_000 * PAIR_UNIT);
        _buy(token, 400 * PAIR_UNIT);

        uint256 toProtocol = _protocol(_fee(1_000 * PAIR_UNIT) + _fee(400 * PAIR_UNIT));
        assertEq(referrals.totalPending(), 0);
        assertEq(referrals.protocolBalance(), toProtocol);
    }

    function test_Distribute_AfterTrades_PaysReferrer() external {
        address token = _deployMeme(bob);
        _buy(token, 1_000 * PAIR_UNIT);
        _buy(token, 400 * PAIR_UNIT);

        address[] memory list = new address[](1);
        list[0] = alice;
        uint256 paid = referrals.distribute(list);
        assertGt(paid, 0);
        assertEq(usdg.balanceOf(alice), paid);
        assertEq(referrals.pendingOf(alice), 0);
    }

    function test_DeployToken_ReferralsUnset_NotRegistered() external {
        vm.prank(address(wire));
        controller.setReferrals(address(0));
        address token = _deployMeme(bob);
        assertEq(referrals.memeReferrer(token), address(0));
    }

    /// @dev A rejecting protocol recipient fails the vault split and with it the hook payout, but
    /// never the swap: the fee stays accrued in the hook and is paid once the wiring is fixed.
    function test_Payout_ReferralsRejectsVault_FeesStayAccruedUntilFixed() external {
        address token = _deployMeme(bob);
        _buy(token, 1_000 * PAIR_UNIT);

        // Referrals reject the notification (e.g. a broken upgrade): the whole payout rolls back.
        vm.mockCallRevert(
            address(referrals),
            abi.encodeWithSelector(IProtocolFeeReceiver.notifyFee.selector),
            abi.encodeWithSelector(IReferrals.NotFeeSource.selector)
        );
        vm.recordLogs();
        _buy(token, 400 * PAIR_UNIT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool failed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IHookManager.PayoutFailed.selector) failed = true;
        }
        assertTrue(failed, "payout failed");
        uint256 fee = ((1_400 * PAIR_UNIT) * FEE_BIPS) / 10_000;
        assertApproxEqAbs(hook.pendingFees(token), fee, 1, "still accrued");
        assertEq(usdg.balanceOf(address(referrals)), 0);
        assertEq(usdg.balanceOf(address(vault)), 0, "vault split rolled back");

        vm.clearMockedCalls();
        hook.distribute(token);
        assertEq(hook.pendingFees(token), 0);
        assertGt(referrals.pendingOf(alice), 0);
    }

    /// @dev The hook holds nothing of the split: the referrals hook setting is irrelevant to new
    /// hooks, the vault keeps paying the protocol share whatever it is.
    function test_Payout_ReferralsHookReplaced_VaultStillPaysProtocolShare() external {
        address token = _deployMeme(bob);
        _buy(token, 1_000 * PAIR_UNIT);

        vm.prank(refOwner);
        referrals.setHook(makeAddr("newHook"));
        _buy(token, 400 * PAIR_UNIT);

        assertEq(hook.pendingFees(token), 0, "hook paid out");
        assertGt(referrals.pendingOf(alice), 0, "referrer credited");
    }

    /// @dev EOA protocol recipient keeps working: no notification is attempted.
    function test_Payout_EoaProtocolRecipient_PaysWithoutNotify() external {
        address eoa = makeAddr("eoa");
        vm.prank(address(wire));
        vault.setProtocolRecipient(eoa);
        address token = _deployMeme(carol);
        _buy(token, 1_000 * PAIR_UNIT);
        _buy(token, 400 * PAIR_UNIT);
        assertEq(usdg.balanceOf(eoa), _protocol(_fee(1_000 * PAIR_UNIT) + _fee(400 * PAIR_UNIT)));
    }

    /// @dev Heaviest payout the hook budgets for: first credit of a referrer (cold referral
    /// slots) and first fee of a vault with a staker (cold accumulator and pending slots), all
    /// inside `PAYOUT_GAS_OVERHEAD`. It must succeed on the first try, not fail and wait.
    function test_Payout_FirstFeeWithStakerAndReferrer_FitsPayoutGasOverhead() external {
        address token = _deployMeme(bob);
        _buy(token, 1_000 * PAIR_UNIT); // accrues only, the PoolManager holds no pair token yet
        uint256 staked = IERC20(token).balanceOf(trader) / 2;
        vm.startPrank(trader);
        IERC20(token).approve(address(vault), staked);
        vault.stake(token, staked);
        vm.stopPrank();

        vm.recordLogs();
        _buy(token, 400 * PAIR_UNIT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IHookManager.PayoutFailed.selector, "payout failed");
        }
        assertEq(hook.pendingFees(token), 0, "paid out at once");
        assertGt(referrals.pendingOf(alice), 0, "referrer credited");
        assertGt(vault.vaultInfo(token).pendingStakerUSDG, 0, "stakers credited");
    }

    /// @dev The protocol share is a vault setting, changed without touching the hook: the next
    /// payout already uses the new share.
    function test_Payout_ProtocolShareChangedInVault_AppliesToNextPayout() external {
        address token = _deployMeme(carol);
        _buy(token, 1_000 * PAIR_UNIT);
        vm.prank(address(wire));
        vault.setProtocolShare(5_000);
        _buy(token, 400 * PAIR_UNIT);

        uint256 fee = _fee(1_000 * PAIR_UNIT) + _fee(400 * PAIR_UNIT);
        assertEq(hook.pendingFees(token), 0, "paid out");
        assertEq(usdg.balanceOf(address(referrals)), fee / 2, "half to the protocol");
        assertEq(usdg.balanceOf(address(vault)), fee - fee / 2, "half to the vault");
    }

    /// @dev Whatever the trade sizes, referrals hold exactly the protocol share, split between
    /// referrer credit and protocol part. A payout the PoolManager cannot cover yet stays accrued
    /// (see ControllerDeployTokenTest), so everything is flushed with `distribute` first. Fees may
    /// arrive in one or two payouts, each split and credit rounds down: at most 1 unit off per
    /// payout.
    function testFuzz_Swap_ReferredMeme_SplitConserved(uint64 a, uint64 b) external {
        uint256 first = bound(a, PAIR_UNIT, 50_000 * PAIR_UNIT);
        uint256 second = bound(b, PAIR_UNIT, 50_000 * PAIR_UNIT);
        address token = _deployMeme(bob);
        _buy(token, first);
        _buy(token, second);
        hook.distribute(token);

        uint256 toProtocol = _protocol(_fee(first) + _fee(second));
        uint256 balance = usdg.balanceOf(address(referrals));
        assertApproxEqAbs(balance, toProtocol, 1, "protocol share");
        assertLe(balance, toProtocol, "split rounds down");
        assertApproxEqAbs(
            referrals.pendingOf(alice), (balance * REF_SHARE) / 10_000, 1, "credit"
        );
        assertLe(referrals.pendingOf(alice), (balance * REF_SHARE) / 10_000, "rounds down");
        assertEq(referrals.pendingOf(alice) + referrals.protocolBalance(), balance, "conservation");
    }

    // ------------------------------------------------------------------ upgrade

    function test_UpgradeReferrals_NewVersion_KeepsState() external {
        address token = _deployMeme(bob);
        _buy(token, 1_000 * PAIR_UNIT);
        _buy(token, 400 * PAIR_UNIT);
        uint256 pending = referrals.pendingOf(alice);

        address proxyAdmin = Upgrades.getAdminAddress(address(referrals));
        GmoonReferralsV2 v2 = new GmoonReferralsV2();
        upgradeScript.upgradeReferrals(
            address(upgradeScript), address(referrals), proxyAdmin, address(v2)
        );

        assertEq(referrals.getVersion(), 2);
        assertEq(referrals.pendingOf(alice), pending);
        assertEq(referrals.memeReferrer(token), alice);
        assertEq(referrals.owner(), refOwner);
    }

    function test_UpgradeReferrals_NotProxyAdminOwner_Reverts() external {
        address proxyAdmin = Upgrades.getAdminAddress(address(referrals));
        GmoonReferrals impl = new GmoonReferrals();
        vm.expectRevert();
        upgradeScript.upgradeReferrals(alice, address(referrals), proxyAdmin, address(impl));
    }
}
