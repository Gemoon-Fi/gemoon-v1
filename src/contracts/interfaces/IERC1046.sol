// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @title ERC-1046: tokenURI Interoperability.
/// @notice Off-chain metadata of an ERC-20 token, the ERC-20 counterpart of ERC-721 `tokenURI`.
/// @dev https://eips.ethereum.org/EIPS/eip-1046. The URI points to a JSON document with at least
/// `name`, `decimals`, `symbol`, `image`, `description`; it may also carry `interop` fields for
/// ERC-721 / ERC-1155 wallets. Interface id: `type(IERC1046).interfaceId` = `0x3c130d90`.
interface IERC1046 {
    /// @notice URI of the token metadata JSON, empty if none.
    function tokenURI() external view returns (string memory);
}
