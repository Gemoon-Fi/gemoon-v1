#!/bin/bash

interfaces=$(ls ./src/contracts/interfaces);

for i in ${interfaces}; do
	contract_dir=$(find ./out -name "${i}" -type d)
	abi_json=$(ls "${contract_dir}")
	full_path="${contract_dir}/${abi_json}"
	patch=$(git --no-pager diff "${full_path}" "${PWD}/../abi/${abi_json}")
	if [ -z "${patch}" ]; then echo "Empty patch for ${abi_json}. Skip."; continue; fi
	echo "${patch}" > "/tmp/${abi_json}"
	cp "${full_path}" "../abi/${abi_json}"
	git apply --allow-empty "/tmp/${abi_json}"
	rm "/tmp/${abi_json}"
done

# Update README:
rm ${PWD}/../README.md || true

echo '# Addresses:' > ${PWD}/../abi/README.md
grep -Pi 'proxy_address=\K0x[A-Za-z0-9]{40}' ./.env | awk -F'\n' '{print NR". - ""`"$0"`""\n"}' >> ${PWD}/../abi/README.md
echo '## Usage:' >> ${PWD}/../abi/README.md
cat ./README-ABI.md >> ${PWD}/../abi/README.md
