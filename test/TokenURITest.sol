// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {GemoonToken} from "../src/contracts/Token.sol";
import {TokenConfig, SocialMedia, IGemoonToken, FeeInfo} from "../src/contracts/interfaces/IToken.sol";
import {IERC1046} from "../src/contracts/interfaces/IERC1046.sol";
import {AdminConfig} from "../src/contracts/utils/Admin.sol";
import {Json} from "../src/contracts/utils/Json.sol";

/// @notice ERC-1046 `tokenURI` of GemoonToken: `data:application/json;base64,` of a JSON built
/// on-chain from name, symbol, decimals, description, image, social links and the fee split. Every test decodes
/// the URI and reads the fields back with `vm.parseJson`, so the JSON must stay valid whatever the
/// creator put into the strings.
contract TokenURITest is Test {
    string constant PREFIX = "data:application/json;base64,";

    address admin = makeAddr("admin");
    address stranger = makeAddr("stranger");

    /// @dev 1.25% fee: a third (3333 bips) to the protocol, 10% of the vault part to the creator.
    function _fees() internal pure returns (FeeInfo memory) {
        return FeeInfo({totalPpm: 12_500, creatorPpm: 833, vaultPpm: 7_501, protocolPpm: 4_166});
    }

    function _deploy(
        string memory name_,
        string memory description_,
        string memory image_,
        SocialMedia memory social_
    ) internal returns (GemoonToken) {
        return _deployWithFees(name_, description_, image_, social_, _fees());
    }

    function _deployWithFees(
        string memory name_,
        string memory description_,
        string memory image_,
        SocialMedia memory social_,
        FeeInfo memory fees_
    ) internal returns (GemoonToken) {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: admin, removable: false});
        return new GemoonToken(
            TokenConfig({
                imgUrl: image_,
                description: description_,
                socialMedia: social_,
                name: name_,
                symbol: "MEME",
                admins: admins
            }),
            address(0xC0FFEE),
            fees_
        );
    }

    function _social() internal pure returns (SocialMedia memory) {
        return SocialMedia({
            farcaster: "https://warpcast.com/meme",
            twitterX: "https://x.com/meme",
            telegram: "https://t.me/meme",
            website: "https://meme.xyz"
        });
    }

    function _deployDefault() internal returns (GemoonToken) {
        return _deploy("Meme", "a meme", "ipfs://image", _social());
    }

    /// @dev Strips the data URI prefix and decodes the base64 payload.
    function _json(GemoonToken token) internal view returns (string memory) {
        bytes memory uri = bytes(token.tokenURI());
        bytes memory prefix = bytes(PREFIX);
        require(uri.length >= prefix.length, "short uri");
        for (uint256 i; i < prefix.length; ++i) require(uri[i] == prefix[i], "prefix");
        bytes memory payload = new bytes(uri.length - prefix.length);
        for (uint256 i; i < payload.length; ++i) payload[i] = uri[prefix.length + i];
        return string(_decodeBase64(payload));
    }

    /// @dev Standard base64 with `=` padding, as produced by OZ `Base64.encode`.
    function _decodeBase64(bytes memory data) internal pure returns (bytes memory out) {
        require(data.length % 4 == 0, "base64 length");
        if (data.length == 0) return out;
        uint256 pad = data[data.length - 1] == "=" ? (data[data.length - 2] == "=" ? 2 : 1) : 0;
        out = new bytes((data.length / 4) * 3 - pad);
        uint256 j;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (_b64(data[i]) << 18) | (_b64(data[i + 1]) << 12)
                | (_b64(data[i + 2]) << 6) | _b64(data[i + 3]);
            if (j < out.length) out[j++] = bytes1(uint8(n >> 16));
            if (j < out.length) out[j++] = bytes1(uint8(n >> 8));
            if (j < out.length) out[j++] = bytes1(uint8(n));
        }
    }

    function _b64(bytes1 c) internal pure returns (uint256) {
        if (c >= "A" && c <= "Z") return uint8(c) - 65;
        if (c >= "a" && c <= "z") return uint8(c) - 71;
        if (c >= "0" && c <= "9") return uint8(c) + 4;
        if (c == "+") return 62;
        if (c == "/") return 63;
        if (c == "=") return 0;
        revert("base64 char");
    }

    // ------------------------------------------------------------------ content

    function test_TokenURI_Prefix_DataJsonBase64() external {
        GemoonToken token = _deployDefault();
        string memory json = _json(token);
        assertEq(token.tokenURI(), string.concat(PREFIX, Base64.encode(bytes(json))));
    }

    function test_TokenURI_Fields_MatchTokenData() external {
        string memory json = _json(_deployDefault());
        assertEq(vm.parseJsonString(json, ".name"), "Meme");
        assertEq(vm.parseJsonString(json, ".symbol"), "MEME");
        assertEq(vm.parseJsonUint(json, ".decimals"), 18);
        assertEq(vm.parseJsonString(json, ".description"), "a meme");
        assertEq(vm.parseJsonString(json, ".image"), "ipfs://image");
    }

    function test_TokenURI_SocialMedia_AllFourLinks() external {
        string memory json = _json(_deployDefault());
        assertEq(vm.parseJsonString(json, ".socialMedia.farcaster"), "https://warpcast.com/meme");
        assertEq(vm.parseJsonString(json, ".socialMedia.twitterX"), "https://x.com/meme");
        assertEq(vm.parseJsonString(json, ".socialMedia.telegram"), "https://t.me/meme");
        assertEq(vm.parseJsonString(json, ".socialMedia.website"), "https://meme.xyz");
    }

    function test_TokenURI_EmptySocialMedia_EmptyStrings() external {
        string memory json = _json(
            _deploy("Meme", "d", "i", SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}))
        );
        assertEq(vm.parseJsonString(json, ".socialMedia.farcaster"), "");
        assertEq(vm.parseJsonString(json, ".socialMedia.website"), "");
    }

    /// @dev Exact JSON layout, so frontends can rely on it.
    function test_TokenURI_Json_ExactLayout() external {
        assertEq(
            _json(_deployDefault()),
            '{"name":"Meme","symbol":"MEME","decimals":18,"description":"a meme","image":"ipfs://image",'
            '"socialMedia":{"farcaster":"https://warpcast.com/meme","twitterX":"https://x.com/meme",'
            '"telegram":"https://t.me/meme","website":"https://meme.xyz"},'
            '"fees":{"totalPercent":1.25,"creatorPercent":0.0833,"vaultPercent":0.7501,"protocolPercent":0.4166}}'
        );
    }

    function test_TokenURI_AfterUpdateImageAndDescription_Reflected() external {
        GemoonToken token = _deployDefault();
        vm.startPrank(admin);
        token.updateImage("ipfs://new-image");
        token.changeDescription("new description");
        vm.stopPrank();
        string memory json = _json(token);
        assertEq(vm.parseJsonString(json, ".image"), "ipfs://new-image");
        assertEq(vm.parseJsonString(json, ".description"), "new description");
    }

    // ------------------------------------------------------------------ fees

    function test_TokenURI_Fees_PercentOfSwap() external {
        string memory json = _json(_deployDefault());
        assertEq(vm.parseJsonString(json, ".fees.totalPercent"), "1.25");
        assertEq(vm.parseJsonString(json, ".fees.creatorPercent"), "0.0833");
        assertEq(vm.parseJsonString(json, ".fees.vaultPercent"), "0.7501");
        assertEq(vm.parseJsonString(json, ".fees.protocolPercent"), "0.4166");
    }

    function test_FeeInfo_Getter_ReturnsConstructorValue() external {
        FeeInfo memory fees = _deployDefault().feeInfo();
        assertEq(fees.totalPpm, 12_500);
        assertEq(fees.creatorPpm, 833);
        assertEq(fees.vaultPpm, 7_501);
        assertEq(fees.protocolPpm, 4_166);
    }

    /// @dev Whole percents print without a fraction, leading zeros of the fraction are kept.
    function test_TokenURI_FeesFormatting_WholeAndLeadingZeros() external {
        string memory json = _json(
            _deployWithFees(
                "Meme",
                "d",
                "i",
                _social(),
                FeeInfo({totalPpm: 100_000, creatorPpm: 66_664, vaultPpm: 3, protocolPpm: 33_333})
            )
        );
        assertEq(vm.parseJsonString(json, ".fees.totalPercent"), "10");
        assertEq(vm.parseJsonString(json, ".fees.creatorPercent"), "6.6664");
        assertEq(vm.parseJsonString(json, ".fees.vaultPercent"), "0.0003");
        assertEq(vm.parseJsonString(json, ".fees.protocolPercent"), "3.3333");
    }

    function test_Constructor_FeePartsNotSummingToTotal_Reverts() external {
        AdminConfig[] memory admins = new AdminConfig[](1);
        admins[0] = AdminConfig({admin: admin, removable: false});
        TokenConfig memory config = TokenConfig({
            imgUrl: "i",
            description: "d",
            socialMedia: _social(),
            name: "Meme",
            symbol: "MEME",
            admins: admins
        });
        vm.expectRevert(IGemoonToken.InvalidFeeInfo.selector);
        new GemoonToken(
            config,
            address(0xC0FFEE),
            FeeInfo({totalPpm: 12_500, creatorPpm: 833, vaultPpm: 7_500, protocolPpm: 4_166})
        );
    }

    /// @dev Any fee split whose parts add up: the JSON stays valid and every percent reads back as
    /// ppm / 10_000 exactly.
    function testFuzz_TokenURI_Fees_ExactPercent(uint32 creator, uint32 vault, uint32 protocol) external {
        creator = uint32(bound(creator, 0, 1_000_000));
        vault = uint32(bound(vault, 0, 1_000_000));
        protocol = uint32(bound(protocol, 0, 1_000_000));
        uint32 total = creator + vault + protocol;
        string memory json = _json(
            _deployWithFees(
                "Meme",
                "d",
                "i",
                _social(),
                FeeInfo({totalPpm: total, creatorPpm: creator, vaultPpm: vault, protocolPpm: protocol})
            )
        );
        assertEq(_ppm(vm.parseJsonString(json, ".fees.totalPercent")), total);
        assertEq(_ppm(vm.parseJsonString(json, ".fees.creatorPercent")), creator);
        assertEq(_ppm(vm.parseJsonString(json, ".fees.vaultPercent")), vault);
        assertEq(_ppm(vm.parseJsonString(json, ".fees.protocolPercent")), protocol);
    }

    /// @dev Percent string with up to 4 decimals back to ppm.
    function _ppm(string memory percent) internal pure returns (uint256 ppm) {
        bytes memory b = bytes(percent);
        uint256 decimals;
        bool dot;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == ".") {
                dot = true;
                continue;
            }
            ppm = ppm * 10 + (uint8(b[i]) - 48);
            if (dot) ++decimals;
        }
        require(decimals <= 4, "too many decimals");
        ppm *= 10 ** (4 - decimals);
    }

    // ------------------------------------------------------------------ escaping

    /// @dev A creator cannot inject fields: quotes are escaped, the injected key does not exist.
    function test_TokenURI_QuoteInDescription_NoInjection() external {
        string memory evil = 'x","image":"https://phish.example';
        string memory json = _json(_deploy("Meme", evil, "ipfs://image", _social()));
        assertEq(vm.parseJsonString(json, ".description"), evil);
        assertEq(vm.parseJsonString(json, ".image"), "ipfs://image");
    }

    function test_TokenURI_ControlCharsAndBackslash_RoundTrip() external {
        string memory raw = string(abi.encodePacked("a\\b\"c\nd\re\tf", bytes1(0x01), bytes1(0x1f), "g"));
        string memory json = _json(_deploy(raw, raw, raw, _social()));
        assertEq(vm.parseJsonString(json, ".name"), raw);
        assertEq(vm.parseJsonString(json, ".description"), raw);
        assertEq(vm.parseJsonString(json, ".image"), raw);
    }

    function test_TokenURI_Utf8_KeptAsIs() external {
        string memory raw = unicode"мем 🚀";
        string memory json = _json(_deploy(raw, raw, "i", _social()));
        assertEq(vm.parseJsonString(json, ".name"), raw);
        assertEq(vm.parseJsonString(json, ".description"), raw);
    }

    function test_Escape_Plain_ReturnsSameString() external pure {
        assertEq(Json.escape("https://meme.xyz/a?b=c"), "https://meme.xyz/a?b=c");
    }

    function test_Escape_SpecialChars_Escaped() external pure {
        assertEq(
            Json.escape(string(abi.encodePacked('"\\', bytes1(0x08), bytes1(0x0c), "\n\r\t", bytes1(0x00)))),
            '\\"\\\\\\b\\f\\n\\r\\t\\u0000'
        );
    }

    /// @dev Any ASCII description (control chars, quotes, backslashes included) survives the round
    /// trip through the JSON unchanged and does not touch the other fields.
    function testFuzz_TokenURI_AsciiDescription_RoundTrip(bytes memory raw) external {
        vm.assume(raw.length <= 256);
        for (uint256 i; i < raw.length; ++i) raw[i] = bytes1(uint8(raw[i]) & 0x7f);
        string memory description_ = string(raw);
        string memory json = _json(_deploy("Meme", description_, "ipfs://image", _social()));
        assertEq(vm.parseJsonString(json, ".description"), description_);
        assertEq(vm.parseJsonString(json, ".image"), "ipfs://image");
        assertEq(vm.parseJsonString(json, ".socialMedia.website"), "https://meme.xyz");
    }

    // ------------------------------------------------------------------ setTokenURI

    function test_SetTokenURI_Admin_OverridesOnChainJson() external {
        GemoonToken token = _deployDefault();
        vm.expectEmit(address(token));
        emit IGemoonToken.UpdateTokenURI("ipfs://custom.json");
        vm.prank(admin);
        token.setTokenURI("ipfs://custom.json");
        assertEq(token.tokenURI(), "ipfs://custom.json");
    }

    function test_SetTokenURI_Empty_BackToOnChainJson() external {
        GemoonToken token = _deployDefault();
        string memory onChain = token.tokenURI();
        vm.startPrank(admin);
        token.setTokenURI("ipfs://custom.json");
        token.setTokenURI("");
        vm.stopPrank();
        assertEq(token.tokenURI(), onChain);
        assertEq(vm.parseJsonString(_json(token), ".name"), "Meme");
    }

    function test_SetTokenURI_NotAdmin_Reverts() external {
        GemoonToken token = _deployDefault();
        string memory before = token.tokenURI();
        vm.expectRevert("Caller is not an admin");
        vm.prank(stranger);
        token.setTokenURI("https://phish.example/meta.json");
        assertEq(token.tokenURI(), before);
    }

    /// @dev A custom URI is returned verbatim and stays put while image / description change.
    function test_SetTokenURI_CustomSet_IgnoresMetadataUpdates() external {
        GemoonToken token = _deployDefault();
        vm.startPrank(admin);
        token.setTokenURI("ipfs://custom.json");
        token.updateImage("ipfs://new-image");
        token.changeDescription("new description");
        vm.stopPrank();
        assertEq(token.tokenURI(), "ipfs://custom.json");
    }

    /// @dev Any non-empty URI is returned verbatim, an empty one restores the on-chain JSON.
    function testFuzz_SetTokenURI_AnyUri_ReturnedOrOnChain(string memory uri) external {
        GemoonToken token = _deployDefault();
        string memory onChain = token.tokenURI();
        vm.prank(admin);
        token.setTokenURI(uri);
        assertEq(token.tokenURI(), bytes(uri).length == 0 ? onChain : uri);
    }

    // ------------------------------------------------------------------ ERC-165

    function test_SupportsInterface_ERC1046_True() external {
        GemoonToken token = _deployDefault();
        assertEq(type(IERC1046).interfaceId, bytes4(0x3c130d90), "ERC-1046 id");
        assertTrue(token.supportsInterface(type(IERC1046).interfaceId));
        assertTrue(ERC165Checker.supportsInterface(address(token), type(IERC1046).interfaceId));
    }

    function test_SupportsInterface_ERC165AndERC20_True() external {
        GemoonToken token = _deployDefault();
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20Metadata).interfaceId));
    }

    function test_SupportsInterface_InvalidId_False() external {
        GemoonToken token = _deployDefault();
        assertFalse(token.supportsInterface(0xffffffff), "ERC-165 invalid id");
        assertFalse(token.supportsInterface(0x80ac58cd), "not ERC-721");
    }
}
