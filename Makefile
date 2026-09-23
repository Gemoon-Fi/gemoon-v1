include .env
export RPC=https://ethereum-sepolia-rpc.publicnode.com

deploy-gemoon:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir --ffi ./script/GemoonDeploy.sol:DeployGemoon --slow --legacy -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

configure-contracts:
	@echo PRIVKEY: $(PRIVATE_KEY)
	cd ./script && node configure.js

deploy-vault:
	forge script --via-ir ./script/GemoonDeploy.sol:DeployVault --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-vault-proxy:
	forge script --via-ir ./script/GemoonDeploy.sol:ProxyVaultUpgrade --slow -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-lpmanager-proxy:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir ./script/ProxyLPManagerDeploy.sol:ProxyLPManagerUpgrade --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-controller-proxy:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir ./script/ProxyGemoonControllerDeploy.sol:ProxyGemoonControllerUpgrade --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

verify-owners:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir ./script/ProxyGemoonControllerDeploy.sol:VerifyOwners --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

unit-tests:
	forge test --show-progress -vv

clean:
	forge clean
	rm -rf out
	rm -rf cache

compile:
	forge build --force