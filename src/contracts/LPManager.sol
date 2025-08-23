// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {ILPManager} from "./interfaces/ILPManager.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "./utils/Percent.sol";

contract LPManager is ILPManager, AccessControl {
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    INonfungiblePositionManager public positionManager;

    uint256 public creatorPercent;

    mapping(address => DeploymentInfo[]) public deployments;

    constructor(address positionManager_, uint256 creatorPercent_) {
        require(
            positionManager_ != address(0),
            "Position manager address cannot be zero"
        );

        creatorPercent = creatorPercent_;
        positionManager = INonfungiblePositionManager(positionManager_);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        // unused parameters
        operator;
        data;

        emit Received(from, tokenId);

        return this.onERC721Received.selector;
    }

    function showDeploymentsForCreator(
        address creator
    ) external view returns (DeploymentInfo[] memory) {
        return deployments[creator];
    }

    function positionId(
        address creator,
        address pool
    ) external view override returns (uint256) {
        DeploymentInfo[] storage creatorDeployments = deployments[creator];
        uint256 poolPositionId;
        for (uint256 i = 0; i < creatorDeployments.length; i++) {
            if (creatorDeployments[i].poolId == pool) {
                poolPositionId = creatorDeployments[i].positionId;
                break;
            }
        }

        require(poolPositionId != 0, "Position not found");

        return poolPositionId;
    }

    function claimRewards(
        address creator,
        address pool
    ) external override returns (uint256 amount0, uint256 amount1) {
        require(creator != address(0), "Creator address cannot be zero");
        require(pool != address(0), "Pool address cannot be zero");

        require(msg.sender == creator, "Only creator can claim rewards");

        DeploymentInfo[] storage creatorDeployments = deployments[creator];

        uint256 poolPositionId;

        for (uint256 i = 0; i < creatorDeployments.length; i++) {
            if (creatorDeployments[i].poolId == pool) {
                poolPositionId = creatorDeployments[i].positionId;
                break;
            }
        }

        require(poolPositionId != 0, "Position not found");

        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: poolPositionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        if (amount0 <= 0 && amount1 <= 0) {
            return (0, 0);
        }

        uint256 rcptAmount1 = Percent.subPercent(amount1, CREATOR_PERCENT);
        uint256 rcptAmount0 = Percent.subPercent(amount0, CREATOR_PERCENT);
        IERC20 token0 = IERC20(IUniswapV3Pool(pool).token0());
        IERC20 token1 = IERC20(IUniswapV3Pool(pool).token1());

        if (amount0 > 0) {
            token0.transfer(creator, rcptAmount0);
        }

        if (amount1 > 0) {
            token1.transfer(creator, rcptAmount1);
        }

        emit RewardClaimed(creator, pool, rcptAmount0, rcptAmount1);

        return (rcptAmount0, rcptAmount1);
    }

    function addNewPosition(
        DeploymentInfo memory deployment
    ) external override onlyRole(CONTROLLER_ROLE) {
        deployments[deployment.creatorAdmin].push(deployment);
    }
}
