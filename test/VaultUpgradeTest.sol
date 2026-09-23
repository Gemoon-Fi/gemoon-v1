// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Upgrades} from "@oz-upgrades/Upgrades.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {IVault, AssetConfig} from "../src/contracts/interfaces/IVault.sol";
import {DeployVault, ProxyVaultUpgrade} from "../script/GemoonDeploy.sol";
import {MockToken, MockSwapAdapter} from "./VaultTest.sol";

/// @dev Next Vault version, to exercise the reinitialize / downgrade paths of the upgrade script.
contract VaultV2 is Vault {
    function getVersion() public pure override returns (uint64) {
        return 2;
    }
}

/// @dev The scripts are called externally, so the script contracts themselves act as the
/// broadcaster: `deployer` of DeployVault and owner of the ProxyAdmin for ProxyVaultUpgrade.
contract VaultUpgradeTest is Test {
    bytes32 private constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    DeployVault deployScript;
    ProxyVaultUpgrade upgradeScript;

    Vault vault;
    address proxyAdmin;
    MockToken usdg;
    MockToken meme;
    MockToken aapl;
    MockSwapAdapter adapter;

    address owner = makeAddr("owner");
    address controller = makeAddr("controller");
    address hook = makeAddr("hook");
    address keeper = makeAddr("keeper");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() external {
        usdg = new MockToken("USDG", 6);
        meme = new MockToken("MEME", 18);
        aapl = new MockToken("AAPL", 18);
        adapter = new MockSwapAdapter();
        adapter.setRate(address(aapl), 2e30);

        deployScript = new DeployVault();
        upgradeScript = new ProxyVaultUpgrade();

        address[] memory allowed = new address[](2);
        allowed[0] = address(aapl);
        allowed[1] = address(usdg);

        vault = deployScript.deployVault(
            address(deployScript),
            DeployVault.VaultDeployParams({
                owner: owner,
                proxyAdminOwner: address(upgradeScript),
                usdg: address(usdg),
                controller: controller,
                hook: hook,
                keeper: keeper,
                swapAdapter: address(adapter),
                allowedAssets: allowed
            })
        );
        proxyAdmin = Upgrades.getAdminAddress(address(vault));

        vm.prank(owner);
        vault.acceptOwnership();
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _register() internal {
        AssetConfig[] memory assets = new AssetConfig[](2);
        assets[0] = AssetConfig({token: address(aapl), weightBps: 6_000});
        assets[1] = AssetConfig({token: address(usdg), weightBps: 4_000});
        vm.prank(controller);
        vault.registerVault(address(meme), creator, assets);
    }

    function _stake(address account, uint256 amount) internal {
        meme.mint(account, amount);
        vm.startPrank(account);
        meme.approve(address(vault), amount);
        vault.stake(address(meme), amount);
        vm.stopPrank();
    }

    function _notify(uint256 amount) internal {
        usdg.mint(address(vault), amount);
        vm.prank(hook);
        vault.notifyFees(address(meme), amount);
    }

    function _convert() internal {
        vm.prank(keeper);
        vault.convertFees(address(meme), new uint256[](2));
    }

    function _initializedVersion() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(vault), INITIALIZABLE_STORAGE)));
    }

    // ---------------------------------------------------------------------------------------------
    // Deploy
    // ---------------------------------------------------------------------------------------------

    function test_DeployVault_Configured_ProxyWithRolesAndOwner() external view {
        assertEq(vault.owner(), owner);
        assertEq(vault.usdg(), address(usdg));
        assertEq(vault.controller(), controller);
        assertEq(vault.hook(), hook);
        assertEq(vault.keeper(), keeper);
        assertEq(vault.swapAdapter(), address(adapter));
        assertTrue(vault.isAssetAllowed(address(aapl)));
        assertTrue(vault.isAssetAllowed(address(usdg)));
        assertEq(ProxyAdmin(proxyAdmin).owner(), address(upgradeScript));
        assertEq(_initializedVersion(), 1);
        assertTrue(Upgrades.getImplementationAddress(address(vault)) != address(0));
    }

    function test_DeployVault_OwnerDiffers_OwnershipPending() external {
        address[] memory allowed = new address[](0);
        Vault fresh = deployScript.deployVault(
            address(deployScript),
            DeployVault.VaultDeployParams({
                owner: owner,
                proxyAdminOwner: owner,
                usdg: address(usdg),
                controller: address(0),
                hook: address(0),
                keeper: keeper,
                swapAdapter: address(0),
                allowedAssets: allowed
            })
        );
        assertEq(fresh.owner(), address(deployScript));
        assertEq(fresh.pendingOwner(), owner);
        assertEq(fresh.controller(), address(0));
    }

    function test_Initialize_Twice_Reverts() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(alice, address(usdg));
    }

    function test_Initialize_Implementation_Reverts() external {
        Vault implementation = Vault(Upgrades.getImplementationAddress(address(vault)));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(alice, address(usdg));
    }

    function test_Initialize_ZeroUsdg_Reverts() external {
        Vault implementation = new Vault();
        vm.expectRevert(IVault.ZeroAddress.selector);
        new TransparentUpgradeableProxy(
            address(implementation), owner, abi.encodeCall(Vault.initialize, (owner, address(0)))
        );
    }

    function test_Reinitialize_SameVersion_Reverts() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.reinitialize();
    }

    // ---------------------------------------------------------------------------------------------
    // Upgrade
    // ---------------------------------------------------------------------------------------------

    function test_UpgradeVault_SameVersion_SwapsImplementation() external {
        address newImpl = address(new Vault());
        upgradeScript.upgradeVault(address(upgradeScript), address(vault), proxyAdmin, newImpl);

        assertEq(Upgrades.getImplementationAddress(address(vault)), newImpl);
        assertEq(_initializedVersion(), 1);
        assertEq(vault.owner(), owner);
    }

    function test_UpgradeVault_VersionBump_RunsReinitialize() external {
        address newImpl = address(new VaultV2());
        upgradeScript.upgradeVault(address(upgradeScript), address(vault), proxyAdmin, newImpl);

        assertEq(Upgrades.getImplementationAddress(address(vault)), newImpl);
        assertEq(_initializedVersion(), 2);
        assertEq(vault.owner(), owner);
        assertEq(vault.usdg(), address(usdg));

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.reinitialize();
    }

    function test_UpgradeVault_Downgrade_Reverts() external {
        address v2 = address(new VaultV2());
        upgradeScript.upgradeVault(address(upgradeScript), address(vault), proxyAdmin, v2);

        address v1 = address(new Vault());
        vm.expectRevert(abi.encodeWithSelector(ProxyVaultUpgrade.VersionDowngrade.selector, 2, 1));
        upgradeScript.upgradeVault(address(upgradeScript), address(vault), proxyAdmin, v1);
    }

    function test_UpgradeVault_NotProxyAdminOwner_Reverts() external {
        address newImpl = address(new Vault());
        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyVaultUpgrade.NotProxyAdminOwner.selector, address(upgradeScript), alice
            )
        );
        upgradeScript.upgradeVault(alice, address(vault), proxyAdmin, newImpl);
    }

    function test_UpgradeVault_WrongProxyAdmin_Reverts() external {
        address newImpl = address(new Vault());
        vm.expectRevert(
            abi.encodeWithSelector(ProxyVaultUpgrade.ProxyAdminMismatch.selector, alice, proxyAdmin)
        );
        upgradeScript.upgradeVault(address(upgradeScript), address(vault), alice, newImpl);
    }

    function test_UpgradeAndCall_NotAdminOwner_Reverts() external {
        address newImpl = address(new Vault());
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, owner)
        );
        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(address(vault)), newImpl, ""
        );
    }

    function test_UpgradeVault_WithStakesAndRewards_KeepsAccountingAndClaims() external {
        _register();
        _stake(alice, 100e18);
        _stake(bob, 300e18);
        _notify(1_000e6);
        _convert();
        _notify(500e6); // stays in the open epoch across the upgrade

        (, uint256[] memory aliceBefore) = vault.earned(address(meme), alice);
        uint256 creditBefore = vault.pendingCreditOf(address(meme), alice);

        upgradeScript.upgradeVault(
            address(upgradeScript), address(vault), proxyAdmin, address(new VaultV2())
        );

        (, uint256[] memory aliceAfter) = vault.earned(address(meme), alice);
        assertEq(aliceAfter[0], aliceBefore[0]);
        assertEq(aliceAfter[1], aliceBefore[1]);
        assertEq(vault.pendingCreditOf(address(meme), alice), creditBefore);
        assertEq(vault.totalStaked(address(meme)), 400e18);
        assertEq(vault.pendingUSDG(address(meme)), 500e6);

        vm.prank(alice);
        vault.claim(address(meme));
        assertEq(aapl.balanceOf(alice), aliceBefore[0]);
        assertEq(usdg.balanceOf(alice), aliceBefore[1]);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz
    // ---------------------------------------------------------------------------------------------

    /// @dev Invariant: an upgrade does not change any observable accounting of the vault.
    function testFuzz_UpgradeVault_PreservesState(
        uint96 aliceStake,
        uint96 bobStake,
        uint64 fee1,
        uint64 fee2
    ) external {
        aliceStake = uint96(bound(aliceStake, 1, type(uint96).max));
        bobStake = uint96(bound(bobStake, 1, type(uint96).max));
        fee1 = uint64(bound(fee1, 1, type(uint64).max));
        fee2 = uint64(bound(fee2, 1, type(uint64).max));

        _register();
        _stake(alice, aliceStake);
        _notify(fee1);
        _convert();
        _stake(bob, bobStake);
        _notify(fee2);

        (, uint256[] memory aliceBefore) = vault.earned(address(meme), alice);
        (, uint256[] memory bobBefore) = vault.earned(address(meme), bob);
        (, uint256[] memory creatorBefore) = vault.creatorAccrued(address(meme));
        uint256 accUsdg = vault.accounted(address(usdg));
        uint256 accAapl = vault.accounted(address(aapl));
        uint256 accMeme = vault.accounted(address(meme));

        upgradeScript.upgradeVault(
            address(upgradeScript), address(vault), proxyAdmin, address(new VaultV2())
        );

        (, uint256[] memory aliceAfter) = vault.earned(address(meme), alice);
        (, uint256[] memory bobAfter) = vault.earned(address(meme), bob);
        (, uint256[] memory creatorAfter) = vault.creatorAccrued(address(meme));
        for (uint256 i; i < 2; ++i) {
            assertEq(aliceAfter[i], aliceBefore[i]);
            assertEq(bobAfter[i], bobBefore[i]);
            assertEq(creatorAfter[i], creatorBefore[i]);
        }
        assertEq(vault.accounted(address(usdg)), accUsdg);
        assertEq(vault.accounted(address(aapl)), accAapl);
        assertEq(vault.accounted(address(meme)), accMeme);
        assertEq(vault.stakedOf(address(meme), alice), aliceStake);
        assertEq(vault.stakedOf(address(meme), bob), bobStake);
        assertEq(vault.owner(), owner);
    }
}
