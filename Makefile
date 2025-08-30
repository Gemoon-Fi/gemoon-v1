include .env
export
RPC=https://testnet-rpc.monad.xyz

deploy-spin:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir --ffi ./script/FortuneWheelDeploy.sol:FortuneWheelDeploy --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

deploy-lpmanager-proxy:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir --ffi ./script/ProxyLPManagerDeploy.sol:ProxyLPManagerDeploy --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-lpmanager-proxy:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir ./script/ProxyLPManagerDeploy.sol:ProxyLPManagerUpgrade --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

deploy-controller-proxy:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir ./script/ProxyGemoonControllerDeploy.sol:ProxyGemoonControllerDeploy --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

upgrade-controller-proxy:
	@echo PRIVKEY: $(PRIVATE_KEY)
	forge script --via-ir ./script/ProxyGemoonControllerDeploy.sol:ProxyGemoonControllerUpgrade --rpc-url=$(RPC) --private-key=$(PRIVATE_KEY) --broadcast

unit-tests:
	forge test --show-progress -vv