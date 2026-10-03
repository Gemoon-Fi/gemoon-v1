// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "./IToken.sol";
import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";
import {AssetConfig} from "./IVault.sol";

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
    /// @dev Reward assets of the Meme vault, chosen by the creator from the vault allowlist.
    AssetConfig[] vaultAssets;
}

int24 constant TICK_SPACING = 200;

/// @dev Start price of every Meme pool: this many Meme units (18 decimals) for one whole pair
/// token, i.e. for `10 ** pairToken.decimals()` raw units of USDG.
uint256 constant PRICE_PER_TOKEN = 300_000 * 1e18;

// TODO: move to GemoonController interface
uint256 constant INITIAL_LIQUIDITY = 1_000_000_000;
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
        PoolId indexed pool, address indexed token0, address indexed token1, uint256 initialPrice, int24 tick
    );

    /// @notice Initial liquidity position of a Meme, minted on deployment and held by the
    ///         controller.
    event PositionCreated(
        address indexed token, uint256 indexed positionId, int24 tickLower, int24 tickUpper, uint128 liquidity
    );

    /// @notice Deploys a Meme token, registers its vault, creates the pool and mints the initial
    ///         position. Admins of the token are `config.tokenConfig.admins` plus the controller
    ///         and the caller.
    function deployToken(DeployConfig memory config) external payable returns (address);

    function changeAdmin(address token, address oldAdmin, address newAdmin) external;
}
