// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap-v4-core/PoolManager.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap-v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap-v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap-v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {PositionManager} from "@uniswap-v4-periphery/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap-v4-periphery/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap-v4-periphery/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {DeployLens} from "../script/DeployLens.s.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {GemoonLens} from "../src/contracts/lens/GemoonLens.sol";
import {GemoonToken} from "../src/contracts/Token.sol";
import {IGemoonLens} from "../src/contracts/interfaces/IGemoonLens.sol";
import {AssetConfig, VaultInfo} from "../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig,
    DevBuyConfig,
    RewardsConfig,
    TICK_SPACING
} from "../src/contracts/interfaces/IGemoon.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../src/contracts/interfaces/IToken.sol";
import {MintableToken} from "./mocks/MintableToken.sol";
import {
    NoMetadataToken,
    MalformedToken,
    RevertingSupplyToken,
    MockQuoteAdapter
} from "./mocks/LensMocks.sol";

/// @notice Shared setup: real PoolManager, PositionManager and Permit2 in-process, the Gemoon
/// contracts deployed through the deploy script, five allowlisted reward assets (USDG and four
/// mock tokens with different decimals) and a Lens over the deployment.
abstract contract GemoonLensTestBase is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 constant PAIR_UNIT = 1e6; // USDG has 6 decimals
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MintableToken usdg;
    MintableToken[4] rewardTokens;
    PoolManager poolManager;
    PositionManager positionManager;
    PoolSwapTest swapRouter;

    Vault vault;
    HookManager hook;
    GemoonController controller;
    GemoonLens lens;

    address creator = makeAddr("creator");
    address trader = makeAddr("trader");

    function setUp() public virtual {
        usdg = new MintableToken("USDG", 6);
        uint8[4] memory decimals = [uint8(8), 18, 6, 2];
        string[4] memory symbols = ["RWA8", "RWA18", "RWA6", "RWA2"];
        for (uint256 i; i < 4; ++i) {
            rewardTokens[i] = new MintableToken(symbols[i], decimals[i]);
        }

        poolManager = new PoolManager(address(this));
        IAllowanceTransfer permit2 = IAllowanceTransfer(new DeployPermit2().deployPermit2());
        positionManager = new PositionManager(
            poolManager, permit2, 100_000, IPositionDescriptor(address(0)), IWETH9(address(0))
        );
        swapRouter = new PoolSwapTest(poolManager);

        address[] memory allowed = new address[](5);
        allowed[0] = address(usdg);
        for (uint256 i; i < 4; ++i) {
            allowed[i + 1] = address(rewardTokens[i]);
        }
        DeployGemoon script = new DeployGemoon();
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
                protocolRecipient: makeAddr("protocolRecipient"),
                feeBips: 125,
                protocolShareBips: 3_333,
                conversionThreshold: 0,
                swapAdapter: address(0),
                allowedAssets: allowed
            })
        );
        vault = d.vault;
        hook = d.hook;
        controller = d.controller;
        lens = new GemoonLens(
            address(controller), address(vault), address(hook), address(poolManager)
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev USDG only: conversion needs no swap adapter.
    function _usdgAsset() internal view returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 10_000});
    }

    /// @dev All five allowlisted assets, weights summing to 10000.
    function _fiveAssets() internal view returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](5);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 2_000});
        for (uint256 i; i < 4; ++i) {
            assets[i + 1] = AssetConfig({token: address(rewardTokens[i]), weightBps: 2_000});
        }
    }

    function _string(uint256 length, bytes1 fill) internal pure returns (string memory) {
        bytes memory b = new bytes(length);
        for (uint256 i; i < length; ++i) {
            b[i] = fill;
        }
        return string(b);
    }

    /// @dev Deploys a Meme as `creator` and moves past the anti-snipe window.
    function _deployMeme(
        AssetConfig[] memory assets,
        string memory description,
        string memory image
    ) internal returns (address meme) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: creator, removable: true});
        DeployConfig memory config = DeployConfig({
            tokenConfig: TokenConfig({
                imgUrl: image,
                description: description,
                socialMedia: _social(),
                name: "Meme",
                symbol: "MEME",
                admins: admins
            }),
            rewardsConfig: RewardsConfig({
                swapFeeBips: 125, creatorAddress: creator, rewardRecipient: address(0)
            }),
            vaultAssets: assets,
            vaultCreatorShareBps: 1_000,
            devBuy: DevBuyConfig({memeAmount: 0, maxPairIn: 0})
        });
        vm.prank(creator);
        meme = controller.deployToken(config);
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());
    }

    function _social() internal pure returns (SocialMedia memory) {
        return SocialMedia({
            farcaster: "fc/meme",
            twitterX: "https://x.com/meme",
            telegram: "",
            website: "https://meme.xyz"
        });
    }

    function _deployMeme(AssetConfig[] memory assets) internal returns (address) {
        return _deployMeme(assets, "test meme", "ipfs://meme");
    }

    function _poolKey(address meme) internal view returns (PoolKey memory) {
        (address token0, address token1) =
            meme < address(usdg) ? (meme, address(usdg)) : (address(usdg), meme);
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev `trader` buys Meme for `usdgIn` USDG, exact input.
    function _buy(address meme, uint256 usdgIn) internal {
        usdg.mint(trader, usdgIn);
        PoolKey memory key = _poolKey(meme);
        bool zeroForOne = Currency.unwrap(key.currency0) == address(usdg);
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

    function _stake(address meme, uint256 amount) internal {
        vm.startPrank(trader);
        IERC20(meme).approve(address(vault), amount);
        vault.stake(meme, amount);
        vm.stopPrank();
    }

    function _one(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _view(address meme, address account)
        internal
        view
        returns (IGemoonLens.TokenView memory)
    {
        return lens.tokens(_one(meme), account)[0];
    }

    function _hash(IGemoonLens.TokenView memory v) internal pure returns (bytes32) {
        return keccak256(abi.encode(v));
    }
}

/// @notice Behaviour of every Lens function, ТЗ section 6 cases 1-8 and 10 plus fuzz.
contract GemoonLensTest is GemoonLensTestBase {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    function test_Constructor_ZeroAddress_Revert() external {
        address a = makeAddr("a");
        vm.expectRevert(IGemoonLens.ZeroAddress.selector);
        new GemoonLens(address(0), a, a, a);
        vm.expectRevert(IGemoonLens.ZeroAddress.selector);
        new GemoonLens(a, address(0), a, a);
        vm.expectRevert(IGemoonLens.ZeroAddress.selector);
        new GemoonLens(a, a, address(0), a);
        vm.expectRevert(IGemoonLens.ZeroAddress.selector);
        new GemoonLens(a, a, a, address(0));
    }

    function test_Constructor_StoresAddresses() external view {
        assertEq(lens.controller(), address(controller));
        assertEq(lens.vault(), address(vault));
        (,,,,,, address hook_, address poolManager_) = lens.protocol();
        assertEq(hook_, address(hook));
        assertEq(poolManager_, address(poolManager));
    }

    // ---------------------------------------------------------------------------------------------
    // 1. Registered Meme, no account
    // ---------------------------------------------------------------------------------------------

    function test_Tokens_RegisteredMemeNoAccount_MatchesDirectReads() external {
        address meme = _deployMeme(_fiveAssets(), "a description", "ipfs://image");
        _buy(meme, 1_000 * PAIR_UNIT); // fee accrued in the hook, not paid out yet
        _buy(meme, 500 * PAIR_UNIT); // pays out both: USDG credited to the creator, open epoch
        vm.prank(trader);
        IERC20(meme).transfer(DEAD, 12_345e18);

        IGemoonLens.TokenView memory v = _view(meme, address(0));
        assertEq(v.meme, meme);

        // meta
        assertTrue(v.meta.ok);
        assertEq(v.meta.name, "Meme");
        assertEq(v.meta.symbol, "MEME");
        assertEq(v.meta.decimals, 18);
        assertTrue(v.meta.decimalsOk);
        assertEq(v.meta.description, "a description");
        assertEq(v.meta.image, "ipfs://image");
        assertEq(v.meta.creator, creator);
        assertTrue(v.meta.creatorOk);
        assertTrue(v.meta.socialOk);
        assertEq(abi.encode(v.meta.social), abi.encode(GemoonToken(meme).getSocialMedia()));
        assertEq(v.meta.social.twitterX, "https://x.com/meme");

        // market
        PoolId id = _poolKey(meme).toId();
        (uint160 sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(id);
        assertEq(v.market.totalSupply, IERC20(meme).totalSupply());
        assertEq(
            v.market.burned,
            IERC20(meme).balanceOf(address(0)) + IERC20(meme).balanceOf(DEAD)
        );
        assertEq(v.market.burned, 12_345e18);
        assertTrue(v.market.burnedOk);
        assertEq(v.market.poolId, PoolId.unwrap(id));
        assertEq(v.market.sqrtPriceX96, sqrtPriceX96);
        assertGt(v.market.sqrtPriceX96, 0);
        assertEq(v.market.memeIsToken0, meme < address(usdg));
        assertEq(v.market.pendingFees, hook.pendingFees(meme));
        assertTrue(v.market.pendingFeesOk);

        // vault
        VaultInfo memory info = vault.vaultInfo(meme);
        assertTrue(v.vault.registered);
        assertTrue(v.vault.registeredOk);
        assertEq(v.vault.registeredAt, info.registeredAt);
        assertEq(v.vault.totalStaked, info.totalStaked);
        assertEq(v.vault.creator, info.creator);
        assertEq(v.vault.pendingStakerUSDG, info.pendingStakerUSDG);
        assertEq(v.vault.pendingCreatorUSDG, info.pendingCreatorUSDG);
        assertGt(v.vault.pendingCreatorUSDG, 0);
        assertEq(v.vault.lastConversionFailure, info.lastConversionFailure);
        assertEq(v.vault.creatorShareBps, info.creatorShareBps);
        assertEq(v.vault.creatorShareBps, 1_000);

        AssetConfig[] memory configs = vault.getAssets(meme);
        assertEq(v.vault.assets.length, 5);
        for (uint256 i; i < configs.length; ++i) {
            assertEq(v.vault.assets[i].token, configs[i].token);
            assertEq(v.vault.assets[i].weightBps, configs[i].weightBps);
            MintableToken asset = MintableToken(configs[i].token);
            assertEq(v.vault.assets[i].symbol, asset.symbol());
            assertTrue(v.vault.assets[i].symbolOk);
            assertEq(v.vault.assets[i].decimals, asset.decimals());
            assertTrue(v.vault.assets[i].decimalsOk);
        }

        // no account: position untouched
        assertEq(abi.encode(v.position), abi.encode(_emptyPosition()));
    }

    /// @dev The first buy of a pool cannot be paid out (the PoolManager holds no USDG yet), so its
    /// fee stays in the hook.
    function test_Tokens_FeeAccruedInHook_PendingFeesMatchHook() external {
        address meme = _deployMeme(_usdgAsset());
        _buy(meme, 1_000 * PAIR_UNIT);

        uint256 pending = _view(meme, address(0)).market.pendingFees;
        assertEq(pending, hook.pendingFees(meme));
        assertGt(pending, 0);
    }

    function test_Tokens_AssetWithBrokenMetadata_AssetFlagsFalse() external {
        MalformedToken broken = new MalformedToken();
        vm.prank(vault.owner());
        vault.setAssetAllowed(address(broken), true);
        AssetConfig[] memory assets = new AssetConfig[](2);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 5_000});
        assets[1] = AssetConfig({token: address(broken), weightBps: 5_000});
        address meme = _deployMeme(assets);

        IGemoonLens.Asset[] memory a = _view(meme, address(0)).vault.assets;
        assertTrue(a[0].symbolOk);
        assertTrue(a[0].decimalsOk);
        assertEq(a[0].decimals, 6);
        assertFalse(a[1].symbolOk); // symbol() reverts
        assertEq(a[1].symbol, "");
        assertFalse(a[1].decimalsOk); // 256 does not fit uint8
        assertEq(a[1].decimals, 0);
        assertEq(a[1].weightBps, 5_000);
    }

    function test_Tokens_HookPendingFeesReverts_PendingFeesOkFalse() external {
        address meme = _deployMeme(_usdgAsset());
        vm.mockCallRevert(address(hook), abi.encodeWithSelector(hook.pendingFees.selector), "");

        IGemoonLens.TokenView memory v = _view(meme, address(0));
        assertFalse(v.market.pendingFeesOk);
        assertEq(v.market.pendingFees, 0);
        assertTrue(v.market.burnedOk);
        assertTrue(v.vault.registered);
    }

    function test_Tokens_IsRegisteredReverts_RegisteredOkFalse() external {
        address meme = _deployMeme(_usdgAsset());
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(vault.isRegistered.selector), "");

        IGemoonLens.TokenView memory v = _view(meme, trader);
        assertFalse(v.vault.registeredOk);
        assertFalse(v.vault.registered);
        assertEq(v.vault.totalStaked, 0);
        assertEq(v.position.staked, 0); // vault reads skipped
        assertTrue(v.meta.ok);
    }

    // ---------------------------------------------------------------------------------------------
    // 2. Account with a stake
    // ---------------------------------------------------------------------------------------------

    function test_Tokens_StakerAccount_PositionMatchesVault() external {
        address meme = _deployMeme(_usdgAsset());
        _buy(meme, 1_000 * PAIR_UNIT);
        uint256 bought = IERC20(meme).balanceOf(trader);
        _stake(meme, bought / 2);
        vm.prank(trader);
        IERC20(meme).approve(address(vault), 777);

        _buy(meme, 1_000 * PAIR_UNIT); // pays out the fees, staker credited
        vault.convertFees(meme); // credits become claimable rewards
        _buy(meme, 1_000 * PAIR_UNIT); // fresh credit in the open epoch

        IGemoonLens.TokenView memory v = _view(meme, trader);
        IGemoonLens.Position memory p = v.position;
        assertEq(p.balance, IERC20(meme).balanceOf(trader));
        assertEq(p.staked, vault.stakedOf(meme, trader));
        assertEq(p.staked, bought / 2);
        assertEq(p.pendingCredit, vault.pendingCreditOf(meme, trader));
        assertGt(p.pendingCredit, 0);
        assertEq(p.allowance, IERC20(meme).allowance(trader, address(vault)));
        assertEq(p.allowance, 777);

        (address[] memory assets, uint256[] memory amounts) = vault.earned(meme, trader);
        assertEq(p.earnedAssets, assets);
        assertEq(p.earnedAmounts, amounts);
        assertGt(p.earnedAmounts[0], 0);
        assertEq(v.vault.totalStaked, bought / 2);
    }

    // ---------------------------------------------------------------------------------------------
    // 3. Unregistered token, 6. pool not created
    // ---------------------------------------------------------------------------------------------

    function test_Tokens_UnregisteredToken_VaultZeroNoRevert() external {
        MintableToken token = new MintableToken("PLAIN", 9);
        token.mint(trader, 5e9);

        IGemoonLens.TokenView memory v = _view(address(token), trader);
        assertTrue(v.meta.ok);
        assertEq(v.meta.symbol, "PLAIN");
        assertEq(v.meta.decimals, 9);
        assertFalse(v.meta.creatorOk);

        assertFalse(v.vault.registered);
        assertTrue(v.vault.registeredOk); // the vault answered: definitely no vault
        IGemoonLens.VaultPublic memory empty;
        empty.registeredOk = true;
        assertEq(abi.encode(v.vault), abi.encode(empty));

        // token reads still answer, vault reads are skipped
        assertEq(v.position.balance, 5e9);
        assertEq(v.position.staked, 0);
        assertEq(v.position.pendingCredit, 0);
        assertEq(v.position.earnedAssets.length, 0);
        assertEq(v.position.earnedAmounts.length, 0);
    }

    /// @dev The hook is not upgradeable: after it is replaced, new Memes trade in pools keyed
    /// with the new hook and old Memes keep theirs. The Lens reads each through its own hook.
    function test_Tokens_HookReplaced_EachMemeReadThroughItsHook() external {
        address oldMeme = _deployMeme(_usdgAsset());

        DeployGemoon script = new DeployGemoon();
        HookManager next = script.deployHook(
            address(script),
            GemoonDeployBase.HookDeployParams({
                owner: address(this),
                poolManager: address(poolManager),
                pairToken: address(usdg),
                protocolRecipient: makeAddr("protocolRecipient"),
                vault: address(vault),
                controller: address(controller),
                feeBips: 125,
                protocolShareBips: 3_333
            })
        );
        vm.startPrank(controller.owner());
        vault.setHook(address(next));
        controller.setHook(address(next));
        vm.stopPrank();
        address newMeme = _deployMeme(_usdgAsset());

        PoolKey memory newKey = _poolKey(newMeme);
        newKey.hooks = IHooks(address(next));
        IGemoonLens.TokenView memory v = _view(newMeme, address(0));
        assertEq(v.market.poolId, PoolId.unwrap(newKey.toId()), "pool of the new hook");
        assertGt(v.market.sqrtPriceX96, 0, "that pool exists");
        assertTrue(v.market.pendingFeesOk);

        v = _view(oldMeme, address(0));
        assertEq(v.market.poolId, PoolId.unwrap(_poolKey(oldMeme).toId()), "old hook kept");
        assertGt(v.market.sqrtPriceX96, 0);
    }

    function test_Tokens_PoolNotCreated_SqrtPriceZeroPoolIdComputed() external {
        MintableToken token = new MintableToken("NOPOOL", 18);

        IGemoonLens.TokenView memory v = _view(address(token), address(0));
        assertEq(v.market.sqrtPriceX96, 0);
        assertEq(v.market.poolId, PoolId.unwrap(_poolKey(address(token)).toId()));
        assertEq(v.market.memeIsToken0, address(token) < address(usdg));
    }

    // ---------------------------------------------------------------------------------------------
    // 4. EOA, 5. tokens without optional getters or with malformed return data
    // ---------------------------------------------------------------------------------------------

    function test_Tokens_EoaInBatch_MetaNotOkOthersCorrect() external {
        address memeA = _deployMeme(_usdgAsset());
        address memeB = _deployMeme(_fiveAssets());
        address eoa = makeAddr("eoa");

        address[] memory list = new address[](3);
        (list[0], list[1], list[2]) = (memeA, eoa, memeB);
        IGemoonLens.TokenView[] memory views = lens.tokens(list, trader);

        assertEq(views.length, 3);
        assertEq(views[1].meme, eoa);
        assertFalse(views[1].meta.ok);
        assertEq(views[1].market.totalSupply, 0);
        assertFalse(views[1].vault.registered);
        assertEq(views[1].market.poolId, PoolId.unwrap(_poolKey(eoa).toId()));
        assertEq(_hash(views[0]), _hash(_view(memeA, trader)));
        assertEq(_hash(views[2]), _hash(_view(memeB, trader)));
    }

    function test_Tokens_TokenWithoutCreatorOrDecimals_FlagsFalse() external {
        NoMetadataToken token = new NoMetadataToken();

        IGemoonLens.TokenView memory v = _view(address(token), trader);
        assertTrue(v.meta.ok);
        assertEq(v.market.totalSupply, 1_000e18);
        assertFalse(v.meta.decimalsOk);
        assertEq(v.meta.decimals, 0);
        assertFalse(v.meta.creatorOk);
        assertEq(v.meta.creator, address(0));
        assertEq(v.meta.name, "");
        assertEq(v.meta.symbol, "");
        assertEq(v.meta.description, "");
        assertEq(v.meta.image, "");
        assertFalse(v.meta.socialOk);
        assertTrue(v.market.burnedOk); // balanceOf exists
        assertEq(v.position.allowance, 0); // no allowance(): read failed, zero
    }

    function test_Tokens_MalformedReturnData_FlagsFalseNoRevert() external {
        MalformedToken token = new MalformedToken();
        address meme = _deployMeme(_usdgAsset());

        address[] memory list = new address[](2);
        (list[0], list[1]) = (address(token), meme);
        IGemoonLens.TokenView[] memory views = lens.tokens(list, trader);

        IGemoonLens.TokenMeta memory m = views[0].meta;
        assertTrue(m.ok);
        assertEq(views[0].market.totalSupply, 7);
        assertEq(m.name, ""); // bytes32, not a string
        assertEq(m.symbol, ""); // reverts
        assertFalse(m.decimalsOk); // 256 does not fit uint8
        assertFalse(m.creatorOk); // not an address
        assertEq(m.description, ""); // length past the data
        assertEq(m.image, ""); // offset past the data
        assertFalse(m.socialOk); // one member offset past the data
        assertEq(abi.encode(m.social), abi.encode(SocialMedia("", "", "", "")));
        assertFalse(views[0].market.burnedOk); // no balanceOf
        assertEq(views[0].market.burned, 0);
        assertEq(_hash(views[1]), _hash(_view(meme, trader)));
    }

    function test_Tokens_TotalSupplyReverts_MetaNotOk() external {
        RevertingSupplyToken token = new RevertingSupplyToken();

        IGemoonLens.TokenView memory v = _view(address(token), trader);
        assertFalse(v.meta.ok);
        assertEq(v.meta.name, "");
        assertEq(abi.encode(v.position), abi.encode(_emptyPosition()));
    }

    function test_Tokens_EmptyInput_EmptyOutput() external view {
        assertEq(lens.tokens(new address[](0), trader).length, 0);
        (IGemoonLens.TokenMarket[] memory m, uint256[] memory s) = lens.markets(new address[](0));
        assertEq(m.length, 0);
        assertEq(s.length, 0);
    }

    function test_Tokens_LongStrings_ReturnedWhole() external {
        string memory description = _string(2_048, "d");
        string memory image = _string(2_048, "i");
        address meme = _deployMeme(_usdgAsset(), description, image);

        IGemoonLens.TokenView memory v = _view(meme, address(0));
        assertEq(v.meta.description, description);
        assertEq(v.meta.image, image);
    }

    // ---------------------------------------------------------------------------------------------
    // 10. Order and duplicates
    // ---------------------------------------------------------------------------------------------

    function test_Tokens_DuplicatesAndOrder_ThreeElementsSameOrder() external {
        address a = _deployMeme(_usdgAsset());
        address b = _deployMeme(_fiveAssets());

        address[] memory list = new address[](3);
        (list[0], list[1], list[2]) = (a, b, a);
        IGemoonLens.TokenView[] memory views = lens.tokens(list, trader);

        assertEq(views.length, 3);
        assertEq(views[0].meme, a);
        assertEq(views[1].meme, b);
        assertEq(views[2].meme, a);
        assertEq(_hash(views[0]), _hash(views[2]));
        assertEq(views[1].vault.assets.length, 5);
    }

    // ---------------------------------------------------------------------------------------------
    // markets / totalStaked
    // ---------------------------------------------------------------------------------------------

    function test_Markets_MatchTokensMarketAndVaultTotalStaked() external {
        address a = _deployMeme(_usdgAsset());
        address b = _deployMeme(_fiveAssets());
        _buy(a, 1_000 * PAIR_UNIT);
        _stake(a, IERC20(a).balanceOf(trader) / 3);

        address[] memory list = new address[](3);
        (list[0], list[1], list[2]) = (a, makeAddr("eoa"), b);
        (IGemoonLens.TokenMarket[] memory market, uint256[] memory staked) = lens.markets(list);
        IGemoonLens.TokenView[] memory views = lens.tokens(list, address(0));

        for (uint256 i; i < list.length; ++i) {
            assertEq(abi.encode(market[i]), abi.encode(views[i].market));
            assertEq(staked[i], vault.totalStaked(list[i]));
        }
        assertGt(staked[0], 0);
        assertEq(lens.totalStaked(list), staked);
    }

    // ---------------------------------------------------------------------------------------------
    // 7. quotes
    // ---------------------------------------------------------------------------------------------

    function test_Quotes_AssetWithoutRoute_OkFalseOthersQuoted() external {
        MockQuoteAdapter adapter = new MockQuoteAdapter();
        adapter.setRate(address(rewardTokens[0]), 3);
        adapter.setRate(address(rewardTokens[2]), 5);
        vm.prank(vault.owner());
        vault.setSwapAdapter(address(adapter));

        address[] memory assets = new address[](4);
        (assets[0], assets[1], assets[2], assets[3]) =
            (address(rewardTokens[0]), address(rewardTokens[1]), address(rewardTokens[2]), address(usdg));
        (uint256[] memory amounts, bool[] memory ok) = lens.quotes(assets, 100);

        assertTrue(ok[0]);
        assertEq(amounts[0], 300);
        assertFalse(ok[1]); // no route: adapter reverts
        assertEq(amounts[1], 0);
        assertTrue(ok[2]);
        assertEq(amounts[2], 500);
        assertTrue(ok[3]); // USDG is credited without a swap
        assertEq(amounts[3], 100);
    }

    function test_Quotes_NoAdapter_AllOkFalseExceptUsdg() external view {
        address[] memory assets = new address[](2);
        (assets[0], assets[1]) = (address(rewardTokens[0]), address(usdg));
        (uint256[] memory amounts, bool[] memory ok) = lens.quotes(assets, 1e6);

        assertEq(vault.swapAdapter(), address(0));
        assertFalse(ok[0]);
        assertEq(amounts[0], 0);
        assertTrue(ok[1]);
        assertEq(amounts[1], 1e6);
    }

    function test_Quotes_AdapterIsEoa_OkFalseNoRevert() external {
        vm.prank(vault.owner());
        vault.setSwapAdapter(makeAddr("eoaAdapter"));

        (, bool[] memory ok) = lens.quotes(_one(address(rewardTokens[0])), 1e6);
        assertFalse(ok[0]);
    }

    // ---------------------------------------------------------------------------------------------
    // 8. protocol, creator
    // ---------------------------------------------------------------------------------------------

    function test_Protocol_MatchesVaultAndHook() external {
        vm.prank(vault.owner());
        vault.setConversionThreshold(5e6);
        (
            address usdg_,
            uint8 usdgDecimals,
            string memory usdgSymbol,
            address swapAdapter,
            uint256 conversionThreshold,
            uint256 conversionCooldown,
            address hook_,
            address poolManager_
        ) = lens.protocol();

        assertEq(usdg_, vault.usdg());
        assertEq(usdg_, Currency.unwrap(hook.pairToken()));
        assertEq(usdgDecimals, 6);
        assertEq(usdgSymbol, "USDG");
        assertEq(swapAdapter, vault.swapAdapter());
        assertEq(conversionThreshold, 5e6);
        assertEq(conversionCooldown, vault.CONVERSION_COOLDOWN());
        assertEq(hook_, address(hook));
        assertEq(poolManager_, address(poolManager));
    }

    function test_Creator_MatchesVault() external {
        address meme = _deployMeme(_usdgAsset());
        _buy(meme, 1_000 * PAIR_UNIT);
        _buy(meme, 1_000 * PAIR_UNIT);
        vault.convertFees(meme);

        (address creatorOf, address[] memory assets, uint256[] memory accrued) = lens.creator(meme);
        (address[] memory expAssets, uint256[] memory expAccrued) = vault.creatorAccrued(meme);
        assertEq(creatorOf, vault.creatorOf(meme));
        assertEq(creatorOf, creator);
        assertEq(assets, expAssets);
        assertEq(accrued, expAccrued);
        assertGt(accrued[0], 0);
    }

    function test_Creator_Unregistered_Zero() external {
        (address creatorOf, address[] memory assets, uint256[] memory accrued) =
            lens.creator(makeAddr("unknown"));
        assertEq(creatorOf, address(0));
        assertEq(assets.length, 0);
        assertEq(accrued.length, 0);
    }

    function test_Creators_Batch_EachEqualsCreator() external {
        address a = _deployMeme(_usdgAsset());
        address b = _deployMeme(_fiveAssets());
        _buy(a, 1_000 * PAIR_UNIT);
        _buy(a, 1_000 * PAIR_UNIT);
        vault.convertFees(a);

        address[] memory list = new address[](4);
        (list[0], list[1], list[2], list[3]) = (a, makeAddr("unknown"), b, a);
        IGemoonLens.CreatorRewards[] memory rewards = lens.creators(list);

        assertEq(rewards.length, 4);
        for (uint256 i; i < list.length; ++i) {
            (address creatorOf, address[] memory assets, uint256[] memory accrued) =
                lens.creator(list[i]);
            assertTrue(rewards[i].ok);
            assertEq(rewards[i].creatorOf, creatorOf);
            assertEq(rewards[i].assets, assets);
            assertEq(rewards[i].accrued, accrued);
        }
        assertEq(rewards[0].creatorOf, creator);
        assertGt(rewards[0].accrued[0], 0);
        assertEq(rewards[1].creatorOf, address(0));
        assertEq(rewards[2].assets.length, 5);
    }

    function test_Creators_VaultReverts_OkFalseNoRevert() external {
        address meme = _deployMeme(_usdgAsset());
        vm.mockCallRevert(
            address(vault), abi.encodeWithSelector(vault.creatorAccrued.selector), ""
        );

        IGemoonLens.CreatorRewards[] memory rewards = lens.creators(_one(meme));
        assertFalse(rewards[0].ok);
        assertEq(rewards[0].creatorOf, creator); // creatorOf still answered
        assertEq(rewards[0].assets.length, 0);
    }

    function testFuzz_Creators_AnyAddresses_OnePerInput(address[] memory list) external view {
        vm.assume(list.length <= 16);
        IGemoonLens.CreatorRewards[] memory rewards = lens.creators(list);
        assertEq(rewards.length, list.length);
        for (uint256 i; i < list.length; ++i) {
            assertTrue(rewards[i].ok);
            assertEq(rewards[i].creatorOf, vault.creatorOf(list[i]));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy script
    // ---------------------------------------------------------------------------------------------

    function test_DeployLens_Create2_DeterministicAndRepeatable() external {
        DeployLens script = new DeployLens();
        DeployLens.Params memory params = DeployLens.Params({
            controller: address(controller),
            vault: address(vault),
            hook: address(hook),
            poolManager: address(poolManager),
            salt: bytes32(uint256(42))
        });
        address expected = script.predict(address(script), params);

        GemoonLens first = script.deploy(address(script), params);
        assertEq(address(first), expected);
        assertEq(first.vault(), address(vault));

        // Second run finds the code and deploys nothing.
        GemoonLens second = script.deploy(address(script), params);
        assertEq(address(second), expected);
    }

    function test_DeployLens_WiringMismatch_Revert() external {
        DeployLens script = new DeployLens();
        DeployLens.Params memory params = DeployLens.Params({
            controller: address(controller),
            vault: address(vault),
            hook: address(hook),
            poolManager: makeAddr("otherPoolManager"),
            salt: bytes32(0)
        });
        vm.expectRevert(abi.encodeWithSelector(DeployLens.WiringMismatch.selector, "hook.poolManager"));
        script.deploy(address(script), params);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// @dev Any addresses (precompiles, cheatcodes, EOAs, contracts) give a result per input and
    /// never revert the batch.
    function testFuzz_Tokens_AnyAddresses_NeverRevertsOnePerInput(
        address[] memory list,
        address account
    ) external {
        vm.assume(list.length <= 16);
        address meme = _deployMeme(_usdgAsset());
        if (list.length > 0) list[0] = meme;

        IGemoonLens.TokenView[] memory views = lens.tokens(list, account);
        (IGemoonLens.TokenMarket[] memory market, uint256[] memory staked) = lens.markets(list);
        assertEq(views.length, list.length);
        assertEq(market.length, list.length);
        assertEq(staked.length, list.length);
        for (uint256 i; i < list.length; ++i) {
            assertEq(views[i].meme, list[i]);
            // Every field but `ok` is zero for a non-token.
            if (!views[i].meta.ok) assertFalse(views[i].vault.registered);
        }
        if (list.length > 0) assertTrue(views[0].vault.registered);
    }

    /// @dev Batch element i equals the single-element call for input i, whatever the mix of
    /// Memes, plain tokens, broken tokens and EOAs, in any order with repeats.
    function testFuzz_Tokens_BatchElementEqualsSingleCall(uint8[] memory picks) external {
        vm.assume(picks.length <= 12);
        address[6] memory pool = [
            _deployMeme(_usdgAsset()),
            _deployMeme(_fiveAssets()),
            address(new MintableToken("PLAIN", 6)),
            address(new MalformedToken()),
            address(new NoMetadataToken()),
            makeAddr("eoa")
        ];
        _buy(pool[0], 1_000 * PAIR_UNIT);

        address[] memory list = new address[](picks.length);
        for (uint256 i; i < picks.length; ++i) {
            list[i] = pool[picks[i] % pool.length];
        }
        IGemoonLens.TokenView[] memory views = lens.tokens(list, trader);
        for (uint256 i; i < list.length; ++i) {
            assertEq(_hash(views[i]), _hash(_view(list[i], trader)));
        }
    }

    /// @dev Burned amount follows transfers to both burn addresses.
    function testFuzz_Tokens_Burned_SumOfBurnAddresses(uint256 toDead) external {
        address meme = _deployMeme(_usdgAsset());
        _buy(meme, 1_000 * PAIR_UNIT);
        toDead = bound(toDead, 0, IERC20(meme).balanceOf(trader));
        vm.prank(trader);
        IERC20(meme).transfer(DEAD, toDead);

        assertEq(_view(meme, address(0)).market.burned, toDead);
    }

    function _emptyPosition() internal pure returns (IGemoonLens.Position memory p) {}
}

/// @notice ТЗ section 6 case 9: gas of the largest batches. The Memes are deployed in setUp, so
/// every account and slot is cold in the measured call, as in a real `eth_call`.
/// @dev Every `tokens` batch: 5 reward assets per Meme, the account holding and staking each one.
/// Two string sizes: realistic (280-byte description, 120-byte image URL) for the 70-token limit,
/// and the 2 KB worst case, which sets the safe chunk size.
contract GemoonLensGasTest is GemoonLensTestBase {
    uint256 constant TOKENS_BATCH = 70;
    uint256 constant SAFE_CHUNK_2KB = 50;
    uint256 constant MARKETS_BATCH = 200;
    uint256 constant TOKENS_GAS_LIMIT = 30_000_000;
    uint256 constant NODE_GAS_CAP = 50_000_000;
    uint256 constant MARKETS_GAS_LIMIT = 15_000_000;

    address[] realistic;
    address[] heavy;
    address[] all;

    function setUp() public override {
        super.setUp();
        _deployStaked(realistic, _string(280, "d"), _string(120, "i"));
        _deployStaked(heavy, _string(2_048, "d"), _string(2_048, "i"));
        while (all.length < MARKETS_BATCH) {
            all.push(_deployMeme(_usdgAsset()));
        }
    }

    function _deployStaked(address[] storage list, string memory description, string memory image)
        internal
    {
        for (uint256 i; i < TOKENS_BATCH; ++i) {
            address meme = _deployMeme(_fiveAssets(), description, image);
            _buy(meme, 100 * PAIR_UNIT);
            _stake(meme, IERC20(meme).balanceOf(trader) / 2);
            list.push(meme);
            all.push(meme);
        }
    }

    function _measureTokens(address[] memory list, address account, string memory label)
        internal
        view
        returns (uint256 used)
    {
        uint256 start = gasleft();
        IGemoonLens.TokenView[] memory views = lens.tokens(list, account);
        used = start - gasleft();
        console.log(label, used);
        assertEq(views.length, list.length);
        assertEq(views[list.length - 1].vault.assets.length, 5);
        if (account != address(0)) assertGt(views[0].position.staked, 0);
    }

    function _first(address[] storage list, uint256 n) internal view returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = list[i];
        }
    }

    function test_Gas_Tokens70WithAccount_Below30M() external view {
        uint256 used = _measureTokens(realistic, trader, "tokens(70, account) gas:");
        assertLt(used, TOKENS_GAS_LIMIT);
    }

    function test_Gas_Tokens70NoAccount_Below30M() external view {
        uint256 used = _measureTokens(realistic, address(0), "tokens(70, 0x0) gas:");
        assertLt(used, TOKENS_GAS_LIMIT);
    }

    /// @dev 2 KB strings: 70 Memes exceed 30M but stay under the usual 50M node cap.
    function test_Gas_Tokens70WithAccount2KbStrings_BelowNodeCap() external view {
        uint256 used = _measureTokens(heavy, trader, "tokens(70, account), 2 KB strings, gas:");
        assertLt(used, NODE_GAS_CAP);
    }

    /// @dev Largest chunk of 2 KB-string Memes under 30M: the chunk size README recommends.
    function test_Gas_Tokens50WithAccount2KbStrings_Below30M() external view {
        uint256 used = _measureTokens(
            _first(heavy, SAFE_CHUNK_2KB), trader, "tokens(50, account), 2 KB strings, gas:"
        );
        assertLt(used, TOKENS_GAS_LIMIT);
    }

    function test_Gas_Markets200_Below15M() external view {
        uint256 start = gasleft();
        (IGemoonLens.TokenMarket[] memory market,) = lens.markets(all);
        uint256 used = start - gasleft();
        console.log("markets(200) gas:", used);
        assertEq(market.length, MARKETS_BATCH);
        assertLt(used, MARKETS_GAS_LIMIT);
    }

    function test_Gas_TotalStaked200_Below15M() external view {
        uint256 start = gasleft();
        uint256[] memory staked = lens.totalStaked(all);
        uint256 used = start - gasleft();
        console.log("totalStaked(200) gas:", used);
        assertEq(staked.length, MARKETS_BATCH);
        assertLt(used, MARKETS_GAS_LIMIT);
    }
}
