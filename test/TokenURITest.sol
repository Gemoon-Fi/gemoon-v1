// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {GemoonToken} from "../src/contracts/Token.sol";
import {
    TokenConfig,
    SocialMedia,
    IGemoonToken,
    MAX_TOKEN_URI_LENGTH
} from "../src/contracts/interfaces/IToken.sol";
import {IERC1046} from "../src/contracts/interfaces/IERC1046.sol";
import {AdminConfig} from "../src/contracts/utils/Admin.sol";

/// @notice ERC-1046 `tokenURI` of GemoonToken: set from `TokenConfig.tokenURI`, changed by admins,
/// advertised through ERC-165.
contract TokenURITest is Test {
    address admin = makeAddr("admin");
    address stranger = makeAddr("stranger");

    function _deploy(string memory uri) internal returns (GemoonToken) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: admin, removable: false});
        return new GemoonToken(
            TokenConfig({
                imgUrl: "ipfs://image",
                description: "uri",
                socialMedia: SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}),
                name: "Meme",
                symbol: "MEME",
                admins: admins,
                tokenURI: uri
            }),
            address(0xC0FFEE)
        );
    }

    function _uri(uint256 length) internal pure returns (string memory) {
        bytes memory b = new bytes(length);
        for (uint256 i; i < length; ++i) b[i] = "a";
        return string(b);
    }

    // ------------------------------------------------------------------ constructor

    function test_TokenURI_FromConfig_Returned() external {
        GemoonToken token = _deploy("ipfs://meta.json");
        assertEq(token.tokenURI(), "ipfs://meta.json");
    }

    function test_TokenURI_EmptyConfig_Empty() external {
        assertEq(_deploy("").tokenURI(), "");
    }

    function test_TokenURI_Constructor_EmitsUpdateTokenURI() external {
        vm.expectEmit(false, false, false, true);
        emit IGemoonToken.UpdateTokenURI("ipfs://meta.json");
        _deploy("ipfs://meta.json");
    }

    function test_TokenURI_MaxLength_Accepted() external {
        assertEq(bytes(_deploy(_uri(MAX_TOKEN_URI_LENGTH)).tokenURI()).length, MAX_TOKEN_URI_LENGTH);
    }

    function test_TokenURI_TooLong_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IGemoonToken.TokenURITooLong.selector, MAX_TOKEN_URI_LENGTH + 1, MAX_TOKEN_URI_LENGTH
            )
        );
        _deploy(_uri(MAX_TOKEN_URI_LENGTH + 1));
    }

    // ------------------------------------------------------------------ setTokenURI

    function test_SetTokenURI_Admin_UpdatesAndEmits() external {
        GemoonToken token = _deploy("ipfs://old");
        vm.expectEmit(address(token));
        emit IGemoonToken.UpdateTokenURI("ipfs://new");
        vm.prank(admin);
        token.setTokenURI("ipfs://new");
        assertEq(token.tokenURI(), "ipfs://new");
    }

    function test_SetTokenURI_Empty_Clears() external {
        GemoonToken token = _deploy("ipfs://old");
        vm.prank(admin);
        token.setTokenURI("");
        assertEq(token.tokenURI(), "");
    }

    function test_SetTokenURI_NotAdmin_Reverts() external {
        GemoonToken token = _deploy("ipfs://old");
        vm.expectRevert("Caller is not an admin");
        vm.prank(stranger);
        token.setTokenURI("ipfs://evil");
        assertEq(token.tokenURI(), "ipfs://old");
    }

    function test_SetTokenURI_TooLong_Reverts() external {
        GemoonToken token = _deploy("ipfs://old");
        vm.expectRevert(
            abi.encodeWithSelector(
                IGemoonToken.TokenURITooLong.selector, MAX_TOKEN_URI_LENGTH + 1, MAX_TOKEN_URI_LENGTH
            )
        );
        vm.prank(admin);
        token.setTokenURI(_uri(MAX_TOKEN_URI_LENGTH + 1));
    }

    /// @dev Any URI up to the cap is stored as is, anything longer is rejected and changes nothing.
    function testFuzz_SetTokenURI_LengthBound(uint16 length) external {
        uint256 len = bound(length, 0, MAX_TOKEN_URI_LENGTH + 64);
        GemoonToken token = _deploy("ipfs://old");
        string memory uri = _uri(len);
        if (len > MAX_TOKEN_URI_LENGTH) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IGemoonToken.TokenURITooLong.selector, len, MAX_TOKEN_URI_LENGTH
                )
            );
        }
        vm.prank(admin);
        token.setTokenURI(uri);
        assertEq(token.tokenURI(), len > MAX_TOKEN_URI_LENGTH ? "ipfs://old" : uri);
    }

    // ------------------------------------------------------------------ ERC-165

    function test_SupportsInterface_ERC1046_True() external {
        GemoonToken token = _deploy("");
        assertEq(type(IERC1046).interfaceId, bytes4(0x3c130d90), "ERC-1046 id");
        assertTrue(token.supportsInterface(type(IERC1046).interfaceId));
        assertTrue(ERC165Checker.supportsInterface(address(token), type(IERC1046).interfaceId));
    }

    function test_SupportsInterface_ERC165AndERC20_True() external {
        GemoonToken token = _deploy("");
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20Metadata).interfaceId));
    }

    function test_SupportsInterface_InvalidId_False() external {
        GemoonToken token = _deploy("");
        assertFalse(token.supportsInterface(0xffffffff), "ERC-165 invalid id");
        assertFalse(token.supportsInterface(0x80ac58cd), "not ERC-721");
    }
}
