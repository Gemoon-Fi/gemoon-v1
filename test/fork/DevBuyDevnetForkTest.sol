// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap-v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap-v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {DeployGemoon} from "../../script/GemoonDeploy.sol";
import {GemoonController} from "../../src/contracts/Gemoon.sol";
import {HookManager} from "../../src/contracts/hooks/HookManager.sol";
import {Vault} from "../../src/contracts/vault/Vault.sol";
import {AssetConfig, VaultInfo} from "../../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig,
    DevBuyConfig,
    RewardsConfig,
    INITIAL_SUPPLY_X18,
    TICK_SPACING
} from "../../src/contracts/interfaces/IGemoon.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../../src/contracts/interfaces/IToken.sol";
import {MintableToken} from "../mocks/MintableToken.sol";

/// @notice End-to-end dev buy against the devnet (Sepolia fork, chain id 1337, canonical Uniswap
/// V4): the creator deploys a Meme buying 3% of the supply in the same transaction, the fee of
/// that buy and of the later trades reaches the protocol and the vault, the vault closes epochs
/// and the creator collects the rewards.
/// @dev The reward asset of the Meme is the pair token itself: the fork has no Uniswap V3 pool
/// for the mock USDG, and with USDG as the asset the vault closes an epoch without a swap. The
/// conversion threshold is low, so every payout closes an epoch.
/// Env: DEVNET_RPC enables the suite (skipped when empty), DEVNET_BLOCK pins the block,
/// OPERATOR_ADDRESS is the funded devnet account that owns the deployment (default: anvil #0).
/// Nothing is broadcast, the fork lives only inside this test run.
contract DevBuyDevnetForkTest is Test {
    uint256 constant DEVNET_CHAIN_ID = 1337;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    uint256 constant BIPS = 10_000;
    uint256 constant PAIR_UNIT = 1e6; // mock USDG has 6 decimals
    /// @dev Production protocol share of every fee, in bips of the fee: 30%.
    uint256 constant PROTOCOL_SHARE_BIPS = 3_000;
    /// @dev Swap fee the creator chooses for the Meme.
    uint256 constant MEME_FEE_BIPS = 300;
    /// @dev Pending USDG at which the vault closes an epoch.
    uint256 constant CONVERSION_THRESHOLD = 1 * PAIR_UNIT;
    /// @dev Dev buy: 3% of the supply.
    uint256 constant DEV_BUY_BIPS = 300;
    uint256 constant DEV_BUY_AMOUNT = (INITIAL_SUPPLY_X18 * DEV_BUY_BIPS) / BIPS;
    /// @dev Pair token the creator holds and approves; far above the cost of the dev buy.
    uint256 constant CREATOR_BUDGET = 10_000 * PAIR_UNIT;

    bool forked;

    IPoolManager poolManager = IPoolManager(POOL_MANAGER);
    MintableToken usdg;
    PoolSwapTest swapRouter;

    DeployGemoon script;
    Vault vault;
    HookManager hook;
    GemoonController controller;

    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address protocolRecipient = makeAddr("protocolRecipient");

    /// @dev Result of a deployment with a dev buy, read from its logs and the hook.
    struct Launch {
        address token;
        /// @dev `DevBuy.pairIn`: pair token the creator paid, fee included.
        uint256 pairIn;
        /// @dev `MemeSwapped` of the dev buy: pool-priced pair amount and the fee on it.
        uint256 pairAmount;
        uint256 fee;
        /// @dev Protocol part of `fee`.
        uint256 protocolFee;
    }

    modifier whenForked() {
        if (!forked) return;
        _;
    }

    function setUp() external {
        string memory rpc = vm.envOr("DEVNET_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        string memory rawBlock = vm.envOr("DEVNET_BLOCK", string(""));
        if (bytes(rawBlock).length == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, vm.parseUint(rawBlock));
        forked = true;
        address devnetAccount = vm.envOr("OPERATOR_ADDRESS", ANVIL_ACCOUNT_0);

        assertEq(block.chainid, DEVNET_CHAIN_ID, "not the devnet");
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager missing");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager missing");

        usdg = new MintableToken("USDG", 6);
        swapRouter = new PoolSwapTest(poolManager);

        script = new DeployGemoon();
        address[] memory assets = new address[](1);
        assets[0] = address(usdg);
        DeployGemoon.Deployment memory d = script.deployAll(
            address(script),
            address(script),
            DeployGemoon.Params({
                owner: devnetAccount,
                proxyAdminOwner: devnetAccount,
                poolManager: POOL_MANAGER,
                positionManager: POSITION_MANAGER,
                permit2: PERMIT2,
                usdg: address(usdg),
                protocolRecipient: protocolRecipient,
                feeBips: 125,
                protocolShareBips: PROTOCOL_SHARE_BIPS,
                conversionThreshold: CONVERSION_THRESHOLD,
                swapAdapter: address(0),
                allowedAssets: assets
            })
        );
        vault = d.vault;
        hook = d.hook;
        controller = d.controller;
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _config() internal view returns (DeployConfig memory) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: creator, removable: true});
        AssetConfig[] memory assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 10_000});
        return DeployConfig({
            tokenConfig: TokenConfig({
                imgUrl: "ipfs://meme",
                description: "devnet dev buy meme",
                socialMedia: SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}),
                name: "DevBuy",
                symbol: "DEVB",
                admins: admins
            }),
            rewardsConfig: RewardsConfig({
                swapFeeBips: MEME_FEE_BIPS, creatorAddress: creator, rewardRecipient: address(0)
            }),
            vaultAssets: assets,
            devBuy: DevBuyConfig({memeAmount: DEV_BUY_AMOUNT, maxPairIn: CREATOR_BUDGET})
        });
    }

    /// @dev Creator deploys the Meme with a 3% dev buy, paid from `CREATOR_BUDGET`.
    function _launch() internal returns (Launch memory l) {
        usdg.mint(creator, CREATOR_BUDGET);
        vm.startPrank(creator);
        usdg.approve(address(controller), CREATOR_BUDGET);
        vm.recordLogs();
        l.token = controller.deployToken(_config());
        vm.stopPrank();

        bytes32 devBuySig = keccak256("DevBuy(address,address,uint256,uint256)");
        bytes32 swapSig =
            keccak256("MemeSwapped(address,address,address,bool,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 devBuys;
        uint256 swaps;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(controller) && logs[i].topics[0] == devBuySig) {
                ++devBuys;
                (l.pairIn,) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (logs[i].emitter == address(hook) && logs[i].topics[0] == swapSig) {
                ++swaps;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(controller), "router");
                assertEq(address(uint160(uint256(logs[i].topics[3]))), creator, "trader");
                (,, uint256 memeAmount,) = abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
                assertEq(memeAmount, DEV_BUY_AMOUNT, "swapped meme");
                (, l.pairAmount,, l.fee) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
            }
        }
        assertEq(devBuys, 1, "one DevBuy");
        assertEq(swaps, 1, "one MemeSwapped");
        l.protocolFee = (l.fee * PROTOCOL_SHARE_BIPS) / BIPS;
    }

    function _poolKey(address token) internal view returns (PoolKey memory) {
        (address token0, address token1) =
            token < address(usdg) ? (token, address(usdg)) : (address(usdg), token);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev `trader` buys the Meme for exactly `usdgIn` pair token.
    function _buyMeme(address token, uint256 usdgIn) internal {
        usdg.mint(trader, usdgIn);
        PoolKey memory key = _poolKey(token);
        bool usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), usdgIn);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: usdgIs0,
                amountSpecified: -int256(usdgIn),
                sqrtPriceLimitX96: usdgIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();
    }

    function _epoch(address token) internal view returns (uint64) {
        VaultInfo memory info = vault.vaultInfo(token);
        return info.epoch;
    }

    // ---------------------------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------------------------

    /// @dev Right after the deployment the creator holds exactly 3% of the supply, paid the pool
    /// price plus the base fee (not the 80% anti-snipe fee), and the fee is accrued in the hook:
    /// the dev buy is settled after its own payout attempt and the fork PoolManager held no mock
    /// USDG before it.
    function test_DeployToken_DevBuyThreePercent_CreatorHoldsThreePercentAndFeeAccrued()
        external
        whenForked
    {
        Launch memory l = _launch();

        assertEq(IERC20(l.token).balanceOf(creator), DEV_BUY_AMOUNT, "creator holds 3%");
        assertEq(
            IERC20(l.token).balanceOf(creator) * BIPS / IERC20(l.token).totalSupply(),
            DEV_BUY_BIPS,
            "3% of the supply"
        );
        assertEq(CREATOR_BUDGET - usdg.balanceOf(creator), l.pairIn, "creator paid pairIn");
        assertEq(l.pairIn, l.pairAmount + l.fee, "pool price plus fee");
        assertEq(l.fee, (l.pairAmount * MEME_FEE_BIPS) / BIPS, "base fee of the meme");
        assertEq(hook.currentFeeBips(l.token), hook.MAX_FEE_BIPS(), "others pay the anti-snipe fee");

        assertEq(hook.pendingFees(l.token), l.fee, "fee accrued in the hook");
        assertEq(hook.accruedProtocol(l.token), l.protocolFee, "protocol part accrued");
        assertEq(usdg.balanceOf(address(controller)), 0, "controller keeps no pair token");
    }

    /// @dev `distribute` (callable by anyone) pays the dev buy fee out right away: the protocol
    /// part reaches the protocol recipient, the rest the vault, which crosses the threshold and
    /// closes epoch 0. Nobody stakes yet, so the whole vault part goes to the creator.
    function test_Distribute_AfterDevBuy_FeeReachesVaultAndProtocolAndClosesEpoch()
        external
        whenForked
    {
        Launch memory l = _launch();
        uint256 toVault = l.fee - l.protocolFee;
        assertGe(toVault, CONVERSION_THRESHOLD, "dev buy fee crosses the threshold");
        assertEq(_epoch(l.token), 0, "epoch 0 open");

        hook.distribute(l.token);

        assertEq(hook.pendingFees(l.token), 0, "nothing accrued");
        assertEq(usdg.balanceOf(protocolRecipient), l.protocolFee, "protocol part paid");
        assertEq(usdg.balanceOf(address(vault)), toVault, "vault part paid");
        assertEq(_epoch(l.token), 1, "epoch 0 closed");

        VaultInfo memory info = vault.vaultInfo(l.token);
        assertEq(info.pendingStakerUSDG + info.pendingCreatorUSDG, 0, "everything converted");
        (, uint256[] memory creatorOwed) = vault.creatorAccrued(l.token);
        assertEq(creatorOwed[0], toVault, "no stakers: all to the creator");
    }

    /// @dev Full flow: dev buy, the creator stakes half of it, two trades after the anti-snipe
    /// window. Each trade pays out everything accrued so far and closes an epoch, so two epochs
    /// close. Invariants at the end:
    ///  - protocol recipient got exactly 30% of every fee, dev buy included;
    ///  - vault got the rest of every fee and owes all of it to the creator and the stakers;
    ///  - the creator collects it as staker and as creator, the vault keeps rounding dust only.
    function test_DeployToken_DevBuyThenTrading_FeesConvertedOverSeveralEpochs()
        external
        whenForked
    {
        Launch memory l = _launch();
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());

        uint256 staked = DEV_BUY_AMOUNT / 2;
        vm.startPrank(creator);
        IERC20(l.token).approve(address(vault), staked);
        vault.stake(l.token, staked);
        vm.stopPrank();

        // trade 1: pays out the dev buy fee together with its own, closes epoch 0
        uint256 buy1 = 1_000 * PAIR_UNIT;
        _buyMeme(l.token, buy1);
        uint256 fee1 = (buy1 * MEME_FEE_BIPS) / BIPS;
        uint256 protocol1 = (fee1 * PROTOCOL_SHARE_BIPS) / BIPS;

        assertEq(hook.pendingFees(l.token), 0, "trade 1 paid everything out");
        assertEq(usdg.balanceOf(protocolRecipient), l.protocolFee + protocol1, "protocol after 1");
        assertEq(_epoch(l.token), 1, "epoch 0 closed");

        // trade 2: closes epoch 1
        uint256 buy2 = 400 * PAIR_UNIT;
        _buyMeme(l.token, buy2);
        uint256 fee2 = (buy2 * MEME_FEE_BIPS) / BIPS;
        uint256 protocol2 = (fee2 * PROTOCOL_SHARE_BIPS) / BIPS;

        assertEq(hook.pendingFees(l.token), 0, "trade 2 paid everything out");
        assertEq(_epoch(l.token), 2, "epoch 1 closed");

        uint256 protocolTotal = l.protocolFee + protocol1 + protocol2;
        uint256 vaultTotal = l.fee + fee1 + fee2 - protocolTotal;
        assertEq(usdg.balanceOf(protocolRecipient), protocolTotal, "protocol got its part");
        assertEq(usdg.balanceOf(address(vault)), vaultTotal, "vault got the rest");

        VaultInfo memory info = vault.vaultInfo(l.token);
        assertEq(info.pendingStakerUSDG + info.pendingCreatorUSDG, 0, "everything converted");

        (, uint256[] memory earnedAmounts) = vault.earned(l.token, creator);
        (, uint256[] memory creatorOwed) = vault.creatorAccrued(l.token);
        assertGt(earnedAmounts[0], 0, "staker rewards");
        assertGe(creatorOwed[0], (vaultTotal * vault.CREATOR_SHARE_BPS()) / BIPS, "creator share");
        // the only staker is owed everything not owed to the creator, up to rounding
        assertApproxEqAbs(earnedAmounts[0] + creatorOwed[0], vaultTotal, 2, "all fees owed");

        uint256 before = usdg.balanceOf(creator);
        vm.startPrank(creator);
        vault.claim(l.token);
        vault.claimCreatorRewards(l.token);
        vm.stopPrank();

        assertEq(
            usdg.balanceOf(creator) - before, earnedAmounts[0] + creatorOwed[0], "creator collected"
        );
        assertLe(usdg.balanceOf(address(vault)), 2, "vault keeps rounding dust only");
    }
}
