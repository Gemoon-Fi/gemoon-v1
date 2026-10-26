// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IGemoonable} from "./IGemoonable.sol";

/// @title Gemoon UniswapV4 hook manager.
/// @notice Charges a swap fee, always denominated in the pair token: 80% right at pool creation,
///         falling linearly within `DYNAMIC_FEE_THRESHOLD` to the base fee its creator chose at
///         deployment (1%..5%). The whole fee goes to the vault, which splits it between the
///         protocol, the creator and the stakers (`IVault.notifyFees`).
///         Every swap ends with a payout of everything accrued for the Meme of the pool.
///         Not upgradeable: everything is configured in the constructor, the fee rates are fixed.
interface IHookManager is IGemoonable {
    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    /// @dev Neither currency of the pool is the pair token.
    error InvalidPoolPair();
    /// @dev LP fee of the pool is not 0.
    error InvalidPoolFee();
    /// @dev `feeBips > MAX_FEE_BIPS`.
    error InvalidFeeBips();
    /// @dev Pool initialized for a Meme without a registered vault.
    error VaultNotRegistered(address meme);
    /// @dev `payout` called by anyone but the hook itself.
    error NotSelf();
    /// @dev `onlyController` function called by anyone but the controller.
    error NotController();
    /// @dev Meme fee outside `MIN_MEME_FEE_BIPS..MAX_MEME_FEE_BIPS`.
    error InvalidMemeFeeBips(uint256 feeBips);
    /// @dev The swap would start the vault conversion with less gas than it needs; the swap is
    /// reverted so that gas estimation raises the limit. `needed` is the gas required at the
    /// check, `available` what was left.
    error NotEnoughGasForConversion(uint256 needed, uint256 available);
    /// @dev `notifyPoolCreated` for a Meme whose base fee was already set: it is set once.
    error PoolAlreadyNotified(address meme);
    /// @dev `notifyPoolCreated` outside the block in which the first pool of `meme` was initialized
    /// (`createdAt`, zero if none): the base fee is set only together with pool creation.
    error PoolNotCreatedInThisBlock(address meme, uint256 createdAt);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    /// @notice One swap in a Meme pool, emitted at the end of every swap.
    /// @param meme       Meme of the pool.
    /// @param router     Caller of `PoolManager.swap`, usually a router, not the trader.
    /// @param trader     Address the swapper passed in `hookData` as an abi-encoded address, zero
    ///                   if none. Self-reported: for display only, never for authorization.
    /// @param isBuy      True if the swapper paid pair token and received Meme.
    /// @param pairAmount Pair-token side of the swap as priced by the pool, hook fee excluded.
    /// @param memeAmount Meme side of the swap.
    /// @param fee        Hook fee charged on this swap, in pair token. The swapper pays
    ///                   `pairAmount + fee` on a buy and receives `pairAmount - fee` on a sell.
    event MemeSwapped(
        address indexed meme,
        address indexed router,
        address indexed trader,
        bool isBuy,
        uint256 pairAmount,
        uint256 memeAmount,
        uint256 fee
    );

    /// @notice Fee taken from one swap and recorded as claims of the hook.
    /// @param poolId Pool the swap happened in.
    /// @param sender Caller of `PoolManager.swap`.
    /// @param amount Fee in pair token.
    event FeeCharged(
        PoolId indexed poolId,
        address indexed sender,
        uint256 amount
    );

    /// @notice Accrued fees of `meme` paid out as real tokens, all of them to the vault.
    /// @param meme   Meme the fees belong to.
    /// @param vault  Receiver, notified via `IVault.notifyFees`; it splits the amount.
    /// @param amount Pair token sent to `vault`.
    event FeesDistributed(
        address indexed meme,
        address indexed vault,
        uint256 amount
    );

    /// @notice Automatic payout at the end of a swap failed; the swap itself succeeded and the fee
    ///         stays accrued until the next successful payout or `distribute`.
    /// @param reason Raw revert data of the failed payout.
    event PayoutFailed(bytes reason);

    /// @notice Vault changed.
    event VaultUpdated(address indexed vault);

    /// @notice Pool of `meme` created: its anti-snipe window starts at `createdAt`, after it every
    ///         swap pays `feeBips`.
    /// @param meme      Meme of the pool.
    /// @param feeBips   Base fee chosen by the creator, in bips of the swap, protocol part included.
    /// @param createdAt Creation time of the pool.
    event MemeFeeConfigured(address indexed meme, uint256 feeBips, uint256 createdAt);

    /// @notice First pool of `meme` initialized: its anti-snipe window starts at `createdAt`.
    ///         Recorded by the hook itself, once per Meme.
    event PoolTimestampRecorded(address indexed meme, uint256 createdAt);

    /// @notice Controller changed.
    event ControllerUpdated(address indexed controller);

    // ---------------------------------------------------------------------------------------------
    // Admin (owner)
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the vault that receives every fee.
    function setVault(address vault_) external;

    /// @notice Sets the GemoonController allowed into `onlyController` functions.
    function setController(address controller_) external;

    // ---------------------------------------------------------------------------------------------
    // Payout
    // ---------------------------------------------------------------------------------------------

    /// @notice Automatic payout, called by the hook itself at the end of every swap.
    /// @dev Reverts with `NotSelf` for any other caller.
    /// @param meme Meme of the pool that was just swapped.
    function payout(address meme) external;

    /// @notice Manual fallback: pays out whatever is accrued for `meme`
    ///         (e.g. after automatic payouts were failing). Anyone can call it.
    /// @dev Must be called outside a swap: opens the PoolManager via `unlock`.
    /// @param meme Meme whose accrued fees are paid out.
    function distribute(address meme) external;

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees accrued for `meme` and not yet paid out, in pair token.
    function pendingFees(address meme) external view returns (uint256);

    /// @notice Same as `pendingFees`: raw accrued mapping.
    function accrued(address meme) external view returns (uint256);

    /// @notice Pair token every Meme pool is quoted in and every fee is charged in.
    function pairToken() external view returns (Currency);

    /// @notice Vault that receives every fee and splits it.
    function vault() external view returns (address);

    /// @notice GemoonController allowed into `onlyController` functions.
    function controller() external view returns (address);

    /// @notice Bips denominator, 10 000.
    function BIPS() external view returns (uint256);

    /// @notice Fallback base fee, in bips of the pair-token side of a swap, for a Meme the
    ///         controller never reported. See `baseFeeBips`.
    function TOTAL_FEE_BIPS() external view returns (uint256);

    /// @notice Lower bound of the Meme fee, in bips (100 = 1%).
    function MIN_MEME_FEE_BIPS() external view returns (uint256);

    /// @notice Upper bound of the Meme fee, in bips (500 = 5%).
    function MAX_MEME_FEE_BIPS() external view returns (uint256);

    /// @notice Gas of a payout on top of the vault conversion, reserved by swaps that trigger it.
    function PAYOUT_GAS_OVERHEAD() external view returns (uint256);

    /// @notice Cap on the conversion gas a vault can demand from a swap.
    function MAX_CONVERSION_GAS() external view returns (uint256);

    /// @notice Gas the vault's `conversionGasRequired` view is called with.
    function CONVERSION_QUERY_GAS() external view returns (uint256);

    /// @notice Base fee of `meme` chosen by its creator, in bips of the swap, zero if never
    ///         reported.
    function memeFeeBips(address meme) external view returns (uint256);

    /// @notice Fee of `meme` after the anti-snipe window: `memeFeeBips(meme)`, or
    ///         `TOTAL_FEE_BIPS` for a Meme never reported.
    function baseFeeBips(address meme) external view returns (uint256);

    /// @notice Fee right at pool creation, in bips (8 000 = 80%).
    function MAX_FEE_BIPS() external view returns (uint256);

    /// @notice Seconds after pool creation during which the fee falls from `MAX_FEE_BIPS` to
    ///         `baseFeeBips(meme)`.
    function DYNAMIC_FEE_THRESHOLD() external view returns (uint256);

    /// @notice Initialization time of the first pool of `meme`, recorded by the hook; zero if none.
    function poolTimestamps(address meme) external view returns (uint256);

    /// @notice Fee of a swap in the pool of `meme` at `timestamp`, in bips. Linear from
    ///         `MAX_FEE_BIPS` at pool creation to `baseFeeBips(meme)` after `DYNAMIC_FEE_THRESHOLD`.
    function feeBipsAt(address meme, uint256 timestamp) external view returns (uint256);

    /// @notice Fee of a swap in the pool of `meme` right now, in bips.
    function currentFeeBips(address meme) external view returns (uint256);

    // ------
    // Utils
    // ------
    /// @notice Sets the base fee the creator of `meme` chose. Only controller, once per Meme
    ///         (`PoolAlreadyNotified`), in the block in which the first pool of `meme` was
    ///         initialized (`PoolNotCreatedInThisBlock`). Reverts with `InvalidMemeFeeBips`
    ///         outside 1%..5%. The anti-snipe window is recorded by the hook, not passed here.
    function notifyPoolCreated(address meme, uint256 feeBips) external;
}
