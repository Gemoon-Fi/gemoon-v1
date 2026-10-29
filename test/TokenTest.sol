pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/Token.sol";
import "../src/contracts/utils/Admin.sol";
import "../src/contracts/interfaces/IToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {console} from "forge-std/console.sol";

/// @dev 1.25% fee, a third to the protocol, 10% of the vault part to the creator.
function FEES() pure returns (FeeInfo memory) {
    return FeeInfo({totalPpm: 12_500, creatorPpm: 833, vaultPpm: 7_501, protocolPpm: 4_166});
}

contract TokenTest is Test {
    address internal constant CREATOR = address(0xC0FFEE);

    function test_Creator_SetInConstructor_ReturnsCreator() external {
        address[] memory initAdmins = new address[](1);
        bool[] memory removables = new bool[](1);
        initAdmins[0] = msg.sender;
        removables[0] = false;

        GemoonToken token = new GemoonToken(
            TokenConfig({
                imgUrl: "https://a.com",
                description: "A test token",
                socialMedia: SocialMedia({
                    farcaster: "https://farcaster.xyz",
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
        );

        assertEq(token.creator(), CREATOR);
    }

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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
        );

        vm.expectRevert(bytes("Caller is not an admin"));
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
                    twitter: "https://twitter.com/test",
                    telegram: "https://t.me/test",
                    website: "https://test.com"
                }),
                name: "Test Token",
                symbol: "TEST",
                admins: initAdminsStruct(initAdmins, removables)
            }),
            CREATOR,
            FEES(),
            address(this)
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
            token.getSocialMedia().twitter,
            "https://twitter.com/test",
            "Invalid twitter social media URL"
        );
        assertEq(
            token.getSocialMedia().website,
            "https://test.com",
            "Invalid website social media URL"
        );
    }

    function _config() internal view returns (TokenConfig memory) {
        address[] memory initAdmins = new address[](1);
        bool[] memory removables = new bool[](1);
        initAdmins[0] = msg.sender;
        return TokenConfig({
            imgUrl: "https://a.com",
            description: "A test token",
            socialMedia: SocialMedia({farcaster: "", twitter: "", telegram: "", website: ""}),
            name: "Test Token",
            symbol: "TEST",
            admins: initAdminsStruct(initAdmins, removables)
        });
    }

    /// @dev The supply goes to the recipient argument, not to the deployer (in the protocol the
    /// deployer is the TokenDeployer, the recipient the controller).
    function test_Constructor_WholeSupplyToRecipientNotDeployer() external {
        address recipient = makeAddr("recipient");
        GemoonToken token = new GemoonToken(_config(), CREATOR, FEES(), recipient);

        assertEq(token.totalSupply(), 1_000_000_000 * 1e18, "fixed supply");
        assertEq(token.balanceOf(recipient), token.totalSupply(), "all to the recipient");
        assertEq(token.balanceOf(address(this)), 0, "deployer gets nothing");
        assertEq(token.totalHolders(), 1);
    }

    function test_Constructor_ZeroSupplyRecipient_Revert() external {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new GemoonToken(_config(), CREATOR, FEES(), address(0));
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
