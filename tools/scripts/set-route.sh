#!/usr/bin/env bash
# Sets the swap route of a reward asset on the UniswapV3SwapAdapter: which Uniswap V3 USDG/asset
# pool the vault's conversions use, and the allowed deviation from the pool TWAP.
#
# Usage:
#   tools/scripts/set-route.sh <adapter> <asset> [fee] [slippage]
#   make set-route ADAPTER=<adapter> ASSET=<asset> [FEE=<fee>] [SLIPPAGE=<bps>]
#
#   fee       pool fee tier: 100, 500, 3000 or 10000. Empty: the tier with the most in-range
#             liquidity is picked.
#   slippage  allowed deviation from the TWAP output in bps, default 100 (1%), at most 500.
#
# From .env: RPC, PRIVATE_KEY, USDG_ADDRESS, UNISWAP_V3_FACTORY. The sender must be the adapter
# owner.
set -euo pipefail

cd "$(dirname "$0")/../.."

usage() {
    echo "Usage: $0 <adapter> <asset> [fee] [slippage]" >&2
    exit 1
}
[ $# -ge 2 ] && [ $# -le 4 ] || usage
ADAPTER="$1"
ASSET="$2"
FEE="${3:-}"
SLIPPAGE="${4:-100}"

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_address "$ADAPTER" || { echo "adapter is not an address: $ADAPTER" >&2; usage; }
is_address "$ASSET" || { echo "asset is not an address: $ASSET" >&2; usage; }

ENV_FILE=.env
[ -f "$ENV_FILE" ] || { echo "No $ENV_FILE in $(pwd)" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
for var in RPC PRIVATE_KEY USDG_ADDRESS UNISWAP_V3_FACTORY; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done

FEE_TIERS=(100 500 3000 10000)
ZERO=0x0000000000000000000000000000000000000000
MAX_SLIPPAGE=500

lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
call() { cast call "$@" --rpc-url "$RPC"; }

# ------------------------------------------------------------------------------------------------
# Checks
# ------------------------------------------------------------------------------------------------

[ "$(lower "$ASSET")" != "$(lower "$USDG_ADDRESS")" ] || {
    echo "USDG is credited without a swap, it needs no route"
    exit 0
}
[[ "$SLIPPAGE" =~ ^[0-9]+$ ]] && [ "$SLIPPAGE" -le "$MAX_SLIPPAGE" ] || {
    echo "slippage must be 0..$MAX_SLIPPAGE bps, got $SLIPPAGE" >&2
    exit 1
}
[ "$(cast codesize "$ADAPTER" --rpc-url "$RPC")" -gt 0 ] || {
    echo "Adapter $ADAPTER has no code on this network" >&2
    exit 1
}
[ "$(cast codesize "$ASSET" --rpc-url "$RPC")" -gt 0 ] || {
    echo "Asset $ASSET has no code on this network" >&2
    exit 1
}

SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
OWNER=$(call "$ADAPTER" "owner()(address)")
[ "$(lower "$OWNER")" = "$(lower "$SENDER")" ] || {
    echo "Adapter owner is $OWNER, PRIVATE_KEY is $SENDER: only the owner can set routes" >&2
    exit 1
}

# The adapter looks the pool up in its own immutable factory; it must be the one from .env.
ADAPTER_FACTORY=$(call "$ADAPTER" "i_factory()(address)")
[ "$(lower "$ADAPTER_FACTORY")" = "$(lower "$UNISWAP_V3_FACTORY")" ] || {
    echo "Adapter uses factory $ADAPTER_FACTORY, UNISWAP_V3_FACTORY is $UNISWAP_V3_FACTORY" >&2
    exit 1
}
ADAPTER_USDG=$(call "$ADAPTER" "i_usdg()(address)")
[ "$(lower "$ADAPTER_USDG")" = "$(lower "$USDG_ADDRESS")" ] || {
    echo "Adapter sells $ADAPTER_USDG, USDG_ADDRESS is $USDG_ADDRESS" >&2
    exit 1
}

VAULT=$(call "$ADAPTER" "i_vault()(address)")
WINDOW=$(call "$ADAPTER" "twapWindow()(uint32)")
VAULT_ADAPTER=$(call "$VAULT" "swapAdapter()(address)")
[ "$(lower "$VAULT_ADAPTER")" = "$(lower "$ADAPTER")" ] || \
    echo "NOTE: vault $VAULT uses adapter $VAULT_ADAPTER; this route takes effect only after" \
        "Vault.setSwapAdapter($ADAPTER)"

SYMBOL=$(call "$ASSET" "symbol()(string)" 2>/dev/null | tr -d '"' || echo "?")
echo "Adapter $ADAPTER (vault $VAULT), factory $UNISWAP_V3_FACTORY, TWAP window ${WINDOW}s"
echo "Asset $SYMBOL $ASSET"

# ------------------------------------------------------------------------------------------------
# Pool
# ------------------------------------------------------------------------------------------------

pool_of() {
    call "$UNISWAP_V3_FACTORY" "getPool(address,address,uint24)(address)" "$USDG_ADDRESS" "$ASSET" "$1"
}

POOL=""
if [ -n "$FEE" ]; then
    POOL=$(pool_of "$FEE")
    [ "$POOL" != "$ZERO" ] || {
        echo "No USDG/$SYMBOL pool with fee $FEE in factory $UNISWAP_V3_FACTORY" >&2
        exit 1
    }
else
    best=0
    for f in "${FEE_TIERS[@]}"; do
        p=$(pool_of "$f")
        [ "$p" != "$ZERO" ] || continue
        liq=$(call "$p" "liquidity()(uint128)" | awk '{print $1}')
        echo "  fee $f: pool $p, liquidity $liq"
        if [ -z "$POOL" ] || [ "$(echo "$liq > $best" | bc)" -eq 1 ]; then
            POOL="$p"; FEE="$f"; best="$liq"
        fi
    done
    [ -n "$POOL" ] || {
        echo "No USDG/$SYMBOL pool in factory $UNISWAP_V3_FACTORY for fee tiers ${FEE_TIERS[*]}" >&2
        exit 1
    }
fi
echo "Pool $POOL, fee $FEE, slippage $SLIPPAGE bps"

# setRoute reverts unless the pool can give a TWAP over the adapter window.
if ! cast call "$POOL" "observe(uint32[])(int56[],uint160[])" "[$WINDOW,0]" --rpc-url "$RPC" \
    >/dev/null 2>&1; then
    echo "Pool has no price history over ${WINDOW}s (observe reverts OLD). Raise the observation" \
        "cardinality, wait for the window to fill, then rerun:" >&2
    echo "  cast send $POOL 'increaseObservationCardinalityNext(uint16)' 300" \
        "--rpc-url \$RPC --private-key \$PRIVATE_KEY" >&2
    exit 1
fi

# ------------------------------------------------------------------------------------------------
# Route
# ------------------------------------------------------------------------------------------------

cast send "$ADAPTER" "setRoute(address,uint24,uint16)" "$ASSET" "$FEE" "$SLIPPAGE" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
echo "Route: $(call "$ADAPTER" "routeOf(address)((address,uint24,uint16))" "$ASSET")"
echo "Quote for 1 USDG: $(call "$ADAPTER" "quote(address,uint256)(uint256)" "$ASSET" 1000000)," \
    "min out $(call "$ADAPTER" "minAmountOut(address,uint256)(uint256)" "$ASSET" 1000000) (raw units)"
