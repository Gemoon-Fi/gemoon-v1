#!/bin/bash

interfaces=$(ls ./src/contracts/interfaces);

for i in ${interfaces}; do
	contract_dir=$(find ./out -name "${i}" -type d)
	abi_json=$(ls ${contract_dir})
	full_path=${contract_dir}/${abi_json}
	patch=$(git --no-pager diff ${full_path} ${PWD}/../abi/${abi_json})
	if [ -z ${patch} ]; then echo "Empty patch for ${abi_json}. Skip."; continue; fi
	echo ${patch} > /tmp/${abi_json}
	cp ${full_path} ../abi/${abi_json}
	git apply --allow-empty /tmp/${abi_json}
	rm /tmp/${abi_json}
done