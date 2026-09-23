// Checks whether an address is a contract or an EOA.
//
// Usage:
//   node index.js <address> [rpcUrl] [--out <file>]
//
// If the address is a contract, its runtime bytecode is printed (or saved to --out).
// For EIP-1967 proxies the implementation address and its bytecode are fetched too.
//
// RPC resolution order: CLI arg -> RPC_URL from .env (this folder or project root) -> http://127.0.0.1:8545 (local anvil)
import { config } from "dotenv";
import { createPublicClient, getAddress, http, isAddress } from "viem";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const envOut = config({ path: [resolve(__dirname, ".env"), resolve(__dirname, "../../.env")], quiet: true });

// EIP-7702: EOA with a delegation designator has code 0xef0100 || <20-byte address>
const EIP7702_PREFIX = "0xef0100";

// EIP-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)
const EIP1967_IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

const args = process.argv.slice(2);
const outIdx = args.indexOf("--out");
const outFile = outIdx !== -1 ? args[outIdx + 1] : undefined;
if (outIdx !== -1) args.splice(outIdx, 2);
const [rawAddress, cliRpc] = args;

if (!rawAddress || !isAddress(rawAddress, { strict: false }) || (outIdx !== -1 && !outFile)) {
	console.error("Usage: node index.js <address> [rpcUrl] [--out <file>]");
	process.exit(1);
}

const rpcUrl = cliRpc || envOut.parsed?.RPC_URL || "http://127.0.0.1:8545";
const address = getAddress(rawAddress);

const client = createPublicClient({ transport: http(rpcUrl) });

try {
	const [chainId, code, nonce, balance] = await Promise.all([
		client.getChainId(),
		client.getCode({ address }),
		client.getTransactionCount({ address }),
		client.getBalance({ address }),
	]);

	const hasCode = code !== undefined && code !== "0x";
	let type;
	if (!hasCode) {
		type = "EOA";
	} else if (code.toLowerCase().startsWith(EIP7702_PREFIX) && code.length === 2 + 23 * 2) {
		type = `EOA (EIP-7702 delegated to ${getAddress("0x" + code.slice(8))})`;
	} else {
		type = "CONTRACT";
	}

	console.log(`Chain ID : ${chainId}`);
	console.log(`Address  : ${address}`);
	console.log(`Type     : ${type}`);
	console.log(`Code size: ${hasCode ? (code.length - 2) / 2 : 0} bytes`);
	console.log(`Nonce    : ${nonce}`);
	console.log(`Balance  : ${balance} wei`);

	if (!hasCode && nonce === 0) {
		console.log("Note: no code and nonce 0 — could also be a not-yet-deployed contract (CREATE2) or an unused address.");
	}

	if (type === "CONTRACT") {
		const result = { address, chainId, bytecode: code };

		const implSlot = await client.getStorageAt({ address, slot: EIP1967_IMPL_SLOT });
		if (implSlot && BigInt(implSlot) !== 0n) {
			const implementation = getAddress("0x" + implSlot.slice(-40));
			const implCode = await client.getCode({ address: implementation });
			console.log(`Proxy    : EIP-1967, implementation ${implementation} (${implCode ? (implCode.length - 2) / 2 : 0} bytes)`);
			result.implementation = { address: implementation, bytecode: implCode ?? "0x" };
		}

		if (outFile) {
			writeFileSync(outFile, JSON.stringify(result, null, 2));
			console.log(`Bytecode saved to ${outFile}`);
		} else {
			console.log(`\nBytecode:\n${code}`);
			if (result.implementation) {
				console.log(`\nImplementation bytecode:\n${result.implementation.bytecode}`);
			}
		}
	}
} catch (error) {
	console.error(`RPC error (${rpcUrl}):`, error.shortMessage || error.message);
	process.exit(1);
}
