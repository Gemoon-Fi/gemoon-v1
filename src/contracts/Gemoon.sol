// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IGemoon.sol";
import "./Deployer.sol";
import "./interfaces/IToken.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    IERC20Metadata
} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./utils/Price.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PositionDeployer} from "./utils/PositionDeployer.sol";
import {
    IPositionManager
} from "@uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {
    IAllowanceTransfer
} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import "./utils/Ticks.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IHookManager} from "./interfaces/IHookManager.sol";
import {
    IUnlockCallback
} from "@uniswap-v4-core/interfaces/callback/IUnlockCallback.sol";
import {SwapParams} from "@uniswap-v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap-v4-core/types/BalanceDelta.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {
    SafeERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract GemoonController is
    Initializable,
    OwnableUpgradeable,
    IGemoonController,
    IUnlockCallback
{
    using SafeERC20 for IERC20;

    error UserNotFound();
    error InvalidAddress();
    error HookNotSet();
    error VaultNotSet();
    error HookPairTokenMismatch(address hookPairToken, address pairToken);
    error HookVaultMismatch(address hookVault, address vault);
    error VaultPairTokenMismatch(address vaultUsdg, address pairToken);
    error PositionManagerNotSet();
    /// @dev `unlockCallback` called by anyone but the PoolManager.
    error NotPoolManager();

    event HookUpdated(address indexed hook);
    event VaultUpdated(address indexed vault);
    event PositionManagerUpdated(
        address indexed positionManager,
        address indexed permit2
    );

    address private _weth;

    IPoolManager public poolManager;

    // Appended in 2.0. Storage is append-only across upgrades.

    /// @notice HookManager attached to every Meme/pair pool.
    address public hook;
    /// @notice Vault that receives the fees of every Meme and holds its stakes.
    IVault public vault;
    /// @notice Uniswap V4 PositionManager that mints the initial position of every Meme.
    IPositionManager public positionManager;
    /// @notice Permit2 the PositionManager pulls the Meme supply through.
    IAllowanceTransfer public permit2;

    /// @dev Version of the Gemoon contract.
    uint64 public constant GEMOON_VERSION = 1;

    function getVersion() public pure returns (uint64) {
        return GEMOON_VERSION;
    }

    function _init(
        address poolManager_,
        address weth_,
        address protocolAdmin_
    ) internal {
        require(weth_ != address(0), "WETH address cannot be zero");

        __Ownable_init(protocolAdmin_);

        require(
            poolManager_ != address(0),
            "Uniswap V4 PoolManager address cannot be zero"
        );

        poolManager = IPoolManager(poolManager_);

        _weth = weth_;
    }

    function reinitialize(
        address poolManager_,
        address weth_,
        address protocolAdmin_
    ) external reinitializer(getVersion()) {
        _init(poolManager_, weth_, protocolAdmin_);
    }

    function initialize(
        address poolManager_,
        address weth_,
        address protocolAdmin_
    ) public initializer {
        _init(poolManager_, weth_, protocolAdmin_);
    }

    /// @notice Sets the hook attached to new pools.
    /// @dev Only owner. The hook must charge fees in the pair token of this controller.
    /// @param hook_ HookManager proxy.
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert InvalidAddress();
        address hookPairToken = Currency.unwrap(
            IHookManager(hook_).pairToken()
        );
        if (hookPairToken != _weth)
            revert HookPairTokenMismatch(hookPairToken, _weth);
        hook = hook_;
        emit HookUpdated(hook_);
    }

    /// @notice Sets the vault new Meme tokens are registered in.
    /// @dev Only owner. Must be the vault the hook pays fees to, and it must account fees in the
    /// pair token of this controller, otherwise every hook payout would revert.
    /// @param vault_ Vault address.
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert InvalidAddress();
        address vaultUsdg = IVault(vault_).usdg();
        if (vaultUsdg != _weth) revert VaultPairTokenMismatch(vaultUsdg, _weth);
        vault = IVault(vault_);
        emit VaultUpdated(vault_);
    }

    /// @notice Sets the PositionManager and Permit2 used to mint the initial position of new
    ///         Memes.
    /// @dev Only owner.
    /// @param positionManager_ Uniswap V4 PositionManager.
    /// @param permit2_         Permit2 contract the PositionManager settles through.
    function setPositionManager(
        address positionManager_,
        address permit2_
    ) external onlyOwner {
        if (positionManager_ == address(0) || permit2_ == address(0))
            revert InvalidAddress();
        positionManager = IPositionManager(positionManager_);
        permit2 = IAllowanceTransfer(permit2_);
        emit PositionManagerUpdated(positionManager_, permit2_);
    }

    /// @notice Entry point for deploying a Meme: token, its vault, the Meme/pair pool and the
    ///         initial one-sided position holding the whole supply, owned by this contract.
    /// @dev If `rewardRecipient` is not set in `rewardsConfig`, it defaults to `creatorAddress`.
    /// Admins of the token are the given ones plus this contract and the caller.
    /// A non-zero `config.devBuy.memeAmount` makes the caller the first buyer of the pool, in this
    /// same transaction: see `_devBuy`.
    /// @param config Token, rewards, vault and dev buy configuration.
    /// @return Address of the new Meme token.
    function deployToken(
        DeployConfig memory config
    ) external payable override returns (address) {
        address hook_ = hook;
        IVault vault_ = vault;
        if (hook_ == address(0)) revert HookNotSet();
        if (address(vault_) == address(0)) revert VaultNotSet();
        if (address(positionManager) == address(0))
            revert PositionManagerNotSet();
        address hookVault = IHookManager(hook_).vault();
        if (hookVault != address(vault_))
            revert HookVaultMismatch(hookVault, address(vault_));

        TokenConfig memory tokenConfig = config.tokenConfig;
        _validateTokenConfig(config.tokenConfig);
        if (config.devBuy.memeAmount > MAX_DEV_BUY_X18)
            revert DevBuyTooLarge(config.devBuy.memeAmount, MAX_DEV_BUY_X18);

        AdminConfig[] memory newAdmins = new AdminConfig[](
            tokenConfig.admins.length + 2
        );

        // Set the reward recipient to the creator address if it is not set.
        config.rewardsConfig.rewardRecipient = config
            .rewardsConfig
            .rewardRecipient == address(0)
            ? config.rewardsConfig.creatorAddress
            : config.rewardsConfig.rewardRecipient;

        newAdmins[tokenConfig.admins.length] = AdminConfig({
            admin: address(this),
            removable: false
        });
        newAdmins[tokenConfig.admins.length + 1] = AdminConfig({
            admin: address(msg.sender),
            removable: false
        });

        tokenConfig.admins = newAdmins;

        // The whole supply is minted to this contract and goes into the position below.
        address deployedToken = Deployer.deployToken(tokenConfig);

        // The hook accepts the pool only if the vault of the Meme already exists.
        vault_.registerVault(
            deployedToken,
            config.rewardsConfig.rewardRecipient,
            config.vaultAssets
        );

        (uint256 positionId, PoolKey memory poolKey) = _configurePool(
            config.rewardsConfig,
            deployedToken,
            hook_
        );

        IHookManager(hook_).notifyPoolCreated(
            deployedToken,
            block.timestamp,
            config.rewardsConfig.swapFeeBips
        );

        if (config.devBuy.memeAmount != 0)
            _devBuy(poolKey, deployedToken, config.devBuy);

        emit TokenCreated(
            deployedToken,
            config.rewardsConfig.creatorAddress,
            positionId,
            config.rewardsConfig.rewardRecipient,
            config.tokenConfig.name,
            config.tokenConfig.symbol
        );

        return deployedToken;
    }

    /// @dev Initializes the Meme/pair pool with the hook and mints the whole Meme supply into a
    /// one-sided position above the initial price. The position NFT is owned by this contract.
    /// @return positionId NFT id of the minted position.
    /// @return poolKey    Key of the Meme/pair pool.
    function _configurePool(
        RewardsConfig memory rewardsConfig_,
        address deployedToken,
        address hook_
    ) private returns (uint256 positionId, PoolKey memory poolKey) {
        require(
            deployedToken != address(0),
            "Deployed token address cannot be zero"
        );
        require(
            rewardsConfig_.creatorAddress != address(0),
            "Creator address cannot be zero"
        );
        require(
            rewardsConfig_.rewardRecipient != address(0),
            "Reward recipient address cannot be zero"
        );

        address tokenA = deployedToken;
        address tokenB = _weth;
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            // LP fee is 0: the whole swap fee is charged by the hook in the pair token.
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
        // Start price: PRICE_PER_TOKEN whole Meme for one whole pair token. PriceMath takes both
        // amounts in raw units, so each side is scaled by its own token's decimals; the token
        // order only decides which amount is token0 and which is token1, the price is the same.
        // PRICE_PER_TOKEN * 1e18 is far below uint256, and the ratio stays below the 2^64 limit
        // of PriceMath for any pair token with 6..18 decimals.
        uint256 memeAmount = PRICE_PER_TOKEN *
            10 ** IERC20Metadata(deployedToken).decimals();
        uint256 pairAmount = 10 ** IERC20Metadata(_weth).decimals();
        uint160 sqrtX96Price = PriceMath.getSqrtPriceX96(
            token0 == deployedToken ? memeAmount : pairAmount,
            token1 == deployedToken ? memeAmount : pairAmount
        );

        (int24 tickLower, int24 tickUpper, int24 tick) = Ticks.getTicks(
            poolKey,
            sqrtX96Price,
            deployedToken,
            TICK_SPACING,
            true
        );

        PoolId poolId = PoolIdLibrary.toId(poolKey);

        emit PoolCreated(poolId, token0, token1, sqrtX96Price, tick);

        try poolManager.initialize(poolKey, sqrtX96Price) returns (
            int24
        ) {} catch {
            revert("Pool initialization failed, check price validity");
        }
        PositionDeployer.Position memory position = PositionDeployer.mint(
            PositionDeployer.MintParams({
                positionManager: positionManager,
                permit2: permit2,
                poolKey: poolKey,
                deployedToken: deployedToken,
                amount: INITIAL_SUPPLY_X18,
                tickLower: tickLower,
                tickUpper: tickUpper,
                recipient: address(this)
            })
        );

        emit PositionCreated(
            deployedToken,
            position.tokenId,
            tickLower,
            tickUpper,
            position.liquidity
        );

        return (position.tokenId, poolKey);
    }

    /// @dev Buys `devBuy.memeAmount` (exact output) from the fresh pool for `msg.sender`. Runs
    /// right after the pool is created, in the same transaction, so no one trades before it.
    /// The hook charges this contract the base fee of the Meme instead of the anti-snipe fee.
    function _devBuy(
        PoolKey memory poolKey,
        address meme,
        DevBuyConfig memory devBuy
    ) private {
        poolManager.unlock(abi.encode(poolKey, meme, msg.sender, devBuy));
    }

    /// @notice Settles the dev buy of `deployToken`. Not callable directly.
    /// @dev Only the PoolManager, and the PoolManager only calls back the contract that unlocked
    /// it: reached only through `_devBuy`. Swaps pair token -> Meme, pulls the owed pair token
    /// from the buyer straight into the PoolManager and sends the Meme to the buyer. Every delta
    /// ends at zero, otherwise the PoolManager reverts the whole `deployToken`.
    /// @param data abi-encoded (PoolKey, meme, buyer, DevBuyConfig).
    /// @return Empty.
    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (
            PoolKey memory poolKey,
            address meme,
            address buyer,
            DevBuyConfig memory devBuy
        ) = abi.decode(data, (PoolKey, address, address, DevBuyConfig));

        bool memeIs0 = Currency.unwrap(poolKey.currency0) == meme;
        // Buy: pair token in, Meme out. Positive amountSpecified = exact output.
        BalanceDelta delta = poolManager.swap(
            poolKey,
            SwapParams({
                zeroForOne: !memeIs0,
                amountSpecified: int256(devBuy.memeAmount),
                sqrtPriceLimitX96: memeIs0
                    ? TickMath.MAX_SQRT_PRICE - 1
                    : TickMath.MIN_SQRT_PRICE + 1
            }),
            // reported as the trader in `MemeSwapped`
            abi.encode(buyer)
        );

        // Caller deltas: negative = owed to the pool, positive = owed to the caller.
        int128 pairDelta = memeIs0 ? delta.amount1() : delta.amount0();
        int128 memeDelta = memeIs0 ? delta.amount0() : delta.amount1();
        uint256 pairIn = uint256(uint128(-pairDelta));
        uint256 memeOut = uint256(uint128(memeDelta));
        if (pairIn > devBuy.maxPairIn)
            revert DevBuySlippage(pairIn, devBuy.maxPairIn);

        Currency pair = memeIs0 ? poolKey.currency1 : poolKey.currency0;
        poolManager.sync(pair);
        IERC20(Currency.unwrap(pair)).safeTransferFrom(
            buyer,
            address(poolManager),
            pairIn
        );
        poolManager.settle();
        poolManager.take(Currency.wrap(meme), buyer, memeOut);

        emit DevBuy(meme, buyer, pairIn, memeOut);
        return "";
    }

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external override {
        Admin(token).replaceAdmin(newAdmin, oldAdmin);
    }

    receive() external payable {}

    function balance() external view onlyOwner returns (uint256) {
        return address(this).balance;
    }

    /// @notice Withdraws native tokens from the contract for Gemoon team members.
    function withdraw(address recipient, uint256 amount) external onlyOwner {
        payable(recipient).transfer(amount);
    }

    /// @notice Withdraws ERC20 tokens from the contract for Gemoon team members.
    /// @param token The address of the ERC20 token to withdraw.
    /// @param to The address to send the withdrawn tokens to.
    /// @param amount The amount of tokens to withdraw.
    function withdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IGemoonToken erc20 = IGemoonToken(token);

        uint256 _balance = erc20.balanceOf(address(this));
        require(
            _balance >= amount,
            "Insufficient balance to withdraw the specified amount"
        );

        erc20.transfer(to, amount);
    }
}

function _validateTokenConfig(TokenConfig memory config) pure {
    require(bytes(config.symbol).length > 0, "Token symbol is required");
    require(bytes(config.name).length > 0, "Token name is required");
    require(
        bytes(config.name).length <= 150,
        "Token name is too long. Max 150 characters."
    );
    require(
        bytes(config.symbol).length <= 50,
        "Token symbol is too long. Max 50 characters."
    );
    require(
        config.admins.length > 0,
        "At least one admin address is required."
    );
    require(bytes(config.imgUrl).length > 0, "Token image required.");
}
