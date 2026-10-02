#!/bin/bash
set -euo pipefail

ABI_DIR="${PWD}/../abi"
mkdir -p "${ABI_DIR}"

# Extract the `abi` object from forge artifacts of every interface and put it into ../abi/<Contract>.json
for i in $(ls ./src/contracts/interfaces); do
	contract_dir=$(find ./out -name "${i}" -type d | head -n 1)
	if [ -z "${contract_dir}" ]; then echo "No artifact for ${i}. Run 'forge build' first. Skip."; continue; fi

	for artifact in "${contract_dir}"/*.json; do
		abi_json=$(basename "${artifact}")
		target="${ABI_DIR}/${abi_json}"

		new_abi=$(jq -S '.abi' "${artifact}")
		if [ -f "${target}" ] && [ "${new_abi}" == "$(cat "${target}")" ]; then
			echo "No changes for ${abi_json}. Skip."
			continue
		fi

		echo "${new_abi}" > "${target}"
		echo "Updated ${abi_json}."
	done
done

# Update README:
rm -f "${ABI_DIR}/README.md"

echo '# Addresses:' > "${ABI_DIR}/README.md"
grep -Pi 'proxy_address=\K0x[A-Za-z0-9]{40}' ./.env | awk -F'\n' '{print NR". - ""`"$0"`""\n"}' >> "${ABI_DIR}/README.md" || true
grep -Pi 'UNISWAP_V3_FACTORY=\K0x[A-Za-z0-9]{40}' ./.env | awk -F'\n' '{print NR". - ""`"$0"`""\n"}' >> "${ABI_DIR}/README.md" || true
grep -Pi 'NATIVE_TOKEN_ADDRESS=\K0x[A-Za-z0-9]{40}' ./.env | awk -F'\n' '{print NR". - ""`"$0"`""\n"}' >> "${ABI_DIR}/README.md" || true
grep -Pi 'VAULT_SWAP_ADAPTER=\K0x[A-Za-z0-9]{40}' ./.env | awk -F'\n' '{print NR". - ""`"$0"`""\n"}' >> "${ABI_DIR}/README.md" || true
grep -Pi 'USDG_ADDRESS=\K0x[A-Za-z0-9]{40}' ./.env | awk -F'\n' '{print NR". - ""`"$0"`""\n"}' >> "${ABI_DIR}/README.md" || true
echo '## Usage:' >> "${ABI_DIR}/README.md"
cat ./README-ABI.md >> "${ABI_DIR}/README.md"

# Update indexing.md:
cp ./indexing.md "${ABI_DIR}/indexing.md"
