#!/usr/bin/env bash
# Adds reward assets to the vault allowlist or removes them: creators can only pick allowlisted
# assets in deployToken. Only the vault owner can change it. Removing does not touch memes already
# created with the asset.
#
# Usage:
#   tools/scripts/set-asset-allowed.sh <vault> <asset> [true|false]
#   tools/scripts/set-asset-allowed.sh <vault> --file <csv> [--dry-run] [--remove] [--without-pool]
#   make set-asset-allowed VAULT=<vault> ASSET=<asset> [ALLOWED=false]
#   make set-asset-allowed VAULT=<vault> FILE=<csv> [DRY_RUN=1]
#
# CSV: header line, then `Ticker,Contract address,Uniswap V3 / USDG pool` per asset
# (tools/scripts/robinhood-assets.csv). In file mode an asset is allowed only if its USDG pool is
# the factory pool for (USDG, asset, pool fee): an allowed asset without a pool cannot be converted
# and its memes keep fees in USDG. --without-pool allows such assets anyway. --dry-run checks
# everything and sends nothing.
#
# From .env: RPC, PRIVATE_KEY, USDG_ADDRESS, UNISWAP_V3_FACTORY (file mode). The sender must be the
# vault owner.
set -euo pipefail

usage() {
    echo "Usage: $0 <vault> <asset> [true|false]" >&2
    echo "       $0 <vault> --file <csv> [--dry-run] [--remove] [--without-pool]" >&2
    exit 1
}

[ $# -ge 2 ] || usage
VAULT="$1"
shift
FILE=""
ASSET=""
ALLOWED=true
DRY_RUN=false
WITHOUT_POOL=false
while [ $# -gt 0 ]; do
    case "$1" in
        --file) [ $# -ge 2 ] || usage; FILE="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        --remove) ALLOWED=false ;;
        --without-pool) WITHOUT_POOL=true ;;
        true|false) ALLOWED="$1" ;;
        0x*) ASSET="$1" ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
    shift
done
[ -n "$FILE" ] || [ -n "$ASSET" ] || usage
# the file path is relative to the caller's directory, resolve it before changing directory
[ -z "$FILE" ] || FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"

cd "$(dirname "$0")/../.."

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_address "$VAULT" || { echo "vault is not an address: $VAULT" >&2; usage; }
[ -z "$ASSET" ] || is_address "$ASSET" || { echo "asset is not an address: $ASSET" >&2; usage; }
[ -z "$FILE" ] || [ -f "$FILE" ] || { echo "No file $FILE" >&2; exit 1; }

ENV_FILE=.env
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE in $(pwd)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
for var in RPC PRIVATE_KEY USDG_ADDRESS; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done
[ -z "$FILE" ] || [ -n "${UNISWAP_V3_FACTORY:-}" ] || {
    echo "UNISWAP_V3_FACTORY is empty in $ENV_FILE" >&2
    exit 1
}

ZERO=0x0000000000000000000000000000000000000000

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
call() { cast call "$@" --rpc-url "$RPC"; }
has_code() { [ "$(cast codesize "$1" --rpc-url "$RPC" 2>/dev/null || echo 0)" -gt 0 ]; }

# ------------------------------------------------------------------------------------------------
# Vault checks
# ------------------------------------------------------------------------------------------------

has_code "$VAULT" || { echo "Vault $VAULT has no code on this network" >&2; exit 1; }
VAULT_USDG=$(call "$VAULT" "usdg()(address)")
[ "$(lower "$VAULT_USDG")" = "$(lower "$USDG_ADDRESS")" ] || {
    echo "Vault $VAULT accounts fees in $VAULT_USDG, USDG_ADDRESS is $USDG_ADDRESS: wrong vault?" >&2
    exit 1
}

SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
OWNER=$(call "$VAULT" "owner()(address)")
if [ "$(lower "$OWNER")" != "$(lower "$SENDER")" ]; then
    PENDING=$(call "$VAULT" "pendingOwner()(address)")
    echo "Vault owner is $OWNER, PRIVATE_KEY is $SENDER: only the owner can change the allowlist." >&2
    [ "$(lower "$PENDING")" = "$(lower "$SENDER")" ] && \
        echo "You are the pending owner: call Vault.acceptOwnership() first." >&2
    [ "$DRY_RUN" = true ] || exit 1
fi
ADAPTER=$(call "$VAULT" "swapAdapter()(address)")
echo "Vault $VAULT, owner $OWNER, adapter $ADAPTER$([ "$DRY_RUN" = true ] && echo ', DRY RUN')"

# ------------------------------------------------------------------------------------------------
# One asset
# ------------------------------------------------------------------------------------------------

# Sets the allowlist flag of `asset` unless it already has it. Returns 1 on a skipped asset.
apply() {
    local asset="$1" label="$2" current
    current=$(call "$VAULT" "isAssetAllowed(address)(bool)" "$asset")
    if [ "$current" = "$ALLOWED" ]; then
        echo "  $label: already allowed=$ALLOWED"
    elif [ "$DRY_RUN" = true ]; then
        echo "  $label: would set allowed=$ALLOWED"
    else
        cast send "$VAULT" "setAssetAllowed(address,bool)" "$asset" "$ALLOWED" \
            --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
        echo "  $label: allowed=$(call "$VAULT" "isAssetAllowed(address)(bool)" "$asset")"
    fi
}

# Warns when an allowed non-USDG asset has no route on the vault adapter: conversions of every meme
# that picks it would fail and its fees stay in USDG.
warn_without_route() {
    local asset="$1" label="$2" pool
    [ "$ALLOWED" = true ] && [ "$(lower "$asset")" != "$(lower "$USDG_ADDRESS")" ] || return 0
    if [ "$ADAPTER" = "$ZERO" ]; then
        echo "  $label: WARNING the vault has no swap adapter" >&2
        return 0
    fi
    pool=$(call "$ADAPTER" "routeOf(address)((address,uint24,uint16))" "$asset" 2>/dev/null \
        | tr -d '()' | cut -d, -f1 || echo "")
    if [ -z "$pool" ] || [ "$pool" = "$ZERO" ]; then
        echo "  $label: WARNING no route on adapter $ADAPTER (make set-route ADAPTER=$ADAPTER" \
            "ASSET=$asset)" >&2
    fi
}

if [ -n "$ASSET" ]; then
    has_code "$ASSET" || { echo "Asset $ASSET has no code on this network" >&2; exit 1; }
    SYMBOL=$(call "$ASSET" "symbol()(string)" 2>/dev/null | tr -d '"' || echo "?")
    apply "$ASSET" "$SYMBOL $ASSET"
    warn_without_route "$ASSET" "$SYMBOL"
else
    # --------------------------------------------------------------------------------------------
    # File mode
    # --------------------------------------------------------------------------------------------
    total=0 applied=0 skipped=0
    while IFS=, read -r ticker asset pool _rest || [ -n "${ticker:-}" ]; do
        ticker=$(echo "$ticker" | tr -d '[:space:]')
        asset=$(echo "${asset:-}" | tr -d '[:space:]')
        pool=$(echo "${pool:-}" | tr -d '[:space:]')
        [ -n "$ticker" ] || continue
        total=$((total + 1))
        label="$ticker $asset"

        if ! is_address "$asset" || ! has_code "$asset"; then
            echo "  $label: SKIP asset has no code on this network"
            skipped=$((skipped + 1)); continue
        fi

        # The pool from the list must be the factory pool the adapter would pick for its fee tier.
        pool_ok=false
        if is_address "$pool" && has_code "$pool"; then
            fee=$(call "$pool" "fee()(uint24)" 2>/dev/null | awk '{print $1}' || echo "")
            if [ -n "$fee" ]; then
                factory_pool=$(call "$UNISWAP_V3_FACTORY" "getPool(address,address,uint24)(address)" \
                    "$USDG_ADDRESS" "$asset" "$fee")
                [ "$(lower "$factory_pool")" = "$(lower "$pool")" ] && pool_ok=true
            fi
        fi
        if [ "$pool_ok" = false ] && [ "$ALLOWED" = true ] && [ "$WITHOUT_POOL" = false ]; then
            echo "  $label: SKIP no USDG pool in factory $UNISWAP_V3_FACTORY (pool '$pool')"
            skipped=$((skipped + 1)); continue
        fi

        apply "$asset" "$label$([ "$pool_ok" = true ] && echo " (pool fee $fee)")"
        applied=$((applied + 1))
    done < <(tail -n +2 "$FILE")
    echo
    echo "Rows $total, processed $applied, skipped $skipped"
    [ "$ALLOWED" = true ] && [ "$applied" -gt 0 ] && \
        echo "Routes are not set by this script: set them per asset with make set-route."
fi

# allowedAssets() exists since the enumerable allowlist, older vault implementations revert.
echo
if LIST=$(call "$VAULT" "allowedAssets()(address[])" 2>/dev/null); then
    echo "Allowlist ($(echo "$LIST" | tr ',' '\n' | grep -c 0x) assets): $LIST"
else
    echo "Allowlist: allowedAssets() not available on this vault implementation (upgrade it)"
fi
