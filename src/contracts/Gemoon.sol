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
                type(uint256).max
            ),
            "Deployed token approval failed"
        );

        require(
            IERC20(_weth).allowance(address(this), address(positionManager)) >=
                config.tokenConfig.maxSupplyTokens,
            "create position failed, insufficient allowance"
        );

        DeploymentInfo memory depInfo = _configurePool(
            config.rewardsConfig,
            PoolConfig({poolSupply: config.tokenConfig.maxSupplyTokens}),
            deployedToken
        );

        _lpManager.addNewPosition(depInfo);

        return deployedToken;
    }

    function _configurePool(
        RewardsConfig memory rewardsConfig_,
        PoolConfig memory poolConfig_,
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

        PoolAddress.PoolKey memory poolKey = PoolAddress.getPoolKey(
            deployedToken,
            _weth,
            FEE_TIER
        );

        bool token0IsNewToken = deployedToken < _weth;

        address pool = factory.createPool(
            poolKey.token0,
            poolKey.token1,
            FEE_TIER
        );

        require(
            pool != address(0),
            "Pool creation failed, check token addresses"
        );

        uint160 sqrtX96Price = PriceMath.getSqrtPriceX96(
            poolConfig_.poolSupply,
            1
        );

        int40 tick = PriceMath.roundTick(
            int40(TickMath.getTickAtSqrtRatio(sqrtX96Price)),
            TICK_SPACING
        );

        require(
            tick % TICK_SPACING == 0,
            "Tick must be a multiple of TICK_SPACING"
        );

        int40 lowerTick = PriceMath.roundTick(tick - 2000, TICK_SPACING);
        int40 upperTick = PriceMath.roundTick(tick, TICK_SPACING);

        require(lowerTick >= MIN_TICK, "Lower tick is too low");
        require(upperTick <= MAX_TICK, "Upper tick is too high");
        require(
            lowerTick < upperTick,
            "Lower tick must be less than upper tick"
        );

        emit ILPManager.PoolCreated(pool, sqrtX96Price);

        IUniswapV3Pool(pool).initialize(sqrtX96Price);

        require(
            IERC20(deployedToken).balanceOf(address(this)) >=
                poolConfig_.poolSupply,
            string(
                abi.encodePacked(
                    "create position failed, not enough new token: ",
                    Strings.toHexString(
                        uint160(token0IsNewToken ? deployedToken : _weth),
                        20
                    )
                )
            )
        );

        require(
            IERC20(deployedToken).allowance(
                address(this),
                address(positionManager)
            ) >= poolConfig_.poolSupply,
            "create position failed, insufficient allowance for token1"
        );

        uint256 positionId;

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams(
                poolKey.token0,
                poolKey.token1,
                FEE_TIER,
                int24(lowerTick),
                int24(upperTick),
                token0IsNewToken ? poolConfig_.poolSupply : 0, // amount0Desired
                token0IsNewToken ? 0 : poolConfig_.poolSupply, // amount1Desired
                0,
                0,
                address(this),
                block.timestamp
            );
        (positionId, , , ) = positionManager.mint(params);

        emit ILPManager.PositionCreated(
            positionId,
            rewardsConfig_.creatorAddress,
            token0IsNewToken ? deployedToken : _weth,
            token0IsNewToken ? _weth : deployedToken,
            poolConfig_.poolSupply
        );

        DeploymentInfo memory deployment = DeploymentInfo({
            token0: token0IsNewToken ? deployedToken : _weth,
            token1: token0IsNewToken ? _weth : deployedToken,
            positionId: positionId,
            poolId: pool,
            rewardRecipient: rewardsConfig_.rewardRecipient,
            creatorAdmin: rewardsConfig_.creatorAddress
        });

        positionManager.safeTransferFrom(
            address(this),
            address(_lpManager),
            positionId
        );

        return deployment;
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
