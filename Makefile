include .env
export RPC ?= "https://rpc-testnet.gmoon.xyz"
FORK_RPC ?= "https://ethereum-sepolia-rpc.publicnode.com"

# Vault + HookManager + GemoonController, wired, in one run.
deploy-gemoon:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployGemoon --slow --legacy -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

# Same as deploy-gemoon without --broadcast: simulation against $(RPC), nothing is sent.
simulate-gemoon:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployGemoon -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY)

deploy-vault:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployVault --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

deploy-swap-adapter:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployUniswapV3SwapAdapter --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

set-swap-adapter:
	cast send $(VAULT_PROXY_ADDRESS) "setSwapAdapter(address)" $(SWAP_ADAPTER) --rpc-url $(RPC) --private-key $(PRIVATE_KEY)

upgrade-vault-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyVaultUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-hook-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyHookUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-controller-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyGemoonControllerUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

# Vault allowlist of reward assets: make set-asset-allowed VAULT=0x.. ASSET=0x.. [ALLOWED=false]
# or a list: make set-asset-allowed VAULT=0x.. FILE=tools/scripts/robinhood-assets.csv [DRY_RUN=1]
set-asset-allowed:
	bash ./tools/scripts/set-asset-allowed.sh $(VAULT) $(if $(FILE),--file $(abspath $(FILE)),$(ASSET) $(ALLOWED)) $(if $(DRY_RUN),--dry-run)

# Swap route on the adapter: make set-route ADAPTER=0x.. ASSET=0x.. [FEE=3000] [SLIPPAGE=100]
# or a list: make set-route ADAPTER=0x.. FILE=tools/scripts/robinhood-assets.csv [SLIPPAGE=100] [DRY_RUN=1]
set-route:
	bash ./tools/scripts/set-route.sh $(ADAPTER) $(if $(FILE),--file $(abspath $(FILE)) $(if $(SLIPPAGE),--slippage $(SLIPPAGE)) $(if $(DRY_RUN),--dry-run),$(ASSET) $(FEE) $(SLIPPAGE))

# Read-only: checks that controller, hook and vault point at each other.
verify-wiring:
	forge script --via-ir ./script/GemoonDeploy.sol:VerifyWiring -vvvv --rpc-url=$(RPC)

unit-tests:
	forge test --show-progress -vv --no-match-path "test/fork/*"

# Fork tests against the devnet, need DEVNET_RPC (see .env.example).
devnet-tests:
	DEVNET_RPC=$(DEVNET_RPC) DEVNET_BLOCK=$(DEVNET_BLOCK) OPERATOR_ADDRESS=$(OPERATOR_ADDRESS) forge test --match-path "test/fork/*" -vv

full-tests: unit-tests devnet-tests

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