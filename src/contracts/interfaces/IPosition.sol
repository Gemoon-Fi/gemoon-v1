// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";

struct DeploymentInfo {
    address token0;
    address token1;
    int24 lowerTick;
    int24 upperTick;
    uint256 positionId;
    PoolId poolId;
    address rewardRecipient;
    address creatorAdmin;
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

interface IPositionCreator is IPositionDeployer {
    function creatorName() external returns (string memory);
}
