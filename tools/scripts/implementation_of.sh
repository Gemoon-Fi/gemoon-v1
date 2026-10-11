#!/bin/bash

source .env

for var in CONTROLLER_PROXY_ADDRESS \
           HOOK_PROXY_ADDRESS \
           VAULT_PROXY_ADDRESS;do
	echo -e "Implementation of: \033[32;1m" ${var};
	impl=$(cast implementation --rpc-url=https://rpc-testnet.gmoon.xyz ${!var})
	echo -e "\033[1;31m${impl}\033[0m"
done