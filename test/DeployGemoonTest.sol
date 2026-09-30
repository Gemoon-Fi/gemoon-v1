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
    address keeper = makeAddr("keeper");

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
            protocolFeeBips: 25,
            keeper: keeper,
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
        assertEq(d.vault.keeper(), keeper);
        assertTrue(d.vault.isAssetAllowed(address(aapl)));
        assertFalse(d.vault.isAssetAllowed(address(usdg)));
        assertEq(d.hook.protocolRecipient(), protocolRecipient);
        assertEq(d.hook.TOTAL_FEE_BIPS(), 125);
        assertEq(d.hook.PROTOCOL_FEE_BIPS(), 25);
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

    function test_Run_FromEnv_DeploysAndWires() external {
        vm.setEnv("POOL_MANAGER", vm.toString(poolManager));
        vm.setEnv("POSITION_MANAGER", vm.toString(positionManager));
        vm.setEnv("PERMIT2", vm.toString(permit2));
        vm.setEnv("USDG_ADDRESS", vm.toString(address(usdg)));
        vm.setEnv("PROTOCOL_FEE_RECIPIENT", vm.toString(protocolRecipient));
        vm.setEnv("VAULT_KEEPER", vm.toString(keeper));
        vm.setEnv("GEMOON_OWNER", vm.toString(owner));
        vm.setEnv("GEMOON_PROXY_ADMIN_OWNER", "");
        vm.setEnv("HOOK_TOTAL_FEE_BIPS", "300");
        vm.setEnv("HOOK_PROTOCOL_FEE_BIPS", "");
        vm.setEnv("VAULT_SWAP_ADAPTER", "");
        vm.setEnv("VAULT_ALLOWED_ASSETS", vm.toString(address(aapl)));

        script.run();
        (Vault vault, HookManager hook, GemoonController controller) = script.deployed();
        DeployGemoon.Deployment memory d =
            DeployGemoon.Deployment({vault: vault, hook: hook, controller: controller});

        _assertWired(d);
        assertEq(hook.owner(), owner);
        assertEq(controller.owner(), owner);
        assertEq(vault.pendingOwner(), owner);
        // empty GEMOON_PROXY_ADMIN_OWNER falls back to GEMOON_OWNER
        assertEq(ProxyAdmin(Upgrades.getAdminAddress(address(hook))).owner(), owner);
        assertEq(hook.TOTAL_FEE_BIPS(), 300);
        assertEq(hook.PROTOCOL_FEE_BIPS(), 25);
        assertTrue(vault.isAssetAllowed(address(aapl)));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
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
                keeper: keeper,
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
}
