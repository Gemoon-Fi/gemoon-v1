// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SocialMedia} from "./IToken.sol";

/// @title Read-only batch reader of the Gemoon protocol for frontends.
/// @notice Every function is `view` and takes a list of addresses, so a screen needs one to three
/// `eth_call`s instead of one per field. Results come in the order of the input, duplicates allowed.
///
/// A failing read never reverts the batch. It leaves zeros and, where zero is a valid value, a
/// false `ok` / `*Ok` flag: the frontend shows "no data" for it.
interface IGemoonLens {
    /// @notice Reward asset of a Meme vault.
    /// @param token     Asset address.
    /// @param weightBps Share of every conversion swapped into the asset, weights sum to 10000.
    /// @param symbol    `symbol()` of the asset, empty if it failed (see `symbolOk`).
    /// @param symbolOk  Whether `symbol()` returned a string.
    /// @param decimals  `decimals()` of the asset, zero if it failed (see `decimalsOk`).
    /// @param decimalsOk Whether `decimals()` returned a valid uint8.
    struct Asset {
        address token;
        uint16 weightBps;
        string symbol;
        bool symbolOk;
        uint8 decimals;
        bool decimalsOk;
    }

    /// @notice Rarely changing token data, safe to cache.
    /// @param ok         False if the address has no code or `totalSupply()` failed. Then every
    ///                   other field of the `TokenView` is zero except `meme` and the pool id.
    /// @param name       `name()`, empty if it failed.
    /// @param symbol     `symbol()`, empty if it failed.
    /// @param decimals   `decimals()`, zero if it failed (see `decimalsOk`).
    /// @param decimalsOk Whether `decimals()` returned a valid uint8.
    /// @param description `description()`, empty if it failed.
    /// @param image      `imageAddress()`, empty if it failed.
    /// @param creator    `creator()` of the token, zero if it failed (see `creatorOk`).
    /// @param creatorOk  Whether `creator()` returned an address. False on tokens without it.
    /// @param social     `getSocialMedia()`: farcaster, twitterX, telegram, website. Empty if it
    ///                   failed (see `socialOk`).
    /// @param socialOk   Whether `getSocialMedia()` returned four strings.
    /// @param tokenURI   ERC-1046 `tokenURI()`, empty if it failed (Memes deployed before it).
    struct TokenMeta {
        bool ok;
        string name;
        string symbol;
        uint8 decimals;
        bool decimalsOk;
        string description;
        string image;
        address creator;
        bool creatorOk;
        SocialMedia social;
        bool socialOk;
        string tokenURI;
    }

    /// @notice Often changing market data.
    /// @param totalSupply  `totalSupply()`, zero if it failed.
    /// @param burned       `balanceOf(0x0) + balanceOf(0xdEaD)`, zero if a read failed.
    /// @param burnedOk     Whether both `balanceOf` reads answered.
    /// @param poolId       Uniswap V4 pool id of the Gemoon pool, always computed.
    /// @param sqrtPriceX96 Pool price from slot0, zero if the pool is not initialized.
    /// @param memeIsToken0 Whether the Meme is currency0 of the pool (Meme address below USDG).
    /// @param pendingFees  `hook.pendingFees(meme)`: fee charged and not paid out yet, zero on error.
    /// @param pendingFeesOk Whether `hook.pendingFees(meme)` answered.
    struct TokenMarket {
        uint256 totalSupply;
        uint256 burned;
        bool burnedOk;
        bytes32 poolId;
        uint160 sqrtPriceX96;
        bool memeIsToken0;
        uint256 pendingFees;
        bool pendingFeesOk;
    }

    /// @notice Public state of the vault of a Meme. All zero except `registered` and
    /// `registeredOk` when the Meme has no vault.
    /// @param registered            `vault.isRegistered(meme)`.
    /// @param registeredOk          Whether `vault.isRegistered(meme)` answered: false means
    ///                              "unknown", not "no vault".
    /// @param registeredAt          Registration timestamp.
    /// @param totalStaked           Meme staked in the vault.
    /// @param creator               Current creator of the vault (receives the creator share).
    /// @param pendingStakerUSDG     USDG credited to stakers in the open epoch, not converted yet.
    /// @param pendingCreatorUSDG    USDG credited to the creator in the open epoch.
    /// @param lastConversionFailure Timestamp of the last failed automatic conversion, zero if none.
    /// @param assets                Reward assets with weights, symbols and decimals.
    struct VaultPublic {
        bool registered;
        bool registeredOk;
        uint64 registeredAt;
        uint256 totalStaked;
        address creator;
        uint256 pendingStakerUSDG;
        uint256 pendingCreatorUSDG;
        uint64 lastConversionFailure;
        Asset[] assets;
    }

    /// @notice Position of an account in a Meme. All zero when no account is given; the vault
    /// fields are zero when the Meme has no vault.
    /// @param balance       `meme.balanceOf(account)`.
    /// @param staked        `vault.stakedOf(meme, account)`.
    /// @param pendingCredit `vault.pendingCreditOf(meme, account)`: USDG credited in the open epoch.
    /// @param allowance     `meme.allowance(account, vault)`.
    /// @param earnedAssets  Assets of `vault.earned(meme, account)`, order of the vault assets.
    /// @param earnedAmounts Claimable amount per asset.
    struct Position {
        uint256 balance;
        uint256 staked;
        uint256 pendingCredit;
        uint256 allowance;
        address[] earnedAssets;
        uint256[] earnedAmounts;
    }

    /// @notice Everything a table row, card or token page shows.
    struct TokenView {
        address meme;
        TokenMeta meta;
        TokenMarket market;
        VaultPublic vault;
        Position position;
    }

    /// @notice Creator of a Meme vault and the creator share claimable now.
    /// @param creatorOf `vault.creatorOf(meme)`, zero if the Meme has no vault.
    /// @param ok        Whether the vault answered both reads.
    /// @param assets    Reward assets, order of the vault assets.
    /// @param accrued   Claimable creator amount per asset.
    struct CreatorRewards {
        address creatorOf;
        bool ok;
        address[] assets;
        uint256[] accrued;
    }

    /// @notice Zero address passed to the constructor.
    error ZeroAddress();

    /// @notice Full view of every Meme in `memes`.
    /// @param memes   Meme tokens, any order, duplicates allowed.
    /// @param account Account whose `position` is filled; `address(0)` skips every account read.
    /// @return views  One `TokenView` per input address, same order.
    function tokens(address[] calldata memes, address account)
        external
        view
        returns (TokenView[] memory views);

    /// @notice Market data and staked total only, for periodic refresh without strings.
    /// @param memes   Meme tokens.
    /// @return market One `TokenMarket` per input address.
    /// @return staked `vault.totalStaked(meme)` per input address, zero on error.
    function markets(address[] calldata memes)
        external
        view
        returns (TokenMarket[] memory market, uint256[] memory staked);

    /// @notice `vault.totalStaked` of every Meme in `memes`.
    /// @param memes   Meme tokens.
    /// @return staked Staked amount per input address, zero on error.
    function totalStaked(address[] calldata memes) external view returns (uint256[] memory staked);

    /// @notice Quotes of the current swap adapter: how much of each asset `amountIn` USDG buys.
    /// @dev USDG itself is quoted 1:1 with `ok` true: the vault credits it without a swap.
    /// @param assets   Reward assets.
    /// @param amountIn USDG amount, in USDG units.
    /// @return amounts Asset amount per input address, zero when the quote failed.
    /// @return ok      False when the adapter has no route for the asset, is missing or reverted.
    function quotes(address[] calldata assets, uint256 amountIn)
        external
        view
        returns (uint256[] memory amounts, bool[] memory ok);

    /// @notice Protocol constants and current settings in one call.
    /// @return usdg                Pair token of every pool, `vault.usdg()`.
    /// @return usdgDecimals        Its decimals, zero if the call failed.
    /// @return usdgSymbol          Its symbol, empty if the call failed.
    /// @return swapAdapter         Current `vault.swapAdapter()`, zero if not set.
    /// @return conversionThreshold `vault.conversionThreshold()`.
    /// @return conversionCooldown  `vault.CONVERSION_COOLDOWN()`.
    /// @return hook                HookManager the Lens builds pool keys with.
    /// @return poolManager         Uniswap V4 PoolManager the Lens reads prices from.
    function protocol()
        external
        view
        returns (
            address usdg,
            uint8 usdgDecimals,
            string memory usdgSymbol,
            address swapAdapter,
            uint256 conversionThreshold,
            uint256 conversionCooldown,
            address hook,
            address poolManager
        );

    /// @notice Creator of a Meme vault and the creator share claimable now.
    /// @param meme       Meme token.
    /// @return creatorOf `vault.creatorOf(meme)`, zero if the Meme has no vault.
    /// @return assets    Reward assets, order of the vault assets; empty if the read failed.
    /// @return accrued   Claimable creator amount per asset.
    function creator(address meme)
        external
        view
        returns (address creatorOf, address[] memory assets, uint256[] memory accrued);

    /// @notice `creator` for every Meme in `memes`: one call for a creator with many Memes.
    /// @param memes    Meme tokens.
    /// @return rewards One `CreatorRewards` per input address, same order.
    function creators(address[] calldata memes)
        external
        view
        returns (CreatorRewards[] memory rewards);

    /// @notice GemoonController the Lens was deployed for.
    function controller() external view returns (address);

    /// @notice Vault the Lens reads.
    function vault() external view returns (address);
}
