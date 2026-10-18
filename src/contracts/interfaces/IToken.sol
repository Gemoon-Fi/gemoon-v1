// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../utils/Admin.sol";
import {IERC1046} from "./IERC1046.sol";

uint8 constant DECIMALS = 18;

struct SocialMedia {
    string farcaster;
    string twitterX;
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

    event UpdateImage(string newAddress);

    event UpdateDescription(string newDescription);

    /// @notice Custom metadata URI set (empty: back to the on-chain JSON).
    event UpdateTokenURI(string newTokenURI);
}
