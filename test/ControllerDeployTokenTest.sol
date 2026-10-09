// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap-v4-core/PoolManager.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
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
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {IGemoonController} from "../src/contracts/interfaces/IGemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {IHookManager} from "../src/contracts/interfaces/IHookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {AssetConfig} from "../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig,
    DevBuyConfig,
    RewardsConfig,
    INITIAL_SUPPLY_X18,
    MAX_DEV_BUY_X18,
    TICK_SPACING,
    PRICE_PER_TOKEN as INITIAL_PRICE
} from "../src/contracts/interfaces/IGemoon.sol";
import {PriceMath} from "../src/contracts/utils/Price.sol";
import {StateLibrary} from "@uniswap-v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../src/contracts/interfaces/IToken.sol";
import {MintableToken} from "./mocks/MintableToken.sol";

/// @notice End-to-end: real PoolManager, PositionManager and Permit2 deployed in-process, the
/// Gemoon contracts deployed through the deploy script, then a Meme is deployed through the
/// controller and traded against its initial position.
contract ControllerDeployTokenTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant PAIR_UNIT = 1e6; // USDG has 6 decimals
    /// @dev Protocol share of every fee, in bips of the fee: 30%.
    uint256 constant PROTOCOL_SHARE = 3_000;

    MintableToken usdg;
    PoolManager poolManager;
    PositionManager positionManager;
    IAllowanceTransfer permit2;
    PoolSwapTest swapRouter;

    DeployGemoon script;
    Vault vault;
    HookManager hook;
    GemoonController controller;

    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address protocolRecipient = makeAddr("protocolRecipient");

    function setUp() external {
        usdg = new MintableToken("USDG", 6);
        poolManager = new PoolManager(address(this));
        permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        positionManager = new PositionManager(
            poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        swapRouter = new PoolSwapTest(poolManager);

        script = new DeployGemoon();
        address[] memory assets = new address[](1);
        assets[0] = address(usdg);
        DeployGemoon.Deployment memory d = script.deployAll(
            address(script),
            address(script),
            DeployGemoon.Params({
                owner: address(script),
                proxyAdminOwner: makeAddr("proxyAdminOwner"),
                poolManager: address(poolManager),
                positionManager: address(positionManager),
                permit2: address(permit2),
                usdg: address(usdg),
                protocolRecipient: protocolRecipient,
                feeBips: 125,
                protocolShareBips: PROTOCOL_SHARE,
                conversionThreshold: 0,
                swapAdapter: address(0),
                allowedAssets: assets
            })
        );
        vault = d.vault;
        hook = d.hook;
        controller = d.controller;
    }

    function _config() internal view returns (DeployConfig memory) {
        return _config(125);
    }

    function _config(uint256 swapFeeBips) internal view returns (DeployConfig memory) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: creator, removable: true});
        AssetConfig[] memory assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 10_000});
        return DeployConfig({
            tokenConfig: TokenConfig({
                imgUrl: "ipfs://meme",
                description: "test meme",
                socialMedia: SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}),
                name: "Meme",
                symbol: "MEME",
                admins: admins
            }),
            rewardsConfig: RewardsConfig({
                swapFeeBips: swapFeeBips, creatorAddress: creator, rewardRecipient: address(0)
            }),
            vaultAssets: assets,
            devBuy: DevBuyConfig({memeAmount: 0, maxPairIn: 0})
        });
    }

    /// @dev Deploys a Meme and moves past the anti-snipe window, so swaps pay the base fee.
    function _deployMeme() internal returns (address token, uint256 positionId) {
        (token, positionId) = _launchMeme();
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());
    }

    /// @dev Deploys a Meme and stays at its creation time: swaps pay the anti-snipe fee.
    function _launchMeme() internal returns (address token, uint256 positionId) {
        positionId = positionManager.nextTokenId();
        vm.prank(creator);
        token = controller.deployToken(_config());
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

    function _buyMeme(address token, uint256 usdgIn) internal {
        usdg.mint(trader, usdgIn);
        _swap(token, true, -int256(usdgIn), bytes(""));
    }

    /// @dev Swaps as `trader` through the test router. `buy`: pair token in, Meme out.
    /// Negative `amountSpecified` is exact input, positive exact output.
    function _swap(address token, bool buy, int256 amountSpecified, bytes memory hookData)
        internal
    {
        PoolKey memory key = _poolKey(token);
        bool usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        bool zeroForOne = buy == usdgIs0;
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), type(uint256).max);
        IERC20(token).approve(address(swapRouter), type(uint256).max);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
        vm.stopPrank();
    }

    struct Trade {
        address meme;
        address router;
        address trader;
        bool isBuy;
        uint256 pairAmount;
        uint256 memeAmount;
        uint256 fee;
    }

    /// @dev The single `MemeSwapped` among the recorded logs.
    function _memeSwapped() internal returns (Trade memory t) {
        return _memeSwappedIn(vm.getRecordedLogs());
    }

    function _memeSwappedIn(Vm.Log[] memory logs) internal view returns (Trade memory t) {
        bytes32 sig = keccak256("MemeSwapped(address,address,address,bool,uint256,uint256,uint256)");
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != sig) continue;
            ++found;
            t.meme = address(uint160(uint256(logs[i].topics[1])));
            t.router = address(uint160(uint256(logs[i].topics[2])));
            t.trader = address(uint160(uint256(logs[i].topics[3])));
            (t.isBuy, t.pairAmount, t.memeAmount, t.fee) =
                abi.decode(logs[i].data, (bool, uint256, uint256, uint256));
        }
        assertEq(found, 1, "exactly one MemeSwapped");
    }

    function _fee(uint256 amount) internal pure returns (uint256) {
        return (amount * 125) / 10_000;
    }

    /// @dev Protocol part of one charged fee, rounded down like the hook does.
    function _protocol(uint256 fee) internal pure returns (uint256) {
        return (fee * PROTOCOL_SHARE) / 10_000;
    }

    function test_DeployToken_MintsWholeSupplyIntoPositionOwnedByController() external {
        (address token, uint256 positionId) = _deployMeme();

        assertEq(positionManager.ownerOf(positionId), address(controller), "position owner");
        assertGt(positionManager.getPositionLiquidity(positionId), 0, "liquidity");
        assertEq(IERC20(token).totalSupply(), INITIAL_SUPPLY_X18, "supply");
        // the position takes (almost) everything, only rounding dust may stay behind
        assertLt(IERC20(token).balanceOf(address(controller)), 1e18, "controller dust");
        assertEq(IERC20(token).balanceOf(creator), 0, "creator gets no tokens");
        assertTrue(vault.isRegistered(token), "vault registered");
    }

    function test_DeployToken_NoAllowanceLeftBehind() external {
        (address token,) = _deployMeme();

        assertEq(IERC20(token).allowance(address(controller), address(permit2)), 0, "erc20");
        (uint160 amount,,) =
            permit2.allowance(address(controller), token, address(positionManager));
        assertEq(amount, 0, "permit2");
    }

    function test_DeployToken_EmitsPositionCreated() external {
        uint256 positionId = positionManager.nextTokenId();
        vm.recordLogs();
        vm.prank(creator);
        address token = controller.deployToken(_config());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(controller)
                    && logs[i].topics[0]
                        == keccak256("PositionCreated(address,uint256,int24,int24,uint128)")
            ) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token);
                assertEq(uint256(logs[i].topics[2]), positionId);
                (,, uint128 liquidity) = abi.decode(logs[i].data, (int24, int24, uint128));
                assertEq(liquidity, positionManager.getPositionLiquidity(positionId));
                found = true;
            }
        }
        assertTrue(found, "PositionCreated not emitted");
    }

    function test_DeployToken_Twice_IndependentPositions() external {
        (address a, uint256 idA) = _deployMeme();
        (address b, uint256 idB) = _deployMeme();
        assertTrue(a != b);
        assertEq(idB, idA + 1);
        assertEq(positionManager.ownerOf(idA), address(controller));
        assertEq(positionManager.ownerOf(idB), address(controller));
    }

    function test_DeployToken_NotifiesHook_PoolTimestampIsBlockTimestamp() external {
        vm.warp(1_700_000_000);
        (address token,) = _deployMeme();
        assertEq(hook.poolTimestamps(token), 1_700_000_000);
    }

    function testFuzz_DeployToken_TwoMemes_EachKeepsOwnPoolTimestamp(uint256 t1, uint256 gap)
        external
    {
        // Realistic timestamps: Permit2 expirations are uint48, far-future warps expire them.
        t1 = bound(t1, 1, type(uint32).max);
        gap = bound(gap, 1, 365 days);

        vm.warp(t1);
        (address a,) = _deployMeme();
        vm.warp(t1 + gap);
        (address b,) = _deployMeme();

        assertEq(hook.poolTimestamps(a), t1, "first meme");
        assertEq(hook.poolTimestamps(b), t1 + gap, "second meme");
    }

    /// @dev The hook accepts the notification only from its controller, so a hook wired to
    /// another controller blocks `deployToken` entirely instead of silently skipping it.
    function test_DeployToken_HookControllerIsOther_Revert() external {
        vm.prank(address(script));
        hook.setController(makeAddr("otherController"));

        vm.prank(creator);
        vm.expectRevert(IHookManager.NotController.selector);
        controller.deployToken(_config());
    }

    function test_DeployToken_PositionManagerNotSet_Revert() external {
        GemoonController fresh = script.deployController(
            address(script),
            GemoonDeployBase.ControllerDeployParams({
                proxyAdminOwner: makeAddr("proxyAdminOwner"),
                poolManager: address(poolManager),
                pairToken: address(usdg)
            })
        );
        vm.startPrank(address(script));
        fresh.setHook(address(hook));
        fresh.setVault(address(vault));
        vm.stopPrank();

        vm.expectRevert(GemoonController.PositionManagerNotSet.selector);
        vm.prank(creator);
        fresh.deployToken(_config());
    }

    function test_SetPositionManager_ZeroAddress_Revert() external {
        vm.startPrank(address(script));
        vm.expectRevert(GemoonController.InvalidAddress.selector);
        controller.setPositionManager(address(0), address(permit2));
        vm.expectRevert(GemoonController.InvalidAddress.selector);
        controller.setPositionManager(address(positionManager), address(0));
        vm.stopPrank();
    }

    function test_SetPositionManager_NotOwner_Revert() external {
        vm.expectRevert();
        vm.prank(creator);
        controller.setPositionManager(address(positionManager), address(permit2));
    }

    /// @dev The swapper's input is settled by the router after `afterSwap`, so the first swap of
    /// a PoolManager that holds no pair token yet cannot pay the fee out: it stays accrued in the
    /// hook and is paid together with the fee of the next swap.
    function test_Swap_FirstBuy_FeeStaysAccruedUntilPoolManagerHoldsPairToken() external {
        (address token,) = _deployMeme();

        uint256 usdgIn = 1_000 * PAIR_UNIT;
        _buyMeme(token, usdgIn);

        assertGt(IERC20(token).balanceOf(trader), 0, "trader got meme");
        assertEq(usdg.balanceOf(trader), 0, "trader spent everything");
        uint256 fee = (usdgIn * 125) / 10_000;
        assertEq(hook.pendingFees(token), fee, "fee accrued");
        assertEq(usdg.balanceOf(protocolRecipient), 0, "not paid out yet");
        assertEq(usdg.balanceOf(address(vault)), 0, "not paid out yet");
    }

    function test_Swap_SecondBuy_PaysOutBothFeesSplitBetweenProtocolAndVault() external {
        (address token,) = _deployMeme();

        uint256 first = 1_000 * PAIR_UNIT;
        uint256 second = 400 * PAIR_UNIT;
        _buyMeme(token, first);
        _buyMeme(token, second);

        // 1.25% of every input: 30% of it (0.375%) to the protocol, 0.875% to the vault.
        uint256 fee = _fee(first) + _fee(second);
        uint256 toProtocol = _protocol(_fee(first)) + _protocol(_fee(second));
        assertEq(hook.pendingFees(token), 0, "nothing left accrued");
        assertEq(usdg.balanceOf(protocolRecipient), toProtocol, "protocol share");
        assertEq(usdg.balanceOf(address(vault)), fee - toProtocol, "vault share");
        assertEq(vault.accounted(address(usdg)), fee - toProtocol, "vault accounted");
    }

    function test_Distribute_AfterFirstBuy_PaysAccruedFee() external {
        (address token,) = _deployMeme();
        uint256 usdgIn = 1_000 * PAIR_UNIT;
        _buyMeme(token, usdgIn);

        hook.distribute(token);

        uint256 fee = _fee(usdgIn);
        uint256 toProtocol = _protocol(fee);
        assertEq(hook.pendingFees(token), 0);
        assertEq(usdg.balanceOf(protocolRecipient), toProtocol);
        assertEq(usdg.balanceOf(address(vault)), fee - toProtocol);
    }

    // ------------------------------------------------------------------ start price

    /// @dev INITIAL_PRICE whole Meme per 1 USDG regardless of USDG having 6 decimals: a 1 USDG
    /// buy returns close to INITIAL_PRICE Meme, less the 1.25% fee and the price impact of a
    /// one-sided position.
    function test_DeployToken_StartPrice_InitialPriceMemePerWholePairToken() external {
        (address token,) = _deployMeme();
        _buyMeme(token, 1 * PAIR_UNIT);

        uint256 got = IERC20(token).balanceOf(trader);
        uint256 startPrice = INITIAL_PRICE * 1e18; // whole Meme for one whole pair token
        assertLt(got, startPrice, "never more than the start price");
        // the hook fee plus price impact of a single pair-token buy stay below 3.3%
        assertGt(got, startPrice * 967 / 1000, "fee and impact on 1 pair token stay below 3.3%");
    }

    function test_DeployToken_PoolInitializedAtPriceForPairDecimals() external {
        (address token,) = _deployMeme();
        PoolKey memory key = _poolKey(token);
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(key.toId());
        uint160 expected = PriceMath.getSqrtPriceX96(
            Currency.unwrap(key.currency0) == token ? INITIAL_PRICE * 1e18 : PAIR_UNIT,
            Currency.unwrap(key.currency1) == token ? INITIAL_PRICE * 1e18 : PAIR_UNIT
        );
        assertEq(sqrtPriceX96, expected, "slot0 price");
    }

    // ------------------------------------------------------------------ MemeSwapped

    function test_Swap_BuyExactIn_EmitsMemeSwapped() external {
        (address token,) = _deployMeme();
        uint256 usdgIn = 1_000 * PAIR_UNIT;
        usdg.mint(trader, usdgIn);

        vm.recordLogs();
        _swap(token, true, -int256(usdgIn), bytes(""));
        Trade memory t = _memeSwapped();

        assertEq(t.meme, token);
        assertEq(t.router, address(swapRouter), "router is the PoolManager caller");
        assertEq(t.trader, address(0), "no hookData, no trader");
        assertTrue(t.isBuy);
        assertEq(t.fee, _fee(usdgIn), "fee on the specified input");
        assertEq(t.pairAmount + t.fee, usdgIn, "pool priced the input net of fee");
        assertEq(t.memeAmount, IERC20(token).balanceOf(trader), "meme received");
        assertEq(usdg.balanceOf(trader), 0);
    }

    function test_Swap_BuyExactOut_EmitsMemeSwapped() external {
        (address token,) = _deployMeme();
        uint256 memeOut = 1_000_000e18; // ~3.3 USDG at the start price
        usdg.mint(trader, 100_000 * PAIR_UNIT);
        uint256 usdgBefore = usdg.balanceOf(trader);

        vm.recordLogs();
        _swap(token, true, int256(memeOut), bytes(""));
        Trade memory t = _memeSwapped();

        assertTrue(t.isBuy);
        assertEq(t.memeAmount, memeOut);
        assertEq(IERC20(token).balanceOf(trader), memeOut);
        assertEq(t.fee, _fee(t.pairAmount), "fee on the pool-priced pair amount");
        assertEq(usdgBefore - usdg.balanceOf(trader), t.pairAmount + t.fee, "buyer pays pair + fee");
    }

    function test_Swap_SellExactIn_EmitsMemeSwapped() external {
        (address token,) = _deployMeme();
        _buyMeme(token, 1_000 * PAIR_UNIT);
        uint256 memeIn = IERC20(token).balanceOf(trader) / 2;
        uint256 usdgBefore = usdg.balanceOf(trader);

        vm.recordLogs();
        _swap(token, false, -int256(memeIn), bytes(""));
        Trade memory t = _memeSwapped();

        assertFalse(t.isBuy);
        assertEq(t.memeAmount, memeIn);
        assertEq(t.fee, _fee(t.pairAmount), "fee on the pool-priced pair amount");
        assertEq(usdg.balanceOf(trader) - usdgBefore, t.pairAmount - t.fee, "seller gets pair - fee");
    }

    function test_Swap_SellExactOut_EmitsMemeSwapped() external {
        (address token,) = _deployMeme();
        _buyMeme(token, 1_000 * PAIR_UNIT);
        uint256 usdgOut = 100 * PAIR_UNIT;
        uint256 usdgBefore = usdg.balanceOf(trader);
        uint256 memeBefore = IERC20(token).balanceOf(trader);

        vm.recordLogs();
        _swap(token, false, int256(usdgOut), bytes(""));
        Trade memory t = _memeSwapped();

        assertFalse(t.isBuy);
        assertEq(t.fee, _fee(usdgOut), "fee on the specified output");
        assertEq(t.pairAmount, usdgOut + t.fee, "pool produced output plus fee");
        assertEq(usdg.balanceOf(trader) - usdgBefore, usdgOut, "seller gets exactly the output");
        assertEq(memeBefore - IERC20(token).balanceOf(trader), t.memeAmount);
    }

    function test_Swap_HookDataAddress_ReportedAsTrader() external {
        (address token,) = _deployMeme();
        address alice = makeAddr("alice");
        usdg.mint(trader, 10 * PAIR_UNIT);

        vm.recordLogs();
        _swap(token, true, -int256(10 * PAIR_UNIT), abi.encode(alice));
        assertEq(_memeSwapped().trader, alice);
    }

    function test_Swap_HookDataWrongLength_TraderZero() external {
        (address token,) = _deployMeme();
        usdg.mint(trader, 10 * PAIR_UNIT);

        vm.recordLogs();
        _swap(token, true, -int256(10 * PAIR_UNIT), hex"0102");
        assertEq(_memeSwapped().trader, address(0));
    }

    /// @dev Invariant: protocol + vault + accrued == 1.25% of everything swapped in.
    function testFuzz_Swap_FeeIsAlwaysCharged(uint256 second) external {
        uint256 first = 1_000 * PAIR_UNIT;
        // keep first + second fees below the pair token the PoolManager holds after `first`,
        // so the second swap can pay everything out
        second = bound(second, 10 * PAIR_UNIT, 50_000 * PAIR_UNIT);
        (address token,) = _deployMeme();
        _buyMeme(token, first);
        _buyMeme(token, second);

        uint256 fee = (first * 125) / 10_000 + (second * 125) / 10_000;
        assertEq(hook.pendingFees(token), 0, "paid out");
        assertEq(
            usdg.balanceOf(protocolRecipient) + usdg.balanceOf(address(vault)), fee, "total fee"
        );
        assertGt(IERC20(token).balanceOf(trader), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Anti-snipe fee: 80% at pool creation, linear down to the base fee over one minute
    // ---------------------------------------------------------------------------------------------

    function test_Swap_BuyAtLaunch_ChargesMaxFee() external {
        (address token,) = _launchMeme();
        uint256 usdgIn = 1_000 * PAIR_UNIT;

        vm.recordLogs();
        _buyMeme(token, usdgIn);
        Trade memory t = _memeSwapped();

        assertEq(t.fee, (usdgIn * 8_000) / 10_000, "80% of the input");
        assertEq(hook.pendingFees(token), t.fee, "accrued");
    }

    function test_Swap_BuyHalfWindowAfterLaunch_ChargesMidpointFee() external {
        (address token,) = _launchMeme();
        uint256 half = hook.DYNAMIC_FEE_THRESHOLD() / 2;
        vm.warp(block.timestamp + half);
        uint256 usdgIn = 1_000 * PAIR_UNIT;
        // linear between 80% and the 1.25% base fee of `_config()`
        uint256 bips = 8_000 - ((8_000 - 125) * half) / hook.DYNAMIC_FEE_THRESHOLD();

        vm.recordLogs();
        _buyMeme(token, usdgIn);

        assertEq(_memeSwapped().fee, (usdgIn * bips) / 10_000);
    }

    function test_Swap_SellAtLaunch_ChargesMaxFeeOnOutput() external {
        (address token,) = _launchMeme();
        _buyMeme(token, 1_000 * PAIR_UNIT);
        uint256 memeIn = IERC20(token).balanceOf(trader) / 2;

        vm.recordLogs();
        _swap(token, false, -int256(memeIn), bytes(""));
        Trade memory t = _memeSwapped();

        assertEq(t.fee, (t.pairAmount * 8_000) / 10_000, "80% of the pool-priced output");
    }

    function test_Swap_BuyOneMinuteAfterLaunch_ChargesBaseFee() external {
        (address token,) = _launchMeme();
        vm.warp(block.timestamp + 60);
        uint256 usdgIn = 1_000 * PAIR_UNIT;

        vm.recordLogs();
        _buyMeme(token, usdgIn);

        assertEq(_memeSwapped().fee, _fee(usdgIn), "base fee");
    }

    /// @dev Invariant: whatever the fee rate, every charged fee ends up either paid to the
    /// protocol and the vault or still accrued, and the protocol gets 30% of every fee, the
    /// anti-snipe excess included.
    function testFuzz_Swap_DynamicFee_ProtocolPlusVaultPlusAccruedEqualsCharged(
        uint256 e1,
        uint256 e2
    ) external {
        e1 = bound(e1, 0, 90);
        e2 = bound(e2, e1, 90);
        (address token,) = _launchMeme();
        uint256 createdAt = block.timestamp;
        uint256 first = 1_000 * PAIR_UNIT;
        uint256 second = 400 * PAIR_UNIT;

        vm.warp(createdAt + e1);
        uint256 bips1 = hook.currentFeeBips(token);
        uint256 fee1 = (first * bips1) / 10_000;
        _buyMeme(token, first);
        vm.warp(createdAt + e2);
        uint256 bips2 = hook.currentFeeBips(token);
        uint256 fee2 = (second * bips2) / 10_000;
        _buyMeme(token, second);

        uint256 toProtocol = usdg.balanceOf(protocolRecipient);
        uint256 toVault = usdg.balanceOf(address(vault));
        assertEq(toProtocol + toVault + hook.pendingFees(token), fee1 + fee2, "fee conserved");
        assertEq(
            toProtocol + hook.accruedProtocol(token),
            _protocol(fee1) + _protocol(fee2),
            "protocol part is 30% of every fee"
        );
        assertLe(hook.accruedProtocol(token), hook.pendingFees(token), "protocol part <= accrued");
        assertGe(bips1, bips2, "fee rate never grows over time");
    }

    // ---------------------------------------------------------------------------------------------
    // Swap fee chosen by the creator: protocol gets 30% of it, vault the rest
    // ---------------------------------------------------------------------------------------------

    function _deployMemeWithFee(uint256 swapFeeBips) internal returns (address token) {
        vm.prank(creator);
        token = controller.deployToken(_config(swapFeeBips));
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());
    }

    function test_DeployToken_SwapFee_StoredInHook() external {
        address token = _deployMemeWithFee(1_000);
        assertEq(hook.memeFeeBips(token), 1_000);
        assertEq(hook.currentFeeBips(token), 1_000);
    }

    function test_DeployToken_SwapFeeBelowOnePercent_Revert() external {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, 99));
        controller.deployToken(_config(99));
    }

    function test_DeployToken_SwapFeeAboveTenPercent_Revert() external {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidMemeFeeBips.selector, 1_001));
        controller.deployToken(_config(1_001));
    }

    /// @dev 10% fee: the protocol gets 30% of it (3% of the volume), the vault 7%.
    function test_Swap_TenPercentFee_ProtocolGetsThirtyPercentVaultRest() external {
        address token = _deployMemeWithFee(1_000);
        uint256 first = 1_000 * PAIR_UNIT;
        uint256 second = 400 * PAIR_UNIT;

        _buyMeme(token, first);
        _buyMeme(token, second);

        uint256 total = first + second;
        assertEq(hook.pendingFees(token), 0, "paid out");
        assertEq(usdg.balanceOf(protocolRecipient), (total * 300) / 10_000, "3% of the volume");
        assertEq(usdg.balanceOf(address(vault)), (total * 700) / 10_000, "7% of the volume");
        assertApproxEqAbs(
            usdg.balanceOf(protocolRecipient) + usdg.balanceOf(address(vault)),
            (total * 1_000) / 10_000,
            1,
            "10% of the volume"
        );
    }

    /// @dev Product examples: of a 1% fee the protocol gets 0.3% of the volume and the vault 0.7%,
    /// of 2% 0.6% and 1.4%, of 10% 3% and 7%.
    function test_Swap_ProtocolShare_ThirtyPercentOfAnyMemeFee() external {
        uint256[3] memory fees = [uint256(100), 200, 1_000];
        uint256[3] memory toProtocolBips = [uint256(30), 60, 300];
        uint256 volume = 1_000 * PAIR_UNIT;
        for (uint256 i; i < fees.length; ++i) {
            address token = _deployMemeWithFee(fees[i]);
            // the first buy only accrues: the PoolManager holds no pair token of this pool yet
            uint256 protocolBefore = usdg.balanceOf(protocolRecipient);
            uint256 vaultBefore = usdg.balanceOf(address(vault));
            _buyMeme(token, volume);
            hook.distribute(token);

            uint256 toProtocol = usdg.balanceOf(protocolRecipient) - protocolBefore;
            uint256 toVault = usdg.balanceOf(address(vault)) - vaultBefore;
            assertEq(toProtocol, (volume * toProtocolBips[i]) / 10_000, "protocol part");
            assertEq(
                toVault, (volume * (fees[i] - toProtocolBips[i])) / 10_000, "vault part"
            );
        }
    }

    /// @dev Invariant over any allowed fee: protocol + vault + accrued == every fee charged, and
    /// the protocol part is always 30% of the fee, rounded down.
    function testFuzz_Swap_AnySwapFee_ProtocolGetsThirtyPercentFeeConserved(uint256 swapFeeBips)
        external
    {
        swapFeeBips = bound(swapFeeBips, 100, 1_000);
        address token = _deployMemeWithFee(swapFeeBips);
        uint256 first = 1_000 * PAIR_UNIT;
        uint256 second = 400 * PAIR_UNIT;

        _buyMeme(token, first);
        _buyMeme(token, second);

        uint256 charged = (first * swapFeeBips) / 10_000 + (second * swapFeeBips) / 10_000;
        uint256 protocolPart = _protocol((first * swapFeeBips) / 10_000)
            + _protocol((second * swapFeeBips) / 10_000);
        uint256 toProtocol = usdg.balanceOf(protocolRecipient);
        uint256 toVault = usdg.balanceOf(address(vault));
        assertEq(toProtocol + toVault + hook.pendingFees(token), charged, "fee conserved");
        assertEq(toProtocol + hook.accruedProtocol(token), protocolPart, "protocol part 30%");
        assertLe(protocolPart * 10_000, charged * PROTOCOL_SHARE, "never above 30%");
    }

    // ---------------------------------------------------------------------------------------------
    // Dev buy: the caller of `deployToken` buys first, in the same transaction, at the base fee
    // ---------------------------------------------------------------------------------------------

    struct DevBuyResult {
        address token;
        uint256 pairIn;
        uint256 memeOut;
        Trade trade;
    }

    function _configWithDevBuy(uint256 swapFeeBips, uint256 memeAmount, uint256 maxPairIn)
        internal
        view
        returns (DeployConfig memory config)
    {
        config = _config(swapFeeBips);
        config.devBuy = DevBuyConfig({memeAmount: memeAmount, maxPairIn: maxPairIn});
    }

    /// @dev Funds `creator` with plenty of pair token, approves the controller and deploys a Meme
    /// with a dev buy of `memeAmount`. Returns the `DevBuy` event fields.
    function _deployWithDevBuy(uint256 swapFeeBips, uint256 memeAmount)
        internal
        returns (DevBuyResult memory r)
    {
        uint256 budget = 1_000_000 * PAIR_UNIT;
        usdg.mint(creator, budget);
        vm.startPrank(creator);
        usdg.approve(address(controller), budget);
        vm.recordLogs();
        r.token = controller.deployToken(_configWithDevBuy(swapFeeBips, memeAmount, budget));
        vm.stopPrank();

        bytes32 sig = keccak256("DevBuy(address,address,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(controller) || logs[i].topics[0] != sig) continue;
            ++found;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), r.token, "event token");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), creator, "event buyer");
            (r.pairIn, r.memeOut) = abi.decode(logs[i].data, (uint256, uint256));
        }
        assertEq(found, 1, "exactly one DevBuy");
        r.trade = _memeSwappedIn(logs);
    }

    function test_DeployToken_DevBuy_BuyerReceivesExactAmountAndPaysPairIn() external {
        uint256 memeAmount = 10_000_000e18; // 1% of the supply
        uint256 before = 1_000_000 * PAIR_UNIT;
        DevBuyResult memory r = _deployWithDevBuy(125, memeAmount);

        assertEq(r.memeOut, memeAmount, "event meme");
        assertEq(IERC20(r.token).balanceOf(creator), memeAmount, "creator meme");
        assertEq(before - usdg.balanceOf(creator), r.pairIn, "creator paid pairIn");
        assertGt(r.pairIn, 0, "not free");
        assertEq(usdg.balanceOf(address(controller)), 0, "controller holds no pair token");
        assertLt(IERC20(r.token).balanceOf(address(controller)), 1e18, "controller holds dust only");
        assertEq(usdg.allowance(creator, address(controller)), before - r.pairIn, "only pairIn pulled");
    }

    function test_DeployToken_DevBuy_ChargesBaseFeeNotSnipeFee() external {
        uint256 memeAmount = 10_000_000e18;
        usdg.mint(creator, 1_000_000 * PAIR_UNIT);
        vm.startPrank(creator);
        usdg.approve(address(controller), type(uint256).max);
        vm.recordLogs();
        address token =
            controller.deployToken(_configWithDevBuy(1_000, memeAmount, type(uint256).max));
        vm.stopPrank();
        Trade memory t = _memeSwapped();

        assertEq(hook.currentFeeBips(token), 8_000, "others still pay the anti-snipe fee");
        assertEq(t.meme, token);
        assertEq(t.router, address(controller), "swapped by the controller");
        assertEq(t.trader, creator, "buyer reported as trader");
        assertTrue(t.isBuy);
        assertEq(t.memeAmount, memeAmount);
        assertEq(t.fee, (t.pairAmount * 1_000) / 10_000, "base fee of the meme");
    }

    /// @dev The dev buy is settled after `afterSwap`, so on a PoolManager without pair token the
    /// fee stays accrued and is paid out by the next swap, like any first buy.
    function test_DeployToken_DevBuy_FeeAccruedThenPaidByNextSwap() external {
        DevBuyResult memory r = _deployWithDevBuy(125, 10_000_000e18);
        uint256 devFee = r.pairIn - (r.pairIn * 10_000) / 10_125; // ~1.25% of pair amount
        assertApproxEqAbs(hook.pendingFees(r.token), devFee, 1, "dev buy fee accrued");
        uint256 accrued = hook.pendingFees(r.token);

        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());
        uint256 usdgIn = 1_000 * PAIR_UNIT;
        _buyMeme(r.token, usdgIn);

        assertEq(hook.pendingFees(r.token), 0, "paid out");
        assertEq(
            usdg.balanceOf(protocolRecipient) + usdg.balanceOf(address(vault)),
            accrued + _fee(usdgIn),
            "both fees paid"
        );
    }

    function test_DeployToken_DevBuy_SameBlockBuyPaysMaxFee() external {
        DevBuyResult memory r = _deployWithDevBuy(125, 10_000_000e18);
        uint256 usdgIn = 1_000 * PAIR_UNIT;

        vm.recordLogs();
        _buyMeme(r.token, usdgIn);

        assertEq(_memeSwapped().fee, (usdgIn * 8_000) / 10_000, "sniper pays 80%");
    }

    /// @dev Snipers trade after the dev buy: they buy at the price the dev buy left behind.
    function test_DeployToken_DevBuy_MovesPriceForLaterBuyers() external {
        DevBuyResult memory r = _deployWithDevBuy(125, MAX_DEV_BUY_X18);
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());
        _buyMeme(r.token, 1 * PAIR_UNIT);

        // the dev paid on average less per Meme than the marginal price after the dev buy
        uint256 devMemePerPair = r.memeOut / r.pairIn;
        uint256 traderMemePerPair = IERC20(r.token).balanceOf(trader) / PAIR_UNIT;
        assertLt(traderMemePerPair, devMemePerPair, "later buyer gets less per pair token");
    }

    function test_DeployToken_DevBuyAtCap_Succeeds() external {
        DevBuyResult memory r = _deployWithDevBuy(125, MAX_DEV_BUY_X18);
        assertEq(IERC20(r.token).balanceOf(creator), MAX_DEV_BUY_X18);
        assertEq(MAX_DEV_BUY_X18, INITIAL_SUPPLY_X18 / 10, "cap is 10% of the supply");
    }

    function test_DeployToken_DevBuyAboveCap_Revert() external {
        uint256 memeAmount = MAX_DEV_BUY_X18 + 1;
        vm.prank(creator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IGemoonController.DevBuyTooLarge.selector, memeAmount, MAX_DEV_BUY_X18
            )
        );
        controller.deployToken(_configWithDevBuy(125, memeAmount, type(uint256).max));
    }

    function test_DeployToken_DevBuySlippage_Revert() external {
        uint256 memeAmount = 10_000_000e18;
        // learn the exact cost from a snapshot, then ask for one unit less
        uint256 snap = vm.snapshotState();
        uint256 pairIn = _deployWithDevBuy(125, memeAmount).pairIn;
        vm.revertToState(snap);

        usdg.mint(creator, pairIn);
        vm.startPrank(creator);
        usdg.approve(address(controller), pairIn);
        vm.expectRevert(
            abi.encodeWithSelector(IGemoonController.DevBuySlippage.selector, pairIn, pairIn - 1)
        );
        controller.deployToken(_configWithDevBuy(125, memeAmount, pairIn - 1));

        // exactly the cost is enough
        address token = controller.deployToken(_configWithDevBuy(125, memeAmount, pairIn));
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(creator), memeAmount);
        assertEq(usdg.balanceOf(creator), 0);
    }

    function test_DeployToken_DevBuyWithoutApproval_Revert() external {
        usdg.mint(creator, 1_000_000 * PAIR_UNIT);
        vm.prank(creator);
        vm.expectRevert();
        controller.deployToken(_configWithDevBuy(125, 10_000_000e18, type(uint256).max));
    }

    /// @dev Someone else's approval to the controller is never spent: the buyer is the caller.
    function test_DeployToken_DevBuy_PaidByCallerNotByOtherApprover() external {
        address victim = makeAddr("victim");
        usdg.mint(victim, 1_000_000 * PAIR_UNIT);
        vm.prank(victim);
        usdg.approve(address(controller), type(uint256).max);

        vm.prank(creator);
        vm.expectRevert();
        controller.deployToken(_configWithDevBuy(125, 10_000_000e18, type(uint256).max));
        assertEq(usdg.balanceOf(victim), 1_000_000 * PAIR_UNIT, "victim untouched");
    }

    function test_DeployToken_NoDevBuy_NoSwap() external {
        vm.recordLogs();
        vm.prank(creator);
        address token = controller.deployToken(_config());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 devBuySig = keccak256("DevBuy(address,address,uint256,uint256)");
        bytes32 swapSig =
            keccak256("MemeSwapped(address,address,address,bool,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != devBuySig, "no DevBuy");
            assertTrue(logs[i].topics[0] != swapSig, "no swap");
        }
        assertEq(IERC20(token).balanceOf(creator), 0);
    }

    function test_UnlockCallback_NotPoolManager_Revert() external {
        vm.expectRevert(GemoonController.NotPoolManager.selector);
        vm.prank(creator);
        controller.unlockCallback("");
    }

    /// @dev Invariants of the dev buy for any amount and fee:
    ///  - the buyer gets exactly `memeAmount` and pays exactly `pairIn` = pool price + base fee,
    ///  - the controller keeps no pair token,
    ///  - the fee charged is the base fee and is fully accounted in the hook.
    function testFuzz_DeployToken_DevBuy_ExactOutAtBaseFee(uint256 memeAmount, uint256 swapFeeBips)
        external
    {
        memeAmount = bound(memeAmount, 1e18, MAX_DEV_BUY_X18);
        swapFeeBips = bound(swapFeeBips, 100, 1_000);
        uint256 before = 1_000_000 * PAIR_UNIT;

        DevBuyResult memory r = _deployWithDevBuy(swapFeeBips, memeAmount);
        Trade memory t = r.trade;

        assertEq(IERC20(r.token).balanceOf(creator), memeAmount, "exact out");
        assertEq(r.memeOut, memeAmount);
        assertEq(before - usdg.balanceOf(creator), r.pairIn, "paid pairIn");
        assertEq(r.pairIn, t.pairAmount + t.fee, "pool price plus fee");
        assertEq(t.fee, (t.pairAmount * swapFeeBips) / 10_000, "base fee");
        assertEq(
            usdg.balanceOf(protocolRecipient) + usdg.balanceOf(address(vault))
                + hook.pendingFees(r.token),
            t.fee,
            "fee conserved"
        );
        assertEq(usdg.balanceOf(address(controller)), 0, "controller holds no pair token");
    }

    /// @dev Buying more never costs less.
    function testFuzz_DeployToken_DevBuy_CostMonotonic(uint256 a, uint256 b) external {
        a = bound(a, 1e18, MAX_DEV_BUY_X18);
        b = bound(b, a, MAX_DEV_BUY_X18);

        uint256 snap = vm.snapshotState();
        uint256 costA = _deployWithDevBuy(125, a).pairIn;
        vm.revertToState(snap);
        uint256 costB = _deployWithDevBuy(125, b).pairIn;

        assertLe(costA, costB);
    }
}
