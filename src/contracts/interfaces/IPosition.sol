// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

type PositionID is bytes32;

struct DeploymentInfo {
    address token0;
    address token1;
    int24 lowerTick;
    int24 upperTick;
    uint256 positionId;
    address poolId;
    address rewardRecipient;
    address creatorAdmin;
    IFeeCollector feeCollector;
}

/// @return bytes32 keccak256 hash of position that will be its ID.
function positionID(address pool, address admin) pure returns (PositionID) {
    return PositionID.wrap((keccak256(abi.encodePacked(pool, admin))));
}

interface IPositionDeployer {
    function deployPosition(
        address positionHolder,
        address creator,
        address deployedToken,
        address pairToken,
        address pool,
        uint160 sqrtX96Price
    ) external returns (DeploymentInfo memory);
}

interface IFeeCollector {
    function collectRewards(
        address creator,
        address pool
    ) external returns (uint256 amount0, uint256 amount1);
}

interface IPositionCreator is IPositionDeployer, IFeeCollector {
    function creatorName() external returns (string memory);
}
