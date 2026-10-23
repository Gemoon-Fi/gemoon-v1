// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Upgrades} from "@oz-upgrades/Upgrades.sol";
import {DeployGemoon, TransferToGovernance} from "../script/GemoonDeploy.sol";
import {DeployMockToken} from "./DeployGemoonTest.sol";

/// @notice `TransferToGovernance`: upgrades and trading settings end up behind a timelock run by
/// the Safe, operational owners with the Safe, nothing with the deployer.
contract TransferToGovernanceTest is Test {
    uint256 constant DELAY = 48 hours;

    DeployGemoon deployScript;
    TransferToGovernance gov;
    DeployGemoon.Deployment d;
    TimelockController timelock;
    TransferToGovernance.Targets t;

    address safe = makeAddr("safe");
    address stranger = makeAddr("stranger");

    /// @dev Deployed with the governance script as owner of everything, the role the deployer EOA
    /// has on chain, so it can hand everything over.
    function setUp() external {
        deployScript = new DeployGemoon();
        gov = new TransferToGovernance();
        DeployMockToken usdg = new DeployMockToken("USDG");
        DeployMockToken aapl = new DeployMockToken("AAPL");
        address[] memory assets = new address[](1);
        assets[0] = address(aapl);
        d = deployScript.deployAll(
            address(deployScript),
            address(deployScript),
            DeployGemoon.Params({
                owner: address(gov),
                proxyAdminOwner: address(gov),
                poolManager: makeAddr("poolManager"),
                positionManager: makeAddr("positionManager"),
                permit2: makeAddr("permit2"),
                usdg: address(usdg),
                protocolRecipient: makeAddr("protocolRecipient"),
                feeBips: 125,
                protocolShareBips: 3_333,
                conversionThreshold: 0,
                swapAdapter: address(0),
                allowedAssets: assets
            })
        );
        vm.prank(address(gov));
        d.vault.acceptOwnership();

        t = TransferToGovernance.Targets({
            controller: address(d.controller),
            hook: address(d.hook),
            vault: address(d.vault),
            referrals: address(0),
            adapter: address(0),
            controllerProxyAdmin: Upgrades.getAdminAddress(address(d.controller)),
            hookProxyAdmin: Upgrades.getAdminAddress(address(d.hook)),
            vaultProxyAdmin: Upgrades.getAdminAddress(address(d.vault)),
            referralsProxyAdmin: address(0)
        });
        vm.etch(safe, hex"00"); // a Safe is a contract
        timelock = gov.deployTimelock(safe, DELAY);
    }

    function _transfer() internal {
        gov.transferToGovernance(address(gov), t, safe, address(timelock));
    }

    function test_DeployTimelock_SafeOnlyRoles_NoAdmin() external view {
        assertEq(timelock.getMinDelay(), DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), safe));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), safe));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), safe));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(gov)), "deployer not admin");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), safe), "no admin at all");
    }

    function test_TransferToGovernance_Owners_TimelockAndSafe() external {
        _transfer();

        assertEq(ProxyAdmin(t.controllerProxyAdmin).owner(), address(timelock), "controller admin");
        assertEq(ProxyAdmin(t.hookProxyAdmin).owner(), address(timelock), "hook admin");
        assertEq(ProxyAdmin(t.vaultProxyAdmin).owner(), address(timelock), "vault admin");
        assertEq(d.controller.owner(), address(timelock), "controller owner");
        assertEq(d.hook.pendingOwner(), address(timelock), "hook pending owner");
        assertEq(d.vault.pendingOwner(), safe, "vault pending owner");
    }

    /// @dev The deployer keeps no power over upgrades right away, the hook and the vault only until
    /// the new owners accept.
    function test_TransferToGovernance_Deployer_CannotUpgrade() external {
        _transfer();
        // onlyOwner reverts before the implementation is even looked at.
        address newImpl = makeAddr("newImplementation");

        vm.prank(address(gov));
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, address(gov))
        );
        ProxyAdmin(t.hookProxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(address(d.hook)), newImpl, "");
    }

    /// @dev Full hand-over of the hook: the Safe schedules `acceptOwnership` on the timelock, it can
    /// only be executed after the delay, then the timelock owns the hook.
    function test_TransferToGovernance_HookAccept_OnlyAfterDelay() external {
        _transfer();
        bytes memory accept = abi.encodeWithSignature("acceptOwnership()");

        vm.prank(safe);
        timelock.schedule(address(d.hook), 0, accept, bytes32(0), bytes32(0), DELAY);

        vm.prank(safe);
        vm.expectRevert();
        timelock.execute(address(d.hook), 0, accept, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        timelock.execute(address(d.hook), 0, accept, bytes32(0), bytes32(0));
        assertEq(d.hook.owner(), address(timelock));
    }

    function test_TransferToGovernance_SafeAcceptsVault() external {
        _transfer();
        vm.prank(safe);
        d.vault.acceptOwnership();
        assertEq(d.vault.owner(), safe);
    }

    /// @dev Only the Safe can schedule through the timelock.
    function testFuzz_Timelock_NotSafe_CannotSchedule(address caller) external {
        vm.assume(caller != safe);
        _transfer();
        vm.prank(caller);
        vm.expectRevert();
        timelock.schedule(address(d.hook), 0, abi.encodeWithSignature("acceptOwnership()"), 0, 0, DELAY);
    }

    function test_TransferToGovernance_NotOwner_Reverts() external {
        vm.expectRevert();
        gov.transferToGovernance(stranger, t, safe, address(timelock));
    }

    /// @dev A Safe address without code (typo, EOA, other chain) would leave the timelock run by
    /// nobody: both the timelock deployment and the transfer refuse it.
    function test_TransferToGovernance_SafeWithoutCode_Reverts() external {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(TransferToGovernance.SafeHasNoCode.selector, eoa));
        gov.deployTimelock(eoa, DELAY);
        vm.expectRevert(abi.encodeWithSelector(TransferToGovernance.SafeHasNoCode.selector, eoa));
        gov.transferToGovernance(address(gov), t, eoa, address(timelock));
    }

    function test_TransferToGovernance_ZeroSafe_Reverts() external {
        vm.expectRevert(TransferToGovernance.ZeroAddress.selector);
        gov.transferToGovernance(address(gov), t, address(0), address(timelock));
    }
}
