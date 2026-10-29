// Builds the Gemoon contract graph for contracts-map (../contracts-map): which contracts are deployed and
// which contract points to which through what method.
//
// Usage (from the repository root):
//   ENVIRONMENT=dev node tools/contracts-map/generate.mjs [--out <file>] [--rpc <url>] [--depth <n>] [--exclude <regex>]
//                                                          [--no-abi] [--no-eoa]
//   make contracts-map ENVIRONMENT=dev
//
// Seeds are the addresses of env/<ENVIRONMENT>.mk (protocol contracts, proxy admins, Uniswap, owners). For every
// contract the script reads the EIP-1967 slots (implementation, admin, beacon), owner() and every view function
// without arguments whose result holds an address (ABI from out/, run `forge build` first). Each non-zero address
// found is a link "from -> to via method"; an unknown address becomes a node too and is explored up to --depth hops
// from the seeds (default 1). --exclude drops getters whose name matches the regex (e.g. "allowedAssets" to hide
// the reward assets). --no-abi leaves the ABIs out of the file, --no-eoa the accounts without code. Default output: deploy-logs/contracts-map-<ENVIRONMENT>.json (gitignored).
//
// Read-only: only eth_call / eth_getStorageAt / eth_getCode. The RPC URL is never written to the output.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, getAddress, http, isAddress, parseAbi, zeroAddress } from "viem";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const FORMAT = "contracts-map/links@1";
// Constants like GemoonLens.BURN_DEAD are addresses too, but no part of the graph.
const IGNORED = new Set(["0x000000000000000000000000000000000000dead"]);

const SLOTS = {
	implementation: "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
	admin: "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103",
	beacon: "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50",
};

const PROBE_ABI = parseAbi([
	"function owner() view returns (address)",
	"function implementation() view returns (address)",
	"function symbol() view returns (string)",
]);

// [env variable, node name, artifact "File.sol:Contract" or null]. Order is the naming priority when several
// variables hold the same address (SWAP_ADAPTER and VAULT_SWAP_ADAPTER, for example).
const SEEDS = [
	["CONTROLLER_PROXY_ADDRESS", "GemoonController", "Gemoon.sol:GemoonController"],
	["TOKEN_DEPLOYER_ADDRESS", "TokenDeployer", "TokenDeployer.sol:TokenDeployer"],
	["HOOK_ADDRESS", "HookManager", "HookManager.sol:HookManager"],
	["VAULT_PROXY_ADDRESS", "Vault", "Vault.sol:Vault"],
	["REFERRALS_PROXY_ADDRESS", "GmoonReferrals", "Referrals.sol:GmoonReferrals"],
	["SWAP_ADAPTER", "UniswapV3SwapAdapter", "UniswapV3SwapAdapter.sol:UniswapV3SwapAdapter"],
	["VAULT_SWAP_ADAPTER", "UniswapV3SwapAdapter", "UniswapV3SwapAdapter.sol:UniswapV3SwapAdapter"],
	["LENS_ADDRESS", "GemoonLens", "GemoonLens.sol:GemoonLens"],
	["CONTROLLER_PROXY_ADMIN_ADDRESS", "GemoonController ProxyAdmin", "ProxyAdmin.sol:ProxyAdmin"],
	["VAULT_PROXY_ADMIN_ADDRESS", "Vault ProxyAdmin", "ProxyAdmin.sol:ProxyAdmin"],
	["REFERRALS_PROXY_ADMIN_ADDRESS", "GmoonReferrals ProxyAdmin", "ProxyAdmin.sol:ProxyAdmin"],
	["TIMELOCK_ADDRESS", "TimelockController", "TimelockController.sol:TimelockController"],
	["POOL_MANAGER", "Uniswap V4 PoolManager", "PoolManager.sol:PoolManager"],
	["POSITION_MANAGER", "Uniswap V4 PositionManager", "PositionManager.sol:PositionManager"],
	["PERMIT2", "Permit2", "IAllowanceTransfer.sol:IAllowanceTransfer"],
	["USDG_ADDRESS", "USDG", "IERC20Metadata.sol:IERC20Metadata"],
	["UNISWAP_V3_FACTORY", "Uniswap V3 Factory", "IUniswapV3Factory.sol:IUniswapV3Factory"],
	["GOVERNANCE_SAFE", "Governance Safe", null],
	["GEMOON_OWNER", "Gemoon owner", null],
	["GEMOON_PROXY_ADMIN_OWNER", "ProxyAdmin owner", null],
	["PROTOCOL_FEE_RECIPIENT", "Protocol fee recipient", null],
	["OPERATOR_ADDRESS", "Operator", null],
];

// ------------------------------------------------------------------------------------------------
// Arguments and environment
// ------------------------------------------------------------------------------------------------

function parseArgs(argv) {
	const opts = { out: undefined, rpc: undefined, depth: 1, exclude: undefined, abi: true, eoa: true };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === "--out") opts.out = argv[++i];
		else if (a === "--rpc") opts.rpc = argv[++i];
		else if (a === "--depth") opts.depth = Number(argv[++i]);
		else if (a === "--exclude") opts.exclude = new RegExp(argv[++i]);
		else if (a === "--no-abi") opts.abi = false;
		else if (a === "--no-eoa") opts.eoa = false;
		else fail(`Unknown argument: ${a}`);
	}
	if (!Number.isInteger(opts.depth) || opts.depth < 0) fail("--depth expects a non-negative integer");
	return opts;
}

function fail(message) {
	console.error(message);
	process.exit(1);
}

/** KEY=VALUE lines of env/<ENVIRONMENT>.mk; variables already in the process environment win (make exports them). */
function loadEnv() {
	const env = process.env.ENVIRONMENT;
	if (env !== "dev" && env !== "prod") fail("ENVIRONMENT is not set: ENVIRONMENT=dev|prod");
	const file = resolve(ROOT, `env/${env}.mk`);
	if (!existsSync(file)) fail(`No env/${env}.mk`);
	const vars = {};
	for (const line of readFileSync(file, "utf8").split("\n")) {
		const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
		if (m) vars[m[1]] = m[2].trim().replace(/^["']|["']$/g, "");
	}
	for (const key of Object.keys(vars)) if (process.env[key] !== undefined) vars[key] = process.env[key];
	return { env, vars };
}

function loadAbi(artifact) {
	if (!artifact) return [];
	const [file, name] = artifact.split(":");
	const path = resolve(ROOT, "out", file, `${name}.json`);
	if (!existsSync(path)) {
		console.warn(`  no artifact out/${file}/${name}.json, run forge build; ${name} goes without ABI`);
		return [];
	}
	return JSON.parse(readFileSync(path, "utf8")).abi;
}

// ------------------------------------------------------------------------------------------------
// ABI helpers
// ------------------------------------------------------------------------------------------------

const hasAddress = (p) => p.type.startsWith("address") || (p.components ?? []).some(hasAddress);

function canonicalType(p) {
	return p.type.startsWith("tuple") ? `(${p.components.map(canonicalType).join(",")})${p.type.slice(5)}` : p.type;
}

const signature = (fn) => `${fn.name}(${fn.inputs.map(canonicalType).join(",")})`;

/** View functions without arguments whose result can contain an address. */
function addressGetters(abi) {
	return abi.filter(
		(i) =>
			i.type === "function" &&
			(i.stateMutability === "view" || i.stateMutability === "pure") &&
			i.inputs.length === 0 &&
			i.outputs.some(hasAddress),
	);
}

/** Every non-zero address inside a call result with its path, same rules as contracts-map's collectAddresses. */
function collectAddresses(fn, value) {
	const out = [];
	const walk = (v, path) => {
		if (typeof v === "string") {
			if (isAddress(v, { strict: false }) && v.toLowerCase() !== zeroAddress) out.push({ address: v.toLowerCase(), path });
			return;
		}
		if (Array.isArray(v)) return v.forEach((x, i) => walk(x, `${path}[${i}]`));
		if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) walk(x, path ? `${path}.${k}` : k);
	};
	if (fn.outputs.length > 1 && Array.isArray(value)) fn.outputs.forEach((o, i) => walk(value[i], o.name || String(i)));
	else walk(value, "");
	return out;
}

const slotAddress = (word) => {
	if (!word || /^0x0*$/.test(word)) return null;
	const a = `0x${word.slice(-40)}`.toLowerCase();
	return a === zeroAddress ? null : a;
};

// ------------------------------------------------------------------------------------------------
// Discovery
// ------------------------------------------------------------------------------------------------

async function main() {
	const opts = parseArgs(process.argv.slice(2));
	const { env, vars } = loadEnv();
	const rpc = opts.rpc || vars.RPC;
	if (!rpc) fail(`RPC is empty in env/${env}.mk (or pass --rpc)`);

	const client = createPublicClient({ transport: http(rpc, { batch: true, timeout: 30_000 }) });
	const [chainId, block] = await Promise.all([client.getChainId(), client.getBlockNumber()]);
	console.log(`Environment ${env}, chain ${chainId}, block ${block}`);

	/** address(lowercase) -> node */
	const nodes = new Map();
	const links = [];
	const linkKeys = new Set();

	const addNode = (address, init) => {
		const node = { address: getAddress(address), name: "", kind: "contract", source: "discovered", artifact: null, abi: [], depth: 0, ...init };
		nodes.set(address.toLowerCase(), node);
		return node;
	};

	const addLink = (from, to, method, sig, path, kind) => {
		const key = `${from}|${to}|${sig}|${path}`;
		if (from === to || linkKeys.has(key)) return;
		linkKeys.add(key);
		links.push({ from: getAddress(from), to: getAddress(to), method, signature: sig, path, kind });
	};

	for (const [envVar, name, artifact] of SEEDS) {
		const raw = vars[envVar];
		if (!raw) continue;
		if (!isAddress(raw, { strict: false })) {
			console.warn(`  ${envVar}=${raw} is not an address, skipped`);
			continue;
		}
		const existing = nodes.get(raw.toLowerCase());
		if (existing) {
			existing.aliases.push(envVar);
			continue;
		}
		addNode(raw, { name, source: `env:${envVar}`, aliases: [], artifact, abi: loadAbi(artifact) });
	}
	if (!nodes.size) fail(`No addresses found in env/${env}.mk`);

	// Breadth-first: every pass explores the nodes added by the previous one.
	let frontier = [...nodes.values()];
	for (let depth = 0; frontier.length; depth++) {
		await Promise.all(frontier.map((n) => fillCode(client, n)));
		const found = (await Promise.all(frontier.map((n) => explore(client, n, opts.exclude)))).flat();

		const next = [];
		for (const f of found) {
			if (IGNORED.has(f.to)) continue;
			let target = nodes.get(f.to);
			if (!target) {
				if (depth + 1 > opts.depth) continue;
				target = addNode(f.to, { depth: depth + 1, aliases: [], via: f });
				next.push(target);
			}
			addLink(f.from, f.to, f.method, f.signature, f.path, f.kind);
		}
		frontier = next;
	}

	// Implementations behind a proxy get the proxy's ABI and name; other discovered nodes a best-effort name.
	for (const n of nodes.values()) {
		if (n.name) continue;
		const via = n.via;
		const parent = via && nodes.get(via.from.toLowerCase());
		if (via?.kind === "slot" && via.method === "implementation" && parent) {
			n.name = `${parent.name} implementation`;
			n.kind = "implementation";
			n.artifact = parent.artifact;
			n.abi = parent.abi;
		} else if (via?.kind === "slot" && via.method === "admin" && parent) {
			n.name = `${parent.name} ProxyAdmin`;
			n.artifact = "ProxyAdmin.sol:ProxyAdmin";
			n.abi = loadAbi(n.artifact);
		} else if (n.kind === "eoa") {
			n.name = parent ? `${parent.name}.${via.method}` : "EOA";
		} else {
			const symbol = await client.readContract({ address: n.address, abi: PROBE_ABI, functionName: "symbol" }).catch(() => null);
			n.name = symbol ? `${symbol} token` : parent ? `${parent.name}.${via.method}` : "Unknown";
		}
	}
	for (const n of nodes.values()) if (n.isProxy && n.kind === "contract") n.kind = "proxy";

	let contracts = [...nodes.values()];
	let outLinks = links;
	if (!opts.eoa) {
		const eoas = new Set(contracts.filter((n) => n.kind === "eoa").map((n) => n.address));
		contracts = contracts.filter((n) => !eoas.has(n.address));
		outLinks = links.filter((l) => !eoas.has(l.from) && !eoas.has(l.to));
	}

	const result = {
		format: FORMAT,
		environment: env,
		chainId,
		block: Number(block),
		generatedAt: new Date().toISOString(),
		contracts: contracts.map((n) => ({
			address: n.address,
			name: n.name,
			kind: n.kind,
			source: n.source,
			...(n.aliases.length ? { aliases: n.aliases } : {}),
			...(n.artifact ? { artifact: n.artifact } : {}),
			...(opts.abi && n.abi.length ? { abi: n.abi } : {}),
		})),
		links: outLinks,
	};

	const out = resolve(ROOT, opts.out ?? `deploy-logs/contracts-map-${env}.json`);
	mkdirSync(dirname(out), { recursive: true });
	writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);

	const name = (a) => nodes.get(a.toLowerCase())?.name ?? a;
	for (const l of outLinks) console.log(`  ${name(l.from)} -> ${name(l.to)}  via ${l.method}${l.path ? `.${l.path}` : ""}`);
	console.log(`${result.contracts.length} contracts, ${outLinks.length} links -> ${out}`);
}

async function fillCode(client, node) {
	const code = await client.getCode({ address: node.address });
	if (!code || code === "0x") node.kind = "eoa";
	// EIP-7702 delegated EOA: code is 0xef0100 || address, still an account of a person.
	else if (code.toLowerCase().startsWith("0xef0100")) node.kind = "eoa";
}

/** Links from one node: proxy slots, owner(), and every address getter of its ABI (or of its implementation). */
async function explore(client, node, exclude) {
	if (node.kind === "eoa") return [];
	const from = node.address.toLowerCase();
	const found = [];

	const slots = await Promise.all(
		Object.entries(SLOTS).map(async ([method, slot]) => [method, slotAddress(await client.getStorageAt({ address: node.address, slot }))]),
	);
	for (const [method, to] of slots) {
		if (!to) continue;
		found.push({ from, to, method, signature: `eip1967.${method}`, path: "", kind: "slot" });
		if (method === "implementation" || method === "beacon") node.isProxy = true;
	}

	const getters = addressGetters(node.abi).filter((fn) => !exclude?.test(fn.name));
	const calls = getters.map(async (fn) => {
		try {
			const value = await client.readContract({ address: node.address, abi: [fn], functionName: fn.name });
			return collectAddresses(fn, value).map((a) => ({ from, to: a.address, method: fn.name, signature: signature(fn), path: a.path, kind: "call" }));
		} catch {
			// a getter that reverts (not initialised, wrong ABI for this address) is no link
			return [];
		}
	});
	// owner() is read even when the ABI does not have it, as contracts-map does for its base fields.
	if (!getters.some((fn) => fn.name === "owner")) {
		calls.push(
			client
				.readContract({ address: node.address, abi: PROBE_ABI, functionName: "owner" })
				.then((v) => (v.toLowerCase() === zeroAddress ? [] : [{ from, to: v.toLowerCase(), method: "owner", signature: "owner()", path: "", kind: "call" }]))
				.catch(() => []),
		);
	}
	for (const list of await Promise.all(calls)) found.push(...list);
	return found;
}

main().catch((e) => fail(e?.shortMessage || e?.message || String(e)));
