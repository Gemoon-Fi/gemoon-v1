// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GemoonLens} from "../../src/contracts/lens/GemoonLens.sol";
import {GemoonToken} from "../../src/contracts/Token.sol";
import {IGemoonLens} from "../../src/contracts/interfaces/IGemoonLens.sol";
import {IVault, VaultInfo, AssetConfig} from "../../src/contracts/interfaces/IVault.sol";
import {IHookManager} from "../../src/contracts/interfaces/IHookManager.sol";

/// @dev Uniswap V4 periphery StateView, only what the test reads.
interface IStateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

/// @notice GemoonLens against the live devnet: the Anvil fork of Robinhood chain (chain id 1488)
/// with the deployed protocol. The Lens is deployed inside the fork, nothing is broadcast.
/// @dev Env: DEVNET_RPC enables the suite (skipped when empty or on another chain), DEVNET_BLOCK
/// pins the block (latest when empty). The Memes are found from the controller nonce: every Meme
/// is a CREATE of the controller, so the last N nonces are the last N Memes.
contract GemoonLensDevnetForkTest is Test {
    uint256 constant CHAIN_ID = 1488;
    /// @dev Current devnet deployment, overridden by CONTROLLER_PROXY_ADDRESS / VAULT_PROXY_ADDRESS
    /// / HOOK_ADDRESS / POOL_MANAGER of env/dev.mk when `make devnet-tests` exports them.
    address constant DEVNET_CONTROLLER = 0x642c1B61F34AcC0b1CA599349b75b5Ba783EfB8E;
    address constant DEVNET_VAULT = 0xB04b1CC84dedf45E25Ce24f493aFEa3c414013B3;
    address constant DEVNET_HOOK = 0xE1c669Ac693F92417C953DBA793Eb1593Dd170cC;
    address constant DEVNET_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address CONTROLLER;
    address VAULT;
    address HOOK;
    address POOL_MANAGER;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant BATCH = 70;

    GemoonLens lens;
    address[] memes;

    function setUp() external {
        string memory rpc = vm.envOr("DEVNET_RPC", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 blockNumber = vm.envOr("DEVNET_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNumber);
        CONTROLLER = vm.envOr("CONTROLLER_PROXY_ADDRESS", DEVNET_CONTROLLER);
        VAULT = vm.envOr("VAULT_PROXY_ADDRESS", DEVNET_VAULT);
        HOOK = vm.envOr("HOOK_ADDRESS", DEVNET_HOOK);
        POOL_MANAGER = vm.envOr("POOL_MANAGER", DEVNET_POOL_MANAGER);
        if (block.chainid != CHAIN_ID || VAULT.code.length == 0) return;

        lens = new GemoonLens(CONTROLLER, VAULT, HOOK, POOL_MANAGER);
        uint256 nonce = vm.getNonce(CONTROLLER);
        for (uint256 k = nonce; k > 0 && memes.length < BATCH; --k) {
            address meme = vm.computeCreateAddress(CONTROLLER, k - 1);
            if (meme.code.length != 0 && IVault(VAULT).isRegistered(meme)) memes.push(meme);
        }
    }

    modifier onDevnet() {
        if (address(lens) == address(0) || memes.length == 0) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_Tokens_DevnetMemes_MatchDirectReadsAndStateView() external onDevnet {
        uint256 n = memes.length < 5 ? memes.length : 5;
        address[] memory list = new address[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = memes[i];
        }
        IGemoonLens.TokenView[] memory views = lens.tokens(list, address(0));

        for (uint256 i; i < n; ++i) {
            IGemoonLens.TokenView memory v = views[i];
            address meme = list[i];
            assertTrue(v.meta.ok);
            assertTrue(v.meta.creatorOk);
            assertTrue(v.meta.socialOk);
            assertEq(abi.encode(v.meta.social), abi.encode(GemoonToken(meme).getSocialMedia()));
            assertTrue(v.market.burnedOk);
            assertTrue(v.market.pendingFeesOk);
            assertTrue(v.vault.registeredOk);
            assertEq(v.market.totalSupply, IERC20(meme).totalSupply());
            assertEq(
                v.market.burned, IERC20(meme).balanceOf(address(0)) + IERC20(meme).balanceOf(DEAD)
            );
            (uint160 sqrtPriceX96,,,) = IStateView(STATE_VIEW).getSlot0(v.market.poolId);
            assertEq(v.market.sqrtPriceX96, sqrtPriceX96);
            assertGt(v.market.sqrtPriceX96, 0);
            assertEq(v.market.pendingFees, IHookManager(HOOK).pendingFees(meme));

            VaultInfo memory info = IVault(VAULT).vaultInfo(meme);
            assertTrue(v.vault.registered);
            assertEq(v.vault.totalStaked, info.totalStaked);
            assertEq(v.vault.creator, info.creator);
            assertEq(v.vault.registeredAt, info.registeredAt);
            AssetConfig[] memory configs = IVault(VAULT).getAssets(meme);
            assertEq(v.vault.assets.length, configs.length);
            for (uint256 j; j < configs.length; ++j) {
                assertEq(v.vault.assets[j].token, configs[j].token);
                assertTrue(v.vault.assets[j].symbolOk);
                assertTrue(v.vault.assets[j].decimalsOk);
                assertEq(v.vault.assets[j].weightBps, configs[j].weightBps);
                assertGt(bytes(v.vault.assets[j].symbol).length, 0);
            }
        }
    }

    function test_Protocol_Devnet_MatchesVault() external onDevnet {
        (address usdg,, string memory symbol, address adapter,,, address hook, address pm) =
            lens.protocol();
        assertEq(usdg, IVault(VAULT).usdg());
        assertGt(bytes(symbol).length, 0);
        assertEq(adapter, IVault(VAULT).swapAdapter());
        assertEq(hook, HOOK);
        assertEq(pm, POOL_MANAGER);
    }

    /// @dev Every allowlisted asset of the devnet has a route, so every quote answers.
    function test_Quotes_DevnetAllowlist_AllQuoted() external onDevnet {
        address[] memory assets = IVault(VAULT).allowedAssets();
        (uint256[] memory amounts, bool[] memory ok) = lens.quotes(assets, 1e6);
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(ok[i]);
            assertGt(amounts[i], 0);
        }
    }

    function test_Creators_DevnetMemes_MatchVault() external onDevnet {
        IGemoonLens.CreatorRewards[] memory rewards = lens.creators(memes);
        for (uint256 i; i < memes.length; ++i) {
            assertTrue(rewards[i].ok);
            assertEq(rewards[i].creatorOf, IVault(VAULT).creatorOf(memes[i]));
        }
    }

    function test_Gas_Tokens70Devnet_Below30M() external onDevnet {
        address account = makeAddr("account");
        uint256 start = gasleft();
        lens.tokens(memes, account);
        uint256 used = start - gasleft();
        console.log("devnet tokens(%d, account) gas:", memes.length, used);
        assertLt(used, 30_000_000);
    }
}
