// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Permit
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IVault, AssetConfig, VaultInfo} from "../interfaces/IVault.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {InterfaceChecker} from "../utils/InterfaceChecker.sol";

/// @title Gemoon fee vault.
/// @notice See {IVault}.
/// @dev Reward accounting.
///
/// USDG credits: every `notifyFees` adds `toStakers * PRECISION / totalStaked` to `accUsdPerShare`
/// (S). A staker with constant stake `a` earns `a * (S_now - S_checkpoint) / PRECISION` USDG.
///
/// Epochs: `convertFees` closes the open epoch `e`, storing S_e (accEnd), X_e (stakers' USDG of the
/// epoch) and, per asset i, A_e,i (stakers' part of the swap output). A USDG credit `c` earned in
/// epoch e is worth `c * A_e,i / X_e` of asset i. For epochs fully covered by a constant stake the
/// cumulative accumulator K_e,i = K_e-1,i + A_e,i * (S_e - S_e-1) / X_e gives the reward directly:
/// `a * (K_last,i - K_first,i) / PRECISION`.
///
/// A staker checkpoint therefore stores its stake, S at the checkpoint, the epoch of the checkpoint
/// and the USDG credit already earned in that epoch (`credit`). On the next checkpoint:
///  - same epoch: credit grows, nothing is converted yet;
///  - later epoch: credit of the checkpoint epoch is converted at that epoch's rate, epochs in
///    between are paid via K, and the credit of the open epoch starts from S_(E-1).
/// All divisions round down, so claimable rewards never exceed what conversions bought.
///
/// Deployed behind a TransparentUpgradeableProxy. OZ parents keep their state in ERC-7201
/// namespaces, the vault's own storage starts at slot 0 and is append-only across upgrades.
contract Vault is
    IVault,
    Initializable,
    Ownable2StepUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------

    struct Staker {
        uint256 amount;
        uint256 accCheckpoint;
        uint256 credit;
        uint64 epoch;
    }

    struct Epoch {
        uint256 accEnd;
        uint256 stakerUsd;
    }

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Version of the implementation, bump it together with `reinitialize` migrations.
    uint64 public constant VAULT_VERSION = 1;

    uint256 public constant BPS = 10_000;
    uint256 public constant CREATOR_SHARE_BPS = 1_000; // 10%
    uint256 public constant MAX_ASSETS = 5;
    uint256 public constant PRECISION = 1e36;

    // ---------------------------------------------------------------------------------------------
    // Storage (proxy). Append-only across upgrades: never reorder, retype or remove fields.
    // ---------------------------------------------------------------------------------------------

    /// @dev Set once in `initialize`, `s_accounted` of this token depends on it.
    IERC20 private s_usdg;
    address private s_controller;
    address private s_hook;
    address private s_keeper;
    address private s_swapAdapter;

    mapping(address asset => bool) private s_assetAllowed;
    mapping(address token => uint256) private s_accounted;

    mapping(address meme => VaultInfo) private s_vaults;
    mapping(address meme => AssetConfig[]) private s_assets;
    mapping(address meme => mapping(address account => Staker))
        private s_stakers;
    mapping(address meme => mapping(address account => mapping(uint256 assetIndex => uint256)))
        private s_owed;
    mapping(address meme => mapping(uint256 assetIndex => uint256))
        private s_creatorOwed;

    mapping(address meme => mapping(uint256 epoch => Epoch)) private s_epochs;
    /// @dev A_e,i: stakers' part of the output of epoch e in asset i.
    mapping(address meme => mapping(uint256 epoch => mapping(uint256 assetIndex => uint256)))
        private s_epochAssetOut;
    /// @dev K_e,i: cumulative asset i per staked Meme up to and including epoch e, scaled by PRECISION.
    mapping(address meme => mapping(uint256 epoch => mapping(uint256 assetIndex => uint256)))
        private s_cumAssetPerShare;

    // ---------------------------------------------------------------------------------------------
    // Modifiers
    // ---------------------------------------------------------------------------------------------

    modifier onlyController() {
        if (msg.sender != s_controller) revert NotController();
        _;
    }

    modifier onlyHook() {
        if (msg.sender != s_hook) revert NotHook();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != s_keeper) revert NotKeeper();
        _;
    }

    modifier onlyRegistered(address meme) {
        if (s_vaults[meme].registeredAt == 0) revert VaultNotRegistered(meme);
        _;
    }

    // ---------------------------------------------------------------------------------------------
    // Construction / initialization
    // ---------------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy storage. Called once, atomically with the proxy deployment.
    /// @param owner_ Admin of the vault (Ownable2Step).
    /// @param usdg_  Token fees arrive in.
    function initialize(address owner_, address usdg_) external initializer {
        if (owner_ == address(0) || usdg_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        s_usdg = IERC20(usdg_);
    }

    /// @notice Migration hook of an upgrade, runs once per `VAULT_VERSION`.
    /// @dev Must be called atomically via `ProxyAdmin.upgradeAndCall`. Owner, USDG and all
    /// accounting are kept as is; put storage migrations of a new version here.
    function reinitialize() external reinitializer(getVersion()) {}

    /// @notice Version of this implementation.
    /// @return Current `VAULT_VERSION`.
    function getVersion() public pure virtual returns (uint64) {
        return VAULT_VERSION;
    }

    // ---------------------------------------------------------------------------------------------
    // Registration
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function registerVault(
        address meme,
        address creator,
        AssetConfig[] calldata assets
    ) external onlyController {
        if (meme == address(0) || creator == address(0)) revert ZeroAddress();
        if (meme == address(s_usdg)) revert AssetNotAllowed(meme);

        VaultInfo storage v = s_vaults[meme];
        if (v.registeredAt != 0) revert VaultAlreadyRegistered(meme);

        uint256 n = assets.length;
        if (n == 0 || n > MAX_ASSETS) revert InvalidAssetsLength();

        uint256 totalWeight;
        AssetConfig[] storage stored = s_assets[meme];
        for (uint256 i; i < n; ++i) {
            address token = assets[i].token;
            if (!s_assetAllowed[token]) revert AssetNotAllowed(token);
            if (assets[i].weightBps == 0) revert InvalidWeights();
            for (uint256 j; j < i; ++j) {
                if (assets[j].token == token) revert DuplicateAsset(token);
            }
            totalWeight += assets[i].weightBps;
            stored.push(assets[i]);
        }
        if (totalWeight != BPS) revert InvalidWeights();

        v.creator = creator;
        v.registeredAt = uint64(block.timestamp);

        emit VaultRegistered(meme, creator, assets);
    }

    // ---------------------------------------------------------------------------------------------
    // Fee intake and conversion
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function notifyFees(
        address meme,
        uint256 usdgAmount
    ) external onlyHook onlyRegistered(meme) {
        if (usdgAmount == 0) revert ZeroAmount();
        address usdg_ = address(s_usdg);
        uint256 balance = IERC20(usdg_).balanceOf(address(this));
        uint256 accounted_ = s_accounted[usdg_];
        uint256 unaccounted = balance > accounted_ ? balance - accounted_ : 0;
        if (unaccounted < usdgAmount)
            revert UnaccountedBalanceTooLow(unaccounted, usdgAmount);

        s_accounted[usdg_] = accounted_ + usdgAmount;

        VaultInfo storage v = s_vaults[meme];
        uint256 toCreator = (usdgAmount * CREATOR_SHARE_BPS) / BPS;
        uint256 toStakers = usdgAmount - toCreator;

        uint256 accDelta = v.totalStaked == 0
            ? 0
            : Math.mulDiv(toStakers, PRECISION, v.totalStaked);
        // Nobody stakes, or the amount is too small to move the accumulator: all to the creator.
        if (accDelta == 0) {
            toCreator = usdgAmount;
            toStakers = 0;
        } else {
            v.accUsdPerShare += accDelta;
        }

        v.pendingStakerUSDG += toStakers;
        v.pendingCreatorUSDG += toCreator;

        emit FeesNotified(meme, toStakers, toCreator);
    }

    /// @inheritdoc IVault
    function convertFees(
        address meme,
        uint256[] calldata minAmountsOut
    )
        external
        onlyKeeper
        nonReentrant
        whenNotPaused
        onlyRegistered(meme)
        returns (uint256[] memory amountsOut)
    {
        AssetConfig[] storage assets = s_assets[meme];
        uint256 n = assets.length;
        if (minAmountsOut.length != n) revert LengthMismatch();

        VaultInfo storage v = s_vaults[meme];
        uint256 stakerUsd = v.pendingStakerUSDG;
        uint256 creatorUsd = v.pendingCreatorUSDG;
        uint256 total = stakerUsd + creatorUsd;
        if (total == 0) revert NothingToConvert();

        // Effects: close the epoch before any external call.
        uint64 e = v.epoch;
        uint256 accEnd = v.accUsdPerShare;
        uint256 accStart = e == 0 ? 0 : s_epochs[meme][e - 1].accEnd;
        s_epochs[meme][e] = Epoch({accEnd: accEnd, stakerUsd: stakerUsd});
        v.pendingStakerUSDG = 0;
        v.pendingCreatorUSDG = 0;
        v.epoch = e + 1;
        s_accounted[address(s_usdg)] -= total;

        // Interactions: swaps through the owner-set adapter, guarded by nonReentrant.
        amountsOut = new uint256[](n);
        uint256 spent;
        for (uint256 i; i < n; ++i) {
            uint256 amountIn = i == n - 1
                ? total - spent
                : (total * assets[i].weightBps) / BPS;
            spent += amountIn;
            amountsOut[i] = _swap(assets[i].token, amountIn, minAmountsOut[i]);
        }

        // Effects: book the outputs.
        uint256[] memory toStakers = new uint256[](n);
        uint256[] memory toCreator = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 out = amountsOut[i];
            toCreator[i] = Math.mulDiv(out, creatorUsd, total);
            toStakers[i] = out - toCreator[i];

            uint256 kPrev = e == 0 ? 0 : s_cumAssetPerShare[meme][e - 1][i];
            uint256 kDelta = stakerUsd == 0
                ? 0
                : Math.mulDiv(toStakers[i], accEnd - accStart, stakerUsd);
            s_epochAssetOut[meme][e][i] = toStakers[i];
            s_cumAssetPerShare[meme][e][i] = kPrev + kDelta;

            s_creatorOwed[meme][i] += toCreator[i];
            s_accounted[assets[i].token] += out;
        }

        emit FeesConverted(meme, e, total, toStakers, toCreator);
    }

    // ---------------------------------------------------------------------------------------------
    // Staking
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function stake(
        address meme,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyRegistered(meme) {
        _stake(meme, amount);
    }

    /// @inheritdoc IVault
    function stakeWithPermit(
        address meme,
        uint256 amount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused onlyRegistered(meme) {
        try
            IERC20Permit(meme).permit(
                msg.sender,
                address(this),
                amount,
                deadline,
                v,
                r,
                s
            )
        {} catch {}
        _stake(meme, amount);
    }

    /// @inheritdoc IVault
    function unstake(
        address meme,
        uint256 amount
    ) external nonReentrant onlyRegistered(meme) {
        _checkpoint(meme, msg.sender);
        _unstake(meme, amount);
    }

    /// @inheritdoc IVault
    function claim(
        address meme
    ) external nonReentrant whenNotPaused onlyRegistered(meme) {
        _checkpoint(meme, msg.sender);
        uint256 n = s_assets[meme].length;
        for (uint256 i; i < n; ++i) {
            _payReward(meme, i);
        }
    }

    /// @inheritdoc IVault
    function claim(
        address meme,
        address[] calldata assets
    ) external nonReentrant whenNotPaused onlyRegistered(meme) {
        _checkpoint(meme, msg.sender);
        for (uint256 i; i < assets.length; ++i) {
            _payReward(meme, _assetIndex(meme, assets[i]));
        }
    }

    /// @inheritdoc IVault
    function exit(
        address meme
    ) external nonReentrant whenNotPaused onlyRegistered(meme) {
        _checkpoint(meme, msg.sender);
        uint256 staked = s_stakers[meme][msg.sender].amount;
        if (staked != 0) _unstake(meme, staked);
        uint256 n = s_assets[meme].length;
        for (uint256 i; i < n; ++i) {
            _payReward(meme, i);
        }
    }

    /// @inheritdoc IVault
    function emergencyUnstake(
        address meme
    ) external nonReentrant onlyRegistered(meme) {
        VaultInfo storage v = s_vaults[meme];
        Staker storage st = s_stakers[meme][msg.sender];
        uint256 amount = st.amount;
        if (amount == 0) revert ZeroAmount();

        st.amount = 0;
        st.credit = 0;
        st.accCheckpoint = v.accUsdPerShare;
        st.epoch = v.epoch;
        v.totalStaked -= amount;
        s_accounted[meme] -= amount;

        IERC20(meme).safeTransfer(msg.sender, amount);
        emit EmergencyUnstaked(meme, msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Creator
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function claimCreatorRewards(
        address meme
    ) external nonReentrant whenNotPaused onlyRegistered(meme) {
        address creator = s_vaults[meme].creator;
        AssetConfig[] storage assets = s_assets[meme];
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            uint256 amount = s_creatorOwed[meme][i];
            if (amount == 0) continue;
            address token = assets[i].token;
            s_creatorOwed[meme][i] = 0;
            s_accounted[token] -= amount;
            IERC20(token).safeTransfer(creator, amount);
            emit CreatorRewardPaid(meme, creator, token, amount);
        }
    }

    /// @inheritdoc IVault
    function transferCreator(
        address meme,
        address newCreator
    ) external onlyRegistered(meme) {
        VaultInfo storage v = s_vaults[meme];
        if (msg.sender != v.creator) revert NotCreator();
        v.pendingCreator = newCreator;
        emit CreatorTransferStarted(meme, msg.sender, newCreator);
    }

    /// @inheritdoc IVault
    function acceptCreator(address meme) external onlyRegistered(meme) {
        VaultInfo storage v = s_vaults[meme];
        if (msg.sender != v.pendingCreator) revert NotPendingCreator();
        address previous = v.creator;
        v.creator = msg.sender;
        v.pendingCreator = address(0);
        emit CreatorTransferred(meme, previous, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        s_controller = controller_;
        emit ControllerUpdated(controller_);
    }

    /// @inheritdoc IVault
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        s_hook = hook_;
        emit HookUpdated(hook_);
    }

    /// @inheritdoc IVault
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        s_keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    /// @inheritdoc IVault
    function setSwapAdapter(address adapter) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        s_swapAdapter = adapter;
        emit SwapAdapterUpdated(adapter);
    }

    /// @inheritdoc IVault
    function setAssetAllowed(address asset, bool allowed) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        s_assetAllowed[asset] = allowed;
        emit AssetAllowedUpdated(asset, allowed);
    }

    /// @inheritdoc IVault
    function setPaused(bool paused_) external onlyOwner {
        if (paused_ == paused()) return;
        if (paused_) _pause();
        else _unpause();
    }

    /// @inheritdoc IVault
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 accounted_ = s_accounted[token];
        uint256 surplus = balance > accounted_ ? balance - accounted_ : 0;
        if (amount > surplus)
            revert RescueExceedsSurplus(token, surplus, amount);
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IVault
    function usdg() external view returns (address) {
        return address(s_usdg);
    }

    /// @inheritdoc IVault
    function controller() external view returns (address) {
        return s_controller;
    }

    /// @inheritdoc IVault
    function hook() external view returns (address) {
        return s_hook;
    }

    /// @inheritdoc IVault
    function keeper() external view returns (address) {
        return s_keeper;
    }

    /// @inheritdoc IVault
    function swapAdapter() external view returns (address) {
        return s_swapAdapter;
    }

    /// @inheritdoc IVault
    function isAssetAllowed(address asset) external view returns (bool) {
        return s_assetAllowed[asset];
    }

    /// @inheritdoc IVault
    function accounted(address token) external view returns (uint256) {
        return s_accounted[token];
    }

    /// @inheritdoc IVault
    function isRegistered(address meme) external view returns (bool) {
        return s_vaults[meme].registeredAt != 0;
    }

    /// @inheritdoc IVault
    function vaultInfo(address meme) external view returns (VaultInfo memory) {
        return s_vaults[meme];
    }

    /// @inheritdoc IVault
    function getAssets(
        address meme
    ) external view returns (AssetConfig[] memory) {
        return s_assets[meme];
    }

    /// @inheritdoc IVault
    function creatorOf(address meme) external view returns (address) {
        return s_vaults[meme].creator;
    }

    /// @inheritdoc IVault
    function totalStaked(address meme) external view returns (uint256) {
        return s_vaults[meme].totalStaked;
    }

    /// @inheritdoc IVault
    function stakedOf(
        address meme,
        address account
    ) external view returns (uint256) {
        return s_stakers[meme][account].amount;
    }

    /// @inheritdoc IVault
    function pendingUSDG(address meme) external view returns (uint256) {
        VaultInfo storage v = s_vaults[meme];
        return v.pendingStakerUSDG + v.pendingCreatorUSDG;
    }

    /// @inheritdoc IVault
    function pendingCreditOf(
        address meme,
        address account
    ) external view returns (uint256) {
        (, uint256 credit) = _settle(meme, s_stakers[meme][account]);
        return credit;
    }

    /// @inheritdoc IVault
    function earned(
        address meme,
        address account
    )
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        (amounts, ) = _settle(meme, s_stakers[meme][account]);
        assets = _assetTokens(meme);
        for (uint256 i; i < amounts.length; ++i) {
            amounts[i] += s_owed[meme][account][i];
        }
    }

    /// @inheritdoc IVault
    function creatorAccrued(
        address meme
    )
        external
        view
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = _assetTokens(meme);
        amounts = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            amounts[i] = s_creatorOwed[meme][i];
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _stake(address meme, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(meme, msg.sender);

        // Balance difference: the credited amount must be what actually arrived.
        IERC20 token = IERC20(meme);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();

        s_stakers[meme][msg.sender].amount += received;
        s_vaults[meme].totalStaked += received;
        s_accounted[meme] += received;

        emit Staked(meme, msg.sender, received);
    }

    /// @dev Caller must checkpoint `msg.sender` first.
    function _unstake(address meme, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        Staker storage st = s_stakers[meme][msg.sender];
        if (st.amount < amount) revert InsufficientStake(st.amount, amount);

        st.amount -= amount;
        s_vaults[meme].totalStaked -= amount;
        s_accounted[meme] -= amount;

        IERC20(meme).safeTransfer(msg.sender, amount);
        emit Unstaked(meme, msg.sender, amount);
    }

    /// @dev Caller must checkpoint `msg.sender` first.
    function _payReward(address meme, uint256 index) internal {
        uint256 amount = s_owed[meme][msg.sender][index];
        if (amount == 0) return;
        address token = s_assets[meme][index].token;
        s_owed[meme][msg.sender][index] = 0;
        s_accounted[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardPaid(meme, msg.sender, token, amount);
    }

    /// @dev Moves everything converted since the last checkpoint of `account` into `s_owed`.
    function _checkpoint(address meme, address account) internal {
        VaultInfo storage v = s_vaults[meme];
        Staker storage st = s_stakers[meme][account];
        (uint256[] memory owedDelta, uint256 credit) = _settle(meme, st);

        for (uint256 i; i < owedDelta.length; ++i) {
            if (owedDelta[i] != 0) s_owed[meme][account][i] += owedDelta[i];
        }
        st.credit = credit;
        st.accCheckpoint = v.accUsdPerShare;
        st.epoch = v.epoch;
    }

    /// @dev Pure accounting step of `_checkpoint`, see the contract-level comment.
    /// @return owedDelta Converted rewards per asset earned since the checkpoint of `st`.
    /// @return credit    USDG credit of `st` in the open epoch after the checkpoint.
    function _settle(
        address meme,
        Staker memory st
    ) internal view returns (uint256[] memory owedDelta, uint256 credit) {
        VaultInfo storage v = s_vaults[meme];
        uint256 n = s_assets[meme].length;
        owedDelta = new uint256[](n);
        uint64 openEpoch = v.epoch;

        if (st.epoch == openEpoch) {
            credit =
                st.credit +
                Math.mulDiv(
                    st.amount,
                    v.accUsdPerShare - st.accCheckpoint,
                    PRECISION
                );
            return (owedDelta, credit);
        }

        uint64 first = st.epoch;
        uint64 lastClosed = openEpoch - 1;
        Epoch storage firstEpoch = s_epochs[meme][first];
        uint256 firstCredit = st.credit +
            Math.mulDiv(
                st.amount,
                firstEpoch.accEnd - st.accCheckpoint,
                PRECISION
            );

        for (uint256 i; i < n; ++i) {
            if (firstCredit != 0 && firstEpoch.stakerUsd != 0) {
                owedDelta[i] = Math.mulDiv(
                    firstCredit,
                    s_epochAssetOut[meme][first][i],
                    firstEpoch.stakerUsd
                );
            }
            if (lastClosed > first && st.amount != 0) {
                owedDelta[i] += Math.mulDiv(
                    st.amount,
                    s_cumAssetPerShare[meme][lastClosed][i] -
                        s_cumAssetPerShare[meme][first][i],
                    PRECISION
                );
            }
        }

        credit = Math.mulDiv(
            st.amount,
            v.accUsdPerShare - s_epochs[meme][lastClosed].accEnd,
            PRECISION
        );
    }

    /// @dev Sells `amountIn` USDG for `asset` through the adapter, output by balance difference.
    function _swap(
        address asset,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        IERC20 usdg_ = s_usdg;
        if (amountIn == 0 || asset == address(usdg_)) {
            amountOut = amountIn;
        } else {
            address adapter = s_swapAdapter;
            if (adapter == address(0)) revert SwapAdapterNotSet();
            uint256 before = IERC20(asset).balanceOf(address(this));
            usdg_.safeTransfer(adapter, amountIn);
            ISwapAdapter(adapter).swap(
                address(usdg_),
                asset,
                amountIn,
                minAmountOut,
                address(this)
            );
            amountOut = IERC20(asset).balanceOf(address(this)) - before;
        }
        if (amountOut < minAmountOut)
            revert SlippageExceeded(asset, amountOut, minAmountOut);
    }

    function _assetIndex(
        address meme,
        address asset
    ) internal view returns (uint256) {
        AssetConfig[] storage assets = s_assets[meme];
        for (uint256 i; i < assets.length; ++i) {
            if (assets[i].token == asset) return i;
        }
        revert AssetNotInVault(meme, asset);
    }

    function _assetTokens(
        address meme
    ) internal view returns (address[] memory tokens) {
        AssetConfig[] storage assets = s_assets[meme];
        tokens = new address[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            tokens[i] = assets[i].token;
        }
    }
}
