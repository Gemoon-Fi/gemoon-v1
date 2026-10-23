#!/usr/bin/env bash
# Full Gemoon deployment in one command:
#   1. DeployGemoon (make deploy-gemoon): Vault, GemoonController, GmoonReferrals, HookManager and
#      UniswapV3SwapAdapter, wired; reward assets of DEPLOY_ASSETS_FILE allowed in the vault with
#      their swap routes; ownership handed to GEMOON_OWNER;
#   2. addresses written into env/$ENVIRONMENT.mk;
#   3. make verify-wiring (read-only, against the chain);
#   4. GemoonLens (make deploy-lens), unless --no-lens;
#   5. report: deploy-logs/deploy-<time>-report.md, what was deployed where and why, the outcome
#      per reward asset, ownership and what is left to do. Printed at the end.
#
# Usage:
#   ENVIRONMENT=dev ./deploy.sh              deploy everything
#   ENVIRONMENT=dev ./deploy.sh --simulate   dry run of DeployGemoon, nothing is broadcast, report still written
#   ENVIRONMENT=dev ./deploy.sh --no-lens    skip GemoonLens
#
# ENVIRONMENT (dev|prod) is required. Reads RPC, PRIVATE_KEY and the deploy variables from
# env/$ENVIRONMENT.mk (see docs/DEPLOY.md). Backs up that file before changing it
# (env/$ENVIRONMENT.mk.bak.<time>, gitignored). Full forge output: deploy-logs/deploy-<time>.log.
set -euo pipefail

cd "$(dirname "$0")"

SIMULATE=false
WITH_LENS=true
for arg in "$@"; do
    case "$arg" in
        --simulate) SIMULATE=true ;;
        --no-lens) WITH_LENS=false ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# shellcheck source=tools/scripts/load-env.sh
source tools/scripts/load-env.sh

for var in RPC PRIVATE_KEY POOL_MANAGER POSITION_MANAGER PERMIT2 USDG_ADDRESS \
    VAULT_CONVERSION_THRESHOLD UNISWAP_V3_FACTORY; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done
ASSETS_FILE="${DEPLOY_ASSETS_FILE:-tools/scripts/robinhood-assets.csv}"
[ -f "$ASSETS_FILE" ] || { echo "No asset file $ASSETS_FILE (DEPLOY_ASSETS_FILE)" >&2; exit 1; }

LOG_DIR=deploy-logs
mkdir -p "$LOG_DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/deploy-$STAMP.log"
REPORT="$LOG_DIR/deploy-$STAMP-report.md"

DEPLOYER=$(cast wallet address --private-key "$PRIVATE_KEY")
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
echo "Deployer: $DEPLOYER"
echo "Chain id: $CHAIN_ID"
echo "Balance:  $(cast balance "$DEPLOYER" --ether --rpc-url "$RPC") native"
echo "Assets:   $ASSETS_FILE ($(($(grep -c . "$ASSETS_FILE") - 1)) rows)"

# Everything the script relies on must exist on the target network.
CREATE2_DEPLOYER=0x4e59b44847b379578588920cA78FbF26c0B4956C
for var in POOL_MANAGER POSITION_MANAGER PERMIT2 USDG_ADDRESS UNISWAP_V3_FACTORY CREATE2_DEPLOYER; do
    size=$(cast codesize "${!var}" --rpc-url "$RPC")
    [ "$size" -gt 0 ] || { echo "$var=${!var} has no code on this network" >&2; exit 1; }
done

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

# Sets KEY=VALUE in env/$ENVIRONMENT.mk: replaces the existing line or appends one.
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

report() { printf '%s\n' "$@" >> "$REPORT"; }

# ------------------------------------------------------------------------------------------------
# DeployGemoon
# ------------------------------------------------------------------------------------------------
# Every forge call goes through the Makefile. It includes env/$ENVIRONMENT.mk, so a value this script sets is
# passed on the make command line (command-line variables beat included ones and are exported to
# the recipe).

if [ "$SIMULATE" = true ]; then
    echo "Simulating DeployGemoon, nothing is broadcast. Log: $LOG"
    status=0
    make -f ./Makefile simulate-gemoon DEPLOY_REPORT="$REPORT" DEPLOY_ASSETS_FILE="$ASSETS_FILE" \
        2>&1 | tee "$LOG" || status=$?
    if [ "$status" -ne 0 ] || [ ! -f "$REPORT" ]; then
        echo "Simulation failed, see $LOG" >&2
        exit 1
    fi
    echo
    cat "$REPORT"
    echo
    echo "Simulation only, nothing was sent. Report: $REPORT, log: $LOG"
    exit 0
fi

echo "Deploying. Log: $LOG"
status=0
make -f ./Makefile deploy-gemoon DEPLOY_REPORT="$REPORT" DEPLOY_ASSETS_FILE="$ASSETS_FILE" \
    2>&1 | tee "$LOG" || status=$?
if [ "$status" -ne 0 ]; then
    if [ -f "$REPORT" ]; then
        report "" "## Result" "" \
            "**FAILED.** make deploy-gemoon exited with $status. The tables above describe the" \
            "simulated run; not every transaction may have been sent. Sent transactions:" \
            "broadcast/GemoonDeploy.sol/$CHAIN_ID/run-latest.json. Log: $LOG." \
            "A half-finished run is safe, see docs/DEPLOY.md."
    fi
    echo "make deploy-gemoon failed, see $LOG. A half-finished run is safe, see docs/DEPLOY.md." >&2
    exit 1
fi

VAULT_PROXY=$(extract "VAULT PROXY" "$LOG")
VAULT_PROXY_ADMIN=$(extract "VAULT PROXY ADMIN" "$LOG")
HOOK=$(extract "HOOK" "$LOG")
CONTROLLER_PROXY=$(extract "CONTROLLER PROXY" "$LOG")
CONTROLLER_PROXY_ADMIN=$(extract "CONTROLLER PROXY ADMIN" "$LOG")
REFERRALS_PROXY=$(extract "REFERRALS PROXY" "$LOG")
REFERRALS_PROXY_ADMIN=$(extract "REFERRALS PROXY ADMIN" "$LOG")
ADAPTER=$(extract "SWAP ADAPTER" "$LOG")

require_address "VAULT PROXY" "$VAULT_PROXY"
require_address "VAULT PROXY ADMIN" "$VAULT_PROXY_ADMIN"
require_address "HOOK" "$HOOK"
require_address "CONTROLLER PROXY" "$CONTROLLER_PROXY"
require_address "CONTROLLER PROXY ADMIN" "$CONTROLLER_PROXY_ADMIN"
require_address "REFERRALS PROXY" "$REFERRALS_PROXY"
require_address "REFERRALS PROXY ADMIN" "$REFERRALS_PROXY_ADMIN"
require_address "SWAP ADAPTER" "$ADAPTER"

cp "$ENV_FILE" "$ENV_FILE.bak.$STAMP"
ENV_KEYS=(
    "VAULT_PROXY_ADDRESS=$VAULT_PROXY"
    "VAULT_PROXY_ADMIN_ADDRESS=$VAULT_PROXY_ADMIN"
    "HOOK_ADDRESS=$HOOK"
    "CONTROLLER_PROXY_ADDRESS=$CONTROLLER_PROXY"
    "CONTROLLER_PROXY_ADMIN_ADDRESS=$CONTROLLER_PROXY_ADMIN"
    "REFERRALS_PROXY_ADDRESS=$REFERRALS_PROXY"
    "REFERRALS_PROXY_ADMIN_ADDRESS=$REFERRALS_PROXY_ADMIN"
    "SWAP_ADAPTER=$ADAPTER"
    "VAULT_SWAP_ADAPTER=$ADAPTER"
)
for kv in "${ENV_KEYS[@]}"; do
    set_env "${kv%%=*}" "${kv#*=}"
done
echo "Addresses written to $ENV_FILE (previous version: $ENV_FILE.bak.$STAMP)"

# env/$ENVIRONMENT.mk now holds the new addresses, the next make targets read them from there.
echo "Checking wiring against the chain"
WIRING="OK"
if ! make -f ./Makefile verify-wiring 2>&1 | tee -a "$LOG"; then
    WIRING="FAILED, see $LOG"
fi

# ------------------------------------------------------------------------------------------------
# GemoonLens
# ------------------------------------------------------------------------------------------------

LENS=""
LENS_NOTE="skipped (--no-lens)"
if [ "$WITH_LENS" = true ]; then
    echo "Deploying GemoonLens"
    if make -f ./Makefile deploy-lens 2>&1 | tee -a "$LOG"; then
        LENS=$(extract "GemoonLens" "$LOG")
        if [[ "$LENS" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
            set_env LENS_ADDRESS "$LENS"
            LENS_NOTE="$LENS"
        else
            LENS_NOTE="FAILED: address not found in $LOG"
        fi
    else
        LENS_NOTE="FAILED, see $LOG; retry with make deploy-lens"
    fi
fi

# ------------------------------------------------------------------------------------------------
# Report
# ------------------------------------------------------------------------------------------------

report "" "## GemoonLens" "" \
    "| Contract | Address | What it is for |" "|---|---|---|" \
    "| GemoonLens | $LENS_NOTE | Read-only batch reader for the frontend: everything about a list of Memes in one \`eth_call\`. No state, no owner; CREATE2, redeployed when protocol addresses change. |"

report "" "## Result" "" \
    "- Broadcast: OK, every transaction was sent (\`broadcast/GemoonDeploy.sol/$CHAIN_ID/run-latest.json\`)." \
    "- On-chain wiring check (\`make verify-wiring\`): $WIRING." \
    "- \`$ENV_FILE\` updated (backup \`$ENV_FILE.bak.$STAMP\`):"
for kv in "${ENV_KEYS[@]}"; do
    report "  - \`${kv%%=*}\` = ${kv#*=}"
done
[ -n "$LENS" ] && report "  - \`LENS_ADDRESS\` = $LENS"
report "- Full forge output: \`$LOG\`."

echo
cat "$REPORT"
echo
echo "Report: $REPORT"
echo "Log:    $LOG"
[ "$WIRING" = "OK" ] || exit 1
