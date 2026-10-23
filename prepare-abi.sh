#!/bin/bash
set -euo pipefail

# Addresses for the README come from both env/dev.mk and env/prod.mk, so ENVIRONMENT is not needed.
# A missing file or an empty value is shown as "—".
ENV_FILES="env/dev.mk env/prod.mk"

ABI_DIR="${PWD}/../abi"
mkdir -p "${ABI_DIR}"

# Third-party interfaces and contracts exported next to our own interfaces (artifact dir name in
# ./out). GemoonLens is read by frontends directly, so its own ABI goes out too.
external_interfaces="IPoolManager.sol GemoonLens.sol"

# Extract the `abi` object from forge artifacts of every interface and put it into ../abi/<Contract>.json
export_abi() {
	local i="$1"
	local contract_dir
	contract_dir=$(find ./out -name "${i}" -type d | head -n 1)
	if [ -z "${contract_dir}" ]; then echo "No artifact for ${i}. Run 'forge build' first. Skip."; return; fi

	for artifact in "${contract_dir}"/*.json; do
		local abi_json target new_abi
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
}

for i in $(ls ./src/contracts/interfaces) ${external_interfaces}; do
	export_abi "${i}"
done

# Update README:
# Prints the value of KEY from an env file (plain KEY=VALUE lines) or "—" when it is absent.
env_value() {
	local file="$1" key="$2" value=""
	[ -f "${file}" ] && value=$(sed -nE "s/^${key}=(0x[0-9A-Fa-f]{40})[[:space:]]*$/\1/p" "${file}" | tail -n 1)
	if [ -n "${value}" ]; then echo "\`${value}\`"; else echo "—"; fi
}

# Contract | ABI | env variable holding the address
address_rows=(
	"GemoonController|\`IGemoonController.json\`|CONTROLLER_PROXY_ADDRESS"
	"Vault|\`IVault.json\`|VAULT_PROXY_ADDRESS"
	"HookManager|\`IHookManager.json\`|HOOK_ADDRESS"
	"GmoonReferrals|\`IReferrals.json\`|REFERRALS_PROXY_ADDRESS"
	"GemoonLens (батч-чтения)|\`GemoonLens.json\`|LENS_ADDRESS"
	"UniswapV3SwapAdapter|\`IUniswapV3SwapAdapter.json\`|VAULT_SWAP_ADAPTER"
	"PoolManager (Uniswap V4)|\`IPoolManager.json\`|POOL_MANAGER"
	"UniswapV3Factory|—|UNISWAP_V3_FACTORY"
	"USDG (pair-токен)|стандартный ERC20|USDG_ADDRESS"
)

addresses_table() {
	echo "| Контракт | ABI | dev | prod |"
	echo "|---|---|---|---|"
	local row name abi key
	for row in "${address_rows[@]}"; do
		IFS='|' read -r name abi key <<< "${row}"
		echo "| ${name} | ${abi} | $(env_value env/dev.mk "${key}") | $(env_value env/prod.mk "${key}") |"
	done
	echo "| Токен мема | \`IGemoonToken.json\` | адрес из \`TokenCreated\` | адрес из \`TokenCreated\` |"
}

for f in ${ENV_FILES}; do
	[ -f "${f}" ] || echo "No ${f}, its addresses are shown as —."
done

# README-ABI.md keeps the marker line where the generated table goes.
marker='<!-- ADDRESSES -->'
grep -qxF "${marker}" ./README-ABI.md || { echo "No ${marker} line in README-ABI.md" >&2; exit 1; }
table=$(addresses_table)
while IFS= read -r line; do
	if [ "${line}" == "${marker}" ]; then echo "${table}"; else echo "${line}"; fi
done < ./README-ABI.md > "${ABI_DIR}/README.md"

# Update indexing.md:
cp ./indexing.md "${ABI_DIR}/indexing.md"
