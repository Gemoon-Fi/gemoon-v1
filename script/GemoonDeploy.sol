// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {TokenDeployer} from "../src/contracts/TokenDeployer.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {UniswapV3SwapAdapter} from "../src/contracts/adapters/UniswapV3SwapAdapter.sol";
import {GmoonReferrals} from "../src/contracts/Referrals.sol";
import {IUniswapV3SwapAdapter} from "../src/contracts/interfaces/IUniswapV3SwapAdapter.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import "@oz-upgrades/Upgrades.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap-v4-core/libraries/Hooks.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

/// @notice Shared deployment and upgrade logic of the Gemoon contracts.
/// @dev Every contract but HookManager and TokenDeployer lives behind a TransparentUpgradeableProxy.
/// The proxy creates its own ProxyAdmin, owned by `proxyAdminOwner`, so the upgrade key is set at
/// deployment and never has to be transferred afterwards. TokenDeployer is replaced instead of
/// upgraded: new token code is a new TokenDeployer set with `GemoonController.setTokenDeployer`.
///
/// HookManager is not upgradeable: pools reference it directly, so its code and fee rates can
/// never change under a live pool. How a fee is split (protocol share and recipient) lives in the
/// upgradeable Vault. The PoolManager decides which callbacks to invoke from the bits of
/// the hook address (BaseHook validates itself in its constructor), so it is deployed with CREATE2
/// and a mined salt that puts `HOOK_FLAGS` into the address. In `forge script` CREATE2 goes through the deterministic
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
        address protocolRecipient;
        uint256 protocolShareBps;
    }

    struct HookDeployParams {
        address poolManager;
        address pairToken;
        address vault;
        address controller;
        uint256 feeBips;
    }

    struct ControllerDeployParams {
        address proxyAdminOwner;
        address poolManager;
        address pairToken;
    }

    struct ReferralsDeployParams {
        address owner;
        address proxyAdminOwner;
        address pairToken;
        address controller;
        address hook;
        uint256 refShareBips;
    }

    // ---------------------------------------------------------------------------------------------
    // Vault
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys and configures a Vault proxy. Must be called by `deployer`.
    /// @dev The proxy is initialized with `deployer` as owner in the deployment transaction (no
    /// front-running of `initialize`) so it can be configured in the same run, then ownership is
    /// handed to `params.owner` via Ownable2Step (needs acceptOwnership). Zero `controller`,
    /// `hook`, `swapAdapter`, `protocolRecipient` and `protocolShareBps` are skipped and can be set
    /// later by the owner. A non-zero share needs a recipient before the first fee arrives.
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
        if (params.protocolRecipient != address(0)) {
            vault.setProtocolRecipient(params.protocolRecipient);
        }
        if (params.protocolShareBps != 0) vault.setProtocolShare(params.protocolShareBps);

        for (uint256 i; i < params.allowedAssets.length; ++i) {
            vault.setAssetAllowed(params.allowedAssets[i], true);
        }

        if (params.owner != deployer) vault.transferOwnership(params.owner);
    }

    // ---------------------------------------------------------------------------------------------
    // HookManager
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a CREATE2-mined HookManager. Not upgradeable and ownerless: no proxy, no
    ///         owner, everything (vault and controller included) is set in the constructor.
    /// @param create2Deployer Account CREATE2 is executed from, see the contract docs.
    /// @param params          Hook configuration; `vault` and `controller` must already be deployed.
    /// @return hook           HookManager.
    function deployHook(address create2Deployer, HookDeployParams memory params)
        public
        returns (HookManager hook)
    {
        bytes memory args = abi.encode(
            params.poolManager,
            params.pairToken,
            params.vault,
            params.controller,
            params.feeBips
        );
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(HookManager).creationCode, args));
        (address expected, bytes32 salt) = findHookSalt(create2Deployer, initCodeHash);

        hook = new HookManager{salt: salt}(
            IPoolManager(params.poolManager),
            Currency.wrap(params.pairToken),
            params.vault,
            params.controller,
            params.feeBips
        );
        if (address(hook) != expected) revert Create2AddressMismatch(expected, address(hook));
        IHooks(address(hook)).validateHookPermissions(hook.getHookPermissions());
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
    // TokenDeployer
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a TokenDeployer serving `controller`. Not upgradeable and ownerless: the
    ///         controller is fixed in its constructor, the token code in its bytecode.
    /// @dev The controller starts using it only after `GemoonController.setTokenDeployer`.
    /// @param controller     GemoonController proxy, the only caller of `deployToken`.
    /// @return tokenDeployer TokenDeployer.
    function deployTokenDeployer(address controller) public returns (TokenDeployer tokenDeployer) {
        tokenDeployer = new TokenDeployer(controller);
    }

    /// @notice Reverts unless the controller has a token deployer and that deployer serves it.
    /// @dev A controller implementation older than the TokenDeployer has no `tokenDeployer()`, the
    /// call then reverts without data.
    function checkTokenDeployerWiring(GemoonController controller) public view {
        address tokenDeployer = address(controller.tokenDeployer());
        if (tokenDeployer == address(0)) revert WiringMismatch("controller.tokenDeployer");
        if (TokenDeployer(tokenDeployer).controller() != address(controller)) {
            revert WiringMismatch("tokenDeployer.controller");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Referrals
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys a Referrals proxy, fully configured by `initialize`.
    /// @dev `params.owner` is the owner right away (Ownable2Step init sets it directly). Zero
    /// `controller` / `hook` are skipped and can be set later by the owner.
    /// @param params     Referrals configuration.
    /// @return referrals Referrals proxy.
    function deployReferrals(ReferralsDeployParams memory params)
        public
        returns (GmoonReferrals referrals)
    {
        GmoonReferrals implementation = new GmoonReferrals();
        referrals = GmoonReferrals(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    params.proxyAdminOwner,
                    abi.encodeCall(
                        GmoonReferrals.initialize,
                        (
                            params.owner,
                            params.pairToken,
                            params.controller,
                            params.hook,
                            params.refShareBips
                        )
                    )
                )
            )
        );
    }

    /// @notice Reverts unless the referrals contract is the protocol recipient of the vault and
    /// points at the same controller and vault, which in turn point at it.
    function checkReferralsWiring(
        GemoonController controller,
        Vault vault,
        GmoonReferrals referrals
    ) public view {
        if (address(controller.referrals()) != address(referrals)) {
            revert WiringMismatch("controller.referrals");
        }
        if (vault.protocolRecipient() != address(referrals)) {
            revert WiringMismatch("vault.protocolRecipient");
        }
        if (referrals.vault() != address(vault)) revert WiringMismatch("referrals.vault");
        if (referrals.controller() != address(controller)) {
            revert WiringMismatch("referrals.controller");
        }
        if (referrals.pairToken() != vault.usdg()) {
            revert WiringMismatch("referrals.pairToken");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------------------------------

    /// @notice Reverts unless controller, hook and vault all point at each other and share the
    /// pair token, and the hook address carries its permission bits.
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

/// @notice Full Gemoon deployment in one run: Vault, GemoonController with its TokenDeployer,
/// GmoonReferrals, HookManager and UniswapV3SwapAdapter, wired together, the reward assets of
/// `DEPLOY_ASSETS_FILE` allowed in the vault with their swap routes on the adapter, ownership handed
/// over, and a report of what was deployed where and why.
/// @dev Order (`deployFull`): vault -> controller -> token deployer (takes the controller in its
/// constructor) -> referrals (protocol recipient of the vault) -> hook (takes vault and controller
/// in its constructor) -> setters -> adapter -> assets and routes -> ownership -> checks.
/// The deployer owns vault, controller, referrals and adapter during the run so it can configure
/// them; the hook and the token deployer have no owner. A half-finished run is safe: the
/// controller reverts on `deployToken` until hook, vault, token deployer and PositionManager are
/// set, the hook rejects pools of unregistered Memes and the vault accepts fees only from its hook.
///
/// Reward assets: a row of the asset file is allowed and routed only if the asset has code, its
/// pool is the factory USDG pool for the pool's fee tier and the pool can serve a TWAP over the
/// adapter window. Other rows are skipped and listed in the report with the reason: an allowed
/// asset without a route would make every conversion of its Memes fail.
///
/// Env:
///  - POOL_MANAGER               Uniswap V4 PoolManager (required)
///  - POSITION_MANAGER           Uniswap V4 PositionManager, mints the initial positions (required)
///  - PERMIT2                    Permit2 the PositionManager settles through (required)
///  - USDG_ADDRESS               pair token of every pool, fees are charged in it (required)
///  - VAULT_CONVERSION_THRESHOLD pending USDG (in USDG units) that closes an epoch; 0 disables
///                               automatic conversion (required)
///  - UNISWAP_V3_FACTORY         Uniswap V3 factory of the USDG/asset pools (required)
///  - GEMOON_OWNER               final owner of every contract (default: broadcaster)
///  - GEMOON_PROXY_ADMIN_OWNER   owner of the ProxyAdmins, i.e. who can upgrade
///                               (default: GEMOON_OWNER)
///  - HOOK_TOTAL_FEE_BIPS        fallback swap fee in bips for Memes without their own fee
///                               (default: 125); every Meme gets its fee from `deployToken`
///  - VAULT_PROTOCOL_SHARE_BPS   protocol share of every fee, in bps of the fee, kept by the vault
///                               and changeable by its owner (default: 2500)
///  - REFERRALS_REF_SHARE_BIPS   referrer share of the protocol fee, in bips (default: 2500)
///  - ADAPTER_TWAP_WINDOW        TWAP window of the adapter in seconds (default: 600)
///  - ADAPTER_MAX_SLIPPAGE_BPS   allowed deviation from the TWAP per route (default: 100)
///  - DEPLOY_ASSETS_FILE         reward asset list, `Ticker,Contract address,Uniswap V3 / USDG pool`
///                               with a header line (default: tools/scripts/robinhood-assets.csv)
///  - VAULT_ALLOWED_ASSETS       extra comma-separated assets allowed without a route, e.g. USDG
///                               itself (optional)
///  - DEPLOY_REPORT              file the report is written to (optional, it is logged anyway)
/// The vault sends the protocol share of the swap fee to the Referrals contract; its owner withdraws the
/// protocol part with `withdrawProtocolFees`. After the run GEMOON_OWNER accepts the ownership of
/// vault, referrals and adapter (Ownable2Step) if it differs from the broadcaster.
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
        uint256 protocolShareBps;
        uint256 conversionThreshold;
        address swapAdapter;
        address[] allowedAssets;
    }

    struct Deployment {
        Vault vault;
        HookManager hook;
        GemoonController controller;
    }

    /// @notice One row of the reward asset file.
    struct AssetRow {
        string ticker;
        address asset;
        address pool;
    }

    /// @notice What the deployment did with a reward asset.
    enum AssetStatus {
        Routed, // allowed in the vault, route set on the adapter
        PairToken, // USDG itself: allowed, credited without a swap, needs no route
        NoCode, // skipped: the asset has no code on this network
        NoPool, // skipped: the listed pool has no code
        NotFactoryPool, // skipped: the pool is not factory.getPool(USDG, asset, pool.fee())
        NoTwapHistory // skipped: the pool cannot serve a TWAP over the adapter window
    }

    struct AssetResult {
        string ticker;
        address asset;
        address pool;
        uint24 fee;
        AssetStatus status;
    }

    /// @notice Parameters of `deployFull`. `core.protocolRecipient` and `core.swapAdapter` are
    /// ignored: the referrals contract and the new adapter take their place.
    struct FullParams {
        Params core;
        uint256 refShareBips;
        address v3Factory;
        uint32 twapWindow;
        uint16 maxSlippageBps;
        AssetRow[] assets;
    }

    struct FullDeployment {
        Vault vault;
        HookManager hook;
        GemoonController controller;
        GmoonReferrals referrals;
        UniswapV3SwapAdapter adapter;
        AssetResult[] assets;
    }

    error InvalidAssetRow(uint256 line);

    string internal constant DEFAULT_ASSETS_FILE = "tools/scripts/robinhood-assets.csv";

    /// @notice Core contracts of the last `run`, for tests.
    Deployment public deployed;
    /// @notice Referrals of the last `run`, for tests.
    GmoonReferrals public deployedReferrals;
    /// @notice Swap adapter of the last `run`, for tests.
    UniswapV3SwapAdapter public deployedAdapter;

    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        FullParams memory params = fullParamsFromEnv(deployer);
        FullDeployment memory d = deployFull(deployer, CREATE2_FACTORY, params);
        vm.stopBroadcast();

        deployed = Deployment({vault: d.vault, hook: d.hook, controller: d.controller});
        deployedReferrals = d.referrals;
        deployedAdapter = d.adapter;

        string memory report = buildReport(deployer, params, d);
        console.log(report);

        // Machine-readable lines, parsed by deploy.sh.
        _logProxy("VAULT", address(d.vault));
        console.log("HOOK: ", address(d.hook));
        _logProxy("CONTROLLER", address(d.controller));
        console.log("TOKEN DEPLOYER: ", address(d.controller.tokenDeployer()));
        _logProxy("REFERRALS", address(d.referrals));
        console.log("SWAP ADAPTER: ", address(d.adapter));

        string memory path = vm.envOr("DEPLOY_REPORT", string(""));
        if (bytes(path).length != 0) {
            vm.writeFile(path, report);
            console.log(string.concat("REPORT: ", path));
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------------------------------

    /// @notice Reads the core deployment parameters from the environment.
    /// @dev `protocolRecipient` and `swapAdapter` stay zero, `deployFull` sets them.
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
            protocolRecipient: address(0),
            feeBips: _envUintOr("HOOK_TOTAL_FEE_BIPS", 125),
            protocolShareBps: _envUintOr("VAULT_PROTOCOL_SHARE_BPS", 2_500),
            conversionThreshold: vm.envUint("VAULT_CONVERSION_THRESHOLD"),
            swapAdapter: address(0),
            allowedAssets: _envAddressList("VAULT_ALLOWED_ASSETS")
        });
    }

    /// @notice Reads every parameter of `deployFull` from the environment, assets from the file.
    /// @param deployer Broadcasting account, default owner.
    function fullParamsFromEnv(address deployer) public view returns (FullParams memory params) {
        string memory file = vm.envOr("DEPLOY_ASSETS_FILE", string(""));
        if (bytes(file).length == 0) file = DEFAULT_ASSETS_FILE;

        params = FullParams({
            core: paramsFromEnv(deployer),
            refShareBips: _envUintOr("REFERRALS_REF_SHARE_BIPS", 2_500),
            v3Factory: vm.envAddress("UNISWAP_V3_FACTORY"),
            twapWindow: SafeCast.toUint32(_envUintOr("ADAPTER_TWAP_WINDOW", 600)),
            maxSlippageBps: SafeCast.toUint16(_envUintOr("ADAPTER_MAX_SLIPPAGE_BPS", 100)),
            assets: parseAssets(vm.readFile(file))
        });
    }

    /// @notice Parses the asset file: a header line, then `Ticker,Contract address,Pool` per row.
    /// @dev Blank lines are skipped, an empty pool column becomes the zero address. Reverts with
    /// the 1-based line number on a row without an address column or with a malformed address.
    /// @param csv File contents.
    /// @return rows Parsed rows in file order.
    function parseAssets(string memory csv) public pure returns (AssetRow[] memory rows) {
        string[] memory lines = vm.split(csv, "\n");
        rows = new AssetRow[](lines.length);
        uint256 count;
        for (uint256 i = 1; i < lines.length; ++i) {
            string memory line = vm.trim(lines[i]);
            if (bytes(line).length == 0) continue;

            string[] memory cols = vm.split(line, ",");
            if (cols.length < 2) revert InvalidAssetRow(i + 1);
            string memory pool = cols.length > 2 ? vm.trim(cols[2]) : "";
            rows[count++] = AssetRow({
                ticker: vm.trim(cols[0]),
                asset: vm.parseAddress(vm.trim(cols[1])),
                pool: bytes(pool).length == 0 ? address(0) : vm.parseAddress(pool)
            });
        }
        assembly ("memory-safe") {
            mstore(rows, count)
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    /// @notice Deploys, wires and configures every contract. Must be called by `deployer`.
    /// @param deployer        Calling account; owns vault, controller, referrals and adapter during
    ///                        the run.
    /// @param create2Deployer Account CREATE2 is executed from, see `GemoonDeployBase`.
    /// @param params          Deployment parameters.
    /// @return d              Deployed contracts and the outcome per reward asset.
    function deployFull(address deployer, address create2Deployer, FullParams memory params)
        public
        returns (FullDeployment memory d)
    {
        Params memory core = params.core;

        // 1. Vault and controller, kept by the deployer until they are configured, and the token
        // deployer of the controller (ownerless).
        (d.vault, d.controller) = _deployVaultAndController(deployer, core);
        TokenDeployer tokenDeployer = deployTokenDeployer(address(d.controller));

        // 2. Referrals, the protocol recipient of the vault.
        d.referrals = deployReferrals(
            ReferralsDeployParams({
                owner: deployer,
                proxyAdminOwner: core.proxyAdminOwner,
                pairToken: core.usdg,
                controller: address(d.controller),
                hook: address(0),
                refShareBips: params.refShareBips
            })
        );

        // 3. Hook, owned by the final owner right away.
        d.hook = _deployCoreHook(create2Deployer, core, d.vault, d.controller);

        // 4. Wiring. Referrals first: `deployToken` opens with `setPositionManager` in `_wireCore`,
        // a Meme deployed before `setReferrals` would never be attributed to a referrer, and no fee
        // may arrive before the vault knows where the protocol share goes.
        d.controller.setReferrals(address(d.referrals));
        d.vault.setProtocolRecipient(address(d.referrals));
        d.referrals.setVault(address(d.vault));
        _wireCore(d.vault, d.controller, d.hook, tokenDeployer, core);

        // 5. Swap adapter, owned by the deployer until the routes are set.
        d.adapter = new UniswapV3SwapAdapter(
            deployer, params.v3Factory, address(d.vault), core.usdg, params.twapWindow
        );
        d.vault.setSwapAdapter(address(d.adapter));

        // 6. Reward assets and their routes.
        d.assets = configureAssets(d.vault, d.adapter, params.assets, params.maxSlippageBps);

        // 7. Ownership. Controller is plain Ownable (immediate), the rest Ownable2Step (pending).
        if (core.owner != deployer) {
            d.vault.transferOwnership(core.owner);
            d.controller.transferOwnership(core.owner);
            d.referrals.transferOwnership(core.owner);
            d.adapter.transferOwnership(core.owner);
        }

        // 8. Sanity.
        checkWiring(d.controller, d.hook, d.vault);
        checkTokenDeployerWiring(d.controller);
        checkReferralsWiring(d.controller, d.vault, d.referrals);
        checkAdapterWiring(d.vault, d.adapter);
        checkAssets(d.vault, d.adapter, d.assets);
    }

    /// @notice Deploys and wires vault, controller with its token deployer and hook only. Must be
    ///         called by `deployer`.
    /// @dev Used by tests that need the core without referrals and adapter.
    /// @param deployer        Calling account; owns vault and controller during the run.
    /// @param create2Deployer Account CREATE2 is executed from, see `GemoonDeployBase`.
    /// @param params          Deployment parameters, `protocolRecipient` must be non-zero.
    /// @return d              Deployed proxies and hook; the token deployer is `controller.tokenDeployer()`.
    function deployAll(address deployer, address create2Deployer, Params memory params)
        public
        returns (Deployment memory d)
    {
        (d.vault, d.controller) = _deployVaultAndController(deployer, params);
        TokenDeployer tokenDeployer = deployTokenDeployer(address(d.controller));
        d.hook = _deployCoreHook(create2Deployer, params, d.vault, d.controller);
        _wireCore(d.vault, d.controller, d.hook, tokenDeployer, params);

        if (params.owner != deployer) {
            d.vault.transferOwnership(params.owner);
            d.controller.transferOwnership(params.owner);
        }
        checkWiring(d.controller, d.hook, d.vault);
        checkTokenDeployerWiring(d.controller);
    }

    /// @notice Allows every routable asset in the vault and sets its route on the adapter.
    /// @dev Must be called by the owner of both. Rows that are not routable are skipped, see
    /// `checkAsset`. An asset already allowed or routed the same way sends nothing.
    /// @param vault          Vault the assets are allowed in.
    /// @param adapter        Adapter the routes are set on.
    /// @param rows           Asset rows.
    /// @param maxSlippageBps Allowed deviation from the TWAP of every route.
    /// @return results       Outcome per row, in row order.
    function configureAssets(
        Vault vault,
        UniswapV3SwapAdapter adapter,
        AssetRow[] memory rows,
        uint16 maxSlippageBps
    ) public returns (AssetResult[] memory results) {
        results = new AssetResult[](rows.length);
        for (uint256 i; i < rows.length; ++i) {
            AssetRow memory row = rows[i];
            (AssetStatus status, uint24 fee) = checkAsset(adapter, row);
            results[i] = AssetResult({
                ticker: row.ticker, asset: row.asset, pool: row.pool, fee: fee, status: status
            });

            if (status != AssetStatus.Routed && status != AssetStatus.PairToken) continue;
            if (!vault.isAssetAllowed(row.asset)) vault.setAssetAllowed(row.asset, true);
            if (status == AssetStatus.Routed) {
                IUniswapV3SwapAdapter.Route memory current = adapter.routeOf(row.asset);
                if (current.pool != row.pool || current.maxSlippageBps != maxSlippageBps) {
                    adapter.setRoute(row.asset, fee, maxSlippageBps);
                }
            }
        }
    }

    /// @notice Whether `row` can be routed through `adapter`, and the fee tier of its pool.
    /// @dev Mirrors what `setRoute` requires, so a routable row never reverts there.
    /// @param adapter Adapter the route would be set on.
    /// @param row     Asset row.
    /// @return status Routed if it can be routed, otherwise why not.
    /// @return fee    Fee tier of the pool, zero unless the pool answered `fee()`.
    function checkAsset(UniswapV3SwapAdapter adapter, AssetRow memory row)
        public
        view
        returns (AssetStatus status, uint24 fee)
    {
        address usdg = adapter.i_usdg();
        if (row.asset == usdg) return (AssetStatus.PairToken, 0);
        if (row.asset.code.length == 0) return (AssetStatus.NoCode, 0);
        if (row.pool.code.length == 0) return (AssetStatus.NoPool, 0);

        try IUniswapV3Pool(row.pool).fee() returns (uint24 poolFee) {
            fee = poolFee;
        } catch {
            return (AssetStatus.NoPool, 0);
        }
        if (adapter.i_factory().getPool(usdg, row.asset, fee) != row.pool) {
            return (AssetStatus.NotFactoryPool, fee);
        }

        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = adapter.twapWindow();
        try IUniswapV3Pool(row.pool).observe(secondsAgos) returns (int56[] memory, uint160[] memory) {
            return (AssetStatus.Routed, fee);
        } catch {
            return (AssetStatus.NoTwapHistory, fee);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Checks
    // ---------------------------------------------------------------------------------------------

    /// @notice Reverts unless the vault uses `adapter` and the adapter serves this vault and USDG.
    function checkAdapterWiring(Vault vault, UniswapV3SwapAdapter adapter) public view {
        if (vault.swapAdapter() != address(adapter)) revert WiringMismatch("vault.swapAdapter");
        if (adapter.i_vault() != address(vault)) revert WiringMismatch("adapter.vault");
        if (adapter.i_usdg() != vault.usdg()) revert WiringMismatch("adapter.usdg");
    }

    /// @notice Reverts unless every routed asset is allowed and routed to its pool, and the pair
    /// token, if listed, is allowed.
    function checkAssets(Vault vault, UniswapV3SwapAdapter adapter, AssetResult[] memory results)
        public
        view
    {
        for (uint256 i; i < results.length; ++i) {
            AssetResult memory r = results[i];
            if (r.status != AssetStatus.Routed && r.status != AssetStatus.PairToken) continue;
            if (!vault.isAssetAllowed(r.asset)) {
                revert WiringMismatch(string.concat("asset not allowed: ", r.ticker));
            }
            if (r.status == AssetStatus.Routed && adapter.routeOf(r.asset).pool != r.pool) {
                revert WiringMismatch(string.concat("route: ", r.ticker));
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Report
    // ---------------------------------------------------------------------------------------------

    /// @notice Human-readable report of a `deployFull` run: what was deployed where, why, how it is
    /// wired and configured, who owns what, the outcome per reward asset and what is left to do.
    /// @dev Reads the current state of the contracts, so it reflects the run it is built after.
    function buildReport(address deployer, FullParams memory params, FullDeployment memory d)
        public
        view
        returns (string memory)
    {
        return string.concat(
            _reportHeader(deployer, params),
            _reportContracts(params, d),
            _reportWiring(d),
            _reportConfig(params, d),
            _reportOwnership(d),
            _reportAssets(params, d),
            _reportTodo(deployer, params, d)
        );
    }

    function _reportHeader(address deployer, FullParams memory params)
        internal
        view
        returns (string memory)
    {
        string memory mode = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)
            ? "broadcast (report is built before the transactions are sent, deploy.sh appends the outcome)"
            : vm.isContext(VmSafe.ForgeContext.ScriptDryRun)
                ? "simulation, nothing was sent"
                : "in-process (tests)";
        return string.concat(
            "# Gemoon deployment report\n\n",
            "- Mode: ", mode, "\n",
            "- Chain id: ", vm.toString(block.chainid), "\n",
            "- Block: ", vm.toString(block.number), ", timestamp ", vm.toString(block.timestamp), "\n",
            "- Deployer (sent every transaction): ", vm.toString(deployer), "\n",
            "- Final owner: ", vm.toString(params.core.owner), "\n",
            "- ProxyAdmin owner (can upgrade everything but the hook): ", vm.toString(params.core.proxyAdminOwner), "\n"
        );
    }

    function _reportContracts(FullParams memory params, FullDeployment memory d)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "\n## Contracts\n\n",
            "| Contract | Address | What it is for |\n|---|---|---|\n",
            _proxyRows(
                "Vault",
                address(d.vault),
                "Holds the creator part of every swap fee per Meme in USDG and converts it per epoch into the Meme's reward asset through the swap adapter; creators claim from it."
            ),
            _proxyRows(
                "GemoonController",
                address(d.controller),
                "Entry point `deployToken`: deploys the Meme, its V4 pool with the hook, the initial position and the optional dev buy, registers the Meme in the vault and referrals."
            ),
            _row(
                "TokenDeployer",
                address(d.controller.tokenDeployer()),
                "Creates the token of every new Meme for the controller, the whole supply minted to the controller. Not upgradeable, no owner: new token code is a new TokenDeployer set with `controller.setTokenDeployer`, Memes deployed before keep their code."
            ),
            _proxyRows(
                "GmoonReferrals",
                address(d.referrals),
                "Protocol fee recipient of the hook: credits the referrer share of every protocol fee to the referrer of the Meme creator, the owner withdraws the rest."
            ),
            _row(
                "HookManager",
                address(d.hook),
                "Uniswap V4 hook of every Meme/USDG pool: charges the swap fee, pays the creator part to the vault and the protocol part to referrals. Not upgradeable, fees fixed at deployment. CREATE2-mined, the address carries the hook permission bits."
            ),
            _row(
                "UniswapV3SwapAdapter",
                address(d.adapter),
                "Sells the vault's USDG for reward assets in Uniswap V3 USDG/asset pools, minimum output from the pool TWAP. Not upgradeable, replaced through `Vault.setSwapAdapter`."
            ),
            "\nExternal contracts used:\n\n",
            "| Contract | Address | Role |\n|---|---|---|\n",
            _row("Uniswap V4 PoolManager", params.core.poolManager, "Holds every Meme pool."),
            _row("Uniswap V4 PositionManager", params.core.positionManager, "Mints the initial position of every Meme."),
            _row("Permit2", params.core.permit2, "Token approvals of the PositionManager."),
            _row("USDG (pair token)", params.core.usdg, "Pair token of every pool, fees are charged in it."),
            _row("Uniswap V3 factory", params.v3Factory, "Source of the USDG/asset pools of the adapter.")
        );
    }

    function _proxyRows(string memory name, address proxy, string memory purpose)
        internal
        view
        returns (string memory)
    {
        address admin = Upgrades.getAdminAddress(proxy);
        return string.concat(
            _row(string.concat(name, " proxy"), proxy, string.concat(purpose, " Use this address.")),
            _row(
                string.concat(name, " implementation"),
                Upgrades.getImplementationAddress(proxy),
                "Code behind the proxy, initializers disabled. Never called directly."
            ),
            _row(
                string.concat(name, " ProxyAdmin"),
                admin,
                string.concat("Upgrades the proxy, owned by ", vm.toString(ProxyAdmin(admin).owner()), ".")
            )
        );
    }

    function _reportWiring(FullDeployment memory d) internal view returns (string memory) {
        return string.concat(
            "\n## Wiring\n\n",
            "| Setting | Points at | Why |\n|---|---|---|\n",
            _row("controller.hook", d.controller.hook(), "Pools of new Memes are created with this hook."),
            _row("controller.vault", address(d.controller.vault()), "New Memes are registered in this vault."),
            _row("controller.positionManager", address(d.controller.positionManager()), "Mints the initial position."),
            _row("controller.tokenDeployer", address(d.controller.tokenDeployer()), "Creates the token of new Memes."),
            _row("tokenDeployer.controller", d.controller.tokenDeployer().controller(), "The only caller of `deployToken` (immutable)."),
            _row("controller.referrals", address(d.controller.referrals()), "New Memes are attributed to the referrer of their creator."),
            _row("hook.vault", d.hook.vault(), "Receives every fee and splits it."),
            _row("hook.controller", d.hook.controller(), "The only caller of the hook's controller functions."),
            _row("vault.hook", d.vault.hook(), "The only source of fees the vault accepts."),
            _row("vault.controller", d.vault.controller(), "The only caller that registers Memes."),
            _row("vault.swapAdapter", d.vault.swapAdapter(), "Converts USDG into reward assets."),
            _row("vault.protocolRecipient", d.vault.protocolRecipient(), "Receives the protocol part of every fee (referrals)."),
            _row("referrals.vault", d.referrals.vault(), "The only caller of `notifyFee`."),
            _row("referrals.controller", d.referrals.controller(), "The only caller of `registerToken`."),
            _row("adapter.vault", d.adapter.i_vault(), "The only caller of `swap` (immutable)."),
            _row("adapter.factory", address(d.adapter.i_factory()), "Pools are looked up here, never taken from calldata (immutable).")
        );
    }

    function _reportConfig(FullParams memory params, FullDeployment memory d)
        internal
        view
        returns (string memory)
    {
        return string.concat(
            "\n## Configuration\n\n",
            "| Setting | Value | Meaning |\n|---|---|---|\n",
            _rowStr("hook.TOTAL_FEE_BIPS", vm.toString(d.hook.TOTAL_FEE_BIPS()), "Fallback swap fee in bips of the trade, every Meme sets its own in `deployToken`."),
            _rowStr("vault.protocolShareBps", vm.toString(d.vault.protocolShareBps()), "Protocol part of every fee in bps of the fee, the rest goes to the creator and stakers; the vault owner can change it."),
            _rowStr("referrals.refShareBips", vm.toString(d.referrals.refShareBips()), "Referrer part of the protocol fee, in bips."),
            _rowStr("vault.conversionThreshold", vm.toString(d.vault.conversionThreshold()), "Pending USDG (raw units) of a Meme that closes its epoch and triggers the conversion; 0 disables it."),
            _rowStr("adapter.twapWindow", string.concat(vm.toString(d.adapter.twapWindow()), " s"), "Window of the TWAP the minimum output is derived from."),
            _rowStr("route maxSlippageBps", vm.toString(params.maxSlippageBps), "Allowed deviation from the TWAP output for every route set by this run.")
        );
    }

    function _reportOwnership(FullDeployment memory d) internal view returns (string memory) {
        return string.concat(
            "\n## Ownership\n\n",
            "| Contract | Owner | Pending owner |\n|---|---|---|\n",
            _ownerRow("Vault", d.vault.owner(), d.vault.pendingOwner()),
            _ownerRow("GemoonController", d.controller.owner(), address(0)),
            _ownerRow("GmoonReferrals", d.referrals.owner(), d.referrals.pendingOwner()),
            _ownerRow("UniswapV3SwapAdapter", d.adapter.owner(), d.adapter.pendingOwner()),
            "\nGemoonController is plain Ownable, ownership moves at once. The others are Ownable2Step: a pending owner becomes the owner only after calling `acceptOwnership()`. HookManager has no owner: vault, controller and fees are fixed in its constructor. TokenDeployer has no owner either: its controller is fixed in its constructor, which one is used decides the controller owner (`setTokenDeployer`).\n"
        );
    }

    function _reportAssets(FullParams memory params, FullDeployment memory d)
        internal
        view
        returns (string memory out)
    {
        uint256 routed;
        uint256 skipped;
        out = string.concat(
            "\n## Reward assets\n\n",
            "Source: the asset file (",
            vm.toString(params.assets.length),
            " rows). Allowed means creators can pick the asset in `deployToken`, the route is the pool the vault's fees are converted through.\n\n",
            "| Ticker | Asset | Pool | Fee | Result |\n|---|---|---|---|---|\n"
        );
        for (uint256 i; i < d.assets.length; ++i) {
            AssetResult memory r = d.assets[i];
            if (r.status == AssetStatus.Routed || r.status == AssetStatus.PairToken) ++routed;
            else ++skipped;
            out = string.concat(
                out,
                "| ", r.ticker,
                " | ", vm.toString(r.asset),
                " | ", r.pool == address(0) ? "-" : vm.toString(r.pool),
                " | ", r.fee == 0 ? "-" : vm.toString(uint256(r.fee)),
                " | ", _statusText(r.status), " |\n"
            );
        }
        out = string.concat(
            out,
            "\nAllowed: ", vm.toString(routed), " (routed or USDG), skipped: ", vm.toString(skipped), ".\n",
            _reportExtraAssets(params, d),
            "\nVault allowlist after the run: ", vm.toString(d.vault.allowedAssets().length), " assets.\n"
        );
    }

    function _reportExtraAssets(FullParams memory params, FullDeployment memory d)
        internal
        view
        returns (string memory out)
    {
        address[] memory extra = params.core.allowedAssets;
        if (extra.length == 0) return "";
        out = "\nAlso allowed from VAULT_ALLOWED_ASSETS (no route is set for them):\n\n";
        for (uint256 i; i < extra.length; ++i) {
            string memory note = extra[i] == params.core.usdg
                ? "USDG, credited without a swap"
                : d.adapter.routeOf(extra[i]).pool != address(0)
                    ? "routed from the asset file"
                    : "WARNING: no route, conversions of Memes with this asset will fail";
            out = string.concat(out, "- ", vm.toString(extra[i]), ": ", note, "\n");
        }
    }

    function _reportTodo(address deployer, FullParams memory params, FullDeployment memory d)
        internal
        view
        returns (string memory out)
    {
        out = "\n## Left to do\n\n";
        if (params.core.owner != deployer) {
            out = string.concat(
                out,
                "- ", vm.toString(params.core.owner), " calls `acceptOwnership()` on Vault ",
                vm.toString(address(d.vault)), ", GmoonReferrals ", vm.toString(address(d.referrals)),
                " and UniswapV3SwapAdapter ", vm.toString(address(d.adapter)),
                ". Until then the deployer keeps them.\n"
            );
        }
        for (uint256 i; i < d.assets.length; ++i) {
            if (d.assets[i].status != AssetStatus.NoTwapHistory) continue;
            out = string.concat(
                out,
                "- Skipped assets without TWAP history: raise the pool observation cardinality (`increaseObservationCardinalityNext`), wait for the window to fill, then `make set-asset-allowed VAULT=",
                vm.toString(address(d.vault)), " FILE=<asset file>` and `make set-route ADAPTER=",
                vm.toString(address(d.adapter)), " FILE=<asset file>` as the owner.\n"
            );
            break;
        }
        out = string.concat(
            out,
            "- Verify the contracts in the explorer (see docs/DEPLOY.md).\n",
            "- First `deployToken` by the team: `PositionCreated` must carry non-zero liquidity.\n"
        );
    }

    function _statusText(AssetStatus status) internal pure returns (string memory) {
        if (status == AssetStatus.Routed) return "allowed + routed";
        if (status == AssetStatus.PairToken) return "allowed, USDG needs no route";
        if (status == AssetStatus.NoCode) return "SKIPPED: asset has no code on this network";
        if (status == AssetStatus.NoPool) return "SKIPPED: pool missing or not a V3 pool";
        if (status == AssetStatus.NotFactoryPool) {
            return "SKIPPED: pool is not the factory USDG pool of its fee tier";
        }
        return "SKIPPED: pool has no price history over the TWAP window";
    }

    function _row(string memory name, address addr, string memory note)
        internal
        pure
        returns (string memory)
    {
        return _rowStr(name, vm.toString(addr), note);
    }

    function _rowStr(string memory name, string memory value, string memory note)
        internal
        pure
        returns (string memory)
    {
        return string.concat("| ", name, " | ", value, " | ", note, " |\n");
    }

    function _ownerRow(string memory name, address owner, address pending)
        internal
        pure
        returns (string memory)
    {
        return _rowStr(name, vm.toString(owner), pending == address(0) ? "-" : vm.toString(pending));
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _deployVaultAndController(address deployer, Params memory params)
        internal
        returns (Vault vault, GemoonController controller)
    {
        vault = deployVault(
            deployer,
            VaultDeployParams({
                owner: deployer,
                proxyAdminOwner: params.proxyAdminOwner,
                usdg: params.usdg,
                controller: address(0),
                hook: address(0),
                conversionThreshold: params.conversionThreshold,
                swapAdapter: params.swapAdapter,
                allowedAssets: params.allowedAssets,
                protocolRecipient: params.protocolRecipient,
                protocolShareBps: params.protocolShareBps
            })
        );
        controller = deployController(
            deployer,
            ControllerDeployParams({
                proxyAdminOwner: params.proxyAdminOwner,
                poolManager: params.poolManager,
                pairToken: params.usdg
            })
        );
    }

    function _deployCoreHook(
        address create2Deployer,
        Params memory params,
        Vault vault,
        GemoonController controller
    ) internal returns (HookManager) {
        return deployHook(
            create2Deployer,
            HookDeployParams({
                poolManager: params.poolManager,
                pairToken: params.usdg,
                vault: address(vault),
                controller: address(controller),
                feeBips: params.feeBips
            })
        );
    }

    /// @dev `setPositionManager` goes last: it is the setter that opens `deployToken`.
    function _wireCore(
        Vault vault,
        GemoonController controller,
        HookManager hook,
        TokenDeployer tokenDeployer,
        Params memory params
    ) internal {
        vault.setHook(address(hook));
        vault.setController(address(controller));
        controller.setHook(address(hook));
        controller.setVault(address(vault));
        controller.setTokenDeployer(address(tokenDeployer));
        controller.setPositionManager(params.positionManager, params.permit2);
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
///  - HOOK_ADDRESS                 HookManager (optional, can be set later)
///  - VAULT_PROTOCOL_RECIPIENT     receiver of the protocol share, e.g. Referrals (optional, can be
///                                 set later; required before the first fee if the share is non-zero)
///  - VAULT_PROTOCOL_SHARE_BPS     protocol share of every fee, in bps of the fee (default: 2500)
/// After the run: owner of the controller calls `GemoonController.setVault` with the vault PROXY
/// address, and GEMOON_OWNER calls `acceptOwnership` if it differs from the broadcaster. The hook
/// has its vault fixed in the constructor: a new vault address needs a new hook (`DeployHook`).
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
            hook: _envAddressOr("HOOK_ADDRESS", address(0)),
            conversionThreshold: vm.envUint("VAULT_CONVERSION_THRESHOLD"),
            swapAdapter: _envAddressOr("VAULT_SWAP_ADAPTER", address(0)),
            allowedAssets: _envAddressList("VAULT_ALLOWED_ASSETS"),
            protocolRecipient: _envAddressOr("VAULT_PROTOCOL_RECIPIENT", address(0)),
            protocolShareBps: _envUintOr("VAULT_PROTOCOL_SHARE_BPS", 2_500)
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
        console.log("PROTOCOL RECIPIENT: ", params.protocolRecipient);
        console.log("PROTOCOL SHARE BPS: ", params.protocolShareBps);
        for (uint256 i; i < params.allowedAssets.length; ++i) {
            console.log("ALLOWED ASSET: ", params.allowedAssets[i]);
        }
    }
}

/// @notice Deploys a new HookManager for an existing deployment and points the vault and the
///         controller at it. New Memes get pools on the new hook; pools of existing Memes stay on
///         their hook, which the vault keeps accepting fees from.
/// @dev Env:
///  - POOL_MANAGER                 Uniswap V4 PoolManager (required)
///  - USDG_ADDRESS                 pair token, must equal `Vault.usdg()` (required)
///  - VAULT_PROXY_ADDRESS          Vault proxy (required)
///  - CONTROLLER_PROXY_ADDRESS     GemoonController proxy (required)
///  - HOOK_TOTAL_FEE_BIPS          fallback base fee of the hook (required)
/// The hook is ownerless, so anyone can deploy it. The broadcaster must own the vault and the
/// controller for the `setHook` calls; the wiring is checked at the end of the run.
contract DeployHook is GemoonDeployBase {
    function run() external {
        Vault vault = Vault(vm.envAddress("VAULT_PROXY_ADDRESS"));
        GemoonController controller =
            GemoonController(payable(vm.envAddress("CONTROLLER_PROXY_ADDRESS")));
        address usdg = vm.envAddress("USDG_ADDRESS");
        if (vault.usdg() != usdg) revert WiringMismatch("vault.usdg != USDG_ADDRESS");

        vm.startBroadcast();
        HookManager hook = deployHook(
            CREATE2_FACTORY,
            HookDeployParams({
                poolManager: vm.envAddress("POOL_MANAGER"),
                pairToken: usdg,
                vault: address(vault),
                controller: address(controller),
                feeBips: vm.envUint("HOOK_TOTAL_FEE_BIPS")
            })
        );
        vault.setHook(address(hook));
        controller.setHook(address(hook));
        vm.stopBroadcast();

        checkWiring(controller, hook, vault);
        console.log("HOOK: ", address(hook));
        console.log("HOOK VAULT: ", hook.vault());
        console.log("HOOK CONTROLLER: ", hook.controller());
        console.log("HOOK TOTAL FEE BIPS: ", hook.TOTAL_FEE_BIPS());
    }
}

/// @notice Deploys a new TokenDeployer for an existing controller and switches the controller to
///         it: Memes deployed from then on get the token code of this commit, Memes deployed before
///         keep theirs. The way to change the token code without a new controller implementation.
/// @dev Env: CONTROLLER_PROXY_ADDRESS (required). The controller must already have the
/// `setTokenDeployer` implementation (`make upgrade-controller-proxy`), otherwise the run reverts
/// in simulation and nothing is sent. The TokenDeployer is ownerless, anyone can deploy it;
/// `setTokenDeployer` is sent only if the broadcaster owns the controller. Otherwise the run only
/// deploys and logs the call the owner (e.g. the governance timelock) has to make.
contract DeployTokenDeployer is GemoonDeployBase {
    function run() external {
        GemoonController controller =
            GemoonController(payable(vm.envAddress("CONTROLLER_PROXY_ADDRESS")));

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        (TokenDeployer tokenDeployer, address previous, bool switched) =
            deployAndSwitch(sender, controller);
        vm.stopBroadcast();

        console.log("TOKEN DEPLOYER: ", address(tokenDeployer));
        console.log("PREVIOUS TOKEN DEPLOYER: ", previous);
        if (switched) {
            console.log("CONTROLLER SWITCHED TO THE NEW TOKEN DEPLOYER");
        } else {
            console.log("Left to do, by the controller owner", controller.owner());
            console.log("  setTokenDeployer(TOKEN DEPLOYER) on", address(controller), "calldata:");
            console.logBytes(
                abi.encodeCall(GemoonController.setTokenDeployer, (address(tokenDeployer)))
            );
        }
    }

    /// @notice Deploys a TokenDeployer for `controller` and, if `sender` owns the controller,
    ///         switches the controller to it. Must be called by `sender`.
    /// @dev Reverts before deploying anything if the controller has no `tokenDeployer()` (an
    /// implementation older than the TokenDeployer).
    /// @param sender         Calling account.
    /// @param controller     GemoonController proxy.
    /// @return tokenDeployer New TokenDeployer.
    /// @return previous      Token deployer of the controller before the call, zero if none.
    /// @return switched      Whether the controller now uses `tokenDeployer`.
    function deployAndSwitch(address sender, GemoonController controller)
        public
        returns (TokenDeployer tokenDeployer, address previous, bool switched)
    {
        previous = address(controller.tokenDeployer());
        tokenDeployer = deployTokenDeployer(address(controller));
        switched = controller.owner() == sender;
        if (switched) {
            controller.setTokenDeployer(address(tokenDeployer));
            checkTokenDeployerWiring(controller);
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

/// @notice Upgrades the GemoonController proxy and re-runs its initializer.
/// @dev Env: GEMOON_OWNER, USDG_ADDRESS, POOL_MANAGER, CONTROLLER_PROXY_ADDRESS,
/// CONTROLLER_PROXY_ADMIN_ADDRESS. `reinitialize` is guarded by `reinitializer(GEMOON_VERSION)`,
/// so it only succeeds when the new implementation bumps the version. `reinitialize` sets the
/// owner again, so GEMOON_OWNER is required here: no fallback to the broadcaster.
/// `reinitialize` also rewrites the pair token, so USDG_ADDRESS must match the pair token of the
/// hook already wired to the controller. A controller upgraded from before the TokenDeployer has
/// none: `deployToken` reverts with `TokenDeployerNotSet` until `make deploy-token-deployer`.
contract ProxyGemoonControllerUpgrade is Script {
    error PairTokenMismatch(address expected, address actual);

    function run() external {
        address owner = vm.envAddress("GEMOON_OWNER");
        address pairToken = vm.envAddress("USDG_ADDRESS");
        address uniswapPoolManager = vm.envAddress("POOL_MANAGER");
        address proxyAddress = vm.envAddress("CONTROLLER_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("CONTROLLER_PROXY_ADMIN_ADDRESS");

        address hook = GemoonController(payable(proxyAddress)).hook();
        if (hook != address(0)) {
            address hookPairToken = Currency.unwrap(HookManager(payable(hook)).pairToken());
            if (hookPairToken != pairToken) revert PairTokenMismatch(hookPairToken, pairToken);
        }

        vm.startBroadcast();

        address controllerImpl = address(new GemoonController());

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxyAddress),
            controllerImpl,
            abi.encodeCall(GemoonController.reinitialize, (uniswapPoolManager, pairToken, owner))
        );

        vm.stopBroadcast();

        address tokenDeployer = address(GemoonController(payable(proxyAddress)).tokenDeployer());
        console.log("CONTROLLER TOKEN DEPLOYER: ", tokenDeployer);
        if (tokenDeployer == address(0)) {
            console.log("deployToken reverts with TokenDeployerNotSet until make deploy-token-deployer");
        }
    }
}

/// @notice Read-only check that a deployment is wired correctly. No broadcast.
/// @dev Env: CONTROLLER_PROXY_ADDRESS, HOOK_ADDRESS, VAULT_PROXY_ADDRESS,
/// REFERRALS_PROXY_ADDRESS (optional: checked only if set). The controller must have a token
/// deployer serving it, so a controller implementation older than the TokenDeployer fails here.
contract VerifyWiring is GemoonDeployBase {
    function run() external view {
        GemoonController controller =
            GemoonController(payable(vm.envAddress("CONTROLLER_PROXY_ADDRESS")));
        HookManager hook = HookManager(payable(vm.envAddress("HOOK_ADDRESS")));
        Vault vault = Vault(vm.envAddress("VAULT_PROXY_ADDRESS"));

        checkWiring(controller, hook, vault);
        checkTokenDeployerWiring(controller);

        _logProxy("VAULT", address(vault));
        console.log("VAULT OWNER: ", vault.owner());
        console.log("VAULT PENDING OWNER: ", vault.pendingOwner());
        console.log("VAULT CONVERSION THRESHOLD: ", vault.conversionThreshold());
        console.log("VAULT PROTOCOL RECIPIENT: ", vault.protocolRecipient());
        console.log("VAULT PROTOCOL SHARE BPS: ", vault.protocolShareBps());
        console.log("HOOK: ", address(hook));
        console.log("HOOK OWNER: none (ownerless, vault and controller fixed at deployment)");
        _logProxy("CONTROLLER", address(controller));
        console.log("CONTROLLER OWNER: ", controller.owner());
        console.log("CONTROLLER POSITION MANAGER: ", address(controller.positionManager()));
        console.log("CONTROLLER PERMIT2: ", address(controller.permit2()));
        console.log("CONTROLLER TOKEN DEPLOYER: ", address(controller.tokenDeployer()));
        console.log("PAIR TOKEN: ", vault.usdg());

        address referralsAddress = _envAddressOr("REFERRALS_PROXY_ADDRESS", address(0));
        if (referralsAddress != address(0)) {
            GmoonReferrals referrals = GmoonReferrals(referralsAddress);
            checkReferralsWiring(controller, vault, referrals);
            _logProxy("REFERRALS", referralsAddress);
            console.log("REFERRALS OWNER: ", referrals.owner());
            console.log("REFERRALS REF SHARE BIPS: ", referrals.refShareBips());
        }

        address adapterAddress = vault.swapAdapter();
        if (adapterAddress != address(0)) {
            UniswapV3SwapAdapter adapter = UniswapV3SwapAdapter(adapterAddress);
            if (adapter.i_vault() != address(vault)) revert WiringMismatch("adapter.vault");
            if (adapter.i_usdg() != vault.usdg()) revert WiringMismatch("adapter.usdg");
            console.log("SWAP ADAPTER: ", adapterAddress);
            console.log("SWAP ADAPTER OWNER: ", adapter.owner());
            console.log("SWAP ADAPTER PENDING OWNER: ", adapter.pendingOwner());
        }
        console.log("VAULT ALLOWED ASSETS: ", vault.allowedAssets().length);
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

/// @notice Deploys the Referrals contract behind a proxy, e.g. for an existing deployment.
/// @dev Env:
///  - USDG_ADDRESS                 pair token the fees arrive in (required)
///  - REFERRALS_REF_SHARE_BIPS     share of the protocol fee credited to referrers, in bips of the
///                                 protocol fee (default: 1000, 10%)
///  - GEMOON_OWNER                 owner, withdraws the protocol part (default: broadcaster)
///  - GEMOON_PROXY_ADMIN_OWNER     owner of the ProxyAdmin, i.e. who can upgrade (default: GEMOON_OWNER)
///  - CONTROLLER_PROXY_ADDRESS     GemoonController proxy (optional, can be set later)
///  - HOOK_ADDRESS                 HookManager (optional, can be set later); its pair token
///                                 must equal USDG_ADDRESS. Only hooks of the older design, that
///                                 paid the protocol share themselves, need it.
/// After the run: `make wire-referrals` with REFERRALS_PROXY_ADDRESS set (owner of the controller,
/// the vault and the referrals), so the vault pays the protocol share here and the controller
/// registers new Memes.
contract DeployReferrals is GemoonDeployBase {
    function run() external {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        address owner = _envAddressOr("GEMOON_OWNER", deployer);
        ReferralsDeployParams memory params = ReferralsDeployParams({
            owner: owner,
            proxyAdminOwner: _envAddressOr("GEMOON_PROXY_ADMIN_OWNER", owner),
            pairToken: vm.envAddress("USDG_ADDRESS"),
            controller: _envAddressOr("CONTROLLER_PROXY_ADDRESS", address(0)),
            hook: _envAddressOr("HOOK_ADDRESS", address(0)),
            refShareBips: _envUintOr("REFERRALS_REF_SHARE_BIPS", 2_500)
        });
        if (
            params.hook != address(0)
                && Currency.unwrap(HookManager(payable(params.hook)).pairToken()) != params.pairToken
        ) revert WiringMismatch("hook.pairToken != USDG_ADDRESS");

        GmoonReferrals referrals = deployReferrals(params);

        vm.stopBroadcast();

        _logProxy("REFERRALS", address(referrals));
        console.log("REFERRALS OWNER: ", params.owner);
        console.log("PAIR TOKEN: ", params.pairToken);
        console.log("CONTROLLER: ", params.controller);
        console.log("HOOK: ", params.hook);
        console.log("REF SHARE BIPS: ", params.refShareBips);
    }
}

/// @notice Points the controller and the vault at the Referrals contract, the referrals at the
///         vault, and checks the wiring.
/// @dev Env: REFERRALS_PROXY_ADDRESS, CONTROLLER_PROXY_ADDRESS, VAULT_PROXY_ADDRESS. The broadcaster
/// must own the controller, the vault and the referrals. From now on the protocol share of every
/// fee goes to the referrals contract instead of the previous protocol recipient.
contract WireReferrals is GemoonDeployBase {
    function run() external {
        GmoonReferrals referrals = GmoonReferrals(vm.envAddress("REFERRALS_PROXY_ADDRESS"));
        GemoonController controller =
            GemoonController(payable(vm.envAddress("CONTROLLER_PROXY_ADDRESS")));
        Vault vault = Vault(vm.envAddress("VAULT_PROXY_ADDRESS"));

        vm.startBroadcast();
        wireReferrals(controller, vault, referrals);
        vm.stopBroadcast();

        console.log("PREVIOUS PROTOCOL RECIPIENT REPLACED BY: ", address(referrals));
        console.log("REFERRALS WIRING OK");
    }

    /// @notice Sets the referrals on the controller and as protocol recipient of the vault, and
    ///         the vault as fee source of the referrals.
    /// @dev Must be called by the owner of all three. Reverts if the referrals contract does not
    /// point at the same controller.
    function wireReferrals(
        GemoonController controller,
        Vault vault,
        GmoonReferrals referrals
    ) public {
        controller.setReferrals(address(referrals));
        referrals.setVault(address(vault));
        vault.setProtocolRecipient(address(referrals));
        checkReferralsWiring(controller, vault, referrals);
    }
}

/// @notice Upgrades the Referrals proxy to a freshly deployed implementation.
/// @dev Env:
///  - REFERRALS_PROXY_ADDRESS        Referrals proxy (required)
///  - REFERRALS_PROXY_ADMIN_ADDRESS  ProxyAdmin of the Referrals proxy (required)
/// The broadcaster must own the ProxyAdmin. If the new implementation bumps `REFERRALS_VERSION`,
/// `reinitialize` runs atomically with the upgrade. Storage must stay append-only, see
/// `ProxyVaultUpgrade`.
contract ProxyReferralsUpgrade is GemoonDeployBase {
    function run() external {
        address proxy = vm.envAddress("REFERRALS_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("REFERRALS_PROXY_ADMIN_ADDRESS");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        address newImplementation = address(new GmoonReferrals());
        upgradeReferrals(sender, proxy, proxyAdmin, newImplementation);
        vm.stopBroadcast();

        _logProxy("REFERRALS", proxy);
        console.log("REFERRALS VERSION: ", uint256(GmoonReferrals(proxy).getVersion()));
    }

    /// @notice Upgrades `proxy` to `newImplementation`. Must be called by `sender`.
    /// @dev Reverts if the proxy admin or its owner do not match, if the version goes down, or if
    /// owner / pair token / owed total / implementation are not as expected after the upgrade.
    function upgradeReferrals(
        address sender,
        address proxy,
        address proxyAdmin,
        address newImplementation
    ) public {
        _checkProxyAdmin(sender, proxy, proxyAdmin);

        GmoonReferrals referrals = GmoonReferrals(proxy);
        address ownerBefore = referrals.owner();
        address pairTokenBefore = referrals.pairToken();
        uint256 pendingBefore = referrals.totalPending();

        uint64 current = _initializedVersion(proxy);
        uint64 next = GmoonReferrals(newImplementation).getVersion();
        if (next < current) revert VersionDowngrade(current, next);
        bytes memory data =
            next > current ? abi.encodeCall(GmoonReferrals.reinitialize, ()) : bytes("");

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy), newImplementation, data
        );

        if (
            Upgrades.getImplementationAddress(proxy) != newImplementation
                || referrals.owner() != ownerBefore || referrals.pairToken() != pairTokenBefore
                || referrals.totalPending() != pendingBefore
        ) revert StateChanged();
    }
}

/// @notice Moves control of a deployment from the deployer to governance: a TimelockController run
///         by a Safe for everything that can change trading (upgrades, controller settings), the
///         Safe itself for the operational owners (vault, referrals, adapter).
/// @dev Env:
///  - GOVERNANCE_SAFE                Safe: proposer and executor of the timelock, owner of the rest (required)
///  - TIMELOCK_ADDRESS               existing TimelockController to reuse (optional: deploys one)
///  - TIMELOCK_MIN_DELAY             delay of a new timelock in seconds (optional, default 48 hours)
///  - CONTROLLER/VAULT_PROXY_ADDRESS and their *_PROXY_ADMIN_ADDRESS (required)
///  - REFERRALS_PROXY_ADDRESS, REFERRALS_PROXY_ADMIN_ADDRESS, SWAP_ADAPTER (optional: skipped if empty)
/// The broadcaster must own every contract and ProxyAdmin it touches. To the timelock: every
/// ProxyAdmin and the controller (one-step, effective at once). The hook has no owner, nothing to hand
/// over.
/// To the Safe: vault, referrals and adapter (Ownable2Step: the Safe calls `acceptOwnership`).
/// The new timelock has no admin: its roles can only change through its own delayed operations.
contract TransferToGovernance is GemoonDeployBase {
    uint256 public constant DEFAULT_TIMELOCK_DELAY = 48 hours;

    error ZeroAddress();
    /// @dev The Safe has no code on this chain (a typo, an EOA or a Safe of another chain): the
    /// timelock would be run by nobody and the protocol could never be upgraded again.
    error SafeHasNoCode(address safe);
    /// @dev Contract `what` is not owned by the broadcaster.
    error NotOwner(string what, address owner, address sender);

    struct Targets {
        address controller;
        address vault;
        address referrals; // zero = skip
        address adapter; // zero = skip
        address controllerProxyAdmin;
        address vaultProxyAdmin;
        address referralsProxyAdmin; // zero = skip
    }

    function run() external {
        address safe = vm.envAddress("GOVERNANCE_SAFE");
        address existingTimelock = _envAddressOr("TIMELOCK_ADDRESS", address(0));
        uint256 delay = _envUintOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_DELAY);
        Targets memory t = Targets({
            controller: vm.envAddress("CONTROLLER_PROXY_ADDRESS"),
            vault: vm.envAddress("VAULT_PROXY_ADDRESS"),
            referrals: _envAddressOr("REFERRALS_PROXY_ADDRESS", address(0)),
            adapter: _envAddressOr("SWAP_ADAPTER", address(0)),
            controllerProxyAdmin: vm.envAddress("CONTROLLER_PROXY_ADMIN_ADDRESS"),
            vaultProxyAdmin: vm.envAddress("VAULT_PROXY_ADMIN_ADDRESS"),
            referralsProxyAdmin: _envAddressOr("REFERRALS_PROXY_ADMIN_ADDRESS", address(0))
        });

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();
        TimelockController timelock = existingTimelock == address(0)
            ? deployTimelock(safe, delay)
            : TimelockController(payable(existingTimelock));
        transferToGovernance(sender, t, safe, address(timelock));
        vm.stopBroadcast();

        console.log("GOVERNANCE SAFE: ", safe);
        console.log("TIMELOCK: ", address(timelock));
        console.log("TIMELOCK MIN DELAY: ", timelock.getMinDelay());
        console.log("Left to do, by the Safe:");
        console.log("  acceptOwnership() on the vault, referrals and adapter");
    }

    /// @notice Deploys a TimelockController run by `safe`: sole proposer, executor and canceller,
    ///         no admin.
    function deployTimelock(address safe, uint256 delay) public returns (TimelockController) {
        if (safe == address(0)) revert ZeroAddress();
        if (safe.code.length == 0) revert SafeHasNoCode(safe);
        address[] memory members = new address[](1);
        members[0] = safe;
        return new TimelockController(delay, members, members, address(0));
    }

    /// @notice Hands every owner role of `t` to governance, see the contract doc. Must be called by
    ///         `sender`, the current owner of everything it touches.
    function transferToGovernance(address sender, Targets memory t, address safe, address timelock)
        public
    {
        if (safe == address(0) || timelock == address(0)) revert ZeroAddress();
        if (safe.code.length == 0) revert SafeHasNoCode(safe);

        _transferProxyAdmin(sender, t.controller, t.controllerProxyAdmin, timelock);
        _transferProxyAdmin(sender, t.vault, t.vaultProxyAdmin, timelock);
        if (t.referrals != address(0)) {
            _transferProxyAdmin(sender, t.referrals, t.referralsProxyAdmin, timelock);
        }

        _transferOwnable(sender, "CONTROLLER", t.controller, timelock);
        _transferOwnable(sender, "VAULT", t.vault, safe);
        if (t.referrals != address(0)) _transferOwnable(sender, "REFERRALS", t.referrals, safe);
        if (t.adapter != address(0)) _transferOwnable(sender, "SWAP ADAPTER", t.adapter, safe);
    }

    function _transferProxyAdmin(address sender, address proxy, address proxyAdmin, address to) internal {
        _checkProxyAdmin(sender, proxy, proxyAdmin);
        ProxyAdmin(proxyAdmin).transferOwnership(to);
    }

    function _transferOwnable(address sender, string memory what, address target, address to) internal {
        address current = OwnableUpgradeable(target).owner();
        if (current != sender) revert NotOwner(what, current, sender);
        OwnableUpgradeable(target).transferOwnership(to);
    }
}
