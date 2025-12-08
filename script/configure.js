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
import lpManagerAbi from "../out/LPManager.sol/LPManager.json" assert { type: "json" };

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
	const addStrategyTx = await walletClient.writeContract({
		abi: controllerAbi.abi,
		address: configOut.parsed?.CONTROLLER_PROXY_ADDRESS,
		functionName: "addDeployStrategyInstance",
		args: [
			"UNISWAP_POSITION_CREATOR",
			configOut.parsed?.DEPLOY_STRATEGY_ADDRESS
		]
	})
	console.log("Adding strategy, tx hash:", addStrategyTx)
	await waitAndLog(addStrategyTx)
} catch (error) {
	console.error("Error adding deploy strategy:", error?.shortMessage + " : " + error?.reason || error)
}


try {
	const grantRoleTx = await walletClient.writeContract({
		abi: lpManagerAbi.abi,
		address: configOut.parsed?.LP_MANAGER_PROXY_ADDRESS,
		functionName: "grantRole",
		args: [
			CONTROLLER_ROLE,
			configOut.parsed?.CONTROLLER_PROXY_ADDRESS
		]
	})

	console.log("Adding controller role to controller tx: ", grantRoleTx)
	await waitAndLog(grantRoleTx)
} catch (error) {
	console.error("Error granting controller role to controller:", error?.shortMessage + " : " + error?.reason || error)
}


try {
	const grantAdminRoleToMultisig = await walletClient.writeContract({
		abi: lpManagerAbi.abi,
		address: configOut.parsed?.LP_MANAGER_PROXY_ADDRESS,
		functionName: "grantRole",
		args: [
			ADMIN_ROLE,
			multiSigAddress
		]
	})
	console.log("Adding admin role to multisig tx: ", grantAdminRoleToMultisig)
	await waitAndLog(grantAdminRoleToMultisig)
} catch (error) {
	console.error("Error granting admin role to multisig:", error?.shortMessage + " : " + error?.reason || error)
}



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

try {
	const transferLpManagerAdminOwnershipTx = await proxyAdminClient.writeContract({
		abi: controllerAbi.abi,
		address: configOut.parsed?.LP_MANAGER_PROXY_ADMIN_ADDRESS,
		functionName: "transferOwnership",
		args: [
			multiSigAddress
		]
	})

	console.log("Transfer lp manager admin ownership tx: ", transferLpManagerAdminOwnershipTx)
	await waitAndLog(transferLpManagerAdminOwnershipTx)
} catch (error) {
	console.error("Error transferring lp manager admin ownership:", error?.shortMessage + " : " + error?.reason || error)
}

console.log("Configuration script execution completed.")