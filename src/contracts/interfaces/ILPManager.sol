// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./IGemoon.sol";

interface ILPManager is IERC721Receiver {
    event RewardClaimed(
        address creator,
        address pool,
        uint256 amount0,
        uint256 amount1
    );
    event Received(address indexed from, uint256 tokenId);

    /// @notice get uniswap position id
    function positionId(
        address creator,
        address pool
    ) external view returns (uint256);

    /// @param creator is token creator address
    /// @param pool is token pool address
    /// @return amount0 and amount1 actually claimed fee of token0 and token1 from uniswap pool
    function claimRewards(
        address creator,
        address pool
    ) external returns (uint256 amount0, uint256 amount1);

    function addNewPosition(DeploymentInfo memory deployment) external;
}
