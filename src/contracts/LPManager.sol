// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.21;

import {ILPManager} from "./interfaces/ILPManager.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "./utils/Percent.sol";
import "./interfaces/IToken.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {DeploymentInfo, IFeeCollector, PositionID, positionID} from "./interfaces/IPosition.sol";

contract LPManager is Initializable, AccessControlUpgradeable, ILPManager {
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    uint256 public creatorFeePercent;

    mapping(PositionID => DeploymentInfo) public deployments;

    mapping(address => uint256) private collectedRewards;

    /// @dev Version of the Gemoon contract.
    uint64 public constant GEMOON_VERSION = 1;

    function getVersion() public pure returns (uint64) {
        return GEMOON_VERSION;
    }

    function _init(uint256 creatorPercent_) internal {
        require(
            creatorPercent_ <= 100,
            "Creator percent must be less than or equal to 100"
        );

        // TODO: who will be owner????
        __AccessControl_init();

        creatorFeePercent = creatorPercent_;
    }

    function reinitialize(
        uint256 creatorPercent_,
        address protocolAdmin_
    ) external reinitializer(getVersion()) {
        _init(creatorPercent_);

        _revokeRole(DEFAULT_ADMIN_ROLE, protocolAdmin_);
        _grantRole(DEFAULT_ADMIN_ROLE, protocolAdmin_);
    }

    function initialize(
        uint256 creatorPercent_,
        address protocolAdmin_
    ) public initializer {
        _init(creatorPercent_);
        _grantRole(DEFAULT_ADMIN_ROLE, protocolAdmin_);
    }

    /// @inheritdoc ILPManager
    function positionId(
        address creator,
        address pool
    ) public view override returns (uint256) {
        DeploymentInfo storage creatorDeployments = deployments[
            positionID(pool, creator)
        ];

        require(creatorDeployments.positionId != 0, "Position not found");

        return creatorDeployments.positionId;
    }

    modifier ownerOrCreator(address creator) {
        require(
            msg.sender == creator || hasRole(DEFAULT_ADMIN_ROLE, msg.sender),
            "Not authorized"
        );
        _;
    }

    /// @inheritdoc ILPManager
    function claimRewards(
        address creator,
        address pool
    ) external override ownerOrCreator(creator) returns (uint256, uint256) {
        require(creator != address(0), "Creator address cannot be zero");
        require(pool != address(0), "Pool address cannot be zero");

        PositionID posID = positionID(pool, creator);

        DeploymentInfo memory depInfo = deployments[posID];

        IFeeCollector feeCollector = IFeeCollector(depInfo.feeCollector);

        (uint256 amount0, uint256 amount1) = feeCollector.collectRewards(
            creator,
            pool
        );

        if (amount0 <= 0 && amount1 <= 0) {
            return (0, 0);
        }

        uint256 rcptAmount1 = Percent.subPercent(amount1, creatorFeePercent);
        uint256 rcptAmount0 = Percent.subPercent(amount0, creatorFeePercent);
        IGemoonToken token0 = IGemoonToken(IUniswapV3Pool(pool).token0());
        IGemoonToken token1 = IGemoonToken(IUniswapV3Pool(pool).token1());

        if (amount0 > 0) {
            token0.transfer(creator, rcptAmount0);
            collectedRewards[address(token0)] += amount0 - rcptAmount0;
        }

        if (amount1 > 0) {
            token1.transfer(creator, rcptAmount1);
            collectedRewards[address(token1)] += amount1 - rcptAmount1;
        }

        emit RewardClaimed(creator, pool, rcptAmount0, rcptAmount1);

        return (rcptAmount0, rcptAmount1);
    }

    function showRewards(
        address token
    ) external view onlyRole(DEFAULT_ADMIN_ROLE) returns (uint256) {
        return collectedRewards[token];
    }

    /// @notice withdrawal of rewards in favor of the protocol creators
    function withdrawRewards(
        address token
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Token address cannot be zero");

        uint256 amount = collectedRewards[token];

        if (amount <= 0) {
            return;
        }

        require(
            amount <= collectedRewards[token],
            "Amount exceeds collected rewards"
        );

        collectedRewards[token] -= amount;
        IGemoonToken(token).transfer(msg.sender, amount);
    }

    function addNewPosition(
        DeploymentInfo memory deployment
    ) external override onlyRole(CONTROLLER_ROLE) {
        deployments[
            positionID(deployment.poolId, deployment.creatorAdmin)
        ] = deployment;
    }
}
