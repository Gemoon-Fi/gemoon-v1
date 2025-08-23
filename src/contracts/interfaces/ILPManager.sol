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


    event PositionCreated(
        uint256 positionId,
        address indexed creator,
        address indexed token0,
        address indexed token1,
        uint256 poolSupply
    );

    function positionId(
        address creator,
        address pool
    ) external view returns (uint256);

    function claimRewards(
        address creator,
        address pool
    ) external returns (uint256 amount0, uint256 amount1);

    function addNewPosition(DeploymentInfo memory deployment) external;
}
