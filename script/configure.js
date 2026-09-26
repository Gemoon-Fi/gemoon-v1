import { config } from "dotenv";
import {
	createWalletClient,
	http,
	keccak256
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { waitForTransactionReceipt } from "viem/actions";
import { monad } from "wagmi/chains";
import controllerAbi from "../out/Gemoon.sol/GemoonController.json" assert { type: "json" };

const configOut = config({ path: "../.env" })
const CONTROLLER_ROLE = keccak256(new TextEncoder().encode("CONTROLLER_ROLE"))
const ADMIN_ROLE = '0x0000000000000000000000000000000000000000000000000000000000000000'
const multiSigAddress = configOut.parsed?.MULTISIG_OWNER_ADDRESS || "not found"
if (multiSigAddress === "not found") {
	console.error("MULTISIG_OWNER_ADDRESS not found in .env file, exiting")
	process.exit(1)
}
console.log("Controller Role:", CONTROLLER_ROLE)

async function waitAndLog(tx) {
	try {
		const txRes = await waitForTransactionReceipt(walletClient, {
			hash: tx,
		})
		console.log("TX status: ", txRes?.status)
	} catch (error) {
		console.error("Error waiting for transaction receipt:", error)
	}
}


const deployProdAcc = privateKeyToAccount(configOut.parsed.OPERATOR_PRIVATE_KEY)
console.info("Using account:", deployProdAcc.address)
const proxyAdminAcc = privateKeyToAccount(configOut.parsed.PRIVATE_KEY)

const walletClient = createWalletClient({
	chain: monad,
	transport: http(),
	account: deployProdAcc,
});

const proxyAdminClient = createWalletClient({
	chain: monad,
	transport: http(),
	account: proxyAdminAcc,
});

// -------- configure contracts --------




try {
	const transferControllerOwnershipTx = await walletClient.writeContract({
		abi: controllerAbi.abi,
		address: configOut.parsed?.CONTROLLER_PROXY_ADDRESS,
		functionName: "transferOwnership",
		args: [
			multiSigAddress
		]
	})

	console.log("Transfer controller ownership tx: ", transferControllerOwnershipTx)
	await waitAndLog(transferControllerOwnershipTx)
} catch (error) {
	console.error("Error transferring controller ownership:", error?.shortMessage + " : " + error?.reason || error)
}

try {
	const transferControllerAdminOwnershipTx = await proxyAdminClient.writeContract({
		abi: controllerAbi.abi,
		address: configOut.parsed?.CONTROLLER_PROXY_ADMIN_ADDRESS,
		functionName: "transferOwnership",
		args: [
			multiSigAddress
		]
	})

	console.log("Transfer controller admin ownership tx: ", transferControllerAdminOwnershipTx)
	await waitAndLog(transferControllerAdminOwnershipTx)
} catch (error) {
	console.error("Error transferring controller admin ownership:", error?.shortMessage + " : " + error?.reason || error)
}

console.log("Configuration script execution completed.")