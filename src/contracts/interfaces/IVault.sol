// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @notice One reward asset of a Meme vault and its share of every conversion.
/// @param token     Reward asset (e.g. tokenized AAPL, NVDA, wBTC). Must be allowlisted.
/// @param weightBps Share of converted USDG swapped into `token`. Weights of a vault sum to BPS.
struct AssetConfig {
    address token;
    uint16 weightBps;
}

/// @notice Aggregated state of one Meme vault.
/// @param creator            Receives CREATOR_SHARE_BPS of every fee, or all of it while nobody stakes.
/// @param pendingCreator     Nominee of a two-step creator transfer, zero if none.
/// @param registeredAt       Registration timestamp, zero if the vault does not exist.
/// @param epoch              Index of the open conversion epoch. Every `convertFees` closes it.
/// @param totalStaked        Meme currently staked in the vault.
/// @param accUsdPerShare     USDG credited per staked Meme since registration, scaled by PRECISION.
/// @param pendingStakerUSDG  USDG credited to stakers in the open epoch, not yet converted.
/// @param pendingCreatorUSDG USDG credited to the creator in the open epoch, not yet converted.
struct VaultInfo {
    address creator;
    address pendingCreator;
    uint64 registeredAt;
    uint64 epoch;
    uint256 totalStaked;
    uint256 accUsdPerShare;
    uint256 pendingStakerUSDG;
    uint256 pendingCreatorUSDG;
}

/// @title Gemoon fee vault.
/// @notice Single contract holding one logical vault per Meme token.
///
/// Flow:
///  1. `registerVault` - controller, on Meme deployment: fixes creator and reward assets.
///  2. `notifyFees`    - hook, right after every swap in the Meme/USDG pool (1% of volume).
///                       The fee is credited in USDG immediately: CREATOR_SHARE_BPS to the creator,
///                       the rest pro rata to current stakers. If nobody stakes, all of it goes
///                       to the creator. So a staker earns only fees that arrive while staked, and
///                       the reward rate follows pool volume.
///  3. `convertFees`   - keeper: swaps all USDG credited in the open epoch into the vault assets
///                       by weight and closes the epoch. Every credit of that epoch is paid out in
///                       the assets bought by that epoch's conversion, pro rata to its USDG amount.
///  4. `stake/unstake/claim` - Meme holders. Only converted rewards can be claimed.
///
/// Roles: owner (Ownable2Step) - admin setters and pause; controller - registration;
/// hook - fee notification; keeper - conversion.
///
/// Invariants (for invariant tests):
///  - For every meme: totalStaked(meme) == sum of stakedOf(meme, account).
///  - For every token: balanceOf(vault) >= accounted amount (stakes + unconverted USDG + unclaimed
///    rewards of stakers and creators).
///  - Sum of stakers' USDG credits of an epoch <= pendingStakerUSDG of that epoch, so the sum of
///    claimable rewards never exceeds what the conversion bought.
///  - Sum of AssetConfig.weightBps of every registered vault == BPS.
///  - Stakers can always withdraw principal via `unstake` / `emergencyUnstake`, even when paused.
interface IVault {
    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error ZeroAmount();
    error NotController();
    error NotHook();
    error NotKeeper();
    error NotCreator();
    error NotPendingCreator();
    error VaultAlreadyRegistered(address meme);
    error VaultNotRegistered(address meme);
    error AssetNotAllowed(address asset);
    error DuplicateAsset(address asset);
    error InvalidAssetsLength();
    error InvalidWeights();
    error AssetNotInVault(address meme, address asset);
    error LengthMismatch();
    error InsufficientStake(uint256 staked, uint256 requested);
    error UnaccountedBalanceTooLow(uint256 unaccounted, uint256 notified);
    error NothingToConvert();
    error SlippageExceeded(address asset, uint256 amountOut, uint256 minAmountOut);
    error SwapAdapterNotSet();
    error RescueExceedsSurplus(address token, uint256 surplus, uint256 requested);

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event VaultRegistered(address indexed meme, address indexed creator, AssetConfig[] assets);
    event FeesNotified(address indexed meme, uint256 toStakers, uint256 toCreator);
    event FeesConverted(
        address indexed meme,
        uint64 indexed epoch,
        uint256 usdgIn,
        uint256[] toStakers,
        uint256[] toCreator
    );
    event Staked(address indexed meme, address indexed account, uint256 amount);
    event Unstaked(address indexed meme, address indexed account, uint256 amount);
    event EmergencyUnstaked(address indexed meme, address indexed account, uint256 amount);
    event RewardPaid(
        address indexed meme,
        address indexed account,
        address indexed asset,
        uint256 amount
    );
    event CreatorRewardPaid(
        address indexed meme,
        address indexed creator,
        address indexed asset,
        uint256 amount
    );
    event CreatorTransferStarted(address indexed meme, address indexed from, address indexed to);
    event CreatorTransferred(address indexed meme, address indexed from, address indexed to);
    event ControllerUpdated(address indexed controller);
    event HookUpdated(address indexed hook);
    event KeeperUpdated(address indexed keeper);
    event SwapAdapterUpdated(address indexed adapter);
    event AssetAllowedUpdated(address indexed asset, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Registration (controller)
    // ---------------------------------------------------------------------------------------------

    /// @notice Creates the vault of a freshly deployed Meme token.
    /// @dev Only controller. Assets are immutable after registration.
    /// Reverts if any asset is not allowlisted, duplicated, or weights do not sum to BPS.
    /// @param meme    Meme token, also the staking token of this vault.
    /// @param creator Receives the creator share of fees.
    /// @param assets  Reward assets and their weights, 1..MAX_ASSETS entries.
    function registerVault(address meme, address creator, AssetConfig[] calldata assets) external;

    // ---------------------------------------------------------------------------------------------
    // Fee intake and conversion
    // ---------------------------------------------------------------------------------------------

    /// @notice Credits USDG already transferred to the vault to the vault of `meme`.
    /// @dev Only hook, in the same tx as the transfer. Not affected by pause.
    /// Reverts if USDG balance minus accounted USDG is below `usdgAmount`.
    /// @param meme       Meme whose pool generated the fees.
    /// @param usdgAmount USDG amount transferred.
    function notifyFees(address meme, uint256 usdgAmount) external;

    /// @notice Swaps all USDG credited in the open epoch of `meme` into its reward assets by weight
    ///         and closes the epoch.
    /// @dev Only keeper, nonReentrant, whenNotPaused.
    /// @param meme          Meme vault to convert.
    /// @param minAmountsOut Minimum output per asset, in the order of `getAssets(meme)`.
    /// @return amountsOut   Output per asset, stakers' and creator's parts together.
    function convertFees(address meme, uint256[] calldata minAmountsOut)
        external
        returns (uint256[] memory amountsOut);

    // ---------------------------------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------------------------------

    /// @notice Stakes Meme tokens into the vault of `meme`.
    /// @dev nonReentrant, whenNotPaused. Credited amount is measured by balance difference.
    /// @param meme   Meme token to stake.
    /// @param amount Amount to transfer from the caller.
    function stake(address meme, uint256 amount) external;

    /// @notice Stakes with an EIP-2612 permit instead of a prior approval.
    /// @dev A failing permit is ignored, so a front-run permit does not block the stake.
    /// @param meme     Meme token to stake.
    /// @param amount   Amount to transfer from the caller.
    /// @param deadline Permit deadline.
    /// @param v        Permit signature v.
    /// @param r        Permit signature r.
    /// @param s        Permit signature s.
    function stakeWithPermit(
        address meme,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;

    /// @notice Withdraws staked Meme. Accrued rewards stay claimable.
    /// @dev nonReentrant. Works while paused.
    /// @param meme   Meme token to unstake.
    /// @param amount Amount to withdraw.
    function unstake(address meme, uint256 amount) external;

    /// @notice Claims all converted rewards of the caller in every asset of `meme`.
    /// @dev nonReentrant, whenNotPaused.
    /// @param meme Meme vault to claim from.
    function claim(address meme) external;

    /// @notice Claims converted rewards of the caller in the given assets only.
    /// @dev Lets a staker skip an asset whose transfer is broken.
    /// @param meme   Meme vault to claim from.
    /// @param assets Subset of `getAssets(meme)`.
    function claim(address meme, address[] calldata assets) external;

    /// @notice Unstakes the whole stake and claims all converted rewards.
    /// @param meme Meme vault to exit.
    function exit(address meme) external;

    /// @notice Withdraws the whole stake without touching reward accounting.
    /// @dev Works while paused. Rewards settled by previous checkpoints (stake/unstake/claim) stay
    /// claimable, everything earned since the last checkpoint of the caller is forfeited.
    /// @param meme Meme vault to exit.
    function emergencyUnstake(address meme) external;

    // ---------------------------------------------------------------------------------------------
    // Creator
    // ---------------------------------------------------------------------------------------------

    /// @notice Sends the converted creator share in every asset of `meme` to the creator.
    /// @dev Callable by anyone, funds always go to the current creator. whenNotPaused.
    /// @param meme Meme vault to claim from.
    function claimCreatorRewards(address meme) external;

    /// @notice Starts a two-step transfer of the creator role.
    /// @dev Only current creator. Zero address cancels a pending transfer.
    /// @param meme       Meme vault.
    /// @param newCreator Nominee.
    function transferCreator(address meme, address newCreator) external;

    /// @notice Accepts the creator role. Unclaimed creator rewards move with the role.
    /// @dev Only pending creator.
    /// @param meme Meme vault.
    function acceptCreator(address meme) external;

    // ---------------------------------------------------------------------------------------------
    // Admin (owner)
    // ---------------------------------------------------------------------------------------------

    /// @notice Sets the controller allowed to register vaults.
    function setController(address controller) external;

    /// @notice Sets the hook allowed to notify fees.
    function setHook(address hook) external;

    /// @notice Sets the keeper allowed to convert fees.
    function setKeeper(address keeper) external;

    /// @notice Sets the adapter that performs USDG -> asset swaps.
    function setSwapAdapter(address adapter) external;

    /// @notice Adds or removes an asset from the allowlist for new vaults.
    /// @dev Does not affect already registered vaults.
    function setAssetAllowed(address asset, bool allowed) external;

    /// @notice Pauses or unpauses stake, claim and conversion. Fee intake and unstake stay available.
    function setPaused(bool paused) external;

    /// @notice Withdraws tokens sent to the vault by mistake.
    /// @dev Only the part of balance above the accounted amount of `token` can be rescued.
    /// @param token  Token to rescue.
    /// @param to     Recipient.
    /// @param amount Amount to rescue.
    function rescueERC20(address token, address to, uint256 amount) external;

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Basis points denominator (10_000).
    function BPS() external view returns (uint256);

    /// @notice Share of every fee credited to the creator (1_000 = 10%).
    function CREATOR_SHARE_BPS() external view returns (uint256);

    /// @notice Maximum number of reward assets per vault.
    function MAX_ASSETS() external view returns (uint256);

    /// @notice Scale of `accUsdPerShare`.
    function PRECISION() external view returns (uint256);

    /// @notice USDG, the token fees arrive in.
    function usdg() external view returns (address);

    function controller() external view returns (address);

    function hook() external view returns (address);

    function keeper() external view returns (address);

    function swapAdapter() external view returns (address);

    function isAssetAllowed(address asset) external view returns (bool);

    /// @notice Balance of `token` owned by stakers, creators or pending conversion.
    function accounted(address token) external view returns (uint256);

    /// @notice True if a vault for `meme` has been registered.
    function isRegistered(address meme) external view returns (bool);

    /// @notice Aggregated state of the vault of `meme`.
    function vaultInfo(address meme) external view returns (VaultInfo memory);

    /// @notice Reward assets of `meme` and their weights, in conversion order.
    function getAssets(address meme) external view returns (AssetConfig[] memory);

    function creatorOf(address meme) external view returns (address);

    function totalStaked(address meme) external view returns (uint256);

    function stakedOf(address meme, address account) external view returns (uint256);

    /// @notice USDG credited in the open epoch of `meme` and not yet converted.
    function pendingUSDG(address meme) external view returns (uint256);

    /// @notice USDG credited to `account` in the open epoch, to be converted by the next `convertFees`.
    function pendingCreditOf(address meme, address account) external view returns (uint256);

    /// @notice Converted rewards of `account` claimable now, in every asset of `meme`.
    /// @return assets  Reward assets, same order as `getAssets(meme)`.
    /// @return amounts Claimable amount per asset.
    function earned(address meme, address account)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);

    /// @notice Converted creator share claimable now, in every asset of `meme`.
    /// @return assets  Reward assets, same order as `getAssets(meme)`.
    /// @return amounts Claimable amount per asset.
    function creatorAccrued(address meme)
        external
        view
        returns (address[] memory assets, uint256[] memory amounts);
}
