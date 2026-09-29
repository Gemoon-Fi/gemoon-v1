include .env
export RPC ?= "https://anvil.devinside.tech"
FORK_RPC ?= "https://ethereum-sepolia-rpc.publicnode.com"

# Vault + HookManager + GemoonController, wired, in one run.
deploy-gemoon:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployGemoon --slow --legacy -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

deploy-vault:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployVault --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-vault-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyVaultUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-hook-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyHookUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-controller-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyGemoonControllerUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

# Read-only: checks that controller, hook and vault point at each other.
verify-wiring:
	forge script --via-ir ./script/GemoonDeploy.sol:VerifyWiring -vvvv --rpc-url=$(RPC)

unit-tests:
	forge test --show-progress -vv --no-match-path "test/fork/*"

# Fork tests against the devnet, need DEVNET_RPC (see .env.example).
devnet-tests:
	DEVNET_RPC=$(DEVNET_RPC) DEVNET_BLOCK=$(DEVNET_BLOCK) forge test --match-path "test/fork/*" -vv

clean:
	forge clean
	rm -rf out
	rm -rf cache

compile:
	forge build --force

run-evm:
	anvil --fork-url $(FORK_RPC) --fork-block-number 11766637 --chain-id 1 --balance 100000000

prepare-abi:
	bash ./prepare-abi.sh