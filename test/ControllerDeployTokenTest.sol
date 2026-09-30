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
    DeployConfig, RewardsConfig, INITIAL_SUPPLY_X18, TICK_SPACING
} from "../src/contracts/interfaces/IGemoon.sol";
import {TokenConfig, SocialMedia, AdminConfig} from "../src/contracts/interfaces/IToken.sol";
import {MintableToken} from "./mocks/MintableToken.sol";

/// @notice End-to-end: real PoolManager, PositionManager and Permit2 deployed in-process, the
/// Gemoon contracts deployed through the deploy script, then a Meme is deployed through the
/// controller and traded against its initial position.
contract ControllerDeployTokenTest is Test {
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
