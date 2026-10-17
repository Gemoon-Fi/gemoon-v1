// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    PausableUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IReferrals} from "./interfaces/IReferrals.sol";
import {Hash, Hashes} from "./utils/Hash.sol";

/// @title Gemoon referrals and protocol fee receiver.
/// @notice See {IReferrals}. Set as `HookManager.protocolRecipient`: receives the protocol share
///         of every swap fee, credits `refShareBips` of it to the referrer of the Meme and keeps
///         the rest for the protocol.
/// @dev Accounting, in the pair token:
///  - `s_pending[r]`: owed to referrer `r`; `s_totalPending` is their sum.
///  - Protocol part: `balance - s_totalPending`, everything not owed to referrers, including fees of
///    Memes without a referrer and tokens sent here directly.
/// Invariant: `pairToken.balanceOf(this) >= s_totalPending`, checked on every credit.
///
/// Pause stops only referral payouts (`claim`, `distribute`). Fees keep being credited, so hook
/// payouts never fail because of it, and the protocol part can always be withdrawn: it never
/// touches what is owed to referrers.
///
/// Deployed behind a TransparentUpgradeableProxy. OZ parents keep their state in ERC-7201
/// namespaces, own storage starts at slot 0 and is append-only across upgrades.
contract GmoonReferrals is
    IReferrals,
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    uint64 public constant REFERRALS_VERSION = 1;
    uint256 public constant BIPS = 10_000;
    uint256 public constant MAX_CODE_LENGTH = 32;

    // ---------------------------------------------------------------------------------------------
    // Storage (proxy). Append-only across upgrades.
    // ---------------------------------------------------------------------------------------------

    IERC20 private s_pairToken;
    address private s_controller;
    address private s_hook;
    uint256 private s_refShareBips;

    mapping(bytes32 codeHash => address) private s_codeOwner;
    mapping(address user => address) private s_referrerOf;
    mapping(address meme => address) private s_memeReferrer;
    mapping(address referrer => uint256) private s_pending;
    mapping(address referrer => uint256) private s_earned;
    uint256 private s_totalPending;

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

    // ---------------------------------------------------------------------------------------------
    // Construction / initialization
    // ---------------------------------------------------------------------------------------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the proxy storage. Called once, atomically with the proxy deployment.
    /// @dev `controller_` and `hook_` may be zero and set later: the hook needs this address in its
    /// own `initialize`, so one of them is always deployed first.
    /// @param owner_        Admin (Ownable2Step).
    /// @param pairToken_    Token the fees arrive in, `HookManager.pairToken()`.
    /// @param controller_   GemoonController, or zero.
    /// @param hook_         HookManager, or zero.
    /// @param refShareBips_ Share of the protocol fee credited to referrers, in bips.
    function initialize(
        address owner_,
        address pairToken_,
        address controller_,
        address hook_,
        uint256 refShareBips_
    ) external initializer {
        if (owner_ == address(0) || pairToken_ == address(0))
            revert ZeroAddress();

        __Ownable_init(owner_);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        s_pairToken = IERC20(pairToken_);
        _setRefShare(refShareBips_);
        if (controller_ != address(0)) _setController(controller_);
        if (hook_ != address(0)) _setHook(hook_);
    }

    /// @notice Migration hook of an upgrade, runs once per `REFERRALS_VERSION`.
    /// @dev Must be called atomically via `ProxyAdmin.upgradeAndCall`.
    function reinitialize() external reinitializer(getVersion()) {}

    /// @notice Version of this implementation.
    /// @return Current `REFERRALS_VERSION`.
    function getVersion() public pure virtual returns (uint64) {
        return REFERRALS_VERSION;
    }

    // ---------------------------------------------------------------------------------------------
    // Users
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IReferrals
    function registerCode(string calldata code) external {
        _validateCode(code);
        bytes32 codeHash = _hash(code);
        if (s_codeOwner[codeHash] != address(0)) revert CodeTaken(codeHash);

        s_codeOwner[codeHash] = msg.sender;
        emit CodeRegistered(msg.sender, codeHash, code);
    }

    /// @inheritdoc IReferrals
    function useCode(string calldata code) external {
        bytes32 codeHash = _hash(code);
        address referrer = s_codeOwner[codeHash];
        if (referrer == address(0)) revert CodeNotFound(codeHash);
        if (referrer == msg.sender) revert SelfReferral();
        address current = s_referrerOf[msg.sender];
        if (current != address(0))
            revert ReferrerAlreadySet(msg.sender, current);

        s_referrerOf[msg.sender] = referrer;
        emit ReferrerSet(msg.sender, referrer, codeHash);
    }

    /// @inheritdoc IReferrals
    function claim()
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount)
    {
        amount = _pay(msg.sender);
        if (amount == 0) revert NothingToClaim();
    }

    /// @inheritdoc IReferrals
    function distribute(
        address[] calldata referrers
    ) external nonReentrant whenNotPaused returns (uint256 total) {
        for (uint256 i; i < referrers.length; ++i) {
            total += _pay(referrers[i]);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Protocol
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IReferrals
    function registerToken(
        address meme,
        address creator
    ) external onlyController {
        address referrer = s_referrerOf[creator];
        if (referrer != address(0)) s_memeReferrer[meme] = referrer;
        emit TokenRegistered(meme, creator, referrer);
    }

    /// @notice Credits the referrer of `meme` with its share of `amount`.
    /// @dev Only hook, right after it transferred `amount` here. Never reverts for a Meme without a
    /// referrer or a zero share, so it cannot block the hook payout; reverts only if the balance
    /// would not cover what is owed to referrers.
    /// @param meme   Meme whose pool generated the fees.
    /// @param amount Pair token amount transferred.
    function notifyFee(address meme, uint256 amount) external onlyHook {
        address referrer = s_memeReferrer[meme];
        uint256 refAmount = referrer == address(0)
            ? 0
            : (amount * s_refShareBips) / BIPS;

        if (refAmount != 0) {
            uint256 newTotal = s_totalPending + refAmount;
            uint256 balance = s_pairToken.balanceOf(address(this));
            if (balance < newTotal) revert BalanceTooLow(balance, newTotal);

            s_totalPending = newTotal;
            s_pending[referrer] += refAmount;
            s_earned[referrer] += refAmount;
        }

        emit FeeReceived(meme, referrer, amount, refAmount);
    }

    /// @inheritdoc IReferrals
    function withdrawProtocolFees(
        address to
    ) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = protocolBalance();
        if (amount == 0) revert NothingToClaim();

        s_pairToken.safeTransfer(to, amount);
        emit ProtocolFeesWithdrawn(to, amount);
    }

    /// @inheritdoc IReferrals
    function rescueERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (token == address(s_pairToken)) revert PairTokenRescue();

        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /// @inheritdoc IReferrals
    function setPaused(bool paused_) external onlyOwner {
        if (paused_ == paused()) return;
        if (paused_) _pause();
        else _unpause();
    }

    /// @inheritdoc IReferrals
    function setRefShare(uint256 refShareBips_) external onlyOwner {
        _setRefShare(refShareBips_);
    }

    /// @inheritdoc IReferrals
    function setController(address controller_) external onlyOwner {
        _setController(controller_);
    }

    /// @inheritdoc IReferrals
    function setHook(address hook_) external onlyOwner {
        _setHook(hook_);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc IReferrals
    function pairToken() external view returns (address) {
        return address(s_pairToken);
    }

    /// @inheritdoc IReferrals
    function controller() external view returns (address) {
        return s_controller;
    }

    /// @inheritdoc IReferrals
    function hook() external view returns (address) {
        return s_hook;
    }

    /// @inheritdoc IReferrals
    function paused()
        public
        view
        override(IReferrals, PausableUpgradeable)
        returns (bool)
    {
        return super.paused();
    }

    /// @inheritdoc IReferrals
    function refShareBips() external view returns (uint256) {
        return s_refShareBips;
    }

    /// @inheritdoc IReferrals
    function codeOwner(string calldata code) external view returns (address) {
        return s_codeOwner[_hash(code)];
    }

    /// @inheritdoc IReferrals
    function codeOwnerByHash(bytes32 codeHash) external view returns (address) {
        return s_codeOwner[codeHash];
    }

    /// @inheritdoc IReferrals
    function referrerOf(address user) external view returns (address) {
        return s_referrerOf[user];
    }

    /// @inheritdoc IReferrals
    function memeReferrer(address meme) external view returns (address) {
        return s_memeReferrer[meme];
    }

    /// @inheritdoc IReferrals
    function pendingOf(address referrer) external view returns (uint256) {
        return s_pending[referrer];
    }

    /// @inheritdoc IReferrals
    function earnedOf(address referrer) external view returns (uint256) {
        return s_earned[referrer];
    }

    /// @inheritdoc IReferrals
    function totalPending() external view returns (uint256) {
        return s_totalPending;
    }

    /// @inheritdoc IReferrals
    function protocolBalance() public view returns (uint256) {
        uint256 balance = s_pairToken.balanceOf(address(this));
        uint256 owed = s_totalPending;
        return balance > owed ? balance - owed : 0;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Pays `referrer` everything credited to it, zero if nothing. Effects before the transfer.
    function _pay(address referrer) internal returns (uint256 amount) {
        amount = s_pending[referrer];
        if (amount == 0) return 0;

        s_pending[referrer] = 0;
        s_totalPending -= amount;

        s_pairToken.safeTransfer(referrer, amount);
        emit ReferralPaid(referrer, amount);
    }

    function _setRefShare(uint256 refShareBips_) internal {
        if (refShareBips_ > BIPS) revert InvalidRefShare(refShareBips_);
        s_refShareBips = refShareBips_;
        emit RefShareUpdated(refShareBips_);
    }

    function _setController(address controller_) internal {
        if (controller_ == address(0)) revert ZeroAddress();
        s_controller = controller_;
        emit ControllerUpdated(controller_);
    }

    function _setHook(address hook_) internal {
        if (hook_ == address(0)) revert ZeroAddress();
        s_hook = hook_;
        emit HookUpdated(hook_);
    }

    function _hash(string calldata code) internal pure returns (bytes32) {
        return Hash.unwrap(Hashes.codeToToken(code));
    }

    /// @dev 1..MAX_CODE_LENGTH chars of `[a-z0-9_-]`.
    function _validateCode(string calldata code) internal pure {
        bytes calldata b = bytes(code);
        if (b.length == 0 || b.length > MAX_CODE_LENGTH) revert InvalidCode();
        for (uint256 i; i < b.length; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= "a" && c <= "z") ||
                (c >= "0" && c <= "9") ||
                c == "_" ||
                c == "-";
            if (!ok) revert InvalidCode();
        }
    }
}
