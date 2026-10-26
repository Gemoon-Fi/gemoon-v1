// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Receiver of the protocol share of the swap fees, notified by the vault after every
///         split. A contract set as `Vault.protocolRecipient` must implement it.
interface IProtocolFeeReceiver {
    /// @notice Called by the vault right after `amount` of the pair token was transferred to the
    ///         receiver as the protocol share of the fees of `meme`.
    /// @dev A revert rolls the whole hook payout back (the fees stay accrued in the hook).
    /// @param meme   Meme whose pool generated the fees.
    /// @param amount Pair token amount transferred.
    function notifyFee(address meme, uint256 amount) external;
}

/// @title Gemoon referrals.
/// @notice A referrer registers a code, a user binds to a referrer once by that code. Every Meme
///         the user deploys afterwards is attributed to the referrer, who then earns `refShareBips`
///         of the protocol fee of that Meme. Everything else received is the protocol's and is
///         withdrawn by the owner.
interface IReferrals is IProtocolFeeReceiver {
    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error NotController();
    /// @dev `notifyFee` called by anyone but the vault or a hook, see `isFeeSource`.
    error NotFeeSource();
    /// @dev `refShareBips` above `BIPS`.
    error InvalidRefShare(uint256 refShareBips);
    /// @dev Code is empty, longer than `MAX_CODE_LENGTH` or has a char outside `[a-z0-9_-]`.
    error InvalidCode();
    error CodeTaken(bytes32 codeHash);
    error CodeNotFound(bytes32 codeHash);
    error ReferrerAlreadySet(address user, address referrer);
    error SelfReferral();
    error NothingToClaim();
    /// @dev The pair token balance would not cover the referral debt: `notifyFee` reported more than
    /// arrived.
    error BalanceTooLow(uint256 balance, uint256 required);
    /// @dev `rescueERC20` on the pair token: use `withdrawProtocolFees`.
    error PairTokenRescue();

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event ControllerUpdated(address indexed controller);
    event HookUpdated(address indexed hook);
    event VaultUpdated(address indexed vault);
    event RefShareUpdated(uint256 refShareBips);
    event CodeRegistered(address indexed referrer, bytes32 indexed codeHash, string code);
    event ReferrerSet(address indexed user, address indexed referrer, bytes32 indexed codeHash);
    /// @notice A Meme was deployed; `referrer` is zero if its creator had none.
    event TokenRegistered(address indexed meme, address indexed creator, address indexed referrer);
    /// @notice Protocol fee of `meme` arrived, `refAmount` of it was credited to `referrer`.
    event FeeReceived(
        address indexed meme, address indexed referrer, uint256 amount, uint256 refAmount
    );
    event ReferralPaid(address indexed referrer, uint256 amount);
    event ProtocolFeesWithdrawn(address indexed to, uint256 amount);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Users
    // ---------------------------------------------------------------------------------------------

    /// @notice Registers `code` as a referral code of the caller.
    /// @dev 1..`MAX_CODE_LENGTH` chars of `[a-z0-9_-]`, so a code has exactly one spelling. First
    /// come first served; a referrer may own several codes.
    /// @param code Referral code.
    function registerCode(string calldata code) external;

    /// @notice Binds the caller to the owner of `code` as its referrer. Once per user, forever.
    /// @dev Affects only Memes deployed afterwards: a Meme takes the referrer of its creator at
    /// deployment.
    /// @param code Referral code of the referrer.
    function useCode(string calldata code) external;

    /// @notice Pays the caller everything credited to it.
    /// @dev nonReentrant, whenNotPaused. Reverts with `NothingToClaim` if nothing is credited.
    /// @return amount Pair token paid.
    function claim() external returns (uint256 amount);

    /// @notice Pays every referrer of the list everything credited to it.
    /// @dev Permissionless, nonReentrant, whenNotPaused: funds only go to their owners. Referrers with nothing
    /// credited (or listed twice) are skipped.
    /// @param referrers Referrers to pay.
    /// @return total    Pair token paid in total.
    function distribute(address[] calldata referrers) external returns (uint256 total);

    // ---------------------------------------------------------------------------------------------
    // Protocol
    // ---------------------------------------------------------------------------------------------

    /// @notice Records the referrer of a new Meme: the referrer of its creator, if any.
    /// @dev Only controller, called from `deployToken`.
    /// @param meme    Deployed Meme.
    /// @param creator Account that deployed it.
    function registerToken(address meme, address creator) external;

    /// @notice Sends the whole protocol part of the pair token balance (balance minus everything
    ///         owed to referrers) to `to`.
    /// @dev Only owner, nonReentrant. Works while paused.
    /// @param to Recipient.
    /// @return amount Pair token sent.
    function withdrawProtocolFees(address to) external returns (uint256 amount);

    /// @notice Sends `amount` of any token but the pair token to `to`.
    /// @dev Only owner.
    function rescueERC20(address token, address to, uint256 amount) external;

    /// @notice Pauses / unpauses referral payouts (`claim`, `distribute`).
    /// @dev Only owner, no-op if already in that state. Crediting (`notifyFee`), code
    /// registration and `withdrawProtocolFees` keep working while paused.
    function setPaused(bool paused_) external;

    /// @notice Share of the protocol fee credited to the referrer of a Meme, in bips.
    /// @dev Only owner. Applies to fees arriving from now on. At most `BIPS`.
    function setRefShare(uint256 refShareBips) external;

    /// @dev Only owner, non-zero.
    function setController(address controller) external;

    /// @dev Only owner, non-zero. Every hook set before stays allowed to call `notifyFee`: hooks
    /// are not upgradeable, the pools of older Memes keep paying through theirs.
    function setHook(address hook) external;

    /// @notice Sets the vault that sends the protocol share of every fee here.
    /// @dev Only owner, non-zero.
    function setVault(address vault) external;

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function pairToken() external view returns (address);
    function controller() external view returns (address);
    /// @notice Hook of new Memes, the last one set by `setHook`.
    function hook() external view returns (address);
    /// @notice Whether `account` is the current hook or any hook set before.
    function isHook(address account) external view returns (bool);
    /// @notice Vault that sends the protocol share of every fee, zero if not set.
    function vault() external view returns (address);
    /// @notice Whether `account` may call `notifyFee`: the vault, or any hook ever set (hooks of
    ///         the older design paid the protocol share themselves).
    function isFeeSource(address account) external view returns (bool);
    function refShareBips() external view returns (uint256);
    /// @notice True while referral payouts are paused.
    function paused() external view returns (bool);

    /// @notice Owner of `code`, zero if not registered.
    function codeOwner(string calldata code) external view returns (address);
    /// @notice Owner of a code by its hash `keccak256(bytes(code))`, zero if not registered.
    function codeOwnerByHash(bytes32 codeHash) external view returns (address);
    /// @notice Referrer of `user`, zero if none.
    function referrerOf(address user) external view returns (address);
    /// @notice Referrer a Meme is attributed to, zero if none.
    function memeReferrer(address meme) external view returns (address);
    /// @notice Pair token credited to `referrer` and not paid yet.
    function pendingOf(address referrer) external view returns (uint256);
    /// @notice Pair token ever credited to `referrer`.
    function earnedOf(address referrer) external view returns (uint256);
    /// @notice Sum of `pendingOf` over all referrers.
    function totalPending() external view returns (uint256);
    /// @notice Pair token `withdrawProtocolFees` would send now.
    function protocolBalance() external view returns (uint256);
}
