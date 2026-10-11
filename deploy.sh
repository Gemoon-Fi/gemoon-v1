#!/usr/bin/env bash
# Full Gemoon deployment: Vault + GemoonController + HookManager (make deploy-gemoon), proxy
# addresses written into .env, wiring check, optionally the swap adapter.
#
# Usage:
#   ./deploy.sh                  deploy the core contracts
#   ./deploy.sh --with-adapter   also deploy UniswapV3SwapAdapter and attach it to the vault
#   ./deploy.sh --simulate       dry run of the core deployment, nothing is broadcast
#
# Reads RPC, PRIVATE_KEY and the deploy variables from .env (see docs/DEPLOY.md). Backs up .env
# before changing it (.env.bak.<time>, gitignored). The deploy log is kept in deploy-logs/ (gitignored).
set -euo pipefail

cd "$(dirname "$0")"

WITH_ADAPTER=false
SIMULATE=false
for arg in "$@"; do
    case "$arg" in
        --with-adapter) WITH_ADAPTER=true ;;
        --simulate) SIMULATE=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

ENV_FILE=.env
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE in $(pwd)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for var in RPC PRIVATE_KEY POOL_MANAGER POSITION_MANAGER PERMIT2 USDG_ADDRESS \
    PROTOCOL_FEE_RECIPIENT VAULT_CONVERSION_THRESHOLD; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done

LOG_DIR=deploy-logs
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/deploy-$STAMP.log"

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
echo "Deployer: $DEPLOYER"
echo "Chain id: $(cast chain-id --rpc-url "$RPC")"
echo "Balance:  $(cast balance "$DEPLOYER" --ether --rpc-url "$RPC") native"

# Uniswap V4 and USDG must exist on the target network, the script itself does not check them.
for var in POOL_MANAGER POSITION_MANAGER PERMIT2 USDG_ADDRESS; do
    size=$(cast codesize "${!var}" --rpc-url "$RPC")
    [ "$size" -gt 0 ] || { echo "$var=${!var} has no code on this network" >&2; exit 1; }
done
# An adapter is bound to one vault (immutable i_vault, swap() accepts only it). This run creates a
# new vault proxy, so an adapter deployed before cannot serve it: it is not attached, and
# VAULT_SWAP_ADAPTER is cleared in .env after the deployment.
OLD_ADAPTER="${VAULT_SWAP_ADAPTER:-}"
if [ -n "$OLD_ADAPTER" ]; then
    echo "Note: VAULT_SWAP_ADAPTER=$OLD_ADAPTER belongs to the previous vault and is not attached to" \
        "the new one. Use --with-adapter to deploy one for the new vault."
fi
export VAULT_SWAP_ADAPTER=""
if [ -n "${VAULT_ALLOWED_ASSETS:-}" ]; then
    IFS=',' read -ra assets <<< "$VAULT_ALLOWED_ASSETS"
    for asset in "${assets[@]}"; do
        asset=$(echo "$asset" | tr -d '[:space:]')
        size=$(cast codesize "$asset" --rpc-url "$RPC")
        [ "$size" -gt 0 ] || echo "WARNING: VAULT_ALLOWED_ASSETS has $asset without code on this network" >&2
    done
fi

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------

# Address printed by the deploy script as "<LABEL>: 0x…" (console.log label + address).
# The label must match exactly: "VAULT PROXY ADMIN" must not match "VAULT PROXY ADMIN OWNER".
extract() {
    local label="$1" file="$2"
    sed -nE "s/^[[:space:]]*${label}:[[:space:]]+(0x[0-9a-fA-F]{40})[[:space:]]*$/\1/p" "$file" \
        | tail -n 1
}

# Sets KEY=VALUE in .env: replaces the existing line or appends one.
set_env() {
    local key="$1" value="$2" tmp
    tmp=$(mktemp)
    awk -v k="$key" -v v="$value" '
        BEGIN { done = 0 }
        $0 ~ "^" k "=" { print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

require_address() {
    local name="$1" value="$2"
    [[ "$value" =~ ^0x[0-9a-fA-F]{40}$ ]] || {
        echo "Could not read $name from the deploy log, see $LOG" >&2
        exit 1
    }
}

# ------------------------------------------------------------------------------------------------
# Core deployment
# ------------------------------------------------------------------------------------------------
# Every forge call goes through the Makefile. It includes .env, so a value this script must
# override is passed on the make command line (command-line variables beat included ones and are
# exported to the recipe), e.g. VAULT_SWAP_ADAPTER= for the core deployment.

if [ "$SIMULATE" = true ]; then
    echo "Simulating DeployGemoon, nothing is broadcast. Log: $LOG"
    make -f ./Makefile simulate-gemoon VAULT_SWAP_ADAPTER= 2>&1 | tee "$LOG"
    exit "${PIPESTATUS[0]}"
fi

echo "Deploying core contracts. Log: $LOG"
if ! make -f ./Makefile deploy-gemoon VAULT_SWAP_ADAPTER= 2>&1 | tee "$LOG"; then
    echo "make deploy-gemoon failed, see $LOG. A half-finished run is safe, see docs/DEPLOY.md." >&2
    exit 1
fi

VAULT_PROXY=$(extract "VAULT PROXY" "$LOG")
VAULT_PROXY_ADMIN=$(extract "VAULT PROXY ADMIN" "$LOG")
HOOK_PROXY=$(extract "HOOK PROXY" "$LOG")
HOOK_PROXY_ADMIN=$(extract "HOOK PROXY ADMIN" "$LOG")
CONTROLLER_PROXY=$(extract "CONTROLLER PROXY" "$LOG")
CONTROLLER_PROXY_ADMIN=$(extract "CONTROLLER PROXY ADMIN" "$LOG")

require_address "VAULT PROXY" "$VAULT_PROXY"
require_address "VAULT PROXY ADMIN" "$VAULT_PROXY_ADMIN"
require_address "HOOK PROXY" "$HOOK_PROXY"
require_address "HOOK PROXY ADMIN" "$HOOK_PROXY_ADMIN"
require_address "CONTROLLER PROXY" "$CONTROLLER_PROXY"
require_address "CONTROLLER PROXY ADMIN" "$CONTROLLER_PROXY_ADMIN"

cp "$ENV_FILE" "$ENV_FILE.bak.$STAMP"
set_env VAULT_PROXY_ADDRESS "$VAULT_PROXY"
set_env VAULT_PROXY_ADMIN_ADDRESS "$VAULT_PROXY_ADMIN"
set_env HOOK_PROXY_ADDRESS "$HOOK_PROXY"
set_env HOOK_PROXY_ADMIN_ADDRESS "$HOOK_PROXY_ADMIN"
set_env CONTROLLER_PROXY_ADDRESS "$CONTROLLER_PROXY"
set_env CONTROLLER_PROXY_ADMIN_ADDRESS "$CONTROLLER_PROXY_ADMIN"
[ -n "$OLD_ADAPTER" ] && set_env VAULT_SWAP_ADAPTER ""
echo "Proxy addresses written to $ENV_FILE (previous version: $ENV_FILE.bak.$STAMP)"

# .env now holds the new proxy addresses, the next make targets read them from there.
echo "Checking wiring"
make -f ./Makefile verify-wiring 2>&1 | tee -a "$LOG"

# The vault owner is pending until it accepts, when GEMOON_OWNER is not the deployer.
VAULT_OWNER=$(cast call "$VAULT_PROXY" "owner()(address)" --rpc-url "$RPC")
VAULT_PENDING=$(cast call "$VAULT_PROXY" "pendingOwner()(address)" --rpc-url "$RPC")
NEEDS_ACCEPT=false
if [ "$VAULT_PENDING" != "0x0000000000000000000000000000000000000000" ]; then
    NEEDS_ACCEPT=true
fi

# ------------------------------------------------------------------------------------------------
# Swap adapter (optional)
# ------------------------------------------------------------------------------------------------

ADAPTER=""
if [ "$WITH_ADAPTER" = true ]; then
    [ -n "${UNISWAP_V3_FACTORY:-}" ] || { echo "UNISWAP_V3_FACTORY is empty in $ENV_FILE" >&2; exit 1; }
    echo "Deploying swap adapter"
    # the adapter script reads VAULT_PROXY_ADDRESS, already written to .env above
    if ! make -f ./Makefile deploy-swap-adapter 2>&1 | tee -a "$LOG"; then
        echo "make deploy-swap-adapter failed, see $LOG" >&2
        exit 1
    fi
    ADAPTER=$(extract "SWAP ADAPTER" "$LOG")
    require_address "SWAP ADAPTER" "$ADAPTER"
    set_env SWAP_ADAPTER "$ADAPTER"
    set_env VAULT_SWAP_ADAPTER "$ADAPTER"

    # Only the vault owner can attach the adapter: possible here when it is the deployer.
    if [ "$(echo "$VAULT_OWNER" | tr '[:upper:]' '[:lower:]')" = \
        "$(echo "$DEPLOYER" | tr '[:upper:]' '[:lower:]')" ]; then
        echo "Attaching adapter to the vault"
        cast send "$VAULT_PROXY" "setSwapAdapter(address)" "$ADAPTER" \
            --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
        echo "Vault.swapAdapter: $(cast call "$VAULT_PROXY" "swapAdapter()(address)" --rpc-url "$RPC")"
    else
        echo "Vault owner is $VAULT_OWNER, not the deployer: it must call" \
            "Vault.setSwapAdapter($ADAPTER) itself"
    fi
fi

# ------------------------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------------------------

cat <<EOF

Deployed:
  Vault proxy         $VAULT_PROXY   (admin $VAULT_PROXY_ADMIN)
  HookManager proxy   $HOOK_PROXY   (admin $HOOK_PROXY_ADMIN)
  Controller proxy    $CONTROLLER_PROXY   (admin $CONTROLLER_PROXY_ADMIN)
EOF
[ -n "$ADAPTER" ] && echo "  Swap adapter        $ADAPTER"

echo
echo "Left to do by hand:"
if [ "$NEEDS_ACCEPT" = true ]; then
    echo "  - $VAULT_PENDING calls Vault.acceptOwnership() on $VAULT_PROXY"
fi
if [ -z "${VAULT_ALLOWED_ASSETS:-}" ]; then
    echo "  - vault owner allows reward assets: Vault.setAssetAllowed(asset, true)"
fi
if [ "$WITH_ADAPTER" = true ]; then
    echo "  - adapter owner sets a route per non-USDG asset: setRoute(asset, fee, maxSlippageBps)"
else
    echo "  - swap adapter for non-USDG reward assets: make deploy-swap-adapter, setRoute per asset," \
        "Vault.setSwapAdapter (or rerun with --with-adapter on a fresh deployment)"
fi
echo "  - first deployToken: check PositionCreated has non-zero liquidity"
echo "Log: $LOG"
