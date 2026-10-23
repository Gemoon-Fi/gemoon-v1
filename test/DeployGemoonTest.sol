// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Upgrades} from "@oz-upgrades/Upgrades.sol";
import {Hooks} from "@uniswap-v4-core/libraries/Hooks.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {IHookManager} from "../src/contracts/interfaces/IHookManager.sol";
import {OwnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract DeployMockToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}
}

/// @notice Runs the deployment script logic in-process and checks the resulting wiring.
/// @dev The PoolManager is a dummy address: nothing in the deployment calls it.
contract DeployGemoonTest is Test {
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    DeployGemoon script;
    DeployMockToken usdg;
    DeployMockToken aapl;

    address poolManager = makeAddr("poolManager");
    address positionManager = makeAddr("positionManager");
    address permit2 = makeAddr("permit2");
    address owner = makeAddr("owner");
    address proxyAdminOwner = makeAddr("proxyAdminOwner");
    address protocolRecipient = makeAddr("protocolRecipient");

    function setUp() external {
        script = new DeployGemoon();
        usdg = new DeployMockToken("USDG");
        aapl = new DeployMockToken("AAPL");
    }

    function _params(address owner_) internal view returns (DeployGemoon.Params memory p) {
        address[] memory assets = new address[](1);
        assets[0] = address(aapl);
        p = DeployGemoon.Params({
            owner: owner_,
            proxyAdminOwner: proxyAdminOwner,
            poolManager: poolManager,
            positionManager: positionManager,
            permit2: permit2,
            usdg: address(usdg),
            protocolRecipient: protocolRecipient,
            feeBips: 125,
            protocolShareBips: 2_000,
            conversionThreshold: 5e6,
            swapAdapter: address(0),
            allowedAssets: assets
        });
    }

    /// @dev Without a broadcast the script contract is both the caller and the CREATE2 deployer.
    function _deploy(address owner_) internal returns (DeployGemoon.Deployment memory) {
        return script.deployAll(address(script), address(script), _params(owner_));
    }

    function _assertWired(DeployGemoon.Deployment memory d) internal view {
        assertEq(d.controller.hook(), address(d.hook), "controller.hook");
        assertEq(address(d.controller.vault()), address(d.vault), "controller.vault");
        assertEq(d.vault.hook(), address(d.hook), "vault.hook");
        assertEq(d.vault.controller(), address(d.controller), "vault.controller");
        assertEq(d.hook.vault(), address(d.vault), "hook.vault");
        assertEq(d.hook.controller(), address(d.controller), "hook.controller");
        assertEq(Currency.unwrap(d.hook.pairToken()), address(usdg), "hook.pairToken");
        assertEq(d.vault.usdg(), address(usdg), "vault.usdg");
    }

    function test_DeployAll_Wiring_AllContractsPointAtEachOther() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        _assertWired(d);
        script.checkWiring(d.controller, d.hook, d.vault);
    }

    function test_DeployAll_Config_AppliedFromParams() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        assertEq(d.vault.conversionThreshold(), 5e6);
        assertTrue(d.vault.isAssetAllowed(address(aapl)));
        assertFalse(d.vault.isAssetAllowed(address(usdg)));
        assertEq(d.hook.protocolRecipient(), protocolRecipient);
        assertEq(d.hook.TOTAL_FEE_BIPS(), 125);
        assertEq(d.hook.PROTOCOL_SHARE_BIPS(), 2_000);
        assertEq(address(d.hook.poolManager()), poolManager);
        assertEq(address(d.controller.poolManager()), poolManager);
        assertEq(address(d.controller.positionManager()), positionManager);
        assertEq(address(d.controller.permit2()), permit2);
    }

    function test_DeployAll_Ownership_HandedToOwner() external {
        DeployGemoon.Deployment memory d = _deploy(owner);

        assertEq(d.hook.owner(), owner, "hook owner");
        assertEq(d.hook.pendingOwner(), address(0), "hook pending");
        assertEq(d.controller.owner(), owner, "controller owner");
        // Ownable2Step: the vault waits for acceptOwnership.
        assertEq(d.vault.owner(), address(script), "vault owner");
        assertEq(d.vault.pendingOwner(), owner, "vault pending");
        vm.prank(owner);
        d.vault.acceptOwnership();
        assertEq(d.vault.owner(), owner);

        assertEq(ProxyAdmin(Upgrades.getAdminAddress(address(d.vault))).owner(), proxyAdminOwner);
        assertEq(ProxyAdmin(Upgrades.getAdminAddress(address(d.hook))).owner(), proxyAdminOwner);
        assertEq(
            ProxyAdmin(Upgrades.getAdminAddress(address(d.controller))).owner(), proxyAdminOwner
        );
    }

    function test_DeployAll_OwnerIsDeployer_NoTransfer() external {
        DeployGemoon.Deployment memory d = _deploy(address(script));
        assertEq(d.vault.owner(), address(script));
        assertEq(d.vault.pendingOwner(), address(0));
        assertEq(d.controller.owner(), address(script));
        assertEq(d.hook.owner(), address(script));
    }

    function test_DeployAll_HookAddresses_CarryPermissionBits() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address implementation = Upgrades.getImplementationAddress(address(d.hook));
        assertEq(uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "proxy bits");
        assertEq(uint160(implementation) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS, "impl bits");
    }

    function test_DeployAll_Twice_FreshAddresses() external {
        DeployGemoon.Deployment memory a = _deploy(owner);
        DeployGemoon.Deployment memory b = _deploy(owner);
        assertTrue(address(a.hook) != address(b.hook));
        assertTrue(
            Upgrades.getImplementationAddress(address(a.hook))
                != Upgrades.getImplementationAddress(address(b.hook))
        );
        _assertWired(b);
    }

    function test_SetVault_UsdgMismatch_Revert() external {
        Vault other = script.deployVault(
            address(script),
            GemoonDeployBase.VaultDeployParams({
                owner: address(script),
                proxyAdminOwner: proxyAdminOwner,
                usdg: address(aapl),
                controller: address(0),
                hook: address(0),
                conversionThreshold: 0,
                swapAdapter: address(0),
                allowedAssets: new address[](0)
            })
        );
        GemoonController controller = script.deployController(
            address(script),
            GemoonDeployBase.ControllerDeployParams({
                proxyAdminOwner: proxyAdminOwner,
                poolManager: poolManager,
                pairToken: address(usdg)
            })
        );

        vm.prank(address(script));
        vm.expectRevert(
            abi.encodeWithSelector(
                GemoonController.VaultPairTokenMismatch.selector, address(aapl), address(usdg)
            )
        );
        controller.setVault(address(other));
    }

    function test_CheckWiring_VaultOfOtherHook_Revert() external {
        DeployGemoon.Deployment memory a = _deploy(owner);
        DeployGemoon.Deployment memory b = _deploy(owner);
        vm.expectRevert(
            abi.encodeWithSelector(GemoonDeployBase.WiringMismatch.selector, "controller.hook")
        );
        script.checkWiring(a.controller, b.hook, a.vault);
    }

    // ---------------------------------------------------------------------------------------------
    // HookManager controller
    // ---------------------------------------------------------------------------------------------

    function test_NotifyPoolCreated_FromController_StoresTimestamp() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address meme = makeAddr("meme");

        vm.warp(1_700_000_000);
        vm.prank(address(d.controller));
        d.hook.notifyPoolCreated(meme, 1_700_000_000, 100);

        assertEq(d.hook.poolTimestamps(meme), 1_700_000_000);
    }

    function testFuzz_NotifyPoolCreated_FromController_StoresPerMeme(
        address meme,
        address other,
        uint256 timestamp
    ) external {
        vm.assume(meme != other);
        timestamp = bound(timestamp, 1, type(uint64).max);
        DeployGemoon.Deployment memory d = _deploy(owner);

        vm.warp(timestamp);
        vm.prank(address(d.controller));
        d.hook.notifyPoolCreated(meme, timestamp, 100);

        assertEq(d.hook.poolTimestamps(meme), timestamp);
        assertEq(d.hook.poolTimestamps(other), 0, "other meme untouched");
    }

    /// @dev The anti-snipe ramp of a Meme starts once: a second report cannot restart it.
    function test_NotifyPoolCreated_CalledTwice_RevertsPoolAlreadyNotified() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address meme = makeAddr("meme");

        vm.warp(200);
        vm.startPrank(address(d.controller));
        d.hook.notifyPoolCreated(meme, 100, 100);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.PoolAlreadyNotified.selector, meme));
        d.hook.notifyPoolCreated(meme, 200, 500);
        vm.stopPrank();

        assertEq(d.hook.poolTimestamps(meme), 100, "creation time kept");
        assertEq(d.hook.memeFeeBips(meme), 100, "base fee kept");
    }

    function test_NotifyPoolCreated_TimestampAfterBlock_RevertsInvalidPoolTimestamp() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address meme = makeAddr("meme");

        vm.warp(1_000);
        vm.prank(address(d.controller));
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidPoolTimestamp.selector, 1_001));
        d.hook.notifyPoolCreated(meme, 1_001, 100);

        assertEq(d.hook.poolTimestamps(meme), 0);
    }

    function test_NotifyPoolCreated_ZeroTimestamp_RevertsInvalidPoolTimestamp() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address meme = makeAddr("meme");

        vm.prank(address(d.controller));
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidPoolTimestamp.selector, 0));
        d.hook.notifyPoolCreated(meme, 0, 100);
    }

    /// @dev The audit scenario: the owner makes itself the controller and tries to restart the
    /// 80% ramp of a live Meme, now or in the future. Every attempt reverts and the fee stays at
    /// the base fee.
    function test_NotifyPoolCreated_OwnerAsController_CannotRestartRamp() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address meme = makeAddr("meme");
        vm.warp(1_000);
        vm.prank(address(d.controller));
        d.hook.notifyPoolCreated(meme, 1_000, 100);
        vm.warp(1_000 + d.hook.DYNAMIC_FEE_THRESHOLD());

        vm.startPrank(owner);
        d.hook.setController(owner);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.PoolAlreadyNotified.selector, meme));
        d.hook.notifyPoolCreated(meme, block.timestamp, 100);
        vm.expectRevert(abi.encodeWithSelector(IHookManager.PoolAlreadyNotified.selector, meme));
        d.hook.notifyPoolCreated(meme, block.timestamp + 365 days, 1_000);
        vm.stopPrank();

        assertEq(d.hook.currentFeeBips(meme), 100, "still the base fee");
    }

    /// @dev Invariant: once a Meme is reported, no later report (any time, any fee) changes its
    /// creation time or base fee, so the fee is the base fee from `createdAt + window` on.
    function testFuzz_NotifyPoolCreated_AfterFirst_AnyReport_RampUnchanged(
        uint256 createdAt,
        uint256 elapsed,
        uint256 timestamp,
        uint256 feeBips
    ) external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address meme = makeAddr("meme");
        createdAt = bound(createdAt, 1, type(uint64).max);
        elapsed = bound(elapsed, 0, 10 * 365 days);
        feeBips = bound(feeBips, 100, 1_000);

        vm.warp(createdAt);
        vm.prank(address(d.controller));
        d.hook.notifyPoolCreated(meme, createdAt, 200);

        vm.warp(createdAt + elapsed);
        vm.prank(address(d.controller));
        vm.expectRevert(abi.encodeWithSelector(IHookManager.PoolAlreadyNotified.selector, meme));
        d.hook.notifyPoolCreated(meme, timestamp, feeBips);

        assertEq(d.hook.poolTimestamps(meme), createdAt);
        assertEq(d.hook.memeFeeBips(meme), 200);
        if (elapsed >= d.hook.DYNAMIC_FEE_THRESHOLD()) assertEq(d.hook.currentFeeBips(meme), 200);
    }

    /// @dev Any creation time after the current block is rejected, so the ramp cannot be stretched.
    function testFuzz_NotifyPoolCreated_TimestampAfterBlock_Revert(uint256 now_, uint256 timestamp) external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        now_ = bound(now_, 1, type(uint64).max);
        timestamp = bound(timestamp, now_ + 1, type(uint256).max);

        vm.warp(now_);
        vm.prank(address(d.controller));
        vm.expectRevert(abi.encodeWithSelector(IHookManager.InvalidPoolTimestamp.selector, timestamp));
        d.hook.notifyPoolCreated(makeAddr("meme"), timestamp, 100);
    }

    function test_NotifyPoolCreated_FromOwner_Revert() external {
        DeployGemoon.Deployment memory d = _deploy(owner);

        vm.prank(owner);
        vm.expectRevert(IHookManager.NotController.selector);
        d.hook.notifyPoolCreated(makeAddr("meme"), 1, 100);
    }

    function test_NotifyPoolCreated_FromVault_Revert() external {
        DeployGemoon.Deployment memory d = _deploy(owner);

        vm.prank(address(d.vault));
        vm.expectRevert(IHookManager.NotController.selector);
        d.hook.notifyPoolCreated(makeAddr("meme"), 1, 100);
    }

    function test_NotifyPoolCreated_FromNewController_AfterSetController_Stores() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address next = makeAddr("nextController");
        address meme = makeAddr("meme");

        vm.prank(owner);
        d.hook.setController(next);

        vm.warp(42);
        vm.prank(next);
        d.hook.notifyPoolCreated(meme, 42, 100);

        assertEq(d.hook.poolTimestamps(meme), 42);
    }

    function testFuzz_NotifyPoolCreated_NotController_Revert(address caller, uint256 timestamp)
        external
    {
        DeployGemoon.Deployment memory d = _deploy(owner);
        vm.assume(caller != address(d.controller));
        // The ProxyAdmin is denied the fallback by the transparent proxy itself.
        vm.assume(caller != Upgrades.getAdminAddress(address(d.hook)));
        address meme = makeAddr("meme");

        vm.prank(caller);
        vm.expectRevert(IHookManager.NotController.selector);
        d.hook.notifyPoolCreated(meme, timestamp, 100);

        assertEq(d.hook.poolTimestamps(meme), 0);
    }

    function test_SetController_ByOwner_UpdatesAndEmits() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address next = makeAddr("nextController");

        vm.expectEmit(address(d.hook));
        emit IHookManager.ControllerUpdated(next);
        vm.prank(owner);
        d.hook.setController(next);

        assertEq(d.hook.controller(), next);

        // The old controller loses access right away.
        vm.prank(address(d.controller));
        vm.expectRevert(IHookManager.NotController.selector);
        d.hook.notifyPoolCreated(makeAddr("meme"), 1, 100);
    }

    function test_SetController_NotOwner_Revert() external {
        DeployGemoon.Deployment memory d = _deploy(owner);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, stranger)
        );
        d.hook.setController(stranger);
    }

    function test_SetController_ZeroAddress_Revert() external {
        DeployGemoon.Deployment memory d = _deploy(owner);

        vm.prank(owner);
        vm.expectRevert(IHookManager.ZeroAddress.selector);
        d.hook.setController(address(0));
    }
}
