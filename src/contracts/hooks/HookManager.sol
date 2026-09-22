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
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    Ownable2StepUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

/// @title Gemoon UniswapV4 hook manager.
/// @notice Charges a fixed 1.25% swap fee, always denominated in `i_pairToken`:
///         0.25% goes to the protocol recipient, 1% goes to the vault.
/// @dev Deployed behind a TransparentUpgradeableProxy. Both the proxy and every implementation
/// must be CREATE2-mined to carry the bit pattern of `getHookPermissions`.
///
/// Fee flow:
///  - every swap: the fee is taken from the swapper via a hook delta and recorded inside the
///    PoolManager as ERC6909 claims owned by this hook (`poolManager.mint`).
///  - end of every swap (`_afterSwap`): all accrued claims are paid out as real tokens, 1/5 to the
///    protocol recipient and 4/5 to the vault. The swapper pays the gas. The payout runs inside
///    try/catch: if it fails, the swap still succeeds and the fee stays accrued until the next
///    successful payout.
///  - `distribute()`: manual fallback that pays out whatever is accrued.
contract HookManager is
    BaseHook,
    IUnlockCallback,
    Initializable,
    Ownable2StepUpgradeable
{
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;

    // ---------------------------------------------------------------------------------------------
    // Errors / events
    // ---------------------------------------------------------------------------------------------

    error ZeroAddress();
    error InvalidPoolPair();
    error NotSelf();

    event FeeCharged(
        PoolId indexed poolId,
        address indexed sender,
        uint256 amount
    );
    event FeesDistributed(
        address indexed protocolRecipient,
        address indexed vault,
        uint256 toProtocol,
        uint256 toVault
    );
    event PayoutFailed(bytes reason);
    event ProtocolRecipientUpdated(address indexed recipient);
    event VaultUpdated(address indexed vault);

    // ---------------------------------------------------------------------------------------------
    // Constants / immutables
    // ---------------------------------------------------------------------------------------------

    uint64 public constant HOOK_MANAGER_VERSION = 1;

    uint256 public constant BIPS = 10_000;
    uint256 public TOTAL_FEE_BIPS = 125; // 1.25%
    uint256 public PROTOCOL_FEE_BIPS = 25; // 0.25%, vault gets the remaining 1%

    /// @dev Immutable so it resolves from implementation bytecode under the proxy's delegatecall.
    Currency private immutable i_pairToken;

    // ---------------------------------------------------------------------------------------------
    // Storage (proxy). Append-only across upgrades.
    // ---------------------------------------------------------------------------------------------

    address public protocolRecipient;
    address public vault;

    // ---------------------------------------------------------------------------------------------
    // Construction / initialization
    // ---------------------------------------------------------------------------------------------

    constructor(
        IPoolManager poolManager_,
        Currency pairToken_
    ) BaseHook(poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        i_pairToken = pairToken_;
        _disableInitializers();
    }

    function getVersion() public pure returns (uint64) {
        return HOOK_MANAGER_VERSION;
    }

    function initialize(
        address owner_,
        address protocolRecipient_,
        address vault_
    ) public initializer {
        _init(owner_, protocolRecipient_, vault_);
    }

    function reinitialize(
        address owner_,
        address protocolRecipient_,
        address vault_
    ) external reinitializer(getVersion()) {
        _init(owner_, protocolRecipient_, vault_);
    }

    function _init(
        address owner_,
        address protocolRecipient_,
        address vault_,
        uint256 feeBips,
        uint256 protocolFeeBips
    ) internal {
        if (owner_ == address(0)) revert ZeroAddress();

        TOTAL_FEE_BIPS = feeBips;
        PROTOCOL_FEE_BIPS = protocolFeeBips;

        __Ownable_init(owner_);
        __Ownable2Step_init();

        _setProtocolRecipient(protocolRecipient_);
        _setVault(vault_);
    }

    // ---------------------------------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------------------------------

    function setProtocolRecipient(address recipient) external onlyOwner {
        _setProtocolRecipient(recipient);
    }

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

    function _beforeInitialize(
        address,
        PoolKey calldata poolKey,
        uint160
    ) internal view override returns (bytes4) {
        if (
            !(poolKey.currency0 == i_pairToken) &&
            !(poolKey.currency1 == i_pairToken)
        ) revert InvalidPoolPair();
        return IHooks.beforeInitialize.selector;
    }

    function _afterInitialize(
        address,
        PoolKey calldata,
        uint160,
        int24
    ) internal pure override returns (bytes4) {
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

        int128 fee = _chargeFee(key, sender, _abs(params.amountSpecified));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee, 0), 0);
    }

    /// @dev pairToken amount is computed by the pool (sell exactIn / buy exactOut): take the fee now.
    /// Then, on every swap, try to pay out everything accrued so far.
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        int128 fee;
        if (!_pairTokenIsSpecified(key, params)) {
            int128 amount = key.currency0 == i_pairToken
                ? delta.amount0()
                : delta.amount1();
            fee = _chargeFee(key, sender, _abs(amount));
        }

        try this.payout() {} catch (bytes memory reason) {
            emit PayoutFailed(reason);
        }
        return (IHooks.afterSwap.selector, fee);
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
        uint256 fee = (amount * TOTAL_FEE_BIPS) / BIPS;
        if (fee == 0) return 0;

        poolManager.mint(address(this), i_pairToken.toId(), fee);
        emit FeeCharged(key.toId(), sender, fee);

        return fee.toInt128();
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    // ---------------------------------------------------------------------------------------------
    // Payout
    // ---------------------------------------------------------------------------------------------

    /// @notice Fees accrued and not yet paid out, in `i_pairToken`.
    function pendingFees() external view returns (uint256) {
        return poolManager.balanceOf(address(this), i_pairToken.toId());
    }

    function pairToken() external view returns (Currency) {
        return i_pairToken;
    }

    /// @notice Automatic payout, called by the hook itself at the end of every swap.
    /// @dev External only so `_afterSwap` can wrap it in try/catch. The PoolManager is already
    /// unlocked during a swap, so burn/take are called directly, without `unlock`.
    function payout() external {
        if (msg.sender != address(this)) revert NotSelf();
        _payout();
    }

    /// @notice Manual fallback: pays out whatever is accrued (e.g. after payouts were failing).
    /// @dev Must be called outside a swap: opens the PoolManager via `unlock`.
    function distribute() external {
        poolManager.unlock("");
    }

    /// @dev Reached only through `distribute()`.
    function unlockCallback(
        bytes calldata
    ) external onlyPoolManager returns (bytes memory) {
        _payout();
        return "";
    }

    /// @dev claims -> positive delta for the hook -> real tokens out -> delta back to zero.
    /// Requires the PoolManager to be unlocked.
    function _payout() internal {
        uint256 id = i_pairToken.toId();
        uint256 total = poolManager.balanceOf(address(this), id);
        if (total == 0) return;

        uint256 toProtocol = (total * PROTOCOL_FEE_BIPS) / TOTAL_FEE_BIPS; // 1/5
        uint256 toVault = total - toProtocol; // 4/5, no rounding loss

        address protocol_ = protocolRecipient;
        address vault_ = vault;

        poolManager.burn(address(this), id, total);
        poolManager.take(i_pairToken, protocol_, toProtocol);
        poolManager.take(i_pairToken, vault_, toVault);

        emit FeesDistributed(protocol_, vault_, toProtocol, toVault);
    }
}
