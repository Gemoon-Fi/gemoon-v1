#!/usr/bin/env bash
# Sets the swap route of reward assets on the UniswapV3SwapAdapter: which Uniswap V3 USDG/asset
# pool the vault's conversions use, and the allowed deviation from the pool TWAP.
#
# Usage:
#   tools/scripts/set-route.sh <adapter> <asset> [fee] [slippage]
#   tools/scripts/set-route.sh <adapter> --file <csv> [--slippage <bps>] [--dry-run]
#   make set-route ADAPTER=<adapter> ASSET=<asset> [FEE=<fee>] [SLIPPAGE=<bps>]
#   make set-route ADAPTER=<adapter> FILE=<csv> [SLIPPAGE=<bps>] [DRY_RUN=1]
#
#   fee       pool fee tier: 100, 500, 3000 or 10000. Empty: the tier with the most in-range
#             liquidity is picked. In file mode the fee of the listed pool is used.
#   slippage  allowed deviation from the TWAP output in bps, default 100 (1%), at most 500.
#
# CSV: header line, then `Ticker,Contract address,Uniswap V3 / USDG pool` per asset
# (tools/scripts/robinhood-assets.csv). A row is routed only if its pool is the factory pool for
# (USDG, asset, pool fee) and has price history over the adapter TWAP window; other rows are
# reported and skipped. Rows already routed to the same pool and slippage send nothing.
#
# From .env: RPC, PRIVATE_KEY, USDG_ADDRESS, UNISWAP_V3_FACTORY. The sender must be the adapter
# owner.
set -euo pipefail

usage() {
    echo "Usage: $0 <adapter> <asset> [fee] [slippage]" >&2
    echo "       $0 <adapter> --file <csv> [--slippage <bps>] [--dry-run]" >&2
    exit 1
}

[ $# -ge 2 ] || usage
ADAPTER="$1"
shift
FILE=""
ASSET=""
FEE=""
SLIPPAGE=100
DRY_RUN=false
if [ "$1" = "--file" ]; then
    [ $# -ge 2 ] || usage
    FILE="$2"
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --slippage) [ $# -ge 2 ] || usage; SLIPPAGE="$2"; shift ;;
            --dry-run) DRY_RUN=true ;;
            *) echo "Unknown argument: $1" >&2; usage ;;
        esac
        shift
    done
    FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
else
    [ $# -le 3 ] || usage
    ASSET="$1"
    FEE="${2:-}"
    SLIPPAGE="${3:-100}"
fi

cd "$(dirname "$0")/../.."

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
is_address "$ADAPTER" || { echo "adapter is not an address: $ADAPTER" >&2; usage; }
[ -z "$ASSET" ] || is_address "$ASSET" || { echo "asset is not an address: $ASSET" >&2; usage; }
[ -z "$FILE" ] || [ -f "$FILE" ] || { echo "No file $FILE" >&2; exit 1; }

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
first() { awk '{print $1}'; }
has_code() { [ "$(cast codesize "$1" --rpc-url "$RPC" 2>/dev/null || echo 0)" -gt 0 ]; }

[[ "$SLIPPAGE" =~ ^[0-9]+$ ]] && [ "$SLIPPAGE" -le "$MAX_SLIPPAGE" ] || {
    echo "slippage must be 0..$MAX_SLIPPAGE bps, got $SLIPPAGE" >&2
    exit 1
}

# ------------------------------------------------------------------------------------------------
# Adapter checks
# ------------------------------------------------------------------------------------------------

has_code "$ADAPTER" || { echo "Adapter $ADAPTER has no code on this network" >&2; exit 1; }
SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
OWNER=$(call "$ADAPTER" "owner()(address)")
if [ "$(lower "$OWNER")" != "$(lower "$SENDER")" ]; then
    echo "Adapter owner is $OWNER, PRIVATE_KEY is $SENDER: only the owner can set routes" >&2
    [ "$DRY_RUN" = true ] || exit 1
fi

# The adapter looks pools up in its own immutable factory; it must be the one from .env.
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
WINDOW=$(call "$ADAPTER" "twapWindow()(uint32)" | first)
VAULT_ADAPTER=$(call "$VAULT" "swapAdapter()(address)")
[ "$(lower "$VAULT_ADAPTER")" = "$(lower "$ADAPTER")" ] || \
    echo "NOTE: vault $VAULT uses adapter $VAULT_ADAPTER; routes take effect only after" \
        "Vault.setSwapAdapter($ADAPTER)"
echo "Adapter $ADAPTER (vault $VAULT), factory $UNISWAP_V3_FACTORY, TWAP window ${WINDOW}s," \
    "slippage $SLIPPAGE bps$([ "$DRY_RUN" = true ] && echo ', DRY RUN')"

# ------------------------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------------------------

pool_of() {
    call "$UNISWAP_V3_FACTORY" "getPool(address,address,uint24)(address)" "$USDG_ADDRESS" "$1" "$2"
}

# setRoute reverts unless the pool can give a TWAP over the adapter window.
twap_ok() {
    cast call "$1" "observe(uint32[])(int56[],uint160[])" "[$WINDOW,0]" --rpc-url "$RPC" \
        >/dev/null 2>&1
}

# Sends setRoute unless the asset already has this route. Prints the outcome after `label`.
route() {
    local asset="$1" fee="$2" pool="$3" label="$4" current
    # cast annotates large numbers (`10000 [1e4]`), drop the annotation before comparing
    current=$(call "$ADAPTER" "routeOf(address)((address,uint24,uint16))" "$asset" \
        | sed 's/ \[[^]]*\]//g' | tr -d '() ')
    if [ "$(lower "$current")" = "$(lower "$pool,$fee,$SLIPPAGE")" ]; then
        echo "  $label: already routed"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        echo "  $label: would route pool $pool fee $fee"
        return 0
    fi
    if ! cast send "$ADAPTER" "setRoute(address,uint24,uint16)" "$asset" "$fee" "$SLIPPAGE" \
        --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null; then
        return 1
    fi
    echo "  $label: routed pool $pool fee $fee"
}

# ------------------------------------------------------------------------------------------------
# One asset
# ------------------------------------------------------------------------------------------------

if [ -n "$ASSET" ]; then
    [ "$(lower "$ASSET")" != "$(lower "$USDG_ADDRESS")" ] || {
        echo "USDG is credited without a swap, it needs no route"
        exit 0
    }
    has_code "$ASSET" || { echo "Asset $ASSET has no code on this network" >&2; exit 1; }
    SYMBOL=$(call "$ASSET" "symbol()(string)" 2>/dev/null | tr -d '"' || echo "?")
    POOL=""
    if [ -n "$FEE" ]; then
        POOL=$(pool_of "$ASSET" "$FEE")
        [ "$POOL" != "$ZERO" ] || {
            echo "No USDG/$SYMBOL pool with fee $FEE in factory $UNISWAP_V3_FACTORY" >&2
            exit 1
        }
    else
        best=0
        for f in "${FEE_TIERS[@]}"; do
            p=$(pool_of "$ASSET" "$f")
            [ "$p" != "$ZERO" ] || continue
            liq=$(call "$p" "liquidity()(uint128)" | first)
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
    twap_ok "$POOL" || {
        echo "Pool $POOL has no price history over ${WINDOW}s (observe reverts OLD). Raise the" \
            "observation cardinality, wait for the window to fill, then rerun:" >&2
        echo "  cast send $POOL 'increaseObservationCardinalityNext(uint16)' 300" \
            "--rpc-url \$RPC --private-key \$PRIVATE_KEY" >&2
        exit 1
    }
    route "$ASSET" "$FEE" "$POOL" "$SYMBOL $ASSET"
    [ "$DRY_RUN" = true ] && exit 0
    echo "Quote for 1 USDG: $(call "$ADAPTER" "quote(address,uint256)(uint256)" "$ASSET" 1000000 | first)," \
        "min out $(call "$ADAPTER" "minAmountOut(address,uint256)(uint256)" "$ASSET" 1000000 | first) (raw units)"
    exit 0
fi

# ------------------------------------------------------------------------------------------------
# File mode
# ------------------------------------------------------------------------------------------------

total=0 routed=0 no_pool=0 no_twap=0 failed=0
NO_TWAP_LIST=""
while IFS=, read -r ticker asset pool _rest || [ -n "${ticker:-}" ]; do
    ticker=$(echo "$ticker" | tr -d '[:space:]')
    asset=$(echo "${asset:-}" | tr -d '[:space:]')
    pool=$(echo "${pool:-}" | tr -d '[:space:]')
    [ -n "$ticker" ] || continue
    total=$((total + 1))
    label="$ticker $asset"

    if ! is_address "$asset" || ! is_address "$pool" || ! has_code "$pool"; then
        echo "  $label: SKIP no pool ('$pool')"
        no_pool=$((no_pool + 1)); continue
    fi
    fee=$(call "$pool" "fee()(uint24)" 2>/dev/null | first || echo "")
    factory_pool=$([ -n "$fee" ] && pool_of "$asset" "$fee" || echo "$ZERO")
    if [ "$(lower "$factory_pool")" != "$(lower "$pool")" ]; then
        echo "  $label: SKIP $pool is not the factory USDG pool for fee '$fee'"
        no_pool=$((no_pool + 1)); continue
    fi
    if ! twap_ok "$pool"; then
        echo "  $label: SKIP pool $pool has no price history over ${WINDOW}s"
        no_twap=$((no_twap + 1)); NO_TWAP_LIST="$NO_TWAP_LIST $pool"; continue
    fi
    if route "$asset" "$fee" "$pool" "$label"; then
        routed=$((routed + 1))
    else
        echo "  $label: FAILED setRoute"
        failed=$((failed + 1))
    fi
done < <(tail -n +2 "$FILE")

echo
echo "Rows $total: routed $routed, no pool $no_pool, no TWAP history $no_twap, failed $failed"
if [ "$no_twap" -gt 0 ]; then
    echo "Pools without enough history: raise cardinality, wait ${WINDOW}s of trading, rerun:"
    for p in $NO_TWAP_LIST; do
        echo "  cast send $p 'increaseObservationCardinalityNext(uint16)' 300" \
            "--rpc-url \$RPC --private-key \$PRIVATE_KEY"
    done
fi
[ "$failed" -eq 0 ]
