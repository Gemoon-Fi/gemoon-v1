// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {TokenDeployer} from "../src/contracts/TokenDeployer.sol";
import {GemoonToken} from "../src/contracts/Token.sol";
import {ITokenDeployer} from "../src/contracts/interfaces/ITokenDeployer.sol";
import {
    TokenConfig,
    SocialMedia,
    FeeInfo,
    IGemoonToken
} from "../src/contracts/interfaces/IToken.sol";
import {AdminConfig} from "../src/contracts/utils/Admin.sol";
import {INITIAL_SUPPLY_X18} from "../src/contracts/interfaces/IGemoon.sol";

/// @notice `TokenDeployer` on its own: who may call it, what the token it creates holds and who
/// gets the supply. The controller is a plain address here; the controller side is in
/// ControllerDeployTokenTest, the deploy script side in DeployGemoonTest.
contract TokenDeployerTest is Test {
    address controller = makeAddr("controller");
    address creator = makeAddr("creator");
    address admin = makeAddr("admin");

    TokenDeployer deployer;

    function setUp() external {
        deployer = new TokenDeployer(controller);
    }

    function _config() internal view returns (TokenConfig memory) {
        AdminConfig[] memory admins = new AdminConfig[](2);
        admins[0] = AdminConfig({admin: admin, removable: true});
        admins[1] = AdminConfig({admin: controller, removable: false});
        return TokenConfig({
            imgUrl: "ipfs://meme",
            description: "test meme",
            socialMedia: SocialMedia({
                farcaster: "https://warpcast.com/meme",
                twitter: "https://x.com/meme",
                telegram: "https://t.me/meme",
                website: "https://meme.xyz"
            }),
            name: "Meme",
            symbol: "MEME",
            admins: admins
        });
    }

    function _fees() internal pure returns (FeeInfo memory) {
        return FeeInfo({totalPpm: 12_500, creatorPpm: 937, vaultPpm: 8_438, protocolPpm: 3_125});
    }

    function _deploy() internal returns (GemoonToken) {
        vm.prank(controller);
        return GemoonToken(deployer.deployToken(_config(), creator, _fees()));
    }

    function test_Constructor_ZeroController_Revert() external {
        vm.expectRevert(ITokenDeployer.ZeroAddress.selector);
        new TokenDeployer(address(0));
    }

    function test_Controller_IsConstructorArgument() external view {
        assertEq(deployer.controller(), controller);
    }

    function test_DeployToken_FromController_WholeSupplyToController() external {
        GemoonToken token = _deploy();

        assertEq(token.totalSupply(), INITIAL_SUPPLY_X18, "supply");
        assertEq(token.balanceOf(controller), INITIAL_SUPPLY_X18, "all to the controller");
        assertEq(token.balanceOf(address(deployer)), 0, "deployer keeps nothing");
        assertEq(token.totalHolders(), 1, "controller is the only holder");
        assertEq(token.decimals(), 18);
    }

    function test_DeployToken_FromController_TokenCarriesInputs() external {
        GemoonToken token = _deploy();
        TokenConfig memory config = _config();

        assertEq(token.name(), "Meme");
        assertEq(token.symbol(), "MEME");
        assertEq(token.imageAddress(), config.imgUrl);
        assertEq(token.description(), config.description);
        assertEq(abi.encode(token.getSocialMedia()), abi.encode(config.socialMedia), "social");
        assertEq(token.creator(), creator, "creator from the argument, not msg.sender");
        assertEq(abi.encode(token.feeInfo()), abi.encode(_fees()), "fee split");
        assertEq(abi.encode(token.getAdmins()), abi.encode(config.admins), "admins as given");
    }

    function test_DeployToken_Twice_NewTokenEachTimeAtNextNonce() external {
        address expectedA = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        GemoonToken a = _deploy();
        address expectedB = vm.computeCreateAddress(address(deployer), vm.getNonce(address(deployer)));
        GemoonToken b = _deploy();

        assertEq(address(a), expectedA, "CREATE of the deployer");
        assertEq(address(b), expectedB, "CREATE of the deployer");
        assertTrue(address(a) != address(b));
        assertEq(b.balanceOf(controller), INITIAL_SUPPLY_X18, "second supply also to the controller");
    }

    function test_DeployToken_NotController_Revert() external {
        vm.prank(creator);
        vm.expectRevert(ITokenDeployer.NotController.selector);
        deployer.deployToken(_config(), creator, _fees());
    }

    /// @dev Invariant: only the controller fixed at construction can create tokens.
    function testFuzz_DeployToken_AnyCallerButController_Revert(address caller) external {
        vm.assume(caller != controller);
        uint256 nonce = vm.getNonce(address(deployer));

        vm.prank(caller);
        vm.expectRevert(ITokenDeployer.NotController.selector);
        deployer.deployToken(_config(), creator, _fees());

        assertEq(vm.getNonce(address(deployer)), nonce, "nothing created");
    }

    /// @dev Invariant: whatever the creator and the fee split (parts adding up), the whole supply
    /// goes to the controller and the token reports the creator and the split it was given.
    function testFuzz_DeployToken_AnyCreatorAndFees_SupplyToControllerInputsKept(
        address creator_,
        uint32 creatorPpm,
        uint32 vaultPpm,
        uint32 protocolPpm
    ) external {
        creatorPpm = uint32(bound(creatorPpm, 0, 1_000_000));
        vaultPpm = uint32(bound(vaultPpm, 0, 1_000_000));
        protocolPpm = uint32(bound(protocolPpm, 0, 1_000_000));
        FeeInfo memory fees = FeeInfo({
            totalPpm: creatorPpm + vaultPpm + protocolPpm,
            creatorPpm: creatorPpm,
            vaultPpm: vaultPpm,
            protocolPpm: protocolPpm
        });

        vm.prank(controller);
        IGemoonToken token = IGemoonToken(deployer.deployToken(_config(), creator_, fees));

        assertEq(token.totalSupply(), INITIAL_SUPPLY_X18);
        assertEq(token.balanceOf(controller), INITIAL_SUPPLY_X18);
        assertEq(token.creator(), creator_);
        assertEq(abi.encode(token.feeInfo()), abi.encode(fees));
    }

    function test_DeployToken_FeePartsDoNotAddUp_Revert() external {
        FeeInfo memory fees = _fees();
        fees.vaultPpm += 1;
        vm.prank(controller);
        vm.expectRevert(IGemoonToken.InvalidFeeInfo.selector);
        deployer.deployToken(_config(), creator, fees);
    }
}
