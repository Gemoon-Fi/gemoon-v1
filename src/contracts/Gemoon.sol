// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IGemoon.sol";
import "./Deployer.sol";
import "./interfaces/IToken.sol";
import "./interfaces/ILPManager.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./utils/Price.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    IPositionCreator,
    IPositionDeployer,
    IFeeCollector,
    DeploymentInfo
} from "./interfaces/IPosition.sol";
import "./utils/Ticks.sol";
import {IVault} from "./interfaces/IVault.sol";

/// @dev Minimal view of HookManager, kept separate to avoid importing uniswap-hooks paths here.
interface IGemoonHook {
    function pairToken() external view returns (address);

    function vault() external view returns (address);
}

contract GemoonController is
    Initializable,
    OwnableUpgradeable,
    IGemoonController
{
    error UserNotFound();
    error InvalidAddress();
    error HookNotSet();
    error VaultNotSet();
    error HookPairTokenMismatch(address hookPairToken, address pairToken);
    error HookVaultMismatch(address hookVault, address vault);

    event HookUpdated(address indexed hook);
    event VaultUpdated(address indexed vault);

    bool private _wethInitialApproved = false;

    mapping(string => address) private _deployStrategies;

    address private _weth;

    IPoolManager public poolManager;

    // Appended in 2.0. Storage is append-only across upgrades.

    /// @notice HookManager attached to every Meme/pair pool.
    address public hook;
    /// @notice Vault that receives the fees of every Meme and holds its stakes.
    IVault public vault;

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

    function addDeployStrategyInstance(
        string calldata instanceName,
        address deployer
    ) external onlyOwner {
        require(deployer != address(0), "deployer address cannot be zero");
        require(
            bytes(instanceName).length != 0,
            "invalid name for deployer instance"
        );

        address currentInstance = _deployStrategies[instanceName];
        require(
            currentInstance == address(0),
            "deployer instance with given name already exists"
        );

        _deployStrategies[instanceName] = deployer;
    }

    /// @notice Sets the hook attached to new pools.
    /// @dev Only owner. The hook must charge fees in the pair token of this controller.
    /// @param hook_ HookManager proxy.
    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert InvalidAddress();
        address hookPairToken = IGemoonHook(hook_).pairToken();
        if (hookPairToken != _weth) revert HookPairTokenMismatch(hookPairToken, _weth);
        hook = hook_;
        emit HookUpdated(hook_);
    }

    /// @notice Sets the vault new Meme tokens are registered in.
    /// @dev Only owner. Must be the vault the hook pays fees to.
    /// @param vault_ Vault address.
    function setVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert InvalidAddress();
        vault = IVault(vault_);
        emit VaultUpdated(vault_);
    }

    /// @dev Configuration for deploying a token.
    /// @notice Entry point for deploying a token.
    /// @notice If `creatorAddress` is not set in `rewardsConfig`, they will be set to the address of this contract.
    function deployToken(
        string memory deployStrategy,
        DeployConfig memory config
    ) external payable override returns (address) {
        IPositionDeployer deployer = IPositionDeployer(
            _deployStrategies[deployStrategy]
        );
        require(
            address(deployer) != address(0),
            "given position deployer not found"
        );
        address hook_ = hook;
        IVault vault_ = vault;
        if (hook_ == address(0)) revert HookNotSet();
        if (address(vault_) == address(0)) revert VaultNotSet();
        address hookVault = IGemoonHook(hook_).vault();
        if (hookVault != address(vault_)) revert HookVaultMismatch(hookVault, address(vault_));

        TokenConfig memory tokenConfig = config.tokenConfig;
        _validateTokenConfig(config.tokenConfig);

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

        address deployedToken = Deployer.deployToken(tokenConfig);

        // Transfer all liquidity to deploy strategy
        require(
            IERC20(deployedToken).transfer(
                address(deployer),
                INITIAL_SUPPLY_X18
            ),
            "fail transfer liquidity to deployer"
        );

        // The hook accepts the pool only if the vault of the Meme already exists.
        vault_.registerVault(
            deployedToken,
            config.rewardsConfig.rewardRecipient,
            config.vaultAssets
        );

        DeploymentInfo memory depInfo = _configurePool(
            deployer,
            config.rewardsConfig,
            deployedToken,
            hook_
        );

        depInfo.rewardRecipient = config.rewardsConfig.rewardRecipient;
        depInfo.creatorAdmin = config.rewardsConfig.creatorAddress;

        emit TokenCreated(
            deployedToken,
            config.rewardsConfig.creatorAddress,
            depInfo.positionId,
            config.rewardsConfig.rewardRecipient,
            config.tokenConfig.name,
            config.tokenConfig.symbol
        );

        return deployedToken;
    }

    function _configurePool(
        IPositionDeployer deployer,
        RewardsConfig memory rewardsConfig_,
        address deployedToken,
        address hook_
    ) private returns (DeploymentInfo memory) {
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
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            // LP fee is 0: the whole swap fee is charged by the hook in the pair token.
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook_)
        });
        uint160 sqrtX96Price = PriceMath.getSqrtPriceX96(
            token0 == deployedToken ? PRICE_PER_TOKEN : 1e18,
            token1 == deployedToken ? PRICE_PER_TOKEN : 1e18
        );

        (, , int24 tick) = Ticks.getTicks(
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
        DeploymentInfo memory depInfo = deployer.deployPosition(
            address(0),
            rewardsConfig_.creatorAddress,
            deployedToken,
            _weth,
            poolId,
            sqrtX96Price,
            hook_
        );

        return depInfo;
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
