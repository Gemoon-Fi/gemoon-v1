// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IGemoonable} from "./IGemoonable.sol";

/// @title Gemoon UniswapV4 hook manager.
/// @notice Charges a fixed swap fee (1.25% by default), always denominated in the pair token:
///         `PROTOCOL_FEE_BIPS` goes to the protocol recipient, the rest goes to the vault.
///         Every swap ends with a payout of everything accrued for the Meme of the pool.
interface IHookManager is IGemoonable {
    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    /// @dev Neither currency of the pool is the pair token.
    error InvalidPoolPair();
    /// @dev LP fee of the pool is not 0.
    error InvalidPoolFee();
    /// @dev `feeBips >= BIPS` or `protocolFeeBips > feeBips`.
    error InvalidFeeBips();
    /// @dev Pool initialized for a Meme without a registered vault.
    error VaultNotRegistered(address meme);
    /// @dev `payout` called by anyone but the hook itself.
    error NotSelf();

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

    /// @notice Accrued fees of `meme` paid out as real tokens.
    /// @param meme              Meme the fees belong to.
    /// @param protocolRecipient Receiver of the protocol share.
    /// @param vault             Receiver of the vault share, notified via `IVault.notifyFees`.
    /// @param toProtocol        Pair token sent to `protocolRecipient`.
    /// @param toVault           Pair token sent to `vault`.
    event FeesDistributed(
        address indexed meme,
        address indexed protocolRecipient,
        address indexed vault,
        uint256 toProtocol,
        uint256 toVault
    );

    /// @notice Automatic payout at the end of a swap failed; the swap itself succeeded and the fee
    ///         stays accrued until the next successful payout or `distribute`.
    /// @param reason Raw revert data of the failed payout.
    event PayoutFailed(bytes reason);

    /// @notice Protocol fee recipient changed.
    event ProtocolRecipientUpdated(address indexed recipient);

    /// @notice Vault changed.
    event VaultUpdated(address indexed vault);

    // ---------------------------------------------------------------------------------------------
    // Initialization (proxy)
    // ---------------------------------------------------------------------------------------------

    /// @notice Initializes the proxy. Called once, right after deployment.
    /// @param owner_             Owner (Ownable2Step).
    /// @param protocolRecipient_ Receiver of the protocol share of every fee.
    /// @param vault_             Vault that receives the rest and holds Meme stakes.
    /// @param feeBips            Total hook fee, in bips of the pair-token side of a swap.
    /// @param protocolFeeBips    Protocol share of `feeBips`, in bips of the swap.
    function initialize(
        address owner_,
        address protocolRecipient_,
        address vault_,
        uint256 feeBips,
        uint256 protocolFeeBips
    ) external;

    /// @notice Re-initializes the proxy after an upgrade. Same parameters as `initialize`.
    function reinitialize(
        address owner_,
        address protocolRecipient_,
        address vault_,
        uint256 feeBips,
        uint256 protocolFeeBips
    ) external;

    // ---------------------------------------------------------------------------------------------
    // Admin (owner)
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the receiver of the protocol share of every fee.
    function setProtocolRecipient(address recipient) external;

    /// @notice Sets the vault that receives the vault share of every fee.
    function setVault(address vault_) external;

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

    /// @notice Receiver of the protocol share of every fee.
    function protocolRecipient() external view returns (address);

    /// @notice Vault that receives the vault share of every fee.
    function vault() external view returns (address);

    /// @notice Bips denominator, 10 000.
    function BIPS() external view returns (uint256);

    /// @notice Total hook fee, in bips of the pair-token side of a swap.
    function TOTAL_FEE_BIPS() external view returns (uint256);

    /// @notice Protocol share of the fee, in bips of the swap. The vault gets
    ///         `TOTAL_FEE_BIPS - PROTOCOL_FEE_BIPS`.
    function PROTOCOL_FEE_BIPS() external view returns (uint256);
}
