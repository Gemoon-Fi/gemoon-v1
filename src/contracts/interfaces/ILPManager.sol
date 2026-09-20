// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./IGemoon.sol";
import {DeploymentInfo} from "./IPosition.sol";
import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";

interface ILPManager {
    event RewardClaimed(
        address creator,
        PoolId pool,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice get uniswap position id
    function positionId(
        address creator,
        PoolId pool
    ) external view returns (uint256);

    /// @param creator is token creator address
    /// @param pool is token pool id
    /// @return amount0 and amount1 actually claimed fee of token0 and token1 from uniswap pool
    function claimRewards(
        address creator,
        PoolId pool
    ) external returns (uint256 amount0, uint256 amount1);

    function addNewPosition(DeploymentInfo memory deployment) external;
}
