pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {LPManager} from "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@oz-upgrades/Upgrades.sol";
import "../src/contracts/deploy_collectors/UniswapDeployCollector.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../src/contracts/interfaces/IPosition.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";

contract DeployGemoon is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address uniswapPositionManager = vm.envAddress("POSITION_MANAGER");
        address permit2 = vm.envAddress("PERMIT2");
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address uniswapPoolManager = vm.envAddress("POOL_MANAGER");
        uint256 creatorPercent = vm.envUint("CREATOR_FEE_PERCENT");
        address operatorAddress = vm.envAddress("OPERATOR_ADDRESS");

        GemoonController controller = new GemoonController();

        address controllerProxy = address(
            new TransparentUpgradeableProxy(
                address(controller),
                msg.sender,
                abi.encodeCall(
                    GemoonController.initialize,
                    (uniswapPoolManager, nativeToken, operatorAddress)
                )
            )
        );

        address controllerAdminAddress = Upgrades.getAdminAddress(controllerProxy);

        // ----- LOGS -----
        console.log("MSG SENDER: ", msg.sender);
        console.log("OPERATOR ADDRESS: ", operatorAddress);


        // ---- CONTROLLER ----
        console.log("Controller Proxy address: ", address(controllerProxy));
        console.log("Controller implementation address: ", address(controller));
        console.log("Controller Proxy admin address: ", address(controllerAdminAddress));
        console.log("CREATOR PERCENT: ", creatorPercent);
        console.log("UNISWAP POSITION MANAGER: ", uniswapPositionManager);
        console.log("PERMIT2: ", permit2);
        console.log("NATIVE TOKEN: ", nativeToken);
        console.log("UNISWAP POOL MANAGER: ", uniswapPoolManager);

        vm.stopBroadcast();
    }
}



contract ProxyGemoonControllerUpgrade is Script {
    function run() external {
        vm.startBroadcast();

        address multisigOwner = vm.envAddress("MULTISIG_OWNER_ADDRESS");
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address uniswapPoolManager = vm.envAddress("POOL_MANAGER");
        address proxyAddress = vm.envAddress("CONTROLLER_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("CONTROLLER_PROXY_ADMIN_ADDRESS");

        address controllerImpl = address(new GemoonController());

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxyAddress),
            controllerImpl,
            abi.encodeCall(GemoonController.reinitialize, (uniswapPoolManager, nativeToken, multisigOwner))
        );

        vm.stopBroadcast();
    }
}


/// @notice Deploys the fee Vault and configures its roles and asset allowlist.
/// @dev Env:
///  - USDG_ADDRESS                 token fees arrive in (required)
///  - VAULT_OWNER                  final owner, e.g. multisig (default: broadcaster)
///  - VAULT_KEEPER                 caller of convertFees (required)
///  - VAULT_SWAP_ADAPTER           USDG -> asset adapter (optional, can be set later)
///  - VAULT_ALLOWED_ASSETS         comma-separated reward assets allowlist (optional)
///  - CONTROLLER_PROXY_ADDRESS     GemoonController proxy (optional, can be set later)
///  - HOOK_ADDRESS                 HookManager proxy (optional, can be set later)
/// After the run: owner of the controller calls `GemoonController.setVault`, owner of the hook
/// calls `HookManager.setVault`, and VAULT_OWNER calls `acceptOwnership` if it differs from
/// the broadcaster.
contract DeployVault is Script {
    struct VaultDeployParams {
        address owner;
        address usdg;
        address controller;
        address hook;
        address keeper;
        address swapAdapter;
        address[] allowedAssets;
    }

    function run() external {
        vm.startBroadcast();
        (, address deployer, ) = vm.readCallers();

        VaultDeployParams memory params = VaultDeployParams({
            owner: vm.envOr("VAULT_OWNER", deployer),
            usdg: vm.envAddress("USDG_ADDRESS"),
            controller: vm.envOr("CONTROLLER_PROXY_ADDRESS", address(0)),
            hook: vm.envOr("HOOK_ADDRESS", address(0)),
            keeper: vm.envAddress("VAULT_KEEPER"),
            swapAdapter: vm.envOr("VAULT_SWAP_ADAPTER", address(0)),
            allowedAssets: vm.envOr("VAULT_ALLOWED_ASSETS", ",", new address[](0))
        });

        Vault vault = deployVault(deployer, params);

        vm.stopBroadcast();

        console.log("VAULT: ", address(vault));
        console.log("VAULT OWNER (pending if differs from deployer): ", params.owner);
        console.log("USDG: ", params.usdg);
        console.log("CONTROLLER: ", params.controller);
        console.log("HOOK: ", params.hook);
        console.log("KEEPER: ", params.keeper);
        console.log("SWAP ADAPTER: ", params.swapAdapter);
        for (uint256 i; i < params.allowedAssets.length; ++i) {
            console.log("ALLOWED ASSET: ", params.allowedAssets[i]);
        }
    }

    /// @notice Deploys and configures a Vault. Must be called inside a broadcast by `deployer`.
    /// @dev The vault is deployed with `deployer` as owner so it can be configured in the same
    /// run, then ownership is handed to `params.owner` via Ownable2Step (needs acceptOwnership).
    /// Zero `controller`, `hook` and `swapAdapter` are skipped and can be set later by the owner.
    /// @param deployer Broadcasting account.
    /// @param params   Vault configuration.
    /// @return vault   Deployed vault.
    function deployVault(address deployer, VaultDeployParams memory params)
        public
        returns (Vault vault)
    {
        vault = new Vault(deployer, params.usdg);

        if (params.controller != address(0)) vault.setController(params.controller);
        if (params.hook != address(0)) vault.setHook(params.hook);
        if (params.swapAdapter != address(0)) vault.setSwapAdapter(params.swapAdapter);
        vault.setKeeper(params.keeper);

        for (uint256 i; i < params.allowedAssets.length; ++i) {
            vault.setAssetAllowed(params.allowedAssets[i], true);
        }

        if (params.owner != deployer) vault.transferOwnership(params.owner);
    }
}
