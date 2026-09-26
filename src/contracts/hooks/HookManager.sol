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
import {IVault} from "../interfaces/IVault.sol";

/// @title Gemoon UniswapV4 hook manager.
/// @notice Charges a fixed 1.25% swap fee, always denominated in `i_pairToken`:
///         0.25% goes to the protocol recipient, 1% goes to the vault.
/// @dev Deployed behind a TransparentUpgradeableProxy. Both the proxy and every implementation
/// must be CREATE2-mined to carry the bit pattern of `getHookPermissions`.
///
/// Fee flow:
///  - pools: only Meme/pairToken pools with LP fee 0 whose Meme has a registered vault.
///  - every swap: the fee is taken from the swapper via a hook delta and recorded inside the
///    PoolManager as ERC6909 claims owned by this hook (`poolManager.mint`), and per Meme in
///    `accrued`.
///  - end of every swap (`_afterSwap`): the claims accrued for the Meme of the pool are paid out as
///    real tokens, 1/5 to the protocol recipient and 4/5 to the vault, and the vault is notified
///    (`IVault.notifyFees`). The swapper pays the gas. The payout runs inside try/catch: if it
///    fails, the swap still succeeds and the fee stays accrued until the next successful payout.
///  - `distribute(meme)`: manual fallback that pays out whatever is accrued for `meme`.
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
    error InvalidPoolFee();
    error InvalidFeeBips();
    error VaultNotRegistered(address meme);
    error NotSelf();

    event FeeCharged(
        PoolId indexed poolId,
        address indexed sender,
        uint256 amount
    );
    event FeesDistributed(
        address indexed meme,
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
    /// @notice Fees charged and not yet paid out, per Meme, in `i_pairToken`.
    /// @dev Sum over all memes equals the ERC6909 claims of this hook.
    mapping(address meme => uint256) public accrued;

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
        address vault_,
        uint256 feeBips,
        uint256 protocolFeeBips
    ) public initializer {
        _init(owner_, protocolRecipient_, vault_, feeBips, protocolFeeBips);
    }

    function reinitialize(
        address owner_,
        address protocolRecipient_,
        address vault_,
        uint256 feeBips,
        uint256 protocolFeeBips
    ) external reinitializer(getVersion()) {
        _init(owner_, protocolRecipient_, vault_, feeBips, protocolFeeBips);
    }

    function _init(
        address owner_,
        address protocolRecipient_,
        address vault_,
        uint256 feeBips,
        uint256 protocolFeeBips
    ) internal {
        if (owner_ == address(0)) revert ZeroAddress();
        if (feeBips >= BIPS || protocolFeeBips > feeBips)
            revert InvalidFeeBips();

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

        try this.payout(_meme(key)) {} catch (bytes memory reason) {
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

        accrued[_meme(key)] += fee;
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

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
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

    /// @dev claims -> positive delta for the hook -> real tokens out -> delta back to zero,
    /// then the vault is told which Meme the fees belong to. A revert anywhere (including in
    /// `notifyFees`) rolls the whole payout back, `accrued` included.
    /// Requires the PoolManager to be unlocked.
    function _payout(address meme) internal {
        uint256 total = accrued[meme];
        if (total == 0) return;

        uint256 toProtocol = (total * PROTOCOL_FEE_BIPS) / TOTAL_FEE_BIPS; // 1/5
        uint256 toVault = total - toProtocol; // 4/5, no rounding loss

        address protocol_ = protocolRecipient;
        address vault_ = vault;

        accrued[meme] = 0;

        poolManager.burn(address(this), i_pairToken.toId(), total);
        poolManager.take(i_pairToken, protocol_, toProtocol);
        poolManager.take(i_pairToken, vault_, toVault);
        if (toVault != 0) IVault(vault_).notifyFees(meme, toVault);
        if (toVault != 0) IVault(vault_).convertFees(meme, toVault);

        emit FeesDistributed(meme, protocol_, vault_, toProtocol, toVault);
    }
}
