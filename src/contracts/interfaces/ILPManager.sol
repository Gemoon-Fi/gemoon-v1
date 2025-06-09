// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {RewardsConfig, PoolConfig} from "./IGemoon.sol";

interface ILPManager is IERC721Receiver {
    event Received(address indexed from, uint256 tokenId);

    /// @dev Creates a new liquidity position.
    function createPosition(
        RewardsConfig memory rewardsConfig_,
        PoolConfig memory poolConfig_
    ) external returns (uint256 positionId);

    function claimRewards(address token) external returns (uint256 amount);

    function showRewardsForCreator(
        address creator
    ) external view returns (uint256 amount);
}
