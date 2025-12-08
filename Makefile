include .env
export RPC=https://magical-proud-owl.monad-mainnet.quiknode.pro/bd6875c9855ba376e6194795d2dfe8c439c7d222/

deploy-spin:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir --ffi ./script/FortuneWheelDeploy.sol:FortuneWheelDeploy --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

deploy-gemoon:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir --ffi ./script/GemoonDeploy.sol:DeployGemoon --slow --legacy -vvvv --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

configure-contracts:
	@echo PRIVKEY: $(PRIVATE_KEY)
	cd ./script && node configure.js

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