// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGemoon.sol";
import "./Deployer.sol";
import "./interfaces/IToken.sol";
import "./interfaces/ILPManager.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {PoolAddress} from "@uniswap-v3-periphery/libraries/PoolAddress.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/interfaces/IUniswapV3Factory.sol";
import "@uniswap-v3-core/libraries/TickMath.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./utils/Price.sol";

contract GemoonController is Ownable, IGemoonController {
    error UserNotFound();

    error MintingFailed(
        string message,
        address token0,
        address token1,
        uint160 sqrtX96Price,
        uint256 balance,
        uint256 approvedAmount,
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper
    );

    uint24 public constant FEE_TIER = 10000;
    int24 public constant TICK_SPACING = 200;

    uint256 public constant INITIAL_LIQUIDITY = 100_000_000_000;
    uint256 public constant INITIAL_SUPPLY_X18 = INITIAL_LIQUIDITY * 1e18;

    int24 public constant MIN_TICK = TickMath.MIN_TICK;
    int24 public constant MAX_TICK = TickMath.MAX_TICK;

    uint256 public _maxCreatorRewardPercent;
    uint256 public _maxDeployerRewardPercent;
    mapping(address => DeployedToken[]) private _deployers;
    ILPManager private _lpManager;
    /// @dev Address of wrapped native token.
    address private _weth;
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public factory;

    constructor(
        uint256 maxCreatorReward_,
        uint256 maxDeployerReward_,
        address lpManager_,
        address factory_,
        address positionManager_,
        address weth_
    ) {
        require(
            maxCreatorReward_ <= 100,
            "Max creator reward percent must be <= 100"
        );
        require(
            maxDeployerReward_ <= 100,
            "Max deployer reward percent must be <= 100"
        );

        require(weth_ != address(0), "WETH address cannot be zero");

        require(lpManager_ != address(0), "LP Manager address cannot be zero");
        require(
            factory_ != address(0),
            "Uniswap V3 Factory address cannot be zero"
        );
        require(
            positionManager_ != address(0),
            "Uniswap V3 Position Manager address cannot be zero"
        );

        _maxCreatorRewardPercent = maxCreatorReward_;
        _maxDeployerRewardPercent = maxDeployerReward_;
        factory = IUniswapV3Factory(factory_);
        _lpManager = ILPManager(lpManager_);
        positionManager = INonfungiblePositionManager(positionManager_);

        _weth = weth_;

        require(
            IERC20(_weth).approve(address(positionManager), type(uint256).max),
            "WETH approval failed"
        );
    }

    /// @dev Configuration for deploying a token.
    /// @notice Entry point for deploying a token.
    /// @notice If `creatorAddress` is not set in `rewardsConfig`, they will be set to the address of this contract.
    function deployToken(
        DeployConfig memory config
    ) external payable override returns (address) {
        TokenConfig memory tokenConfig = config.tokenConfig;

        address[] memory newAdmins = new address[](
            tokenConfig.admins.length + 2
        );
        for (uint256 i = 0; i < tokenConfig.admins.length; i++) {
            newAdmins[i] = tokenConfig.admins[i];
        }

        if (config.rewardsConfig.creatorAddress == address(0)) {
            config.rewardsConfig.creatorAddress = address(this);
        }

        // Set the reward recipient to the creator address if it is not set.
        config.rewardsConfig.rewardRecipient = config
            .rewardsConfig
            .rewardRecipient == address(0)
            ? config.rewardsConfig.creatorAddress
            : config.rewardsConfig.rewardRecipient;

        newAdmins[tokenConfig.admins.length] = address(this);
        newAdmins[tokenConfig.admins.length + 1] = address(msg.sender);
        tokenConfig.admins = newAdmins;

        address deployedToken = Deployer.deployToken(tokenConfig);

        // TODO: assign position id to deploy info
        _deployers[address(msg.sender)].push(
            DeployedToken(msg.sender, deployedToken)
        );

        emit TokenCreated(
            deployedToken,
            config.rewardsConfig.creatorAddress,
            config.rewardsConfig.rewardRecipient,
            0,
            config.tokenConfig.name,
            config.tokenConfig.symbol,
            0
        );

        require(
            IERC20(deployedToken).approve(
                address(positionManager),
                INITIAL_SUPPLY_X18
            ),
            "Deployed token approval failed"
        );

        DeploymentInfo memory depInfo = _configurePool(
            config.rewardsConfig,
            deployedToken
        );

        _lpManager.addNewPosition(depInfo);

        return deployedToken;
    }

    function _configurePool(
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

        // Сортируем токены вручную (Uniswap требует token0 < token1)
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

        // Мы задаем цену как 1 tokenA = 1 WETH
        uint160 sqrtX96Price = PriceMath.getSqrtPriceX96(
            token0 == deployedToken ? INITIAL_SUPPLY_X18 : 1e18,
            token1 == deployedToken ? INITIAL_SUPPLY_X18 : 1e18
        );

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtX96Price);
        int40 roundedTick = PriceMath.roundTick(tick - 400, TICK_SPACING);

        int40 tickLower = PriceMath.roundTick(roundedTick - 200, TICK_SPACING);
        int40 tickUpper = roundedTick;

        emit ILPManager.PoolCreated(pool, sqrtX96Price);

        try IUniswapV3Pool(pool).initialize(sqrtX96Price) {} catch {
            revert("Pool initialization failed, check price validity");
        }

        // Определяем, сколько токенов положить в amount0/amount1
        uint256 amount0Desired = token0 == deployedToken
            ? INITIAL_SUPPLY_X18
            : 0;
        uint256 amount1Desired = token1 == deployedToken
            ? INITIAL_SUPPLY_X18
            : 0;

        uint256 balanceOfController = IERC20(deployedToken).balanceOf(
            address(this)
        );

        require(
            balanceOfController >= INITIAL_SUPPLY_X18,
            "Insufficient token balance"
        );

        uint256 allowance = IERC20(deployedToken).allowance(
            address(this),
            address(positionManager)
        );

        require(
            allowance >= INITIAL_SUPPLY_X18,
            "Insufficient token allowance for position manager"
        );

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: int24(tickLower),
                tickUpper: int24(tickUpper),
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });

        uint256 positionId;
        try positionManager.mint(params) returns (
            uint256 _positionId,
            uint128,
            uint256,
            uint256
        ) {
            positionId = _positionId;
        } catch {
            revert MintingFailed(
                "error minting position, check parameters",
                token0,
                token1,
                sqrtX96Price,
                balanceOfController,
                allowance,
                amount0Desired,
                amount1Desired,
                tick,
                int24(tickLower),
                int24(tickUpper)
            );
        }

        require(
            positionId > 0,
            "create position failed, position ID must be greater than zero"
        );

        emit ILPManager.PositionCreated(
            positionId,
            rewardsConfig_.creatorAddress,
            token0,
            token1,
            INITIAL_SUPPLY_X18
        );

        positionManager.safeTransferFrom(
            address(this),
            address(_lpManager),
            positionId
        );

        return
            DeploymentInfo({
                token0: deployedToken,
                token1: _weth,
                positionId: positionId,
                poolId: pool,
                rewardRecipient: rewardsConfig_.rewardRecipient,
                creatorAdmin: rewardsConfig_.creatorAddress
            });
    }

    function deployTokenWithCustomTeamRewardRecipient(
        DeployConfig memory config,
        address teamRewardRecipient
    )
        external
        payable
        override
        returns (address tokenAddress, uint256 positionId)
    {}

    function getTokensDeployedByUser(
        address user
    ) external view override returns (DeployedToken[] memory) {
        if (_deployers[user].length == 0) {
            revert UserNotFound();
        }

        return _deployers[user];
    }

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external override {
        Admin(token).replaceAdmin(newAdmin, oldAdmin);
    }

    function claimRewards(address token) external override {}

    function MAX_CREATOR_REWARD() external view override returns (uint256) {
        return _maxCreatorRewardPercent;
    }

    function MAX_DEPLOYER_REWARD() external view override returns (uint256) {
        return _maxDeployerRewardPercent;
    }

    receive() external payable {}

    fallback() external payable {}

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
        IERC20 erc20 = IERC20(token);

        uint256 _balance = erc20.balanceOf(address(this));
        require(
            _balance >= amount,
            "Insufficient balance to withdraw the specified amount"
        );

        erc20.transfer(to, amount);
    }
}
