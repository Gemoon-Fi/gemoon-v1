#!/bin/bash

cd "$(dirname "$0")/../.."
# shellcheck source=tools/scripts/load-env.sh
source tools/scripts/load-env.sh

for var in CONTROLLER_PROXY_ADDRESS \
           HOOK_PROXY_ADDRESS \
           VAULT_PROXY_ADDRESS;do
	echo -e "Implementation of: \033[32;1m" ${var};
	impl=$(cast implementation --rpc-url="$RPC" ${!var})
	echo -e "\033[1;31m${impl}\033[0m"
done