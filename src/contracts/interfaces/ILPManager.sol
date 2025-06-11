// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "./IGemoon.sol";

interface ILPManager is IERC721Receiver {
    event Received(address indexed from, uint256 tokenId);
    event PoolCreated(address indexed pool, uint256 initialPrice);
    event PositionCreated(
        uint256 positionId,
        address indexed creator,
        address indexed token0,
        address indexed token1,
        uint256 poolSupply
    );

    function claimRewards(address token) external returns (uint256 amount);

    function addNewPosition(DeploymentInfo memory deployment) external;

    function showRewardsForCreator(
        address creator
    ) external view returns (uint256 amount);
}
