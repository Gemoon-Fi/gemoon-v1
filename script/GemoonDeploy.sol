// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {UniswapV3SwapAdapter} from "../src/contracts/adapters/UniswapV3SwapAdapter.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@oz-upgrades/Upgrades.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap-v4-core/libraries/Hooks.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";

/// @notice Shared deployment and upgrade logic of the Gemoon contracts.
/// @dev Every contract lives behind a TransparentUpgradeableProxy. The proxy creates its own
/// ProxyAdmin, owned by `proxyAdminOwner`, so the upgrade key is set at deployment and never has
/// to be transferred afterwards.
///
/// HookManager is special: the PoolManager decides which callbacks to invoke from the bits of the
/// hook address, so both the implementation (BaseHook validates itself in its constructor) and the
/// proxy (the address pools actually reference) are deployed with CREATE2 and a mined salt that
/// puts `HOOK_FLAGS` into the address. In `forge script` CREATE2 goes through the deterministic
/// deployer at `CREATE2_FACTORY`; in `forge test` it is the calling contract itself.
abstract contract GemoonDeployBase is Script {
    using Hooks for IHooks;

    /// @dev Address bits of `HookManager.getHookPermissions`.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    /// @dev Upper bound of the salt search; 14 fixed bits need ~16k tries on average.
    uint256 internal constant MAX_SALT_ITERATIONS = 2_000_000;

    /// @dev ERC-7201 slot of OZ Initializable, `_initialized` is its lowest uint64.
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;

    error SaltNotFound();
    error Create2AddressMismatch(address expected, address actual);
    error WiringMismatch(string what);
    error NotProxyAdminOwner(address expected, address actual);
    error ProxyAdminMismatch(address expected, address actual);
    error VersionDowngrade(uint64 current, uint64 next);
    error StateChanged();

    struct VaultDeployParams {
        address owner;
        address proxyAdminOwner;
        address usdg;
        address controller;
        address hook;
        uint256 conversionThreshold;
        address swapAdapter;
        address[] allowedAssets;
    }

    struct HookDeployParams {
        address owner;
        address proxyAdminOwner;
        address poolManager;
        address pairToken;
        address protocolRecipient;
        address vault;
        address controller;
        uint256 feeBips;
        uint256 protocolFeeBips;
    }

    struct ControllerDeployParams {
        address proxyAdminOwner;
        address poolManager;
        address pairToken;
    }

    // ---------------------------------------------------------------------------------------------
    // Vault
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys and configures a Vault proxy. Must be called by `deployer`.
    /// @dev The proxy is initialized with `deployer` as owner in the deployment transaction (no
    /// front-running of `initialize`) so it can be configured in the same run, then ownership is
    /// handed to `params.owner` via Ownable2Step (needs acceptOwnership). Zero `controller`,
    /// `hook` and `swapAdapter` are skipped and can be set later by the owner.
    /// @param deployer Calling account, owner of the vault until `params.owner` accepts.
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
        if (params.conversionThreshold != 0) {
            vault.setConversionThreshold(params.conversionThreshold);
        }

        for (uint256 i; i < params.allowedAssets.length; ++i) {
            vault.setAssetAllowed(params.allowedAssets[i], true);
        }

        if (params.owner != deployer) vault.transferOwnership(params.owner);
    }

    // ---------------------------------------------------------------------------------------------
    // HookManager
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a HookManager implementation and proxy, both CREATE2-mined.
    /// @dev Everything the hook needs is passed to `initialize`, so `params.owner` is set as the
    /// owner right away (Ownable2Step init sets it directly, no acceptOwnership).
    /// @param create2Deployer Account CREATE2 is executed from, see the contract docs.
    /// @param params          Hook configuration; `vault` and `controller` must already be deployed.
    /// @return hook           HookManager proxy.
    function deployHook(address create2Deployer, HookDeployParams memory params)
        public
        returns (HookManager hook)
    {
        HookManager implementation =
            deployHookImplementation(create2Deployer, params.poolManager, params.pairToken);

        bytes memory initData = abi.encodeCall(
            HookManager.initialize,
            (
                params.owner,
                params.protocolRecipient,
                params.vault,
                params.controller,
                params.feeBips,
                params.protocolFeeBips
            )
        );
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(address(implementation), params.proxyAdminOwner, initData)
            )
        );
        (address expected, bytes32 salt) = findHookSalt(create2Deployer, initCodeHash);

        hook = HookManager(
            payable(
                address(
                    new TransparentUpgradeableProxy{salt: salt}(
                        address(implementation), params.proxyAdminOwner, initData
                    )
                )
            )
        );
        if (address(hook) != expected) revert Create2AddressMismatch(expected, address(hook));
        IHooks(address(hook)).validateHookPermissions(hook.getHookPermissions());
    }

    /// @notice Deploys a CREATE2-mined HookManager implementation (used for upgrades too).
    /// @param create2Deployer Account CREATE2 is executed from.
    /// @param poolManager     Uniswap V4 PoolManager.
    /// @param pairToken       Token every pool is paired with and fees are charged in.
    /// @return implementation Deployed implementation, initializers disabled.
    function deployHookImplementation(
        address create2Deployer,
        address poolManager,
        address pairToken
    ) public returns (HookManager implementation) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(HookManager).creationCode, abi.encode(poolManager, pairToken))
        );
        (address expected, bytes32 salt) = findHookSalt(create2Deployer, initCodeHash);

        implementation =
            new HookManager{salt: salt}(IPoolManager(poolManager), Currency.wrap(pairToken));
        if (address(implementation) != expected) {
            revert Create2AddressMismatch(expected, address(implementation));
        }
    }

    /// @notice Finds the first salt whose CREATE2 address carries `HOOK_FLAGS` and is unused.
    /// @param deployer     Account CREATE2 is executed from.
    /// @param initCodeHash keccak256 of creation code with constructor args appended.
    /// @return addr        Address the contract deploys to.
    /// @return salt        Salt to pass as `new X{salt: salt}`.
    function findHookSalt(address deployer, bytes32 initCodeHash)
        public
        view
        returns (address addr, bytes32 salt)
    {
        for (uint256 i; i < MAX_SALT_ITERATIONS; ++i) {
            addr = address(
                uint160(
                    uint256(
                        keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))
                    )
                )
            );
            if (uint160(addr) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && addr.code.length == 0) {
                return (addr, bytes32(i));
            }
        }
        revert SaltNotFound();
    }

    // ---------------------------------------------------------------------------------------------
    // Controller
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a GemoonController proxy owned by `deployer`.
    /// @dev Hook and vault are set by the caller afterwards, then ownership is transferred.
    /// @param deployer   Calling account, initial owner.
    /// @param params     Controller configuration.
    /// @return controller Controller proxy.
    function deployController(address deployer, ControllerDeployParams memory params)
        public
        returns (GemoonController controller)
    {
        GemoonController implementation = new GemoonController();
        controller = GemoonController(
            payable(
                address(
                    new TransparentUpgradeableProxy(
                        address(implementation),
                        params.proxyAdminOwner,
                        abi.encodeCall(
                            GemoonController.initialize,
                            (params.poolManager, params.pairToken, deployer)
                        )
                    )
                )
            )
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------------------------------

    /// @notice Reverts unless controller, hook and vault all point at each other and share the
    /// pair token, and the hook proxy address carries its permission bits.
    function checkWiring(GemoonController controller, HookManager hook, Vault vault)
        public
        view
    {
        if (controller.hook() != address(hook)) revert WiringMismatch("controller.hook");
        if (address(controller.vault()) != address(vault)) revert WiringMismatch("controller.vault");
        if (vault.hook() != address(hook)) revert WiringMismatch("vault.hook");
        if (vault.controller() != address(controller)) revert WiringMismatch("vault.controller");
        if (hook.vault() != address(vault)) revert WiringMismatch("hook.vault");
        if (hook.controller() != address(controller)) revert WiringMismatch("hook.controller");
        if (Currency.unwrap(hook.pairToken()) != vault.usdg()) {
            revert WiringMismatch("hook.pairToken != vault.usdg");
        }
        if (address(controller.positionManager()) == address(0)) {
            revert WiringMismatch("controller.positionManager");
        }
        if (address(controller.permit2()) == address(0)) revert WiringMismatch("controller.permit2");
        IHooks(address(hook)).validateHookPermissions(hook.getHookPermissions());
    }

    function _checkProxyAdmin(address sender, address proxy, address proxyAdmin) internal view {
        address actualAdmin = Upgrades.getAdminAddress(proxy);
        if (actualAdmin != proxyAdmin) revert ProxyAdminMismatch(proxyAdmin, actualAdmin);
        address adminOwner = ProxyAdmin(proxyAdmin).owner();
        if (adminOwner != sender) revert NotProxyAdminOwner(adminOwner, sender);
    }

    function _initializedVersion(address proxy) internal view returns (uint64) {
        return uint64(uint256(vm.load(proxy, INITIALIZABLE_STORAGE)));
    }

    // ---------------------------------------------------------------------------------------------
    // Env helpers: an env var that is present but empty counts as unset.
    // ---------------------------------------------------------------------------------------------

    function _envAddressOr(string memory name, address fallback_) internal view returns (address) {
        string memory raw = vm.envOr(name, string(""));
        return bytes(raw).length == 0 ? fallback_ : vm.parseAddress(raw);
    }

    function _envUintOr(string memory name, uint256 fallback_) internal view returns (uint256) {
        string memory raw = vm.envOr(name, string(""));
        return bytes(raw).length == 0 ? fallback_ : vm.parseUint(raw);
    }

    function _envAddressList(string memory name) internal view returns (address[] memory) {
        string memory raw = vm.envOr(name, string(""));
        return bytes(raw).length == 0 ? new address[](0) : vm.envAddress(name, ",");
    }

    function _logProxy(string memory label, address proxy) internal view {
        address admin = Upgrades.getAdminAddress(proxy);
        console.log(string.concat(label, " PROXY: "), proxy);
        console.log(string.concat(label, " IMPLEMENTATION: "), Upgrades.getImplementationAddress(proxy));
        console.log(string.concat(label, " PROXY ADMIN: "), admin);
        console.log(string.concat(label, " PROXY ADMIN OWNER: "), ProxyAdmin(admin).owner());
    }
}

/// @notice Deploys Vault, HookManager and GemoonController and wires them in one run.
/// @dev Order: vault -> controller -> hook (needs both in `initialize`) -> setters -> ownership. A half-finished run is safe: the controller reverts on `deployToken` until both hook
/// and vault are set, the hook rejects pools of unregistered Memes and the vault accepts fees only
/// from its hook.
/// Env:
///  - POOL_MANAGER               Uniswap V4 PoolManager (required)
///  - POSITION_MANAGER           Uniswap V4 PositionManager, mints the initial positions (required)
///  - PERMIT2                    Permit2 the PositionManager settles through (required)
///  - USDG_ADDRESS               pair token of every pool, fees are charged in it (required)
///  - PROTOCOL_FEE_RECIPIENT     receives the protocol share of the swap fee (required)
///  - VAULT_CONVERSION_THRESHOLD pending USDG (in USDG units) that closes an epoch; 0 disables
///                               automatic conversion (required)
///  - GEMOON_OWNER               final owner of the three contracts (default: broadcaster)
///  - GEMOON_PROXY_ADMIN_OWNER   owner of the three ProxyAdmins, i.e. who can upgrade
///                               (default: GEMOON_OWNER)
///  - HOOK_TOTAL_FEE_BIPS        swap fee in bips (default: 125)
///  - HOOK_PROTOCOL_FEE_BIPS     protocol share of it in bips (default: 25)
///  - VAULT_SWAP_ADAPTER         USDG -> asset adapter (optional)
///  - VAULT_ALLOWED_ASSETS       comma-separated reward asset allowlist (optional)
/// After the run: GEMOON_OWNER calls `Vault.acceptOwnership` if it differs from the broadcaster.
/// The hook and the controller are owned by GEMOON_OWNER right away. Put the logged addresses into
/// *_PROXY_ADDRESS / *_PROXY_ADMIN_ADDRESS for the upgrade and verify scripts.
contract DeployGemoon is GemoonDeployBase {
    struct Params {
        address owner;
        address proxyAdminOwner;
        address poolManager;
        address positionManager;
        address permit2;
        address usdg;
        address protocolRecipient;
        uint256 feeBips;
        uint256 protocolFeeBips;
        uint256 conversionThreshold;
        address swapAdapter;
        address[] allowedAssets;
    }

    struct Deployment {
        Vault vault;
        HookManager hook;
        GemoonController controller;
    }

    /// @notice Result of the last `run`, for tests.
    Deployment public deployed;

    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Params memory params = paramsFromEnv(deployer);
        Deployment memory d = deployAll(deployer, CREATE2_FACTORY, params);
        vm.stopBroadcast();
        deployed = d;

        console.log("DEPLOYER: ", deployer);
        console.log("OWNER (vault pending until acceptOwnership): ", params.owner);
        console.log("POOL MANAGER: ", params.poolManager);
        console.log("POSITION MANAGER: ", params.positionManager);
        console.log("PERMIT2: ", params.permit2);
        console.log("USDG / PAIR TOKEN: ", params.usdg);
        console.log("PROTOCOL FEE RECIPIENT: ", params.protocolRecipient);
        console.log("HOOK TOTAL FEE BIPS: ", params.feeBips);
        console.log("HOOK PROTOCOL FEE BIPS: ", params.protocolFeeBips);
        console.log("VAULT CONVERSION THRESHOLD: ", params.conversionThreshold);
        console.log("VAULT SWAP ADAPTER: ", params.swapAdapter);
        for (uint256 i; i < params.allowedAssets.length; ++i) {
            console.log("VAULT ALLOWED ASSET: ", params.allowedAssets[i]);
        }
        _logProxy("VAULT", address(d.vault));
        _logProxy("HOOK", address(d.hook));
        _logProxy("CONTROLLER", address(d.controller));
    }

    /// @notice Reads the deployment parameters from the environment.
    /// @param deployer Broadcasting account, default owner.
    function paramsFromEnv(address deployer) public view returns (Params memory params) {
        address owner = _envAddressOr("GEMOON_OWNER", deployer);
        params = Params({
            owner: owner,
            proxyAdminOwner: _envAddressOr("GEMOON_PROXY_ADMIN_OWNER", owner),
            poolManager: vm.envAddress("POOL_MANAGER"),
            positionManager: vm.envAddress("POSITION_MANAGER"),
            permit2: vm.envAddress("PERMIT2"),
            usdg: vm.envAddress("USDG_ADDRESS"),
            protocolRecipient: vm.envAddress("PROTOCOL_FEE_RECIPIENT"),
            feeBips: _envUintOr("HOOK_TOTAL_FEE_BIPS", 125),
            protocolFeeBips: _envUintOr("HOOK_PROTOCOL_FEE_BIPS", 25),
            conversionThreshold: vm.envUint("VAULT_CONVERSION_THRESHOLD"),
            swapAdapter: _envAddressOr("VAULT_SWAP_ADAPTER", address(0)),
            allowedAssets: _envAddressList("VAULT_ALLOWED_ASSETS")
        });
    }

    /// @notice Deploys and wires everything. Must be called by `deployer`.
    /// @param deployer        Calling account; owns vault and controller during the run.
    /// @param create2Deployer Account CREATE2 is executed from, see `GemoonDeployBase`.
    /// @param params          Deployment parameters.
    /// @return d              Deployed proxies.
    function deployAll(address deployer, address create2Deployer, Params memory params)
        public
        returns (Deployment memory d)
    {
        // 1. Vault, kept by the deployer until it is wired.
        d.vault = deployVault(
            deployer,
            VaultDeployParams({
                owner: deployer,
                proxyAdminOwner: params.proxyAdminOwner,
                usdg: params.usdg,
                controller: address(0),
                hook: address(0),
                conversionThreshold: params.conversionThreshold,
                swapAdapter: params.swapAdapter,
                allowedAssets: params.allowedAssets
            })
        );

        // 2. Controller, same pair token as the vault and the hook.
        d.controller = deployController(
            deployer,
            ControllerDeployParams({
                proxyAdminOwner: params.proxyAdminOwner,
                poolManager: params.poolManager,
                pairToken: params.usdg
            })
        );

        // 3. Hook, fully configured by `initialize`, owned by the final owner right away.
        d.hook = deployHook(
            create2Deployer,
            HookDeployParams({
                owner: params.owner,
                proxyAdminOwner: params.proxyAdminOwner,
                poolManager: params.poolManager,
                pairToken: params.usdg,
                protocolRecipient: params.protocolRecipient,
                vault: address(d.vault),
                controller: address(d.controller),
                feeBips: params.feeBips,
                protocolFeeBips: params.protocolFeeBips
            })
        );

        // 4. Wiring.
        d.vault.setHook(address(d.hook));
        d.vault.setController(address(d.controller));
        d.controller.setHook(address(d.hook));
        d.controller.setVault(address(d.vault));
        d.controller.setPositionManager(params.positionManager, params.permit2);

        // 5. Ownership. Vault is Ownable2Step (pending), controller is plain Ownable (immediate).
        if (params.owner != deployer) {
            d.vault.transferOwnership(params.owner);
            d.controller.transferOwnership(params.owner);
        }

        // 6. Sanity.
        checkWiring(d.controller, d.hook, d.vault);
    }
}

/// @notice Deploys a standalone fee Vault behind a proxy, e.g. to replace the vault of an
/// existing deployment.
/// @dev Env:
///  - USDG_ADDRESS                 token fees arrive in (required)
///  - VAULT_CONVERSION_THRESHOLD   pending USDG that closes an epoch, 0 disables automatic
///                                 conversion (required)
///  - GEMOON_OWNER                 final owner, e.g. multisig (default: broadcaster)
///  - GEMOON_PROXY_ADMIN_OWNER     owner of the ProxyAdmin, i.e. who can upgrade (default: GEMOON_OWNER)
///  - VAULT_SWAP_ADAPTER           USDG -> asset adapter (optional, can be set later)
///  - VAULT_ALLOWED_ASSETS         comma-separated reward assets allowlist (optional)
///  - CONTROLLER_PROXY_ADDRESS     GemoonController proxy (optional, can be set later)
///  - HOOK_PROXY_ADDRESS           HookManager proxy (optional, can be set later)
/// After the run: owner of the controller calls `GemoonController.setVault`, owner of the hook
/// calls `HookManager.setVault` (both with the vault PROXY address), and GEMOON_OWNER calls
/// `acceptOwnership` if it differs from the broadcaster.
contract DeployVault is GemoonDeployBase {
    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address owner = _envAddressOr("GEMOON_OWNER", deployer);
        VaultDeployParams memory params = VaultDeployParams({
            owner: owner,
            proxyAdminOwner: _envAddressOr("GEMOON_PROXY_ADMIN_OWNER", owner),
            usdg: vm.envAddress("USDG_ADDRESS"),
            controller: _envAddressOr("CONTROLLER_PROXY_ADDRESS", address(0)),
            hook: _envAddressOr("HOOK_PROXY_ADDRESS", address(0)),
            conversionThreshold: vm.envUint("VAULT_CONVERSION_THRESHOLD"),
            swapAdapter: _envAddressOr("VAULT_SWAP_ADAPTER", address(0)),
            allowedAssets: _envAddressList("VAULT_ALLOWED_ASSETS")
        });

        Vault vault = deployVault(deployer, params);

        vm.stopBroadcast();

        _logProxy("VAULT", address(vault));
        console.log("VAULT OWNER (pending if differs from deployer): ", params.owner);
        console.log("USDG: ", params.usdg);
        console.log("CONTROLLER: ", params.controller);
        console.log("HOOK: ", params.hook);
        console.log("CONVERSION THRESHOLD: ", params.conversionThreshold);
        console.log("SWAP ADAPTER: ", params.swapAdapter);
        for (uint256 i; i < params.allowedAssets.length; ++i) {
            console.log("ALLOWED ASSET: ", params.allowedAssets[i]);
        }
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
contract ProxyVaultUpgrade is GemoonDeployBase {
    function run() external {
        address proxy = vm.envAddress("VAULT_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("VAULT_PROXY_ADMIN_ADDRESS");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        address newImplementation = address(new Vault());
        upgradeVault(sender, proxy, proxyAdmin, newImplementation);
        vm.stopBroadcast();

        _logProxy("VAULT", proxy);
        console.log("VAULT VERSION: ", uint256(Vault(proxy).getVersion()));
    }

    /// @notice Upgrades `proxy` to `newImplementation`. Must be called by `sender`.
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
        _checkProxyAdmin(sender, proxy, proxyAdmin);

        Vault vault = Vault(proxy);
        address ownerBefore = vault.owner();
        address usdgBefore = vault.usdg();

        uint64 current = _initializedVersion(proxy);
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

/// @notice Upgrades the HookManager proxy to a freshly deployed, CREATE2-mined implementation.
/// @dev Env:
///  - HOOK_PROXY_ADDRESS           HookManager proxy (required)
///  - HOOK_PROXY_ADMIN_ADDRESS     ProxyAdmin of the hook proxy (required)
/// PoolManager and pair token are read from the proxy. The broadcaster must own the ProxyAdmin.
/// If the new implementation bumps `HOOK_MANAGER_VERSION`, `reinitialize` runs atomically with
/// the upgrade, re-passing the current owner, recipient, vault, controller and fees; otherwise the upgrade
/// carries no call. Storage must stay append-only, see `ProxyVaultUpgrade`.
contract ProxyHookUpgrade is GemoonDeployBase {
    using Hooks for IHooks;

    function run() external {
        address proxy = vm.envAddress("HOOK_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("HOOK_PROXY_ADMIN_ADDRESS");
        HookManager hook = HookManager(payable(proxy));

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        HookManager newImplementation = deployHookImplementation(
            CREATE2_FACTORY, address(hook.poolManager()), Currency.unwrap(hook.pairToken())
        );
        upgradeHook(sender, proxy, proxyAdmin, address(newImplementation));
        vm.stopBroadcast();

        _logProxy("HOOK", proxy);
        console.log("HOOK VERSION: ", uint256(hook.getVersion()));
    }

    /// @notice Upgrades `proxy` to `newImplementation`. Must be called by `sender`.
    /// @dev Reverts if the proxy admin or its owner do not match, if the version goes down, or if
    /// owner / vault / pair token / implementation are not as expected after the upgrade, or if
    /// the proxy address no longer matches the permissions of the new implementation.
    /// @param sender            Broadcasting account, owner of `proxyAdmin`.
    /// @param proxy             HookManager proxy.
    /// @param proxyAdmin        ProxyAdmin of `proxy`.
    /// @param newImplementation Deployed, CREATE2-mined HookManager implementation.
    function upgradeHook(
        address sender,
        address proxy,
        address proxyAdmin,
        address newImplementation
    ) public {
        _checkProxyAdmin(sender, proxy, proxyAdmin);

        HookManager hook = HookManager(payable(proxy));
        address ownerBefore = hook.owner();
        address vaultBefore = hook.vault();
        address controllerBefore = hook.controller();
        address pairTokenBefore = Currency.unwrap(hook.pairToken());

        uint64 current = _initializedVersion(proxy);
        uint64 next = HookManager(payable(newImplementation)).getVersion();
        if (next < current) revert VersionDowngrade(current, next);
        bytes memory data = next > current
            ? abi.encodeCall(
                HookManager.reinitialize,
                (
                    ownerBefore,
                    hook.protocolRecipient(),
                    vaultBefore,
                    controllerBefore,
                    hook.TOTAL_FEE_BIPS(),
                    hook.PROTOCOL_FEE_BIPS()
                )
            )
            : bytes("");

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy), newImplementation, data
        );

        if (
            Upgrades.getImplementationAddress(proxy) != newImplementation
                || hook.owner() != ownerBefore || hook.vault() != vaultBefore
                || hook.controller() != controllerBefore
                || Currency.unwrap(hook.pairToken()) != pairTokenBefore
        ) revert StateChanged();
        IHooks(proxy).validateHookPermissions(hook.getHookPermissions());
    }
}

/// @notice Upgrades the GemoonController proxy and re-runs its initializer.
/// @dev Env: MULTISIG_OWNER_ADDRESS, NATIVE_TOKEN_ADDRESS, POOL_MANAGER, CONTROLLER_PROXY_ADDRESS,
/// CONTROLLER_PROXY_ADMIN_ADDRESS. `reinitialize` is guarded by `reinitializer(GEMOON_VERSION)`,
/// so it only succeeds when the new implementation bumps the version.
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

/// @notice Read-only check that a deployment is wired correctly. No broadcast.
/// @dev Env: CONTROLLER_PROXY_ADDRESS, HOOK_PROXY_ADDRESS, VAULT_PROXY_ADDRESS.
contract VerifyWiring is GemoonDeployBase {
    function run() external view {
        GemoonController controller =
            GemoonController(payable(vm.envAddress("CONTROLLER_PROXY_ADDRESS")));
        HookManager hook = HookManager(payable(vm.envAddress("HOOK_PROXY_ADDRESS")));
        Vault vault = Vault(vm.envAddress("VAULT_PROXY_ADDRESS"));

        checkWiring(controller, hook, vault);

        _logProxy("VAULT", address(vault));
        console.log("VAULT OWNER: ", vault.owner());
        console.log("VAULT PENDING OWNER: ", vault.pendingOwner());
        console.log("VAULT CONVERSION THRESHOLD: ", vault.conversionThreshold());
        _logProxy("HOOK", address(hook));
        console.log("HOOK OWNER: ", hook.owner());
        console.log("HOOK PENDING OWNER: ", hook.pendingOwner());
        console.log("HOOK PROTOCOL RECIPIENT: ", hook.protocolRecipient());
        _logProxy("CONTROLLER", address(controller));
        console.log("CONTROLLER OWNER: ", controller.owner());
        console.log("CONTROLLER POSITION MANAGER: ", address(controller.positionManager()));
        console.log("CONTROLLER PERMIT2: ", address(controller.permit2()));
        console.log("PAIR TOKEN: ", vault.usdg());
        console.log("WIRING OK");
    }
}

/// @notice Deploys a UniswapV3SwapAdapter for an existing Vault.
/// @dev Env:
///  - UNISWAP_V3_FACTORY           Uniswap V3 factory (required)
///  - VAULT_PROXY_ADDRESS          Vault proxy the adapter serves (required)
///  - USDG_ADDRESS                 token the vault sells, must equal `Vault.usdg()` (required)
///  - GEMOON_OWNER                 owner of the adapter, sets routes (default: broadcaster)
///  - ADAPTER_TWAP_WINDOW          TWAP window in seconds (default: 600)
/// After the run: the owner calls `setRoute(asset, fee, maxSlippageBps)` for every reward asset
/// (e.g. 100 bps) and the vault owner calls `Vault.setSwapAdapter` with the logged address. Make
/// sure every pool's observation cardinality covers the window.
contract DeployUniswapV3SwapAdapter is GemoonDeployBase {
    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address owner = _envAddressOr("GEMOON_OWNER", deployer);
        address factory = vm.envAddress("UNISWAP_V3_FACTORY");
        address vault = vm.envAddress("VAULT_PROXY_ADDRESS");
        address usdg = vm.envAddress("USDG_ADDRESS");
        uint32 window = uint32(_envUintOr("ADAPTER_TWAP_WINDOW", 600));

        if (Vault(vault).usdg() != usdg) revert WiringMismatch("adapter usdg");
        UniswapV3SwapAdapter adapter =
            new UniswapV3SwapAdapter(owner, factory, vault, usdg, window);

        vm.stopBroadcast();

        console.log("SWAP ADAPTER: ", address(adapter));
        console.log("OWNER: ", owner);
        console.log("FACTORY: ", factory);
        console.log("VAULT: ", vault);
        console.log("USDG: ", usdg);
        console.log("TWAP WINDOW: ", uint256(window));
    }
}
