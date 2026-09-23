// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";

type PositionID is bytes32;

struct DeploymentInfo {
    address token0;
    address token1;
    int24 lowerTick;
    int24 upperTick;
    uint256 positionId;
    PoolId poolId;
    address rewardRecipient;
    address creatorAdmin;
    IFeeCollector feeCollector;
}

/// @return bytes32 keccak256 hash of position that will be its ID.
function positionID(PoolId pool, address admin) pure returns (PositionID) {
    return PositionID.wrap((keccak256(abi.encodePacked(PoolId.unwrap(pool), admin))));
}

interface IPositionDeployer {
    function deployPosition(
        address positionHolder,
        address creator,
        address deployedToken,
        address pairToken,
        PoolId pool,
        uint160 sqrtX96Price,
        address hook
    ) external returns (DeploymentInfo memory);
}

interface IFeeCollector {
    function collectRewards(
        address creator,
        PoolId pool
    ) external returns (uint256 amount0, uint256 amount1);
}

interface IPositionCreator is IPositionDeployer, IFeeCollector {
    function creatorName() external returns (string memory);
}
