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
import {CustomRevert} from "@uniswap-v4-core/libraries/CustomRevert.sol";
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
import {AssetConfig, IVault} from "../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig,
    DevBuyConfig,
    RewardsConfig,
    INITIAL_SUPPLY_X18,
    MAX_DEV_BUY_X18,
    TICK_SPACING,
    INITIAL_MARKET_CAP,
    PRICE_PER_TOKEN as INITIAL_PRICE
} from "../src/contracts/interfaces/IGemoon.sol";
import {PriceMath} from "../src/contracts/utils/Price.sol";
import {StateLibrary} from "@uniswap-v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../src/contracts/interfaces/IToken.sol";
import {IERC1046} from "../src/contracts/interfaces/IERC1046.sol";
import {MintableToken} from "./mocks/MintableToken.sol";

/// @notice End-to-end: real PoolManager, PositionManager and Permit2 deployed in-process, the
/// Gemoon contracts deployed through the deploy script, then a Meme is deployed through the
/// controller and traded against its initial position.
contract ControllerDeployTokenTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant PAIR_UNIT = 1e6; // USDG has 6 decimals
    /// @dev Protocol share of every fee, in bips of the fee: a third.
    uint256 constant PROTOCOL_SHARE = 3_333;

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
            vaultCreatorShareBps: 1_000,
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

    /// @dev ERC-1046 metadata of a deployed Meme is an on-chain base64 JSON data URI.
    function test_DeployToken_TokenURI_DataJsonBase64() external {
        (address token,) = _deployMeme();
        string memory uri = IERC1046(token).tokenURI();
        bytes memory prefix = bytes("data:application/json;base64,");
        assertGt(bytes(uri).length, prefix.length, "has payload");
        for (uint256 i; i < prefix.length; ++i) assertEq(bytes(uri)[i], prefix[i], "prefix");
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

        // 1.25% of every input: a third of it to the protocol, the rest to the vault.
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

    /// @dev Supply 1 000 000 000 at 50 000 Meme per USDG: the start market cap is 20 000 USDG.
    function test_DeployToken_StartMarketCap_TwentyThousandPairTokens() external pure {
        assertEq(INITIAL_MARKET_CAP, 20_000);
        assertEq(INITIAL_PRICE, 50_000, "Meme per one pair token");
        assertEq((INITIAL_SUPPLY_X18 / 1e18) / INITIAL_PRICE, 20_000, "supply / price");
        assertEq(INITIAL_PRICE * INITIAL_MARKET_CAP, INITIAL_SUPPLY_X18 / 1e18, "price is exact");
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
        uint256 memeOut = 1_000_000e18; // ~20 USDG at the start price
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

    function test_DeployToken_CreatorShare_StoredInVault() external {
        DeployConfig memory config = _config();
        config.vaultCreatorShareBps = 3_500;
        vm.prank(creator);
        address token = controller.deployToken(config);
        assertEq(vault.creatorShareBpsOf(token), 3_500);
        assertEq(vault.vaultInfo(token).creatorShareBps, 3_500);
    }

    function test_DeployToken_CreatorShareAboveBps_Revert() external {
        DeployConfig memory config = _config();
        config.vaultCreatorShareBps = 10_001;
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IVault.InvalidCreatorShare.selector, 10_001));
        controller.deployToken(config);
    }

    /// @dev 10% fee: the protocol gets a third of it (~3.33% of the volume), the vault the rest.
    function test_Swap_TenPercentFee_ProtocolGetsOneThirdVaultRest() external {
        address token = _deployMemeWithFee(1_000);
        uint256 first = 1_000 * PAIR_UNIT;
        uint256 second = 400 * PAIR_UNIT;

        _buyMeme(token, first);
        _buyMeme(token, second);

        uint256 total = first + second;
        assertEq(hook.pendingFees(token), 0, "paid out");
        uint256 fee1 = (first * 1_000) / 10_000;
        uint256 fee2 = (second * 1_000) / 10_000;
        uint256 toProtocol = _protocol(fee1) + _protocol(fee2);
        assertEq(usdg.balanceOf(protocolRecipient), toProtocol, "a third of the fee");
        assertEq(usdg.balanceOf(address(vault)), fee1 + fee2 - toProtocol, "the rest");
        assertApproxEqRel(toProtocol, (total * 1_000) / 10_000 / 3, 1e14, "~3.33% of the volume");
        assertApproxEqAbs(
            usdg.balanceOf(protocolRecipient) + usdg.balanceOf(address(vault)),
            (total * 1_000) / 10_000,
            1,
            "10% of the volume"
        );
    }

    /// @dev A third of any fee to the protocol: of 3% it is ~1% of the volume and ~2% to the vault,
    /// of 1% ~0.33% and ~0.67%, of 10% ~3.33% and ~6.67%. 3 333 bips undershoot an exact third
    /// by 0.01% of the fee, which goes to the vault.
    function test_Swap_ProtocolShare_OneThirdOfAnyMemeFee() external {
        uint256[3] memory fees = [uint256(100), 300, 1_000];
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
            uint256 fee = (volume * fees[i]) / 10_000;
            assertEq(toProtocol, _protocol(fee), "protocol part");
            assertEq(toVault, fee - toProtocol, "vault part");
            assertApproxEqRel(toProtocol, fee / 3, 1e14, "a third of the fee");
            assertApproxEqRel(toVault, (fee * 2) / 3, 1e14, "two thirds to the vault");
        }
    }

    /// @dev Invariant over any allowed fee: protocol + vault + accrued == every fee charged, and
    /// the protocol part is always a third (3 333 bips) of the fee, rounded down.
    function testFuzz_Swap_AnySwapFee_ProtocolGetsOneThirdFeeConserved(uint256 swapFeeBips)
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
        assertEq(toProtocol + hook.accruedProtocol(token), protocolPart, "protocol part a third");
        assertLe(protocolPart * 3, charged, "never above a third");
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

    /// @dev 80% of a one-sided position starting at the 20 000 USDG market cap costs about
    /// cap * f / (1 - f) = 4 * 20 000 at the pool price; the position starts one or two tick
    /// spacings above the start price, so slightly more.
    function test_DeployToken_DevBuyAtCap_Succeeds() external {
        DevBuyResult memory r = _deployWithDevBuy(125, MAX_DEV_BUY_X18);
        assertEq(IERC20(r.token).balanceOf(creator), MAX_DEV_BUY_X18);
        assertEq(MAX_DEV_BUY_X18, (INITIAL_SUPPLY_X18 * 8) / 10, "cap is 80% of the supply");
        assertGe(r.trade.pairAmount, 80_000 * PAIR_UNIT, "at least 4x the start market cap");
        assertLt(r.trade.pairAmount, 85_000 * PAIR_UNIT, "start range gap adds a few percent");
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

    // ---------------------------------------------------------------------------------------------
    // Conversion gas: a swap that starts the vault conversion carries enough gas for it, or reverts
    // ---------------------------------------------------------------------------------------------

    /// @dev Meme whose next swap starts the conversion: a first buy funds the PoolManager with pair
    /// token (its own fee stays accrued), then the vault threshold is set to 1 USDG.
    function _memeAboutToConvert() internal returns (address token) {
        (token,) = _deployMeme();
        _buyMeme(token, 1_000 * PAIR_UNIT);
        vm.prank(address(script));
        vault.setConversionThreshold(1 * PAIR_UNIT);
    }

    /// @dev Buys as `trader` through the test router with an explicit gas limit, catching a revert.
    function _buyWithGas(address token, uint256 usdgIn, uint256 gasLimit)
        internal
        returns (bool ok, bytes memory reason)
    {
        usdg.mint(trader, usdgIn);
        PoolKey memory key = _poolKey(token);
        bool usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        vm.startPrank(trader);
        usdg.approve(address(swapRouter), usdgIn);
        try swapRouter.swap{gas: gasLimit}(
            key,
            SwapParams({
                zeroForOne: usdgIs0,
                amountSpecified: -int256(usdgIn),
                sqrtPriceLimitX96: usdgIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        ) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
        vm.stopPrank();
    }

    /// @dev Selector of the hook's own revert inside the PoolManager `WrappedError`, zero if the
    /// revert is something else (e.g. a plain out-of-gas).
    function _hookRevertSelector(bytes memory reason) internal pure returns (bytes4) {
        if (reason.length < 4 || bytes4(reason) != CustomRevert.WrappedError.selector) return 0;
        bytes memory args = new bytes(reason.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = reason[i + 4];
        }
        (,, bytes memory inner,) = abi.decode(args, (address, bytes4, bytes, bytes));
        return inner.length < 4 ? bytes4(0) : bytes4(inner);
    }

    function test_Swap_CrossesThreshold_EnoughGas_ConvertsInSameSwap() external {
        address token = _memeAboutToConvert();

        (bool ok,) = _buyWithGas(token, 100 * PAIR_UNIT, 5_000_000);

        assertTrue(ok, "swap succeeds");
        assertEq(vault.vaultInfo(token).epoch, 1, "epoch closed in the swap");
        assertEq(vault.pendingUSDG(token), 0, "everything converted");
    }

    function test_Swap_CrossesThreshold_LowGas_RevertsWithNotEnoughGasForConversion() external {
        address token = _memeAboutToConvert();
        uint256 accruedBefore = hook.pendingFees(token);

        (bool ok, bytes memory reason) = _buyWithGas(token, 100 * PAIR_UNIT, 300_000);

        assertFalse(ok, "swap reverts");
        assertEq(
            _hookRevertSelector(reason),
            IHookManager.NotEnoughGasForConversion.selector,
            "reverted by the gas guard, not by a plain out-of-gas"
        );
        assertEq(vault.vaultInfo(token).epoch, 0, "nothing converted");
        assertEq(hook.pendingFees(token), accruedBefore, "nothing charged");
        assertEq(usdg.balanceOf(trader), 100 * PAIR_UNIT, "trader keeps the input");
    }

    /// @dev Sells trigger the conversion exactly like buys: every swap ends with the payout.
    function test_Swap_SellCrossesThreshold_ConvertsInSameSwap() external {
        address token = _memeAboutToConvert();
        (bool ok,) = _buyWithGas(token, 1_000 * PAIR_UNIT, 5_000_000);
        assertTrue(ok);
        assertEq(vault.vaultInfo(token).epoch, 1, "the buy converted");
        assertEq(vault.pendingUSDG(token), 0);

        uint256 memeIn = IERC20(token).balanceOf(trader) / 2;
        vm.recordLogs();
        _swap(token, false, -int256(memeIn), bytes(""));
        Trade memory t = _memeSwapped();

        assertFalse(t.isBuy, "a sell");
        assertGt(t.fee * 2 / 3, 1 * PAIR_UNIT, "vault part of the sell fee crosses 1 USDG");
        assertEq(vault.vaultInfo(token).epoch, 2, "the sell converted");
        assertEq(vault.pendingUSDG(token), 0, "everything converted");
    }

    /// @dev A sell with too little gas reverts like a buy.
    function test_Swap_SellLowGas_RevertsWithNotEnoughGasForConversion() external {
        address token = _memeAboutToConvert();
        (bool ok,) = _buyWithGas(token, 1_000 * PAIR_UNIT, 5_000_000);
        assertTrue(ok);

        PoolKey memory key = _poolKey(token);
        bool usdgIs0 = Currency.unwrap(key.currency0) == address(usdg);
        uint256 memeIn = IERC20(token).balanceOf(trader) / 2;
        vm.startPrank(trader);
        IERC20(token).approve(address(swapRouter), memeIn);
        bytes memory reason;
        try swapRouter.swap{gas: 300_000}(
            key,
            SwapParams({
                zeroForOne: !usdgIs0,
                amountSpecified: -int256(memeIn),
                sqrtPriceLimitX96: !usdgIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        ) {
            ok = true;
        } catch (bytes memory r) {
            ok = false;
            reason = r;
        }
        vm.stopPrank();

        assertFalse(ok);
        assertEq(_hookRevertSelector(reason), IHookManager.NotEnoughGasForConversion.selector);
    }

    /// @dev The requirement holds below the threshold too, so a swap estimated now cannot fail
    /// later because other swaps filled the threshold in between.
    function test_Swap_BelowThreshold_LowGas_RevertsToo() external {
        address token = _memeAboutToConvert();
        vm.prank(address(script));
        vault.setConversionThreshold(1_000_000 * PAIR_UNIT);

        (bool ok, bytes memory reason) = _buyWithGas(token, 100 * PAIR_UNIT, 300_000);

        assertFalse(ok);
        assertEq(_hookRevertSelector(reason), IHookManager.NotEnoughGasForConversion.selector);
    }

    /// @dev With automatic conversion off (threshold 0) nothing extra is required.
    function test_Swap_ConversionOff_LowGas_Succeeds() external {
        address token = _memeAboutToConvert();
        vm.prank(address(script));
        vault.setConversionThreshold(0);

        (bool ok,) = _buyWithGas(token, 100 * PAIR_UNIT, 300_000);

        assertTrue(ok, "no conversion possible, no extra gas required");
    }

    /// @dev Smallest gas limit at which the buy succeeds in the current state, like
    /// `eth_estimateGas`. State is restored afterwards.
    function _minGasToBuy(address token, uint256 usdgIn) internal returns (uint256 high) {
        uint256 low = 100_000;
        high = 5_000_000;
        while (high - low > 1_000) {
            uint256 mid = (low + high) / 2;
            uint256 snap = vm.snapshotState();
            (bool ok,) = _buyWithGas(token, usdgIn, mid);
            vm.revertToState(snap);
            if (ok) high = mid;
            else low = mid;
        }
    }

    /// @dev The race from review: the swap is estimated while the threshold is far, other swaps
    /// fill it to just below before ours lands, ours crosses it. With the stale estimate it still
    /// succeeds and converts.
    function test_Swap_EstimatedBelowThreshold_OthersFillIt_EstimateStillEnough() external {
        address token = _memeAboutToConvert();
        (bool ok,) = _buyWithGas(token, 100 * PAIR_UNIT, 5_000_000);
        assertTrue(ok);
        assertEq(vault.vaultInfo(token).epoch, 1, "fresh epoch");
        // vault part: 5000 USDG buy -> 41.67, our 100 USDG buy -> 0.83: only ours crosses 42
        vm.prank(address(script));
        vault.setConversionThreshold(42 * PAIR_UNIT);

        uint256 estimate = _minGasToBuy(token, 100 * PAIR_UNIT);
        (ok,) = _buyWithGas(token, 5_000 * PAIR_UNIT, 5_000_000);
        assertTrue(ok);
        assertEq(vault.vaultInfo(token).epoch, 1, "others stay below the threshold");

        (ok,) = _buyWithGas(token, 100 * PAIR_UNIT, estimate);

        assertTrue(ok, "stale estimate still lands");
        assertEq(vault.vaultInfo(token).epoch, 2, "and converts");
    }

    /// @dev Invariant: whatever gas limit the swapper picks, a swap that crosses the threshold
    /// either closes the epoch or reverts as a whole. A swap never succeeds while its conversion
    /// silently runs out of gas, which is what made gas estimation skip conversions before.
    function testFuzz_Swap_CrossesThreshold_AnyGas_ConvertsOrReverts(uint256 gasLimit) external {
        gasLimit = bound(gasLimit, 150_000, 3_000_000);
        address token = _memeAboutToConvert();
        uint256 accruedBefore = hook.pendingFees(token);

        vm.recordLogs();
        (bool ok,) = _buyWithGas(token, 100 * PAIR_UNIT, gasLimit);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        if (ok) {
            assertEq(vault.vaultInfo(token).epoch, 1, "a successful swap converts");
            bytes32 failed = keccak256("ConversionFailed(address,bytes)");
            for (uint256 i; i < logs.length; ++i) {
                assertTrue(logs[i].topics[0] != failed, "no silent conversion failure");
            }
        } else {
            assertEq(vault.vaultInfo(token).epoch, 0, "reverted swap changes nothing");
            assertEq(hook.pendingFees(token), accruedBefore, "no fee charged");
        }
    }
}
