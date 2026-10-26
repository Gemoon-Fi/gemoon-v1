// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {
    IUnlockCallback
} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IHookManager} from "../interfaces/IHookManager.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

/// @title Gemoon UniswapV4 hook manager.
/// @notice Charges a swap fee, always denominated in `i_pairToken`.
///         Base fee of a Meme is chosen by its creator at deployment (1%..5%). The whole fee, the
///         anti-snipe excess included, goes to the vault; the vault splits it between the protocol
///         (`IVault.protocolShareBps`), the creator and the stakers. The hook knows nothing of the
///         split.
///         Anti-snipe: the fee starts at `MAX_FEE_BIPS` (80%) when the pool is created and falls
///         linearly to the base fee over `DYNAMIC_FEE_THRESHOLD`. Swaps of the controller (the
///         dev buy inside `deployToken`) always pay the base fee.
/// @dev Not upgradeable: no proxy, the code and the fee rate parameters (`TOTAL_FEE_BIPS`,
/// `MAX_FEE_BIPS`, the meme fee bounds) are fixed at deployment. The address is CREATE2-mined to
/// carry the bit pattern of `getHookPermissions`. A new version is a new hook at a new address:
/// pools of existing Memes stay on the hook they were created with. The owner can only re-point
/// the vault and the controller (`setVault`, `setController`); it cannot change any fee rate.
/// How a fee is split is not the hook's business: it lives in the upgradeable vault.
///
/// Fee flow:
///  - pools: only Meme/pairToken pools with LP fee 0 whose Meme has a registered vault.
///  - every swap: the fee is taken from the swapper via a hook delta and recorded inside the
///    PoolManager as ERC6909 claims owned by this hook (`poolManager.mint`), and per Meme in
///    `accrued`.
///  - end of every swap (`_afterSwap`): the claims accrued for the Meme of the pool are paid out as
///    real tokens, all of them to the vault, which is notified (`IVault.notifyFees`) and splits
///    them. The swapper pays the gas. The payout runs inside try/catch: if it fails, the swap still
///    succeeds and the fee stays accrued until the next successful payout.
///  - `distribute(meme)`: manual fallback that pays out whatever is accrued for `meme`.
contract HookManager is IHookManager, BaseHook, IUnlockCallback, Ownable2Step {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using SignedMath for int256;

    // Errors and events are declared in `IHookManager`.

    // ---------------------------------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------------------------------

    uint64 public constant HOOK_MANAGER_VERSION = 2;

    uint256 public constant BIPS = 10_000;
    /// @notice Fallback base fee for a Meme the controller never reported, see `baseFeeBips`.
    ///         Fixed at deployment (1.25% in production).
    uint256 public immutable TOTAL_FEE_BIPS;
    /// @notice Time after pool creation during which the fee falls from `MAX_FEE_BIPS` to
    ///         `baseFeeBips`.
    uint256 public constant DYNAMIC_FEE_THRESHOLD = 30 seconds;
    /// @notice Fee right at pool creation, 80%.
    uint256 public constant MAX_FEE_BIPS = 8_000;
    /// @notice Bounds of the Meme fee its creator chooses at deployment: 1%..5%.
    uint256 public constant MIN_MEME_FEE_BIPS = 100;
    uint256 public constant MAX_MEME_FEE_BIPS = 500;
    /// @notice Gas of the payout itself on top of the vault conversion: claims burn, take, vault
    ///         `notifyFees` bookkeeping including its protocol transfer and `notifyFee`. The
    ///         heaviest payout (first fee of a vault with stakers, first credit of a referrer:
    ///         cold slots everywhere) measured ~240k; the rest is margin for the 63/64 rule of the
    ///         nested calls.
    uint256 public constant PAYOUT_GAS_OVERHEAD = 300_000;
    /// @notice Cap on the conversion gas a vault can demand from a swap. Above the most a Gemoon
    ///         vault reports (150k base + 8 assets x 300k = 2.55M), so a vault reporting more
    ///         cannot block trading; a conversion that really needs more fails inside the caught
    ///         payout and the fees stay accrued.
    uint256 public constant MAX_CONVERSION_GAS = 3_000_000;
    /// @notice Gas the vault's `conversionGasRequired` view is called with (it reads at most a few
    ///         storage slots), so a vault cannot burn the swap's gas there either.
    uint256 public constant CONVERSION_QUERY_GAS = 100_000;

    Currency private immutable i_pairToken;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    address public vault;
    /// @notice Fees charged and not yet paid out, per Meme, in `i_pairToken`.
    /// @dev Sum over all memes equals the ERC6909 claims of this hook.
    mapping(address meme => uint256) public accrued;
    /// @notice Initialization time of the first pool of a Meme, set by the hook itself; zero if
    ///         no pool of it was initialized.
    mapping(address meme => uint256) public poolTimestamps;
    /// @notice GemoonController, the only caller allowed into `onlyController` functions.
    address public controller;
    /// @notice Base fee of a Meme chosen by its creator, in bips of the swap, zero if the
    ///         controller never reported it. Protocol part included.
    mapping(address meme => uint256) public memeFeeBips;

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    modifier onlyController() {
        if (msg.sender != controller) revert NotController();
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Construction / initialization
    // ---------------------------------------------------------------------------------------------

    /// @param poolManager_       Uniswap V4 PoolManager.
    /// @param pairToken_         Token every pool is paired with and fees are charged in.
    /// @param owner_      Owner: may re-point vault and controller.
    /// @param vault_      Receives every fee and splits it; must know Memes before their pools.
    /// @param controller_ GemoonController, the only caller of `notifyPoolCreated`.
    /// @param feeBips     `TOTAL_FEE_BIPS`, at most `MAX_FEE_BIPS`.
    constructor(
        IPoolManager poolManager_,
        Currency pairToken_,
        address owner_,
        address vault_,
        address controller_,
        uint256 feeBips
    ) BaseHook(poolManager_) Ownable(owner_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        if (feeBips > MAX_FEE_BIPS) revert InvalidFeeBips();

        i_pairToken = pairToken_;
        TOTAL_FEE_BIPS = feeBips;

        _setVault(vault_);
        _setController(controller_);
    }

    /// @notice Version of this hook contract. Informational only: the hook is not upgradeable.
    function getVersion() public pure returns (uint64) {
        return HOOK_MANAGER_VERSION;
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    function setVault(address vault_) external onlyOwner {
        _setVault(vault_);
    }

    function setController(address controller_) external onlyOwner {
        _setController(controller_);
    }

    function _setVault(address vault_) internal {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultUpdated(vault_);
    }

    function _setController(address controller_) internal {
        if (controller_ == address(0)) revert ZeroAddress();
        controller = controller_;
        emit ControllerUpdated(controller_);
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: true,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // ---------------------------------------------------------------------------------------------
    // Hook lifecycle
    // ---------------------------------------------------------------------------------------------

    /// @dev LP fee must be 0: the whole swap fee is charged by the hook in `i_pairToken`.
    /// The vault must be registered first, otherwise `notifyFees` would revert on every payout.
    function _beforeInitialize(
        address,
        PoolKey calldata poolKey,
        uint160
    ) internal view override returns (bytes4) {
        if (
            !(poolKey.currency0 == i_pairToken) &&
            !(poolKey.currency1 == i_pairToken)
        ) revert InvalidPoolPair();
        if (poolKey.fee != 0) revert InvalidPoolFee();
        address meme = _meme(poolKey);
        if (!IVault(vault).isRegistered(meme)) revert VaultNotRegistered(meme);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Starts the anti-snipe window of the Meme at the moment the controller initializes its
    /// first pool (inside `deployToken`). The hook takes the time itself, so no role can choose
    /// it. Pools initialized by anyone else, and later pools of the same Meme (another tick
    /// spacing), do not start or move it: otherwise a second pool of a live Meme that has no
    /// window yet (deployed before the anti-snipe) would put it under the 80% fee.
    function _afterInitialize(
        address sender,
        PoolKey calldata poolKey,
        uint160,
        int24
    ) internal override returns (bytes4) {
        address meme = _meme(poolKey);
        if (sender == controller && poolTimestamps[meme] == 0) {
            poolTimestamps[meme] = block.timestamp;
            emit PoolTimestampRecorded(meme, block.timestamp);
        }
        return IHooks.afterInitialize.selector;
    }

    /// @dev pairToken amount is fixed by the user (buy exactIn / sell exactOut): take the fee now.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        if (!_pairTokenIsSpecified(key, params)) {
            return (
                IHooks.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                0
            );
        }

        int128 fee = _chargeFee(key, sender, params.amountSpecified.abs());
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @dev pairToken amount is computed by the pool (sell exactIn / buy exactOut): take the fee now.
    /// Then emit the trade and, on every swap, try to pay out everything accrued so far.
    /// `delta` is the pool's result for the swapper: net of the fee taken in `_beforeSwap`, before
    /// the fee returned from here.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        bool pairIs0 = key.currency0 == i_pairToken;
        uint256 pairAmount = int256(pairIs0 ? delta.amount0() : delta.amount1())
            .abs();
        uint256 memeAmount = int256(pairIs0 ? delta.amount1() : delta.amount0())
            .abs();

        int128 fee;
        uint256 feeAmount;
        if (_pairTokenIsSpecified(key, params)) {
            // Already charged in `_beforeSwap` on the amount the swapper specified.
            feeAmount = _feeOf(
                _meme(key),
                sender,
                params.amountSpecified.abs()
            );
        } else {
            fee = _chargeFee(key, sender, pairAmount);
            feeAmount = uint256(uint128(fee));
        }

        address meme = _meme(key);
        emit MemeSwapped(
            meme,
            sender,
            _trader(hookData),
            params.zeroForOne == pairIs0,
            pairAmount,
            memeAmount,
            feeAmount
        );

        // Bounded gas: a vault that burns everything it gets cannot take the rest of the swap with it.
        uint256 payoutGas = _payoutGas(meme);
        try this.payout{gas: payoutGas}(meme) {} catch (bytes memory reason) {
            emit PayoutFailed(reason);
        }
        return (IHooks.afterSwap.selector, fee);
    }

    /// @dev Gas the payout below is called with, and reverts the swap unless it carries that much
    /// when the vault may start a conversion. The conversion runs inside caught calls, so an out-of-gas there would not revert
    /// the swap: gas estimation (wallets, routers, aggregators) would settle on a limit at which
    /// the conversion always dies silently. Reverting here makes the estimate include it.
    /// Required on every swap of a meme with automatic conversion on, whether or not this swap
    /// reaches the threshold: an estimate made before other swaps fill the threshold must still
    /// hold when this one lands. Only the gas actually used is paid.
    /// Three nested calls (hook -> payout, vault -> notifyFees, vault -> convertFees) each get at
    /// most 63/64 of the gas left, hence the factors.
    /// No vault can block trading through this: the view runs with `CONVERSION_QUERY_GAS`, a
    /// failing view counts as no conversion, its figure is capped at `MAX_CONVERSION_GAS`, and the
    /// payout gets exactly the returned gas, so a vault burning all gas it is given costs a swap at
    /// most that much and gas estimation covers it.
    /// @return payoutGas Gas to call the payout with.
    function _payoutGas(address meme) internal view returns (uint256 payoutGas) {
        uint256 conversionGas;
        try IVault(vault).conversionGasRequired{gas: CONVERSION_QUERY_GAS}(meme) returns (
            uint256 gas_
        ) {
            conversionGas = gas_ < MAX_CONVERSION_GAS ? gas_ : MAX_CONVERSION_GAS;
        } catch {}

        // conversion behind the two forwards inside the payout
        payoutGas = (conversionGas * 64 * 64) / (63 * 63) + PAYOUT_GAS_OVERHEAD;
        if (conversionGas == 0) return payoutGas;

        // the payout itself behind one more forward
        uint256 needed = (payoutGas * 64) / 63;
        uint256 available = gasleft();
        if (available < needed) revert NotEnoughGasForConversion(needed, available);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee internals
    // ---------------------------------------------------------------------------------------------

    /// @dev exactIn (amountSpecified < 0) -> input currency is specified,
    ///      exactOut (amountSpecified > 0) -> output currency is specified.
    function _pairTokenIsSpecified(
        PoolKey calldata key,
        SwapParams calldata params
    ) internal view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool pairTokenIs0 = key.currency0 == i_pairToken;
        return specifiedIs0 == pairTokenIs0;
    }

    /// @dev Records the fee as claims owned by the hook and returns it as a positive hook delta
    /// (positive = hook takes, swapper pays more / receives less).
    function _chargeFee(
        PoolKey calldata key,
        address sender,
        uint256 amount
    ) internal returns (int128) {
        address meme = _meme(key);
        uint256 fee = _feeOf(meme, sender, amount);
        if (fee == 0) return 0;

        accrued[meme] += fee;
        poolManager.mint(address(this), i_pairToken.toId(), fee);
        emit FeeCharged(key.toId(), sender, fee);

        return fee.toInt128();
    }

    /// @dev The non-pair currency of a pool, i.e. the Meme token.
    function _meme(PoolKey calldata key) internal view returns (address) {
        return
            Currency.unwrap(
                key.currency0 == i_pairToken ? key.currency1 : key.currency0
            );
    }

    /// @dev The controller swaps only for the dev buy inside `deployToken`, right at pool creation:
    /// it pays the base fee, everyone else the time-based fee of `feeBipsAt`.
    function _feeOf(
        address meme,
        address sender,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 bips = sender == controller
            ? baseFeeBips(meme)
            : feeBipsAt(meme, block.timestamp);
        return (amount * bips) / BIPS;
    }

    /// @dev Trader address self-reported by the swapper through `hookData`, zero if absent or
    /// not exactly one abi-encoded word. Never trusted for anything but events.
    function _trader(bytes calldata hookData) internal pure returns (address) {
        if (hookData.length != 32) return address(0);
        return address(uint160(uint256(bytes32(hookData))));
    }

    // ---------------------------------------------------------------------------------------------
    // Payout
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees accrued for `meme` and not yet paid out, in `i_pairToken`.
    function pendingFees(address meme) external view returns (uint256) {
        return accrued[meme];
    }

    function pairToken() external view returns (Currency) {
        return i_pairToken;
    }

    /// @notice Automatic payout, called by the hook itself at the end of every swap.
    /// @dev External only so `_afterSwap` can wrap it in try/catch. The PoolManager is already
    /// unlocked during a swap, so burn/take are called directly, without `unlock`.
    /// @param meme Meme of the pool that was just swapped.
    function payout(address meme) external {
        if (msg.sender != address(this)) revert NotSelf();
        _payout(meme);
    }

    /// @notice Manual fallback: pays out whatever is accrued for `meme`
    ///         (e.g. after payouts were failing).
    /// @dev Must be called outside a swap: opens the PoolManager via `unlock`.
    /// @param meme Meme whose accrued fees are paid out.
    function distribute(address meme) external {
        poolManager.unlock(abi.encode(meme));
    }

    /// @dev Reached only through `distribute()`.
    function unlockCallback(
        bytes calldata data
    ) external onlyPoolManager returns (bytes memory) {
        _payout(abi.decode(data, (address)));
        return "";
    }

    /// @dev claims -> positive delta for the hook -> real tokens out to the vault -> delta back to
    /// zero, then the vault is told which Meme the fees belong to and splits them itself. A revert
    /// anywhere (including in `notifyFees`) rolls the whole payout back, `accrued` included.
    /// Requires the PoolManager to be unlocked.
    function _payout(address meme) internal {
        uint256 amount = accrued[meme];
        if (amount == 0) return;

        address vault_ = vault;
        accrued[meme] = 0;

        poolManager.burn(address(this), i_pairToken.toId(), amount);
        poolManager.take(i_pairToken, vault_, amount);
        IVault(vault_).notifyFees(meme, amount);

        emit FeesDistributed(meme, vault_, amount);
    }

    // ---- Utils ----

    /// @notice Sets the base fee the creator of `meme` chose.
    /// @dev Only controller, once per Meme, and only in the block in which the first pool of the
    /// Meme was initialized: the anti-snipe window is recorded by the hook itself
    /// (`_afterInitialize`), so the controller cannot start, restart or move it on a live pool,
    /// and the base fee cannot be changed afterwards, whoever holds the controller role.
    /// Reverts unless `feeBips` is within `MIN_MEME_FEE_BIPS..MAX_MEME_FEE_BIPS`.
    /// @param meme    Meme whose pool was created in this block.
    /// @param feeBips Base fee of the Meme in bips of the swap, protocol part included.
    function notifyPoolCreated(
        address meme,
        uint256 feeBips
    ) external onlyController {
        if (memeFeeBips[meme] != 0) revert PoolAlreadyNotified(meme);
        uint256 createdAt = poolTimestamps[meme];
        if (createdAt != block.timestamp) revert PoolNotCreatedInThisBlock(meme, createdAt);
        if (feeBips < MIN_MEME_FEE_BIPS || feeBips > MAX_MEME_FEE_BIPS)
            revert InvalidMemeFeeBips(feeBips);
        memeFeeBips[meme] = feeBips;
        emit MemeFeeConfigured(meme, feeBips, createdAt);
    }

    /// @notice Fee of a swap in the pool of `meme` once the anti-snipe window is over, in bips.
    /// @dev The fee chosen by the creator; `TOTAL_FEE_BIPS` for a Meme the controller never
    /// reported.
    /// @param meme Meme of the pool.
    function baseFeeBips(address meme) public view returns (uint256) {
        uint256 memeFee = memeFeeBips[meme];
        return memeFee == 0 ? TOTAL_FEE_BIPS : memeFee;
    }

    /// @notice Fee of a swap in the pool of `meme` at `timestamp`, in bips.
    /// @dev Linear from `MAX_FEE_BIPS` at pool creation down to `baseFeeBips` after
    /// `DYNAMIC_FEE_THRESHOLD`. The decay rounds down, so the fee rounds up. A Meme without an
    /// initialized pool (timestamp 0) pays the base fee; a timestamp at or before creation pays the
    /// max fee.
    /// @param meme      Meme of the pool.
    /// @param timestamp Time of the swap, normally `block.timestamp`.
    /// @return Fee in bips, between `baseFeeBips(meme)` and `MAX_FEE_BIPS`.
    function feeBipsAt(
        address meme,
        uint256 timestamp
    ) public view returns (uint256) {
        uint256 createdAt = poolTimestamps[meme];
        uint256 baseFee = baseFeeBips(meme);
        if (createdAt == 0) return baseFee;
        if (timestamp <= createdAt) return MAX_FEE_BIPS;

        uint256 elapsed = timestamp - createdAt;
        if (elapsed >= DYNAMIC_FEE_THRESHOLD) return baseFee;

        uint256 decay = ((MAX_FEE_BIPS - baseFee) * elapsed) /
            DYNAMIC_FEE_THRESHOLD;
        return MAX_FEE_BIPS - decay;
    }

    /// @notice Fee of a swap in the pool of `meme` right now, in bips.
    /// @param meme Meme of the pool.
    function currentFeeBips(address meme) external view returns (uint256) {
        return feeBipsAt(meme, block.timestamp);
    }
}
