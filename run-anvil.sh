#!/bin/bash

RPC_URL="https://ethereum-sepolia-rpc.publicnode.com"
BLOCK=${1:-7259602}

if [ $(which anvil) -eq 1 ]; then
  echo "Anvil is not installed."
  exit 1;
fi

echo "RUNNING ANVIL FORK WITH RPC_URL: ${RPC_URL} AND BLOCK: ${BLOCK}"

anvil --fork-url ${RPC_URL} --fork-block-number ${BLOCK} --chain-id 1 --balance 100000000