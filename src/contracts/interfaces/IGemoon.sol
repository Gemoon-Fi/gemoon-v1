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
    /// @dev Swap fee of the Meme in bips: 100..500 (1%..5%). The vault splits it: the protocol
    /// gets `Vault.protocolShareBps` of it (a third by default), the Meme vault the rest.
    uint256 swapFeeBips;
    address creatorAddress;
    address rewardRecipient; // now is only
}

/// @dev Optional first buy of the new Meme by the caller of `deployToken`, made in the same
/// transaction as the pool creation, so no one can buy before it. Paid in the pair token at the
/// pool price plus the base swap fee of the Meme (no anti-snipe fee). The caller must approve
/// the controller for `maxPairIn` of the pair token.
struct DevBuyConfig {
    /// @dev Exact Meme amount to buy, raw units. 0 = no dev buy. At most
    /// `MAX_DEV_BUY_BIPS` of the supply.
    uint256 memeAmount;
    /// @dev Most pair token the caller agrees to pay for `memeAmount`, swap fee included.
    uint256 maxPairIn;
}

struct DeployConfig {
    TokenConfig tokenConfig;
    RewardsConfig rewardsConfig;
    /// @dev Reward assets of the Meme vault, chosen by the creator from the vault allowlist.
    AssetConfig[] vaultAssets;
    /// @dev Share of every vault fee credited to `rewardRecipient`, in bps: 0..5_000
    /// (1_000 = 10%), the rest goes to the stakers. Immutable after deployment.
    uint16 vaultCreatorShareBps;
    DevBuyConfig devBuy;
}

int24 constant TICK_SPACING = 200;

// TODO: move to GemoonController interface
uint256 constant INITIAL_LIQUIDITY = 1_000_000_000;
uint256 constant INITIAL_SUPPLY_X18 = INITIAL_LIQUIDITY * 1e18;

/// @dev Market cap of every Meme at the start price, in whole pair tokens: 20 000 USDG.
/// Must divide `INITIAL_LIQUIDITY`, so that the start price below is exact.
uint256 constant INITIAL_MARKET_CAP = 20_000;

/// @dev Start price of every Meme pool: this many whole Meme for one whole pair token, the
/// supply over the start market cap (1 000 000 000 / 20 000 = 50 000). A human-readable count, not
/// raw units: `_configurePool` scales it by the decimals of both tokens.
uint256 constant PRICE_PER_TOKEN = INITIAL_LIQUIDITY / INITIAL_MARKET_CAP;

/// @dev Largest dev buy, in bips of the supply: 80%.
uint256 constant MAX_DEV_BUY_BIPS = 8_000;
/// @dev Largest dev buy in raw Meme units.
uint256 constant MAX_DEV_BUY_X18 = (INITIAL_SUPPLY_X18 * MAX_DEV_BUY_BIPS) / 10_000;

interface IGemoonController {
    /// @dev Dev buy above `MAX_DEV_BUY_X18` (80% of the supply).
    error DevBuyTooLarge(uint256 memeAmount, uint256 maxMemeAmount);
    /// @dev Dev buy costs more pair token than `DevBuyConfig.maxPairIn`.
    error DevBuySlippage(uint256 pairIn, uint256 maxPairIn);

    event TokenCreated(
        address indexed tokenAddress,
        address indexed creatorAdmin,
        uint256 indexed positionId,
        address creatorRewardRecipient,
        string name,
        string symbol
    );

    event PoolCreated(
        PoolId indexed pool,
        address indexed token0,
        address indexed token1,
        uint256 initialPrice,
        int24 tick
    );

    /// @notice Initial liquidity position of a Meme, minted on deployment and held by the
    ///         controller.
    event PositionCreated(
        address indexed token,
        uint256 indexed positionId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    );

    /// @notice First buy of a Meme by its deployer, made in the `deployToken` transaction.
    /// @param token    Meme bought.
    /// @param buyer    Caller of `deployToken`: paid the pair token and received the Meme.
    /// @param pairIn   Pair token paid, swap fee included.
    /// @param memeOut  Meme received.
    event DevBuy(
        address indexed token,
        address indexed buyer,
        uint256 pairIn,
        uint256 memeOut
    );

    /// @notice Deploys a Meme token, registers its vault, creates the pool and mints the initial
    ///         position. Admins of the token are `config.tokenConfig.admins` plus the controller
    ///         and the caller. With a non-zero `config.devBuy.memeAmount` the caller then buys that
    ///         much Meme from the new pool in the same transaction.
    function deployToken(
        DeployConfig memory config
    ) external payable returns (address);

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external;

    /// @notice Hook the pool of `meme` was created with, zero if not recorded (Meme deployed by
    ///         an older controller version). Fixed per Meme, whatever `hook()` is later set to.
    function hookOf(address meme) external view returns (address);
}
