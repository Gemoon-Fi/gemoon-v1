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
    /// @dev ERC-1046 metadata JSON URI (`tokenURI()`), optional: empty = none. At most
    /// `MAX_TOKEN_URI_LENGTH` bytes.
    string tokenURI;
}

/// @dev Longest `tokenURI` accepted at deployment and by `setTokenURI`.
uint256 constant MAX_TOKEN_URI_LENGTH = 2048;

/// @dev Also ERC-1046 (`tokenURI()`) and ERC-165: `supportsInterface` reports IERC165, IERC20,
/// IERC20Metadata and IERC1046.
interface IGemoonToken is IERC20, IERC1046 {
    /// @dev `tokenURI` longer than `MAX_TOKEN_URI_LENGTH`.
    error TokenURITooLong(uint256 length, uint256 maxLength);

    function creator() external view returns (address);

    function imageAddress() external view returns (string memory);

    function updateImage(string memory addr) external;

    function description() external view returns (string memory);

    function getSocialMedia() external view returns (SocialMedia memory);

    function changeDescription(string memory desc_) external;

    /// @notice Replaces the ERC-1046 metadata URI. Only admin. Empty clears it.
    /// @param uri New metadata JSON URI, at most `MAX_TOKEN_URI_LENGTH` bytes.
    function setTokenURI(string calldata uri) external;

    function showAdmins() external view returns (address[] memory);

    /// @notice Number of addresses holding a non-zero balance, contracts included.
    function totalHolders() external view returns (uint256);

    event UpdateImage(string newAddress);

    event UpdateDescription(string newDescription);

    /// @notice ERC-1046 metadata URI changed.
    event UpdateTokenURI(string newTokenURI);
}
