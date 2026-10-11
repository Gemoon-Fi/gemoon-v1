#!/usr/bin/env bash
# Adds a reward asset to the vault allowlist or removes it: creators can only pick allowlisted
# assets in deployToken. Only the vault owner can change it. Removing does not touch memes already
# created with the asset.
#
# Usage:
#   tools/scripts/set-asset-allowed.sh <vault> <asset> [true|false]
#   make set-asset-allowed VAULT=<vault> ASSET=<asset> [ALLOWED=false]
#
# From .env: RPC, PRIVATE_KEY, USDG_ADDRESS. The sender must be the vault owner.
set -euo pipefail

cd "$(dirname "$0")/../.."

usage() {
    echo "Usage: $0 <vault> <asset> [true|false]" >&2
    exit 1
}
[ $# -ge 2 ] && [ $# -le 3 ] || usage
VAULT="$1"
ASSET="$2"
ALLOWED="${3:-true}"

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_address "$VAULT" || { echo "vault is not an address: $VAULT" >&2; usage; }
is_address "$ASSET" || { echo "asset is not an address: $ASSET" >&2; usage; }
[ "$ALLOWED" = true ] || [ "$ALLOWED" = false ] || { echo "allowed must be true or false" >&2; usage; }

ENV_FILE=.env
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE in $(pwd)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
for var in RPC PRIVATE_KEY USDG_ADDRESS; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done

ZERO=0x0000000000000000000000000000000000000000

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
call() { cast call "$@" --rpc-url "$RPC"; }

# ------------------------------------------------------------------------------------------------
# Checks
# ------------------------------------------------------------------------------------------------

[ "$(cast codesize "$VAULT" --rpc-url "$RPC")" -gt 0 ] || {
    echo "Vault $VAULT has no code on this network" >&2
    exit 1
}
[ "$(cast codesize "$ASSET" --rpc-url "$RPC")" -gt 0 ] || {
    echo "Asset $ASSET has no code on this network" >&2
    exit 1
}
VAULT_USDG=$(call "$VAULT" "usdg()(address)")
[ "$(lower "$VAULT_USDG")" = "$(lower "$USDG_ADDRESS")" ] || {
    echo "Vault $VAULT accounts fees in $VAULT_USDG, USDG_ADDRESS is $USDG_ADDRESS: wrong vault?" >&2
    exit 1
}

SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
OWNER=$(call "$VAULT" "owner()(address)")
[ "$(lower "$OWNER")" = "$(lower "$SENDER")" ] || {
    PENDING=$(call "$VAULT" "pendingOwner()(address)")
    echo "Vault owner is $OWNER, PRIVATE_KEY is $SENDER: only the owner can change the allowlist." >&2
    [ "$(lower "$PENDING")" = "$(lower "$SENDER")" ] && \
        echo "You are the pending owner: call Vault.acceptOwnership() first." >&2
    exit 1
}

SYMBOL=$(call "$ASSET" "symbol()(string)" 2>/dev/null | tr -d '"' || echo "?")
DECIMALS=$(call "$ASSET" "decimals()(uint8)" 2>/dev/null || echo "?")
echo "Vault $VAULT, owner $OWNER"
echo "Asset $SYMBOL $ASSET ($DECIMALS decimals)"

# ------------------------------------------------------------------------------------------------
# Allowlist
# ------------------------------------------------------------------------------------------------

CURRENT=$(call "$VAULT" "isAssetAllowed(address)(bool)" "$ASSET")
if [ "$CURRENT" = "$ALLOWED" ]; then
    echo "Already allowed=$ALLOWED, nothing to send"
else
    cast send "$VAULT" "setAssetAllowed(address,bool)" "$ASSET" "$ALLOWED" \
        --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
    echo "allowed=$(call "$VAULT" "isAssetAllowed(address)(bool)" "$ASSET")"
fi

# An allowed non-USDG asset needs a swap route on the vault's adapter, otherwise conversions of
# every meme that picks it fail and its fees stay in USDG.
if [ "$ALLOWED" = true ] && [ "$(lower "$ASSET")" != "$(lower "$USDG_ADDRESS")" ]; then
    ADAPTER=$(call "$VAULT" "swapAdapter()(address)")
    if [ "$ADAPTER" = "$ZERO" ]; then
        echo "WARNING: the vault has no swap adapter, conversions into $SYMBOL will fail" >&2
    else
        POOL=$(call "$ADAPTER" "routeOf(address)((address,uint24,uint16))" "$ASSET" 2>/dev/null \
            | tr -d '()' | cut -d, -f1 || echo "")
        if [ -z "$POOL" ] || [ "$POOL" = "$ZERO" ]; then
            echo "WARNING: adapter $ADAPTER has no route for $SYMBOL: make set-route" \
                "ADAPTER=$ADAPTER ASSET=$ASSET" >&2
        else
            echo "Route: pool $POOL"
        fi
    fi
fi

# allowedAssets() exists since the enumerable allowlist, older vault implementations revert.
if LIST=$(call "$VAULT" "allowedAssets()(address[])" 2>/dev/null); then
    echo "Allowlist: $LIST"
else
    echo "Allowlist: allowedAssets() not available on this vault implementation (upgrade it)"
fi
