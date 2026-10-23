# Contract verification on Blockscout through the PRO API (one endpoint for every chain, the chain is
# picked by chain_id) and standard JSON input for manual verification in the explorer UI.
# Separate from the main Makefile:
#   make -f verify.mk verify-hook ENVIRONMENT=prod          # implementation + proxy
#   make -f verify.mk standard-json-hook ENVIRONMENT=prod   # files into $(STANDARD_JSON_DIR)
# Run from the commit the contracts were deployed from: the sources must match the deployed code.
#
# From env/<ENVIRONMENT>.mk: RPC, BLOCKSCOUT_API_KEY (verify-* only), POOL_MANAGER, USDG_ADDRESS,
# HOOK_PROXY_ADDRESS, GEMOON_OWNER, GEMOON_PROXY_ADMIN_OWNER, REFERRALS_PROXY_ADDRESS,
# VAULT_PROXY_ADDRESS, CONTROLLER_PROXY_ADDRESS, HOOK_TOTAL_FEE_BIPS, HOOK_PROTOCOL_SHARE_BIPS.

ifndef ENVIRONMENT
$(error ENVIRONMENT is not set: make -f verify.mk <target> ENVIRONMENT=dev|prod)
endif
ifeq ($(filter $(ENVIRONMENT),dev prod),)
$(error Unknown ENVIRONMENT=$(ENVIRONMENT), expected dev or prod)
endif
ENV_FILE := env/$(ENVIRONMENT).mk
ifeq ($(wildcard $(ENV_FILE)),)
$(error No $(ENV_FILE))
endif
include $(ENV_FILE)
export ENVIRONMENT

# Shell expressions below ($$(...)) run when the recipe starts, not when the file is read.
CHAIN_ID ?= $$(cast chain-id --rpc-url $(RPC))
STANDARD_JSON_DIR ?= deploy-logs/standard-json

# Recipes carrying the API key start with @, so make does not print the key.
VERIFIER_FLAGS = --chain-id $(CHAIN_ID) \
	--verifier blockscout \
	--verifier-url "https://api.blockscout.com/v2/api?chain_id=$(CHAIN_ID)&apikey=$(BLOCKSCOUT_API_KEY)" \
	--etherscan-api-key "$(BLOCKSCOUT_API_KEY)" \
	--watch

HOOK_CONTRACT := src/contracts/hooks/HookManager.sol:HookManager
PROXY_CONTRACT := lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy

# Implementation currently behind the hook proxy.
HOOK_IMPL ?= $$(cast implementation $(HOOK_PROXY_ADDRESS) --rpc-url $(RPC))
# HookManager(poolManager, pairToken)
HOOK_IMPL_ARGS = $$(cast abi-encode "constructor(address,address)" $(POOL_MANAGER) $(USDG_ADDRESS))
# TransparentUpgradeableProxy(implementation, ProxyAdmin owner, initialize calldata), rebuilt the way
# DeployGemoon built it. After an upgrade the proxy still holds the args of its creation: pass
# HOOK_PROXY_IMPL=<first implementation>, and the env values must be the ones of the deployment.
HOOK_PROXY_IMPL ?= $(HOOK_IMPL)
HOOK_INIT_DATA = $$(cast calldata "initialize(address,address,address,address,uint256,uint256)" \
	$(GEMOON_OWNER) $(REFERRALS_PROXY_ADDRESS) $(VAULT_PROXY_ADDRESS) $(CONTROLLER_PROXY_ADDRESS) \
	$(HOOK_TOTAL_FEE_BIPS) $(HOOK_PROTOCOL_SHARE_BIPS))
HOOK_PROXY_ARGS = $$(cast abi-encode "constructor(address,address,bytes)" $(HOOK_PROXY_IMPL) \
	$(GEMOON_PROXY_ADMIN_OWNER) $(HOOK_INIT_DATA))

.PHONY: check-api-key verify-hook verify-hook-impl verify-hook-proxy verify-hook-impl-sourcify \
	verify-tokens-sourcify \
	standard-json-hook standard-json-hook-impl standard-json-hook-proxy

check-api-key:
	@[ -n "$(BLOCKSCOUT_API_KEY)" ] || { echo "BLOCKSCOUT_API_KEY is empty in $(ENV_FILE)" >&2; exit 1; }

# ---- Verification -------------------------------------------------------------------------------

verify-hook: verify-hook-impl verify-hook-proxy

verify-hook-impl: check-api-key
	@echo "Verifying HookManager implementation $(HOOK_IMPL)"
	@forge verify-contract $(HOOK_IMPL) $(HOOK_CONTRACT) --constructor-args $(HOOK_IMPL_ARGS) $(VERIFIER_FLAGS)

verify-hook-proxy: check-api-key
	@echo "Verifying HookManager proxy $(HOOK_PROXY_ADDRESS)"
	@forge verify-contract $(HOOK_PROXY_ADDRESS) $(PROXY_CONTRACT) --constructor-args $(HOOK_PROXY_ARGS) $(VERIFIER_FLAGS)

# Fallback when the Blockscout API keeps answering "Unable to verify": Sourcify API v2 with the
# standard JSON input (no key, constructor args are read from the creation tx). Blockscout shows
# Sourcify-verified sources. `forge --verifier sourcify` is not used: it fails on the v2 responses.
SOURCIFY_URL ?= https://sourcify.dev/server
SOLC_VERSION ?= 0.8.26+commit.8a97fa7a

# curl -q skips ~/.curlrc, whose extra output would break the JSON. 409 already_verified is a success.
verify-hook-impl-sourcify: standard-json-hook-impl
	@body=$$(jq -n --slurpfile s $(STANDARD_JSON_DIR)/HookManager.json \
		'{stdJsonInput: $$s[0], compilerVersion: "$(SOLC_VERSION)", contractIdentifier: "$(HOOK_CONTRACT)"}' \
		| curl -q -s -X POST -H 'content-type: application/json' --data @- \
			"$(SOURCIFY_URL)/v2/verify/$(CHAIN_ID)/$(HOOK_IMPL)"); \
	id=$$(jq -r '.verificationId // empty' <<<"$$body"); \
	code=$$(jq -r '.customCode // empty' <<<"$$body"); \
	if [ -n "$$id" ]; then echo "Sourcify job $$id, status: $(SOURCIFY_URL)/v2/verify/$$id"; \
	elif [ "$$code" = already_verified ]; then echo "Already verified: $$(jq -r .message <<<"$$body")"; \
	else echo "Sourcify error: $$body" >&2; exit 1; fi

# Every Meme token of the controller on Sourcify, one standard JSON input for all, sources at
# SOURCE_REF (default HEAD). Rerunnable: already verified tokens are skipped.
verify-tokens-sourcify: check-api-key
	@bash ./tools/scripts/verify-tokens-sourcify.sh

# ---- Standard JSON input (nothing is sent) ------------------------------------------------------

standard-json-hook: standard-json-hook-impl standard-json-hook-proxy

standard-json-hook-impl:
	@mkdir -p $(STANDARD_JSON_DIR)
	@forge verify-contract --show-standard-json-input $(HOOK_IMPL) $(HOOK_CONTRACT) \
		> $(STANDARD_JSON_DIR)/HookManager.json
	@echo "$(STANDARD_JSON_DIR)/HookManager.json"
	@echo "  address:          $(HOOK_IMPL)"
	@echo "  contract:         $(HOOK_CONTRACT)"
	@echo "  constructor args: $(HOOK_IMPL_ARGS)"

standard-json-hook-proxy:
	@mkdir -p $(STANDARD_JSON_DIR)
	@forge verify-contract --show-standard-json-input $(HOOK_PROXY_ADDRESS) $(PROXY_CONTRACT) \
		> $(STANDARD_JSON_DIR)/HookManagerProxy.json
	@echo "$(STANDARD_JSON_DIR)/HookManagerProxy.json"
	@echo "  address:          $(HOOK_PROXY_ADDRESS)"
	@echo "  contract:         $(PROXY_CONTRACT)"
	@echo "  constructor args: $(HOOK_PROXY_ARGS)"
