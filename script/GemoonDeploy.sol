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


/// @notice Deploys the fee Vault behind a TransparentUpgradeableProxy and configures its roles and
/// asset allowlist.
/// @dev Env:
///  - USDG_ADDRESS                 token fees arrive in (required)
///  - VAULT_OWNER                  final owner, e.g. multisig (default: broadcaster)
///  - VAULT_PROXY_ADMIN_OWNER      owner of the ProxyAdmin, i.e. who can upgrade (default: VAULT_OWNER)
///  - VAULT_KEEPER                 caller of convertFees (required)
///  - VAULT_SWAP_ADAPTER           USDG -> asset adapter (optional, can be set later)
///  - VAULT_ALLOWED_ASSETS         comma-separated reward assets allowlist (optional)
///  - CONTROLLER_PROXY_ADDRESS     GemoonController proxy (optional, can be set later)
///  - HOOK_ADDRESS                 HookManager proxy (optional, can be set later)
/// After the run: owner of the controller calls `GemoonController.setVault`, owner of the hook
/// calls `HookManager.setVault` (both with the vault PROXY address), and VAULT_OWNER calls
/// `acceptOwnership` if it differs from the broadcaster. Put the logged proxy and proxy admin
/// addresses into VAULT_PROXY_ADDRESS / VAULT_PROXY_ADMIN_ADDRESS for `ProxyVaultUpgrade`.
contract DeployVault is Script {
    struct VaultDeployParams {
        address owner;
        address proxyAdminOwner;
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

        address owner = vm.envOr("VAULT_OWNER", deployer);
        VaultDeployParams memory params = VaultDeployParams({
            owner: owner,
            proxyAdminOwner: vm.envOr("VAULT_PROXY_ADMIN_OWNER", owner),
            usdg: vm.envAddress("USDG_ADDRESS"),
            controller: vm.envOr("CONTROLLER_PROXY_ADDRESS", address(0)),
            hook: vm.envOr("HOOK_ADDRESS", address(0)),
            keeper: vm.envAddress("VAULT_KEEPER"),
            swapAdapter: vm.envOr("VAULT_SWAP_ADAPTER", address(0)),
            allowedAssets: vm.envOr("VAULT_ALLOWED_ASSETS", ",", new address[](0))
        });

        Vault vault = deployVault(deployer, params);

        vm.stopBroadcast();

        console.log("VAULT PROXY: ", address(vault));
        console.log("VAULT IMPLEMENTATION: ", Upgrades.getImplementationAddress(address(vault)));
        console.log("VAULT PROXY ADMIN: ", Upgrades.getAdminAddress(address(vault)));
        console.log("VAULT PROXY ADMIN OWNER: ", params.proxyAdminOwner);
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

    /// @notice Deploys and configures a Vault proxy. Must be called inside a broadcast by `deployer`.
    /// @dev The proxy is initialized with `deployer` as owner in the deployment transaction (no
    /// front-running of `initialize`) so it can be configured in the same run, then ownership is
    /// handed to `params.owner` via Ownable2Step (needs acceptOwnership). The ProxyAdmin is created
    /// by the proxy and owned by `params.proxyAdminOwner`. Zero `controller`, `hook` and
    /// `swapAdapter` are skipped and can be set later by the owner.
    /// @param deployer Broadcasting account.
    /// @param params   Vault configuration.
    /// @return vault   Vault proxy.
    function deployVault(address deployer, VaultDeployParams memory params)
        public
        returns (Vault vault)
    {
        Vault implementation = new Vault();
        vault = Vault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    params.proxyAdminOwner,
                    abi.encodeCall(Vault.initialize, (deployer, params.usdg))
                )
            )
        );

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

/// @notice Upgrades the Vault proxy to a freshly deployed implementation.
/// @dev Env:
///  - VAULT_PROXY_ADDRESS          Vault proxy (required)
///  - VAULT_PROXY_ADMIN_ADDRESS    ProxyAdmin of the Vault proxy (required)
/// The broadcaster must own the ProxyAdmin. If the new implementation bumps `VAULT_VERSION`,
/// `reinitialize` runs atomically with the upgrade, otherwise the upgrade carries no call.
/// Storage of the new implementation must stay append-only, check it before running, e.g.
/// `forge inspect Vault storageLayout` against the deployed version.
contract ProxyVaultUpgrade is Script {
    /// @dev ERC-7201 slot of OZ Initializable, `_initialized` is its lowest uint64.
    bytes32 private constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    error NotProxyAdminOwner(address expected, address actual);
    error ProxyAdminMismatch(address expected, address actual);
    error VersionDowngrade(uint64 current, uint64 next);
    error StateChanged();

    function run() external {
        address proxy = vm.envAddress("VAULT_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("VAULT_PROXY_ADMIN_ADDRESS");

        vm.startBroadcast();
        (, address sender, ) = vm.readCallers();
        address newImplementation = address(new Vault());
        upgradeVault(sender, proxy, proxyAdmin, newImplementation);
        vm.stopBroadcast();

        console.log("VAULT PROXY: ", proxy);
        console.log("VAULT PROXY ADMIN: ", proxyAdmin);
        console.log("VAULT NEW IMPLEMENTATION: ", newImplementation);
        console.log("VAULT VERSION: ", uint256(Vault(proxy).getVersion()));
    }

    /// @notice Upgrades `proxy` to `newImplementation`. Must be called inside a broadcast by `sender`.
    /// @dev Reverts if the proxy admin or its owner do not match, if the version goes down, or if
    /// owner / USDG / implementation are not as expected after the upgrade.
    /// @param sender            Broadcasting account, owner of `proxyAdmin`.
    /// @param proxy             Vault proxy.
    /// @param proxyAdmin        ProxyAdmin of `proxy`.
    /// @param newImplementation Deployed Vault implementation.
    function upgradeVault(
        address sender,
        address proxy,
        address proxyAdmin,
        address newImplementation
    ) public {
        address actualAdmin = Upgrades.getAdminAddress(proxy);
        if (actualAdmin != proxyAdmin) revert ProxyAdminMismatch(proxyAdmin, actualAdmin);
        address adminOwner = ProxyAdmin(proxyAdmin).owner();
        if (adminOwner != sender) revert NotProxyAdminOwner(adminOwner, sender);

        Vault vault = Vault(proxy);
        address ownerBefore = vault.owner();
        address usdgBefore = vault.usdg();

        uint64 current = uint64(uint256(vm.load(proxy, INITIALIZABLE_STORAGE)));
        uint64 next = Vault(newImplementation).getVersion();
        if (next < current) revert VersionDowngrade(current, next);
        bytes memory data = next > current ? abi.encodeCall(Vault.reinitialize, ()) : bytes("");

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy), newImplementation, data
        );

        if (
            Upgrades.getImplementationAddress(proxy) != newImplementation
                || vault.owner() != ownerBefore || vault.usdg() != usdgBefore
        ) revert StateChanged();
    }
}
