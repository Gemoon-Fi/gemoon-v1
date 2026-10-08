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
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {AssetConfig} from "../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig,
    RewardsConfig,
    INITIAL_SUPPLY_X18,
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
                protocolFeeBips: 25,
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
                creatorRewards: 0, creatorAddress: creator, rewardRecipient: address(0)
            }),
            vaultAssets: assets
        });
    }

    function _deployMeme() internal returns (address token, uint256 positionId) {
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
        bytes32 sig = keccak256("MemeSwapped(address,address,address,bool,uint256,uint256,uint256)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
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

        // 1.25% of every input: 0.25% to the protocol, 1% to the vault.
        uint256 fee = ((first + second) * 125) / 10_000;
        uint256 toProtocol = (fee * 25) / 125;
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

        uint256 fee = (usdgIn * 125) / 10_000;
        uint256 toProtocol = (fee * 25) / 125;
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
}
