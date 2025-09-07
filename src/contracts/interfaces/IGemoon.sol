// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./IToken.sol";

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

uint24 constant FEE_TIER = 10000;
int24 constant TICK_SPACING = 200;

uint256 constant PRICE_PER_TOKEN = 33_333_333 * 1e18;

// TODO: move to GemoonController interface
uint256 constant INITIAL_LIQUIDITY = 100_000_000_000;
uint256 constant INITIAL_SUPPLY_X18 = INITIAL_LIQUIDITY * 1e18;

interface IGemoonController {
    event TokenCreated(
        address indexed tokenAddress,
        address indexed creatorAdmin,
        uint256 indexed positionId,
        address creatorRewardRecipient,
        string name,
        string symbol
    );

    event PoolCreated(
        address indexed pool,
        address indexed token0,
        address indexed token1,
        uint256 initialPrice,
        int24 tick
    );

    // admins will be (address(this) + address(msg.sender))
    function deployToken(
        string memory deployStrategy,
        DeployConfig memory config
    ) external payable returns (address);

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external;
}
