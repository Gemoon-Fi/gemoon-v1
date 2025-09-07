// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IGemoon.sol";
import "./Deployer.sol";
import "./interfaces/IToken.sol";
import "./interfaces/ILPManager.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {PoolAddress} from "@uniswap-v3-periphery/libraries/PoolAddress.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/interfaces/IUniswapV3Factory.sol";
import "./utils/Price.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPositionCreator, IPositionDeployer, IFeeCollector, DeploymentInfo} from "./interfaces/IPosition.sol";
import "./utils/Ticks.sol";

contract GemoonController is
    Initializable,
    OwnableUpgradeable,
    IGemoonController
{


    error UserNotFound();

    bool private _wethInitialApproved = false;

    mapping(string => address) private _deployStrategies;

    ILPManager private _lpManager;
    /// @dev Address of wrapped native token.
    address private _weth;

    IUniswapV3Factory public factory;

    /// @dev Version of the Gemoon contract.
    uint64 public constant GEMOON_VERSION = 1;

    function getVersion() public pure returns (uint64) {
        return GEMOON_VERSION;
    }

    function _init(
        address lpManager_,
        address factory_,
        address weth_,
        address protocolAdmin_
    ) internal {
        require(weth_ != address(0), "WETH address cannot be zero");

        __Ownable_init(protocolAdmin_);

        require(lpManager_ != address(0), "LP Manager address cannot be zero");
        require(
            factory_ != address(0),
            "Uniswap V3 Factory address cannot be zero"
        );

        factory = IUniswapV3Factory(factory_);
        _lpManager = ILPManager(lpManager_);

        _weth = weth_;
    }

    function reinitialize(
        address lpManager_,
        address factory_,
        address weth_,
        address protocolAdmin_
    ) external reinitializer(getVersion()) {
        _init(lpManager_, factory_, weth_, protocolAdmin_);
    }

    function initialize(
        address lpManager_,
        address factory_,
        address weth_,
        address protocolAdmin_
    ) public initializer {
        _init(lpManager_, factory_, weth_, protocolAdmin_);
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

        _deployStrategies[instanceName] = deployer;
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

        TokenConfig memory tokenConfig = config.tokenConfig;
        _validateTokenConfig(config.tokenConfig);

        AdminConfig[] memory newAdmins = new AdminConfig[](
            tokenConfig.admins.length + 2
        );

        if (config.rewardsConfig.creatorAddress == address(0)) {
            config.rewardsConfig.creatorAddress = address(_lpManager);
        }
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

        DeploymentInfo memory depInfo = _configurePool(
            deployer,
            config.rewardsConfig,
            deployedToken
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

        _lpManager.addNewPosition(depInfo);

        return deployedToken;
    }

    function _configurePool(
        IPositionDeployer deployer,
        RewardsConfig memory rewardsConfig_,
        address deployedToken
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
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: token0,
            token1: token1,
            fee: FEE_TIER
        });
        address pool = factory.createPool(token0, token1, FEE_TIER);
        require(
            pool != address(0),
            "Pool creation failed, check token addresses"
        );
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
        emit PoolCreated(pool, token0, token1, sqrtX96Price, tick);
        try IUniswapV3Pool(pool).initialize(sqrtX96Price) {} catch {
            revert("Pool initialization failed, check price validity");
        }

        DeploymentInfo memory depInfo = deployer.deployPosition(
            address(_lpManager),
            rewardsConfig_.creatorAddress,
            deployedToken,
            _weth,
            pool,
            sqrtX96Price
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
