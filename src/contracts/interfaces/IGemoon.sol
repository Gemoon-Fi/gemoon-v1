// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./IToken.sol";

struct DeploymentInfo {
    address token0;
    address token1;
    int24 lowerTick;
    int24 upperTick;
    uint256 positionId;
    address poolId;
    address rewardRecipient;
    address creatorAdmin;
}

struct DeployedToken {
    address creatorAdmin;
    address tokenAddress;
}

struct RewardsConfig {
    uint256 creatorRewards;
    address creatorAddress;
    address rewardRecipient; // now is only
}

struct DeployConfig {
    TokenConfig tokenConfig;
    RewardsConfig rewardsConfig;
}

interface IGemoonController {
    event TokenCreated(
        address indexed tokenAddress,
        address indexed creatorAdmin,
        uint256 indexed positionId,
        address creatorRewardRecipient,
        string name,
        string symbol
    );

    event PositionCreated(
        uint256 positionId,
        address indexed creator,
        address indexed token0,
        address indexed token1,
        uint256 poolSupply
    );

    event PoolCreated(address indexed pool, uint256 initialPrice);

    // admins will be (address(this) + address(msg.sender))
    function deployToken(
        DeployConfig memory config
    ) external payable returns (address);

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external;
}
