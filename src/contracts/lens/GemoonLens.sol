// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap-v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IGemoonLens} from "../interfaces/IGemoonLens.sol";
import {IGemoonToken, SocialMedia} from "../interfaces/IToken.sol";
import {IHookManager} from "../interfaces/IHookManager.sol";
import {IUniswapV3SwapAdapter} from "../interfaces/IUniswapV3SwapAdapter.sol";
import {IVault, VaultInfo, AssetConfig} from "../interfaces/IVault.sol";
import {IGemoonController, TICK_SPACING} from "../interfaces/IGemoon.sol";

/// @dev `GemoonToken.getSocialMedia`, not part of `IGemoonToken`.
interface ISocialMediaToken {
    function getSocialMedia() external view returns (SocialMedia memory);
}

/// @title GemoonLens
/// @notice Read-only batch reader for frontends, see `IGemoonLens`. No state, no owner, no
/// upgrades, no funds: every function is `view`, so a broken or missing Lens costs nothing but
/// the frontend falling back to direct reads. A new protocol deployment gets a new Lens.
///
/// @dev Failure isolation. `try/catch` does not catch a revert while decoding the return data
/// (an EOA returns nothing, an old token may return `bytes32` from `name()`), so every read of a
/// token, an asset, the hook or the swap adapter is a low-level `staticcall` whose return data is
/// checked before decoding: `_readWord`, `_readAddress`, `_readString`, `_readSocial`. Only the
/// Vault, whose code
/// is part of the protocol, is called through its interface, and only inside `try`.
///
/// Gas: one batch is one `eth_call`, bound by the node gas cap. Measured limits are in README.md.
contract GemoonLens is IGemoonLens {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Burn addresses counted in `TokenMarket.burned`.
    address public constant BURN_ZERO = address(0);
    address public constant BURN_DEAD =
        0x000000000000000000000000000000000000dEaD;

    /// @dev GemoonController of the deployment, reported by `controller()`.
    address private immutable i_controller;
    /// @dev Vault of the deployment. USDG and the swap adapter are read from it on every call,
    /// the adapter can be replaced by the vault owner.
    IVault private immutable i_vault;
    /// @dev Fallback HookManager for Memes the controller has no `hookOf` for (deployed by an
    /// older controller version). Every other Meme is read through its own hook.
    address private immutable i_hook;
    /// @dev PoolManager whose slot0 gives the pool prices (StateLibrary, same as StateView).
    IPoolManager private immutable i_poolManager;

    /// @param controller_  GemoonController of the deployment.
    /// @param vault_       Vault of the deployment.
    /// @param hook_        HookManager of Memes without `controller.hookOf` (older controllers).
    /// @param poolManager_ Uniswap V4 PoolManager holding the pools.
    constructor(
        address controller_,
        address vault_,
        address hook_,
        address poolManager_
    ) {
        if (
            controller_ == address(0) ||
            vault_ == address(0) ||
            hook_ == address(0) ||
            poolManager_ == address(0)
        ) revert ZeroAddress();
        i_controller = controller_;
        i_vault = IVault(vault_);
        i_hook = hook_;
        i_poolManager = IPoolManager(poolManager_);
    }

    // ---------------------------------------------------------------------------------------------
    // Batch reads
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IGemoonLens
    function tokens(
        address[] calldata memes,
        address account
    ) external view returns (TokenView[] memory views) {
        address usdg = i_vault.usdg();
        views = new TokenView[](memes.length);
        for (uint256 i; i < memes.length; ++i) {
            views[i] = _tokenView(memes[i], account, usdg);
        }
    }

    /// @inheritdoc IGemoonLens
    function markets(
        address[] calldata memes
    )
        external
        view
        returns (TokenMarket[] memory market, uint256[] memory staked)
    {
        address usdg = i_vault.usdg();
        market = new TokenMarket[](memes.length);
        staked = new uint256[](memes.length);
        for (uint256 i; i < memes.length; ++i) {
            (market[i], ) = _market(memes[i], usdg);
            staked[i] = _totalStaked(memes[i]);
        }
    }

    /// @inheritdoc IGemoonLens
    function totalStaked(
        address[] calldata memes
    ) external view returns (uint256[] memory staked) {
        staked = new uint256[](memes.length);
        for (uint256 i; i < memes.length; ++i) {
            staked[i] = _totalStaked(memes[i]);
        }
    }

    /// @inheritdoc IGemoonLens
    function quotes(
        address[] calldata assets,
        uint256 amountIn
    ) external view returns (uint256[] memory amounts, bool[] memory ok) {
        address usdg = i_vault.usdg();
        address adapter = i_vault.swapAdapter();
        amounts = new uint256[](assets.length);
        ok = new bool[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i] == usdg) {
                (amounts[i], ok[i]) = (amountIn, true);
            } else {
                (ok[i], amounts[i]) = _readWord(
                    adapter,
                    abi.encodeCall(
                        IUniswapV3SwapAdapter.quote,
                        (assets[i], amountIn)
                    )
                );
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Single reads
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IGemoonLens
    function protocol()
        external
        view
        returns (
            address usdg,
            uint8 usdgDecimals,
            string memory usdgSymbol,
            address swapAdapter,
            uint256 conversionThreshold,
            uint256 conversionCooldown,
            address hook,
            address poolManager
        )
    {
        usdg = i_vault.usdg();
        (, usdgDecimals) = _readDecimals(usdg);
        (, usdgSymbol) = _readString(
            usdg,
            abi.encodeCall(IERC20Metadata.symbol, ())
        );
        swapAdapter = i_vault.swapAdapter();
        conversionThreshold = i_vault.conversionThreshold();
        conversionCooldown = i_vault.CONVERSION_COOLDOWN();
        hook = i_hook;
        poolManager = address(i_poolManager);
    }

    /// @inheritdoc IGemoonLens
    function creator(
        address meme
    )
        external
        view
        returns (
            address creatorOf,
            address[] memory assets,
            uint256[] memory accrued
        )
    {
        CreatorRewards memory r = _creatorRewards(meme);
        return (r.creatorOf, r.assets, r.accrued);
    }

    /// @inheritdoc IGemoonLens
    function creators(
        address[] calldata memes
    ) external view returns (CreatorRewards[] memory rewards) {
        rewards = new CreatorRewards[](memes.length);
        for (uint256 i; i < memes.length; ++i) {
            rewards[i] = _creatorRewards(memes[i]);
        }
    }

    /// @inheritdoc IGemoonLens
    function controller() external view returns (address) {
        return i_controller;
    }

    /// @inheritdoc IGemoonLens
    function vault() external view returns (address) {
        return address(i_vault);
    }

    // ---------------------------------------------------------------------------------------------
    // Per token
    // ---------------------------------------------------------------------------------------------

    function _tokenView(
        address meme,
        address account,
        address usdg
    ) private view returns (TokenView memory v) {
        v.meme = meme;
        (v.market, v.meta.ok) = _market(meme, usdg);
        // Not a token: everything else would fail too, only the pool id is reported.
        if (!v.meta.ok) return v;

        v.meta = _meta(meme);
        v.vault = _vaultPublic(meme);
        if (account != address(0))
            v.position = _position(meme, account, v.vault.registered);
    }

    /// @return m        Market data of `meme`.
    /// @return supplyOk Whether `totalSupply()` answered, which is what `TokenMeta.ok` reports.
    function _market(
        address meme,
        address usdg
    ) private view returns (TokenMarket memory m, bool supplyOk) {
        address hook_ = _hookOf(meme);
        bool memeIsToken0 = meme < usdg;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(memeIsToken0 ? meme : usdg),
            currency1: Currency.wrap(memeIsToken0 ? usdg : meme),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
        PoolId id = key.toId();
        m.poolId = PoolId.unwrap(id);
        m.memeIsToken0 = memeIsToken0;

        (supplyOk, m.totalSupply) = _readWord(
            meme,
            abi.encodeCall(IERC20.totalSupply, ())
        );
        if (!supplyOk) return (m, false);

        // The pool exists only for Memes of this deployment; for other tokens slot0 reads zero.
        (m.sqrtPriceX96, , , ) = i_poolManager.getSlot0(id);
        (bool zeroOk, uint256 burnedZero) = _readWord(
            meme,
            abi.encodeCall(IERC20.balanceOf, (BURN_ZERO))
        );
        (bool deadOk, uint256 burnedDead) = _readWord(
            meme,
            abi.encodeCall(IERC20.balanceOf, (BURN_DEAD))
        );
        m.burnedOk = zeroOk && deadOk;
        if (m.burnedOk) m.burned = burnedZero + burnedDead;
        (m.pendingFeesOk, m.pendingFees) = _readWord(
            hook_,
            abi.encodeCall(IHookManager.pendingFees, (meme))
        );
    }

    function _meta(address meme) private view returns (TokenMeta memory t) {
        t.ok = true;
        (, t.name) = _readString(meme, abi.encodeCall(IERC20Metadata.name, ()));
        (, t.symbol) = _readString(
            meme,
            abi.encodeCall(IERC20Metadata.symbol, ())
        );
        (t.decimalsOk, t.decimals) = _readDecimals(meme);
        (, t.description) = _readString(
            meme,
            abi.encodeCall(IGemoonToken.description, ())
        );
        (, t.image) = _readString(
            meme,
            abi.encodeCall(IGemoonToken.imageAddress, ())
        );
        (t.creatorOk, t.creator) = _readAddress(
            meme,
            abi.encodeCall(IGemoonToken.creator, ())
        );
        (t.socialOk, t.social) = _readSocial(meme);
    }

    function _vaultPublic(
        address meme
    ) private view returns (VaultPublic memory p) {
        (bool ok, uint256 registered) = _readWord(
            address(i_vault),
            abi.encodeCall(IVault.isRegistered, (meme))
        );
        // Anything but an ABI bool is "unknown", not "no vault".
        p.registeredOk = ok && registered <= 1;
        if (!p.registeredOk || registered == 0) return p;
        p.registered = true;

        try i_vault.vaultInfo(meme) returns (VaultInfo memory info) {
            p.registeredAt = info.registeredAt;
            p.totalStaked = info.totalStaked;
            p.creator = info.creator;
            p.pendingStakerUSDG = info.pendingStakerUSDG;
            p.pendingCreatorUSDG = info.pendingCreatorUSDG;
            p.lastConversionFailure = info.lastConversionFailure;
            p.creatorShareBps = info.creatorShareBps;
        } catch {}
        try i_vault.getAssets(meme) returns (AssetConfig[] memory configs) {
            p.assets = new Asset[](configs.length);
            for (uint256 i; i < configs.length; ++i) {
                address token = configs[i].token;
                p.assets[i].token = token;
                p.assets[i].weightBps = configs[i].weightBps;
                (p.assets[i].symbolOk, p.assets[i].symbol) = _readString(
                    token,
                    abi.encodeCall(IERC20Metadata.symbol, ())
                );
                (p.assets[i].decimalsOk, p.assets[i].decimals) = _readDecimals(
                    token
                );
            }
        } catch {}
    }

    function _position(
        address meme,
        address account,
        bool registered
    ) private view returns (Position memory pos) {
        (, pos.balance) = _readWord(
            meme,
            abi.encodeCall(IERC20.balanceOf, (account))
        );
        (, pos.allowance) = _readWord(
            meme,
            abi.encodeCall(IERC20.allowance, (account, address(i_vault)))
        );
        if (!registered) return pos;

        (, pos.staked) = _readWord(
            address(i_vault),
            abi.encodeCall(IVault.stakedOf, (meme, account))
        );
        (, pos.pendingCredit) = _readWord(
            address(i_vault),
            abi.encodeCall(IVault.pendingCreditOf, (meme, account))
        );
        try i_vault.earned(meme, account) returns (
            address[] memory a,
            uint256[] memory amounts
        ) {
            (pos.earnedAssets, pos.earnedAmounts) = (a, amounts);
        } catch {}
    }

    /// @dev `ok` only when both vault reads answered.
    function _creatorRewards(
        address meme
    ) private view returns (CreatorRewards memory r) {
        try i_vault.creatorOf(meme) returns (address c) {
            r.creatorOf = c;
        } catch {
            return r;
        }
        try i_vault.creatorAccrued(meme) returns (
            address[] memory a,
            uint256[] memory amounts
        ) {
            (r.assets, r.accrued, r.ok) = (a, amounts, true);
        } catch {}
    }

    function _totalStaked(address meme) private view returns (uint256 staked) {
        (, staked) = _readWord(
            address(i_vault),
            abi.encodeCall(IVault.totalStaked, (meme))
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Safe low-level reads: never revert, `ok` false on a failed call or malformed return data
    // ---------------------------------------------------------------------------------------------

    /// @dev First 32-byte word of the return data.
    /// @dev Hook the pool of `meme` was created with: `controller.hookOf(meme)`, or `i_hook` when
    /// the controller has none recorded (older Meme or controller) or does not answer.
    function _hookOf(address meme) private view returns (address hook_) {
        (bool ok, address recorded) = _readAddress(
            i_controller,
            abi.encodeCall(IGemoonController.hookOf, (meme))
        );
        return ok && recorded != address(0) ? recorded : i_hook;
    }

    function _readWord(
        address target,
        bytes memory data
    ) private view returns (bool ok, uint256 word) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success || ret.length < 32) return (false, 0);
        return (true, abi.decode(ret, (uint256)));
    }

    /// @dev Word that fits an address, as the ABI encodes one.
    function _readAddress(
        address target,
        bytes memory data
    ) private view returns (bool ok, address value) {
        (bool success, uint256 word) = _readWord(target, data);
        if (!success || word > type(uint160).max) return (false, address(0));
        return (true, address(uint160(word)));
    }

    /// @dev `decimals()` of `token`, if it returns a value that fits a uint8.
    function _readDecimals(
        address token
    ) private view returns (bool ok, uint8 value) {
        (bool success, uint256 word) = _readWord(
            token,
            abi.encodeCall(IERC20Metadata.decimals, ())
        );
        if (!success || word > type(uint8).max) return (false, 0);
        return (true, uint8(word));
    }

    /// @dev Returned `string`, see `_stringAt`.
    function _readString(
        address target,
        bytes memory data
    ) private view returns (bool ok, string memory value) {
        (bool success, bytes memory ret) = target.staticcall(data);
        if (!success) return (false, "");
        return _stringAt(ret, 0, 0);
    }

    /// @dev `getSocialMedia()` returns a struct of four strings: the data starts with the offset
    /// of the tuple, the tuple holds four offsets relative to its own start. All four strings must
    /// be valid, otherwise the result is empty with `ok` false.
    function _readSocial(
        address meme
    ) private view returns (bool ok, SocialMedia memory social) {
        (bool success, bytes memory ret) = meme.staticcall(
            abi.encodeCall(ISocialMediaToken.getSocialMedia, ())
        );
        if (!success || ret.length < 32) return (false, social);
        uint256 tuple = _wordAt(ret, 0);
        // Bounds the head positions below, so `tuple + 96` cannot overflow.
        if (tuple > ret.length) return (false, social);

        bool[4] memory valid;
        (valid[0], social.farcaster) = _stringAt(ret, tuple, tuple);
        (valid[1], social.twitterX) = _stringAt(ret, tuple, tuple + 32);
        (valid[2], social.telegram) = _stringAt(ret, tuple, tuple + 64);
        (valid[3], social.website) = _stringAt(ret, tuple, tuple + 96);
        if (!(valid[0] && valid[1] && valid[2] && valid[3])) {
            return (
                false,
                SocialMedia({
                    farcaster: "",
                    twitterX: "",
                    telegram: "",
                    website: ""
                })
            );
        }
        return (true, social);
    }

    /// @dev String inside ABI-encoded return data: its offset is the word at `head`, counted from
    /// `base` (both 0 for a returned string, the tuple start for a struct member). Every position
    /// is checked against the data length before it is read, so `bytes32` names and short or
    /// malformed data give `ok` false. The string is returned in place, without a second copy of
    /// long descriptions in memory.
    function _stringAt(
        bytes memory ret,
        uint256 base,
        uint256 head
    ) private pure returns (bool ok, string memory value) {
        uint256 size = ret.length;
        if (size < 64 || head > size - 32 || base > size - 32)
            return (false, "");
        uint256 offset = _wordAt(ret, head);
        // The length word must lie inside the data...
        if (offset > size - 32 - base) return (false, "");
        uint256 start = base + offset;
        // ...and so must the bytes it announces.
        if (_wordAt(ret, start) > size - 32 - start) return (false, "");
        // The length word and the bytes after it are a valid `string` inside `ret`.
        assembly ("memory-safe") {
            value := add(add(ret, 32), start)
        }
        return (true, value);
    }

    /// @dev 32-byte word of `data` at byte `position`; the caller checks `position + 32 <= length`.
    function _wordAt(
        bytes memory data,
        uint256 position
    ) private pure returns (uint256 word) {
        assembly ("memory-safe") {
            word := mload(add(add(data, 32), position))
        }
    }
}
