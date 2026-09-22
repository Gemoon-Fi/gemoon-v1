// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
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
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title Gemoon UniswapV4 hook manager.
/// @notice Charges a fixed 1.25% swap fee, always denominated in `i_pairToken`:
///         0.25% goes to the protocol recipient, 1% goes to the vault.
/// @dev Deployed behind a TransparentUpgradeableProxy. UniswapV4 derives a hook's permissions from
/// the low bits of its address, so both the proxy (the address stored in `PoolKey.hooks`) and every
/// implementation must be CREATE2-mined to carry the bit pattern of `getHookPermissions`.
///
/// Fee flow:
///  - every swap: the fee is taken from the swapper via a hook delta and kept inside the PoolManager
///    as ERC6909 claims owned by this hook (`poolManager.mint`). No ERC20 transfer per swap.
///  - `distribute()`: burns all accrued claims and pays them out as real tokens, 1/5 to the protocol
///    recipient and 4/5 to the vault.
contract HookManager is BaseHook, IUnlockCallback, Initializable, Ownable2StepUpgradeable {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------------------------------
    // Errors / events
    // ---------------------------------------------------------------------------------------------

    /// @notice Thrown when a zero address is supplied where a contract is required.
    error ZeroAddress();

    /// @notice Thrown when a pool being initialized does not contain `i_pairToken`.
    error InvalidPoolPair();

    /// @notice Emitted on every swap that paid a fee.
    event FeeCharged(PoolId indexed poolId, address indexed sender, uint256 amount);

    /// @notice Emitted when accrued fees are paid out.
    event FeesDistributed(address indexed protocolRecipient, address indexed vault, uint256 toProtocol, uint256 toVault);

    event ProtocolRecipientUpdated(address indexed recipient);
    event VaultUpdated(address indexed vault);

    // ---------------------------------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------------------------------

    /// @dev Version of the HookManager contract.
    uint64 public constant HOOK_MANAGER_VERSION = 1;

    uint256 public constant BIPS = 10_000;
    /// @notice Total fee charged on a swap: 1.25%.
    uint256 public constant TOTAL_FEE_BIPS = 125;
    /// @notice Protocol part of the total fee: 0.25%. The vault gets the rest (1%).
    uint256 public constant PROTOCOL_FEE_BIPS = 25;

    /// @dev Immutable (not storage) so it resolves from implementation bytecode under the proxy's delegatecall.
    Currency private immutable i_pairToken;

    // ---------------------------------------------------------------------------------------------
    // Storage (proxy). Append-only across upgrades.
    // ---------------------------------------------------------------------------------------------

    /// @notice Receives 0.25% of every swap.
    address public protocolRecipient;
    /// @notice Receives 1% of every swap.
    address public vault;

    // ---------------------------------------------------------------------------------------------
    // Construction / initialization
    // ---------------------------------------------------------------------------------------------

    /// @param poolManager_ UniswapV4 pool manager this hook is bound to.
    /// @param pairToken_ Currency every pool bound to this hook must contain; all fees are paid in it.
    constructor(IPoolManager poolManager_, Currency pairToken_) BaseHook(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        i_pairToken = pairToken_;
        _disableInitializers();
    }

    /// @notice Returns the version of this implementation.
    function getVersion() public pure returns (uint64) {
        return HOOK_MANAGER_VERSION;
    }

    /// @notice Initializes the proxy.
    function initialize(address owner_, address protocolRecipient_, address vault_) public initializer {
        _init(owner_, protocolRecipient_, vault_);
    }

    /// @notice Re-initializes the proxy after an upgrade.
    function reinitialize(address owner_, address protocolRecipient_, address vault_)
        external
        reinitializer(getVersion())
    {
        _init(owner_, protocolRecipient_, vault_);
    }

    function _init(address owner_, address protocolRecipient_, address vault_) internal {
        if (owner_ == address(0)) revert ZeroAddress();

        __Ownable_init(owner_);
        __Ownable2Step_init();

        _setProtocolRecipient(protocolRecipient_);
        _setVault(vault_);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    /// @dev Fees already accrued are paid to whatever recipient is set at `distribute()` time.
    /// Call `distribute()` first if accrued fees must go to the old recipient.
    function setProtocolRecipient(address recipient) external onlyOwner {
        _setProtocolRecipient(recipient);
    }

    /// @dev Same note as `setProtocolRecipient`.
    function setVault(address vault_) external onlyOwner {
        _setVault(vault_);
    }

    function _setProtocolRecipient(address recipient) internal {
        if (recipient == address(0)) revert ZeroAddress();
        protocolRecipient = recipient;
        emit ProtocolRecipientUpdated(recipient);
    }

    function _setVault(address vault_) internal {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultUpdated(vault_);
    }

    // ---------------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------------

    /// @inheritdoc BaseHook
    /// @dev The *ReturnDelta flags are required: without them the PoolManager ignores the deltas
    /// returned from beforeSwap/afterSwap and no fee can be taken.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
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

    /// @dev Only pools that contain `i_pairToken` may use this hook.
    function _beforeInitialize(address, PoolKey calldata poolKey, uint160) internal view override returns (bytes4) {
        if (!(poolKey.currency0 == i_pairToken) && !(poolKey.currency1 == i_pairToken)) revert InvalidPoolPair();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev No-op.
    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    /// @dev `i_pairToken` is the specified currency (the amount the user fixed): its value is known before
    /// the swap, so the fee is taken here. The specified delta is applied by the PoolManager immediately:
    ///  - exactIn  (pairToken in):  only `amount - fee` goes through the pool
    ///  - exactOut (pairToken out): the pool outputs `amount + fee`, the user still receives `amount`
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (!_pairTokenIsSpecified(key, params)) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        int128 fee = _chargeFee(key, sender, _abs(params.amountSpecified));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @dev `i_pairToken` is the unspecified currency (the amount the pool computed): its value is known
    /// only after the swap, so the fee is taken here from the pool delta:
    ///  - exactIn  (pairToken out): the user receives `out - fee`
    ///  - exactOut (pairToken in):  the user pays `in + fee`
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        if (_pairTokenIsSpecified(key, params)) {
            return (IHooks.afterSwap.selector, 0);
        }

        int128 amount = key.currency0 == i_pairToken ? delta.amount0() : delta.amount1();
        return (IHooks.afterSwap.selector, _chargeFee(key, sender, _abs(amount)));
    }

    // ---------------------------------------------------------------------------------------------
    // Fee internals
    // ---------------------------------------------------------------------------------------------

    /// @dev Specified currency = the one whose amount is fixed in `amountSpecified`:
    /// exactIn (amountSpecified < 0) -> input currency, exactOut (> 0) -> output currency.
    function _pairTokenIsSpecified(PoolKey calldata key, SwapParams calldata params) internal view returns (bool) {
        bool specifiedIs0 = (params.amountSpecified < 0) == params.zeroForOne;
        bool pairTokenIs0 = key.currency0 == i_pairToken;
        return specifiedIs0 == pairTokenIs0;
    }

    /// @dev Computes the fee, closes the hook's positive delta by minting ERC6909 claims to itself and
    /// returns the fee as a positive hook delta (positive = hook takes, swapper pays).
    function _chargeFee(PoolKey calldata key, address sender, uint256 amount) internal returns (int128) {
        uint256 fee = amount * TOTAL_FEE_BIPS / BIPS;
        if (fee == 0) return 0;

        poolManager.mint(address(this), i_pairToken.toId(), fee);
        emit FeeCharged(key.toId(), sender, fee);

        return fee.toInt128();
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    // ---------------------------------------------------------------------------------------------
    // Distribution
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees accrued and not yet distributed, in `i_pairToken`.
    function pendingFees() external view returns (uint256) {
        return poolManager.balanceOf(address(this), i_pairToken.toId());
    }

    /// @notice Currency all fees are paid in.
    function pairToken() external view returns (Currency) {
        return i_pairToken;
    }

    /// @notice Pays out all accrued fees: 1/5 to `protocolRecipient`, 4/5 to `vault`.
    /// @dev Permissionless: recipients are fixed by the owner, the caller only pays gas.
    /// Must not be called from inside another PoolManager unlock (reverts with AlreadyUnlocked).
    function distribute() external {
        poolManager.unlock("");
    }

    /// @dev Called by the PoolManager only as a result of `distribute()` (the PoolManager calls back
    /// `msg.sender` of `unlock`, i.e. this proxy).
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 id = i_pairToken.toId();
        uint256 total = poolManager.balanceOf(address(this), id);
        if (total == 0) return "";

        uint256 toProtocol = total * PROTOCOL_FEE_BIPS / TOTAL_FEE_BIPS; // 0.25 / 1.25 = 1/5
        uint256 toVault = total - toProtocol; // remainder, no rounding loss

        address protocol_ = protocolRecipient;
        address vault_ = vault;

        // claims -> positive delta for the hook -> real tokens out, delta back to zero
        poolManager.burn(address(this), id, total);
        poolManager.take(i_pairToken, protocol_, toProtocol);
        poolManager.take(i_pairToken, vault_, toVault);

        emit FeesDistributed(protocol_, vault_, toProtocol, toVault);
        return "";
    }
}
