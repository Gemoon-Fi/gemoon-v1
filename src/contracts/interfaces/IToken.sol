// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../utils/Admin.sol";
import {IERC1046} from "./IERC1046.sol";

uint8 constant DECIMALS = 18;

struct SocialMedia {
    string farcaster;
    string twitter;
    string telegram;
    string website;
}

struct TokenConfig {
    string imgUrl;
    string description;
    SocialMedia socialMedia;
    string name;
    string symbol;
    AdminConfig[] admins;
}

/// @dev Swap fee split of a Meme, fixed at deployment, in parts per million of the swap amount
/// (1_000_000 = 100%, 12_500 = 1.25%). Base fee only, without the anti-snipe excess of the first
/// seconds. `creatorPpm + vaultPpm + protocolPpm == totalPpm`.
struct FeeInfo {
    /// @dev Whole swap fee of the Meme.
    uint32 totalPpm;
    /// @dev Part credited to the creator (reward recipient) in the vault.
    uint32 creatorPpm;
    /// @dev Part left in the vault for the stakers.
    uint32 vaultPpm;
    /// @dev Part paid to the protocol (Referrals contract).
    uint32 protocolPpm;
}

/// @dev Also ERC-1046 (`tokenURI()`, metadata built on-chain) and ERC-165: `supportsInterface`
/// reports IERC165, IERC20, IERC20Metadata and IERC1046.
interface IGemoonToken is IERC20, IERC1046 {
    function creator() external view returns (address);

    function imageAddress() external view returns (string memory);

    function updateImage(string memory addr) external;

    function description() external view returns (string memory);

    function getSocialMedia() external view returns (SocialMedia memory);

    function changeDescription(string memory desc_) external;

    /// @notice Sets a custom ERC-1046 metadata URI returned by `tokenURI()` instead of the
    ///         on-chain JSON. Empty string switches back to the on-chain JSON. Only admin.
    /// @param uri Metadata JSON URI (e.g. `ipfs://...`, `https://...`, `data:...`), or empty.
    function setTokenURI(string calldata uri) external;

    function showAdmins() external view returns (address[] memory);

    /// @notice Number of addresses holding a non-zero balance, contracts included.
    function totalHolders() external view returns (uint256);

    /// @notice Swap fee split fixed at deployment, also in the `fees` field of `tokenURI()`.
    /// @return Fee split in parts per million of the swap amount.
    function feeInfo() external view returns (FeeInfo memory);

    /// @dev Constructor got a fee split whose parts do not add up to the total.
    error InvalidFeeInfo();

    event UpdateImage(string newAddress);

    event UpdateDescription(string newDescription);

    /// @notice Custom metadata URI set (empty: back to the on-chain JSON).
    event UpdateTokenURI(string newTokenURI);
}
