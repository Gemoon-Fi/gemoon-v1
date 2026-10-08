// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap-v4-core/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap-v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap-v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {IPositionManager} from "@uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {
    PositionInfo, PositionInfoLibrary
} from "@uniswap-v4-periphery/libraries/PositionInfoLibrary.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployGemoon} from "../../script/GemoonDeploy.sol";
import {GemoonController} from "../../src/contracts/Gemoon.sol";
import {HookManager} from "../../src/contracts/hooks/HookManager.sol";
import {Vault} from "../../src/contracts/vault/Vault.sol";
import {AssetConfig} from "../../src/contracts/interfaces/IVault.sol";
import {
    DeployConfig,
    RewardsConfig,
    INITIAL_SUPPLY_X18,
    TICK_SPACING,
    PRICE_PER_TOKEN
} from "../../src/contracts/interfaces/IGemoon.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../../src/contracts/interfaces/IToken.sol";
import {PriceMath} from "../../src/contracts/utils/Price.sol";
import {MintableToken} from "../mocks/MintableToken.sol";

/// @notice Controller and token deployment against the devnet: a Sepolia fork (chain id 1337)
/// with the canonical Uniswap V4 PoolManager, PositionManager and Permit2. The Gemoon contracts
/// are deployed onto the fork through the deploy script, the pair token is a mock USDG.
/// @dev Env: DEVNET_RPC enables the suite (skipped when empty), DEVNET_BLOCK pins the block,
/// OPERATOR_ADDRESS is the funded devnet account that owns the deployment (default: anvil #0).
/// Nothing is broadcast, the fork lives only inside this test run.
contract ControllerDevnetForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;

    uint256 constant DEVNET_CHAIN_ID = 1337;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant POSITION_MANAGER = 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant ANVIL_ACCOUNT_0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    /// @dev Funded devnet account, becomes the owner of the deployed contracts.
    address DEVNET_ACCOUNT;

    uint256 constant PAIR_UNIT = 1e6; // mock USDG has 6 decimals

    bool forked;

    IPoolManager poolManager = IPoolManager(POOL_MANAGER);
    IPositionManager positionManager = IPositionManager(POSITION_MANAGER);
    MintableToken usdg;
    PoolSwapTest swapRouter;

    DeployGemoon script;
    Vault vault;
    HookManager hook;
    GemoonController controller;

    address creator = makeAddr("creator");
    address trader = makeAddr("trader");
    address protocolRecipient = makeAddr("protocolRecipient");

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
        DEVNET_ACCOUNT = vm.envOr("OPERATOR_ADDRESS", ANVIL_ACCOUNT_0);

        assertEq(block.chainid, DEVNET_CHAIN_ID, "not the devnet");
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager missing");
        assertGt(POSITION_MANAGER.code.length, 0, "PositionManager missing");
        assertGt(PERMIT2.code.length, 0, "Permit2 missing");

        usdg = new MintableToken("USDG", 6);
        swapRouter = new PoolSwapTest(poolManager);

        script = new DeployGemoon();
        address[] memory assets = new address[](1);
        assets[0] = address(usdg);
        DeployGemoon.Deployment memory d = script.deployAll(
            address(script),
            address(script),
            DeployGemoon.Params({
                owner: DEVNET_ACCOUNT,
                proxyAdminOwner: DEVNET_ACCOUNT,
                poolManager: POOL_MANAGER,
                positionManager: POSITION_MANAGER,
                permit2: PERMIT2,
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

    function _config(string memory symbol) internal view returns (DeployConfig memory) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: creator, removable: true});
        AssetConfig[] memory assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 10_000});
        return DeployConfig({
            tokenConfig: TokenConfig({
                imgUrl: "ipfs://meme",
                description: "devnet meme",
                socialMedia: SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}),
                name: symbol,
                symbol: symbol,
                admins: admins
            }),
            rewardsConfig: RewardsConfig({
                creatorRewards: 0, creatorAddress: creator, rewardRecipient: address(0)
            }),
            vaultAssets: assets
        });
    }

    function _deployMeme(string memory symbol) internal returns (address token, uint256 positionId) {
        positionId = positionManager.nextTokenId();
        vm.prank(creator);
        token = controller.deployToken(_config(symbol));
    }

    function _sorted(address token) internal view returns (address token0, address token1) {
        return token < address(usdg) ? (token, address(usdg)) : (address(usdg), token);
    }

    function _poolKey(address token) internal view returns (PoolKey memory) {
        (address token0, address token1) = _sorted(token);
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

    function test_Fork_Deployment_WiredAgainstDevnetUniswap() external view whenForked {
        script.checkWiring(controller, hook, vault);
        assertEq(address(controller.poolManager()), POOL_MANAGER);
        assertEq(address(controller.positionManager()), POSITION_MANAGER);
        assertEq(address(controller.permit2()), PERMIT2);
        assertEq(address(hook.poolManager()), POOL_MANAGER);
    }

    function test_Fork_Deployment_OwnedByDevnetAccount() external whenForked {
        assertGt(DEVNET_ACCOUNT.balance, 0, "devnet account is funded");
        assertEq(hook.owner(), DEVNET_ACCOUNT, "hook owner");
        assertEq(controller.owner(), DEVNET_ACCOUNT, "controller owner");
        assertEq(vault.pendingOwner(), DEVNET_ACCOUNT, "vault pending owner");

        vm.prank(DEVNET_ACCOUNT);
        vault.acceptOwnership();
        assertEq(vault.owner(), DEVNET_ACCOUNT, "vault owner");
    }

    function test_Fork_DeployToken_MintsPositionOnDevnetPositionManager() external whenForked {
        (address token, uint256 positionId) = _deployMeme("MEME");

        assertEq(IERC721(POSITION_MANAGER).ownerOf(positionId), address(controller), "owner");
        assertGt(positionManager.getPositionLiquidity(positionId), 0, "liquidity");
        assertEq(IERC20(token).totalSupply(), INITIAL_SUPPLY_X18, "supply");
        assertLt(IERC20(token).balanceOf(address(controller)), 1e18, "controller keeps dust only");
        assertEq(IERC20(token).balanceOf(creator), 0, "creator gets no tokens");
        assertTrue(vault.isRegistered(token), "vault registered");

        assertEq(IERC20(token).allowance(address(controller), PERMIT2), 0, "erc20 allowance");
        (uint160 amount,,) =
            IAllowanceTransfer(PERMIT2).allowance(address(controller), token, POSITION_MANAGER);
        assertEq(amount, 0, "permit2 allowance");
    }

    function test_Fork_DeployToken_PoolInitializedWithHookAtExpectedPrice() external whenForked {
        (address token, uint256 positionId) = _deployMeme("MEME");
        (address token0, address token1) = _sorted(token);

        (PoolKey memory key, PositionInfo info) = positionManager.getPoolAndPositionInfo(positionId);
        assertEq(address(key.hooks), address(hook), "hook");
        assertEq(key.fee, 0, "lp fee");
        assertEq(key.tickSpacing, TICK_SPACING, "tick spacing");
        assertEq(Currency.unwrap(key.currency0), token0, "currency0");
        assertEq(Currency.unwrap(key.currency1), token1, "currency1");

        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = poolManager.getSlot0(key.toId());
        uint256 memeAmount = PRICE_PER_TOKEN * 10 ** IERC20Metadata(token).decimals();
        uint256 pairUnit = 10 ** usdg.decimals();
        uint160 expected = PriceMath.getSqrtPriceX96(
            token0 == token ? memeAmount : pairUnit,
            token1 == token ? memeAmount : pairUnit
        );
        assertEq(sqrtPriceX96, expected, "initial price");
        assertEq(lpFee, 0, "pool lp fee");

        // one-sided position: the whole range sits on the Meme side of the current tick
        if (token0 == token) assertGt(info.tickLower(), tick, "range above price");
        else assertLt(info.tickUpper(), tick, "range below price");
    }

    function test_Fork_DeployToken_Buy_TraderReceivesMemeAndHookChargesFee() external whenForked {
        (address token,) = _deployMeme("MEME");
        // past the anti-snipe window: the swap pays the base fee
        vm.warp(block.timestamp + hook.DYNAMIC_FEE_THRESHOLD());

        uint256 usdgIn = 1_000 * PAIR_UNIT;
        _buyMeme(token, usdgIn);

        assertGt(IERC20(token).balanceOf(trader), 0, "trader got meme");
        assertEq(usdg.balanceOf(trader), 0, "trader spent everything");
        // fee of the very first swap stays accrued: the PoolManager holds no mock USDG yet
        uint256 fee = (usdgIn * 125) / 10_000;
        assertEq(hook.pendingFees(token), fee, "fee accrued");
    }

    function test_Fork_DeployToken_Twice_IndependentPositions() external whenForked {
        (address a, uint256 idA) = _deployMeme("AAA");
        (address b, uint256 idB) = _deployMeme("BBB");

        assertTrue(a != b, "distinct tokens");
        assertEq(idB, idA + 1, "consecutive positions");
        assertEq(IERC721(POSITION_MANAGER).ownerOf(idA), address(controller));
        assertEq(IERC721(POSITION_MANAGER).ownerOf(idB), address(controller));
        assertTrue(vault.isRegistered(a) && vault.isRegistered(b), "both registered");
    }
}
