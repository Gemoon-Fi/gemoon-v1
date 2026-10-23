// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {Upgrades} from "@oz-upgrades/Upgrades.sol";
import {Hooks} from "@uniswap-v4-core/libraries/Hooks.sol";
import {DeployGemoon, GemoonDeployBase} from "../script/GemoonDeploy.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {HookManager} from "../src/contracts/hooks/HookManager.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {GmoonReferrals} from "../src/contracts/Referrals.sol";
import {UniswapV3SwapAdapter} from "../src/contracts/adapters/UniswapV3SwapAdapter.sol";

contract FullDeployMockToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}
}

/// @dev Uniswap V3 pool with just what the deployment and `setRoute` read.
contract MockV3Pool {
    uint24 public fee;
    bool public hasHistory = true;

    constructor(uint24 fee_) {
        fee = fee_;
    }

    function setHistory(bool hasHistory_) external {
        hasHistory = hasHistory_;
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory liquidityCumulatives)
    {
        require(hasHistory, "OLD");
        tickCumulatives = new int56[](secondsAgos.length);
        liquidityCumulatives = new uint160[](secondsAgos.length);
    }
}

/// @dev Uniswap V3 factory keyed by the non-USDG token, order of the pair does not matter.
contract MockV3Factory {
    mapping(address token => mapping(uint24 fee => address)) internal s_pools;

    function setPool(address token, uint24 fee, address pool) external {
        s_pools[token][fee] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        address pool = s_pools[tokenB][fee];
        return pool != address(0) ? pool : s_pools[tokenA][fee];
    }
}

/// @notice `DeployGemoon.deployFull` / `run`: all five contracts, reward assets, routes, ownership
/// and the report. See TEST-CASES.md, section DeployGemoonFullTest.
contract DeployGemoonFullTest is Test {
    uint24 constant FEE = 3_000;
    uint16 constant SLIPPAGE = 100;
    uint32 constant WINDOW = 600;

    DeployGemoon script;
    FullDeployMockToken usdg;
    MockV3Factory factory;

    address poolManager = makeAddr("poolManager");
    address positionManager = makeAddr("positionManager");
    address permit2 = makeAddr("permit2");
    address owner = makeAddr("owner");
    address proxyAdminOwner = makeAddr("proxyAdminOwner");

    function setUp() external {
        script = new DeployGemoon();
        usdg = new FullDeployMockToken("USDG");
        factory = new MockV3Factory();
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Asset with a factory pool of `FEE` that has TWAP history.
    function _routable(string memory ticker) internal returns (DeployGemoon.AssetRow memory row) {
        FullDeployMockToken asset = new FullDeployMockToken(ticker);
        MockV3Pool pool = new MockV3Pool(FEE);
        factory.setPool(address(asset), FEE, address(pool));
        row = DeployGemoon.AssetRow({ticker: ticker, asset: address(asset), pool: address(pool)});
    }

    function _params(address owner_, DeployGemoon.AssetRow[] memory rows)
        internal
        view
        returns (DeployGemoon.FullParams memory p)
    {
        p.core = DeployGemoon.Params({
            owner: owner_,
            proxyAdminOwner: proxyAdminOwner,
            poolManager: poolManager,
            positionManager: positionManager,
            permit2: permit2,
            usdg: address(usdg),
            protocolRecipient: address(0),
            feeBips: 125,
            protocolShareBips: 3_333,
            conversionThreshold: 5e6,
            swapAdapter: address(0),
            allowedAssets: new address[](0)
        });
        p.refShareBips = 1_000;
        p.v3Factory = address(factory);
        p.twapWindow = WINDOW;
        p.maxSlippageBps = SLIPPAGE;
        p.assets = rows;
    }

    /// @dev Without a broadcast the script contract is both the caller and the CREATE2 deployer.
    function _deploy(address owner_, DeployGemoon.AssetRow[] memory rows)
        internal
        returns (DeployGemoon.FullDeployment memory)
    {
        return script.deployFull(address(script), address(script), _params(owner_, rows));
    }

    function _oneRow(DeployGemoon.AssetRow memory row)
        internal
        pure
        returns (DeployGemoon.AssetRow[] memory rows)
    {
        rows = new DeployGemoon.AssetRow[](1);
        rows[0] = row;
    }

    // ---------------------------------------------------------------------------------------------
    // Wiring and ownership
    // ---------------------------------------------------------------------------------------------

    function test_DeployFull_Wiring_AllContractsPointAtEachOther() external {
        DeployGemoon.FullDeployment memory d = _deploy(owner, new DeployGemoon.AssetRow[](0));

        script.checkWiring(d.controller, d.hook, d.vault);
        script.checkReferralsWiring(d.controller, d.hook, d.referrals);
        script.checkAdapterWiring(d.vault, d.adapter);

        assertEq(d.hook.protocolRecipient(), address(d.referrals), "referrals get protocol fee");
        assertEq(address(d.controller.referrals()), address(d.referrals), "controller.referrals");
        assertEq(d.vault.swapAdapter(), address(d.adapter), "vault.swapAdapter");
        assertEq(address(d.adapter.i_factory()), address(factory), "adapter.factory");
        assertEq(d.adapter.twapWindow(), WINDOW, "adapter.twapWindow");
        assertEq(d.referrals.refShareBips(), 1_000, "refShareBips");
        assertEq(d.vault.conversionThreshold(), 5e6, "threshold");
        uint160 flags = uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK;
        assertTrue(flags != 0, "hook address carries permission bits");
    }

    function test_DeployFull_Ownership_TwoStepPendingUntilAccepted() external {
        DeployGemoon.FullDeployment memory d = _deploy(owner, new DeployGemoon.AssetRow[](0));

        assertEq(d.controller.owner(), owner, "controller: immediate");
        assertEq(d.hook.owner(), owner, "hook: owner from the constructor");
        assertEq(d.vault.pendingOwner(), owner, "vault pending");
        assertEq(d.referrals.pendingOwner(), owner, "referrals pending");
        assertEq(d.adapter.pendingOwner(), owner, "adapter pending");
        assertEq(d.vault.owner(), address(script), "vault kept by deployer");

        vm.startPrank(owner);
        d.vault.acceptOwnership();
        d.referrals.acceptOwnership();
        d.adapter.acceptOwnership();
        vm.stopPrank();
        assertEq(d.vault.owner(), owner);
        assertEq(d.referrals.owner(), owner);
        assertEq(d.adapter.owner(), owner);

        address[3] memory proxies = [address(d.vault), address(d.controller), address(d.referrals)];
        for (uint256 i; i < proxies.length; ++i) {
            assertEq(
                ProxyAdmin(Upgrades.getAdminAddress(proxies[i])).owner(),
                proxyAdminOwner,
                "proxy admin owner"
            );
        }
        assertEq(Upgrades.getAdminAddress(address(d.hook)), address(0), "hook: no proxy admin");
    }

    function test_DeployFull_OwnerIsDeployer_NothingPending() external {
        DeployGemoon.FullDeployment memory d =
            _deploy(address(script), new DeployGemoon.AssetRow[](0));

        assertEq(d.vault.owner(), address(script));
        assertEq(d.vault.pendingOwner(), address(0));
        assertEq(d.referrals.owner(), address(script));
        assertEq(d.referrals.pendingOwner(), address(0));
        assertEq(d.adapter.owner(), address(script));
        assertEq(d.adapter.pendingOwner(), address(0));
        assertEq(d.controller.owner(), address(script));
    }

    // ---------------------------------------------------------------------------------------------
    // Reward assets
    // ---------------------------------------------------------------------------------------------

    function test_DeployFull_RoutableAssets_AllowedAndRouted() external {
        DeployGemoon.AssetRow[] memory rows = new DeployGemoon.AssetRow[](2);
        rows[0] = _routable("AAPL");
        rows[1] = _routable("TSLA");

        DeployGemoon.FullDeployment memory d = _deploy(owner, rows);

        for (uint256 i; i < rows.length; ++i) {
            assertEq(uint8(d.assets[i].status), uint8(DeployGemoon.AssetStatus.Routed), "status");
            assertEq(d.assets[i].fee, FEE, "fee");
            assertTrue(d.vault.isAssetAllowed(rows[i].asset), "allowed");
            assertEq(d.adapter.routeOf(rows[i].asset).pool, rows[i].pool, "route pool");
            assertEq(d.adapter.routeOf(rows[i].asset).fee, FEE, "route fee");
            assertEq(d.adapter.routeOf(rows[i].asset).maxSlippageBps, SLIPPAGE, "route slippage");
        }
        assertEq(d.vault.allowedAssets().length, 2);
    }

    function test_DeployFull_UnroutableAssets_SkippedWithReason() external {
        DeployGemoon.AssetRow[] memory rows = new DeployGemoon.AssetRow[](5);
        // asset without code
        rows[0] = DeployGemoon.AssetRow("NOCODE", makeAddr("noCode"), address(new MockV3Pool(FEE)));
        // no pool column
        rows[1] =
            DeployGemoon.AssetRow("NOPOOL", address(new FullDeployMockToken("NOPOOL")), address(0));
        // listed pool is not the factory pool
        rows[2] = _routable("WRONG");
        rows[2].pool = address(new MockV3Pool(FEE));
        // factory pool without TWAP history
        rows[3] = _routable("OLD");
        MockV3Pool(rows[3].pool).setHistory(false);
        // the pair token itself
        rows[4] = DeployGemoon.AssetRow("USDG", address(usdg), address(0));

        DeployGemoon.FullDeployment memory d = _deploy(owner, rows);

        DeployGemoon.AssetStatus[5] memory expected = [
            DeployGemoon.AssetStatus.NoCode,
            DeployGemoon.AssetStatus.NoPool,
            DeployGemoon.AssetStatus.NotFactoryPool,
            DeployGemoon.AssetStatus.NoTwapHistory,
            DeployGemoon.AssetStatus.PairToken
        ];
        for (uint256 i; i < rows.length; ++i) {
            assertEq(uint8(d.assets[i].status), uint8(expected[i]), d.assets[i].ticker);
            assertEq(d.adapter.routeOf(rows[i].asset).pool, address(0), "no route");
            assertEq(
                d.vault.isAssetAllowed(rows[i].asset),
                expected[i] == DeployGemoon.AssetStatus.PairToken,
                "only USDG allowed"
            );
        }
    }

    function test_ConfigureAssets_SameRowTwice_SendsNothingNew() external {
        DeployGemoon.AssetRow[] memory rows = _oneRow(_routable("AAPL"));
        DeployGemoon.FullDeployment memory d = _deploy(address(script), rows);

        vm.recordLogs();
        script.configureAssets(d.vault, d.adapter, rows, SLIPPAGE);
        assertEq(vm.getRecordedLogs().length, 0, "no setAssetAllowed / setRoute events");

        // a new slippage re-sets only the route
        script.configureAssets(d.vault, d.adapter, rows, 200);
        assertEq(d.adapter.routeOf(rows[0].asset).maxSlippageBps, 200);
    }

    function test_ConfigureAssets_NotOwner_Revert() external {
        DeployGemoon.AssetRow[] memory rows = _oneRow(_routable("AAPL"));
        DeployGemoon.FullDeployment memory d = _deploy(owner, new DeployGemoon.AssetRow[](0));

        // ownership of the vault left the deployer in this run: only the owner may allow assets
        vm.prank(owner);
        d.vault.acceptOwnership();
        vm.expectRevert();
        script.configureAssets(d.vault, d.adapter, rows, SLIPPAGE);
    }

    function test_CheckAssets_RouteMissing_Revert() external {
        DeployGemoon.AssetRow[] memory rows = _oneRow(_routable("AAPL"));
        DeployGemoon.FullDeployment memory d = _deploy(address(script), rows);

        vm.prank(address(script));
        d.adapter.removeRoute(rows[0].asset);

        vm.expectRevert(
            abi.encodeWithSelector(GemoonDeployBase.WiringMismatch.selector, "route: AAPL")
        );
        script.checkAssets(d.vault, d.adapter, d.assets);
    }

    /// @dev Invariant: after `configureAssets` an asset is allowed iff its row is routable or the
    /// pair token, and has a route iff its row is routable, the route pointing at the listed pool.
    function testFuzz_ConfigureAssets_AllowedIffRoutable(uint256 seed) external {
        DeployGemoon.FullDeployment memory d =
            _deploy(address(script), new DeployGemoon.AssetRow[](0));

        uint256 n = 6;
        DeployGemoon.AssetRow[] memory rows = new DeployGemoon.AssetRow[](n);
        for (uint256 i; i < n; ++i) {
            uint256 kind = (seed >> (i * 8)) % 5;
            rows[i] = _routable(string.concat("A", vm.toString(i)));
            if (kind == 1) rows[i].pool = address(0);
            else if (kind == 2) rows[i].pool = address(new MockV3Pool(FEE));
            else if (kind == 3) MockV3Pool(rows[i].pool).setHistory(false);
            else if (kind == 4) rows[i].asset = makeAddr(string.concat("noCode", vm.toString(i)));
        }

        DeployGemoon.AssetResult[] memory results =
            script.configureAssets(d.vault, d.adapter, rows, SLIPPAGE);
        script.checkAssets(d.vault, d.adapter, results);

        uint256 allowed;
        for (uint256 i; i < n; ++i) {
            bool routable = (seed >> (i * 8)) % 5 == 0;
            assertEq(results[i].status == DeployGemoon.AssetStatus.Routed, routable, "status");
            assertEq(d.vault.isAssetAllowed(rows[i].asset), routable, "allowed iff routable");
            assertEq(
                d.adapter.routeOf(rows[i].asset).pool,
                routable ? rows[i].pool : address(0),
                "route iff routable"
            );
            if (routable) ++allowed;
        }
        assertEq(d.vault.allowedAssets().length, allowed, "allowlist size");
    }

    // ---------------------------------------------------------------------------------------------
    // Asset file
    // ---------------------------------------------------------------------------------------------

    function test_ParseAssets_Csv_SkipsHeaderAndBlankLines() external view {
        string memory csv = string.concat(
            "Ticker,Contract address,Uniswap V3 / USDG pool\r\n",
            "AAPL , 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 , 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D\r\n",
            "\n",
            "AMC,0x05a3d1Cd21d0C88145E82600E62e7E496e0F222B,\n"
        );
        DeployGemoon.AssetRow[] memory rows = script.parseAssets(csv);

        assertEq(rows.length, 2);
        assertEq(rows[0].ticker, "AAPL");
        assertEq(rows[0].asset, 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9);
        assertEq(rows[0].pool, 0xAae0d815EE56e4092a5E5C2911E676Fea50B2d6D);
        assertEq(rows[1].ticker, "AMC");
        assertEq(rows[1].pool, address(0), "empty pool column");
    }

    function test_ParseAssets_RowWithoutAddress_Revert() external {
        vm.expectRevert(abi.encodeWithSelector(DeployGemoon.InvalidAssetRow.selector, 2));
        script.parseAssets("Ticker,Contract address,Pool\nAAPL\n");
    }

    function test_ParseAssets_RepoAssetFile_AllRowsHaveAssetAndPool() external view {
        DeployGemoon.AssetRow[] memory rows =
            script.parseAssets(vm.readFile("tools/scripts/robinhood-assets.csv"));

        assertGt(rows.length, 0);
        for (uint256 i; i < rows.length; ++i) {
            assertTrue(bytes(rows[i].ticker).length != 0, "ticker");
            assertTrue(rows[i].asset != address(0), rows[i].ticker);
            assertTrue(rows[i].pool != address(0), rows[i].ticker);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Report and run
    // ---------------------------------------------------------------------------------------------

    function test_BuildReport_ListsContractsOwnershipAndAssets() external {
        DeployGemoon.AssetRow[] memory rows = new DeployGemoon.AssetRow[](2);
        rows[0] = _routable("AAPL");
        rows[1] = _routable("OLD");
        MockV3Pool(rows[1].pool).setHistory(false);
        DeployGemoon.FullParams memory p = _params(owner, rows);
        DeployGemoon.FullDeployment memory d = script.deployFull(address(script), address(script), p);

        string memory report = script.buildReport(address(script), p, d);

        string[7] memory expected = [
            vm.toString(address(d.vault)),
            vm.toString(address(d.hook)),
            vm.toString(address(d.controller)),
            vm.toString(address(d.referrals)),
            vm.toString(address(d.adapter)),
            "| AAPL | ",
            "SKIPPED: pool has no price history over the TWAP window"
        ];
        for (uint256 i; i < expected.length; ++i) {
            assertTrue(vm.contains(report, expected[i]), expected[i]);
        }
        assertTrue(vm.contains(report, "calls `acceptOwnership()`"), "pending owner to-do");
        assertTrue(vm.contains(report, "Allowed: 1 (routed or USDG), skipped: 1"), "summary");
    }

    function test_Run_FromEnv_DeploysWiresAndWritesReport() external {
        DeployGemoon.AssetRow memory row = _routable("AAPL");
        string memory assetsFile = "deploy-logs/test-run-assets.csv";
        string memory reportFile = "deploy-logs/test-run-report.md";
        vm.createDir("deploy-logs", true);
        vm.writeFile(
            assetsFile,
            string.concat(
                "Ticker,Contract address,Uniswap V3 / USDG pool\n",
                "AAPL,", vm.toString(row.asset), ",", vm.toString(row.pool), "\n"
            )
        );

        vm.setEnv("POOL_MANAGER", vm.toString(poolManager));
        vm.setEnv("POSITION_MANAGER", vm.toString(positionManager));
        vm.setEnv("PERMIT2", vm.toString(permit2));
        vm.setEnv("USDG_ADDRESS", vm.toString(address(usdg)));
        vm.setEnv("VAULT_CONVERSION_THRESHOLD", "5000000");
        vm.setEnv("UNISWAP_V3_FACTORY", vm.toString(address(factory)));
        vm.setEnv("GEMOON_OWNER", vm.toString(owner));
        vm.setEnv("GEMOON_PROXY_ADMIN_OWNER", "");
        vm.setEnv("HOOK_TOTAL_FEE_BIPS", "300");
        vm.setEnv("HOOK_PROTOCOL_SHARE_BIPS", "");
        vm.setEnv("REFERRALS_REF_SHARE_BIPS", "");
        vm.setEnv("ADAPTER_TWAP_WINDOW", "");
        vm.setEnv("ADAPTER_MAX_SLIPPAGE_BPS", "");
        vm.setEnv("VAULT_ALLOWED_ASSETS", vm.toString(address(usdg)));
        vm.setEnv("DEPLOY_ASSETS_FILE", assetsFile);
        vm.setEnv("DEPLOY_REPORT", reportFile);

        script.run();

        (Vault vault, HookManager hook, GemoonController controller) = script.deployed();
        GmoonReferrals referrals = script.deployedReferrals();
        UniswapV3SwapAdapter adapter = script.deployedAdapter();

        script.checkWiring(controller, hook, vault);
        script.checkReferralsWiring(controller, hook, referrals);
        script.checkAdapterWiring(vault, adapter);
        assertEq(hook.TOTAL_FEE_BIPS(), 300);
        assertEq(hook.PROTOCOL_SHARE_BIPS(), 3_333, "default protocol share");
        assertEq(referrals.refShareBips(), 1_000, "default ref share");
        assertEq(adapter.twapWindow(), 600, "default window");
        assertEq(adapter.routeOf(row.asset).maxSlippageBps, 100, "default slippage");
        assertTrue(vault.isAssetAllowed(row.asset), "asset from file");
        assertTrue(vault.isAssetAllowed(address(usdg)), "extra asset from env");
        // empty GEMOON_PROXY_ADMIN_OWNER falls back to GEMOON_OWNER
        assertEq(ProxyAdmin(Upgrades.getAdminAddress(address(controller))).owner(), owner);

        string memory report = vm.readFile(reportFile);
        assertTrue(vm.contains(report, vm.toString(address(adapter))), "report has adapter");
        assertTrue(vm.contains(report, "USDG, credited without a swap"), "report has extra asset");

        vm.setEnv("DEPLOY_REPORT", "");
        vm.removeFile(assetsFile);
        vm.removeFile(reportFile);
    }
}
