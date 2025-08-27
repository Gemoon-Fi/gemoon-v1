pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/Token.sol";
import "../src/contracts/utils/Admin.sol";
import "../src/contracts/interfaces/IToken.sol";
import {console} from "forge-std/console.sol";

// struct TokenConfig {
//     string imgUrl;
//     string description;
//     SocialMedia socialMedia;
//     string name;
//     string symbol;
//     AdminConfig[] admins;
// }

contract TokenTest is Test {
    function testTokenGetAdmin() external {
        address[] memory initAdmins = new address[](2);
        bool[] memory removables = new bool[](2);

        initAdmins[0] = msg.sender;
        removables[0] = false;
        initAdmins[1] = address(0);
        removables[1] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        assertEq(Admin(token).getAdmins().length, 2, "Not enough admins");
        assertEq(
            Admin(token).getAdmins()[0].admin,
            address(msg.sender),
            "Invalid admin"
        );
        assertEq(
            Admin(token).getAdmins()[0].removable,
            false,
            "Admin should not be removable"
        );
        assertEq(
            Admin(token).getAdmins()[1].admin,
            address(0),
            "Invalid admin"
        );
        assertEq(
            Admin(token).getAdmins()[1].removable,
            true,
            "Admin should be removable"
        );
    }

    function testTokenAddressIsAdmin() external {
        address[] memory initAdmins = new address[](2);
        bool[] memory removables = new bool[](2);

        initAdmins[0] = address(msg.sender);
        removables[0] = false;
        initAdmins[1] = address(0);
        removables[1] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        assertEq(Admin(token).isAdmin(msg.sender), true, "Should be admin");
    }

    function testTokenReplaceReplacableAdmin() external {
        address[] memory initAdmins = new address[](2);
        bool[] memory removables = new bool[](2);

        initAdmins[0] = address(this);
        removables[0] = false;
        initAdmins[1] = address(1);
        removables[1] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        assertEq(Admin(token).isAdmin(address(this)), true, "Should be admin");

        // Replace admin=address(1) for address(2):
        Admin(token).replaceAdmin(address(2), address(1)); // (new, old)

        assertEq(Admin(token).getAdmins()[1].admin, address(2));
    }

    function testTokenReplaceReplacableAdminWithoutAdminRole() external {
        address[] memory initAdmins = new address[](1);
        bool[] memory removables = new bool[](1);

        initAdmins[0] = address(1);
        removables[0] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        assertEq(Admin(token).isAdmin(address(this)), false, "Should be admin");
        vm.expectRevert('NotAdmin("Only admin can replace admin")');
        Admin(token).replaceAdmin(address(2), address(1)); // (new, old)
    }

    function testTokenChangeDescription() external {
        address[] memory initAdmins = new address[](2);
        bool[] memory removables = new bool[](2);

        initAdmins[0] = address(this);
        removables[0] = false;
        initAdmins[1] = address(1);
        removables[1] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        token.changeDescription("New description");

        assertEq(token.description(), "New description", "Invalid description");
    }

    function testTokenChangeDescriptionFailBecauseUserIsNotAdmin() external {
        address[] memory initAdmins = new address[](1);
        bool[] memory removables = new bool[](1);

        initAdmins[0] = address(1);
        removables[0] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        vm.expectRevert("Caller is not admin");
        token.changeDescription("New description");
    }

    function testGetTokenInfo() external {
        address[] memory initAdmins = new address[](2);
        bool[] memory removables = new bool[](2);

        initAdmins[0] = msg.sender;
        removables[0] = false;
        initAdmins[1] = address(0);
        removables[1] = true;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitterX: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            })
        );

        assertEq(token.description(), "A test token", "Invalid description");
        assertEq(token.name(), "Test Token", "Invalid name");
        assertEq(token.symbol(), "TEST", "Invalid symbol");
        assertEq(
            token.getSocialMedia().telegram,
            "https://t.me/test",
            "Invalid telegram social media URL"
        );
        assertEq(
            token.getSocialMedia().farcaster,
            "https://farcaster.xyz",
            "Invalid farcaster social media URL"
        );
        assertEq(
            token.getSocialMedia().twitterX,
            "https://twitter.com/test",
            "Invalid twitterX social media URL"
        );
        assertEq(
            token.getSocialMedia().website,
            "https://test.com",
            "Invalid website social media URL"
        );
    }
}

function initAdminsStruct(
    address[] memory _admins,
    bool[] memory _removables
) pure returns (AdminConfig[] memory admins) {
    require(_admins.length == _removables.length, "length mismatch");
    admins = new AdminConfig[](_admins.length);
    for (uint i = 0; i < _admins.length; i++) {
        admins[i] = AdminConfig(_admins[i], _removables[i]);
    }
}
