// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IToken.sol";

struct DeploymentInfo {
    address token;
    uint256 positionId;
}

struct RewardsConfig {
    uint256 creatorRewards;
    address creatorAddress;
    address rewardRecipient; // now is only
}

struct PoolConfig {
    address token0;
    address token1;
}

struct DeployConfig {
    TokenConfig tokenConfig;
    RewardsConfig rewardsConfig;
    PoolConfig poolConfig;
}

interface IGemoonController {
    event RewardClaimed();
    event TokenCreated(
        address indexed tokenAddress,
        address indexed creatorAdmin,
        address creatorRewardRecipient,
        uint256 positionId,
        string name,
        string symbol,
        int24 startingTickIfToken0IsNewToken
    );

    // admins will be (address(this) + address(msg.sender))
    function deployToken(
        DeployConfig memory config
    ) external payable returns (address);

    function deployTokenWithCustomTeamRewardRecipient(
        DeployConfig memory config,
        address teamRewardRecipient
    ) external payable returns (address tokenAddress, uint256 positionId);

    function getTokensDeployedByUser(
        address user
    ) external view returns (DeploymentInfo[] memory);

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external;

    function claimRewards(address token) external;

    function MAX_CREATOR_REWARD() external view returns (uint256);

    function MAX_DEPLOYER_REWARD() external view returns (uint256);
}
