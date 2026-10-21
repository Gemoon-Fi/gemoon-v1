#!/usr/bin/env bash
# Deploys N Memes with random parameters through GemoonController.deployToken, for filling a
# devnet with test data. Each Meme gets a random name, ticker, description, image, base swap fee
# (MIN_MEME_FEE_BIPS..MAX_MEME_FEE_BIPS of the hook) and 1..4 reward assets taken from the vault
# allowlist with random weights summing to 10000 bps. No dev buy. The sender is the creator, the
# admin and the reward recipient of every Meme.
#
# Usage:
#   tools/scripts/create-tokens.sh [count] [--dry-run]
#   make create-tokens [COUNT=150] [DRY_RUN=1]
#
#   count  number of Memes, default 10.
#
# From env/$ENVIRONMENT.mk: RPC, PRIVATE_KEY, CONTROLLER_PROXY_ADDRESS. Not for mainnet: every Meme is a real pool.
set -euo pipefail

usage() {
    echo "Usage: $0 [count] [--dry-run]" >&2
    exit 1
}

COUNT=10
DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        *) [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ] || usage; COUNT="$1" ;;
    esac
    shift
done

cd "$(dirname "$0")/../.."

# shellcheck source=tools/scripts/load-env.sh
source tools/scripts/load-env.sh
for var in RPC PRIVATE_KEY CONTROLLER_PROXY_ADDRESS; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done

call() { cast call "$@" --rpc-url "$RPC"; }
first() { awk '{print $1}'; }
# Random integer in [min, max].
rand() { echo $(($1 + (RANDOM * 32768 + RANDOM) % ($2 - $1 + 1))); }
# Random element of the arguments.
pick() { shift $((RANDOM % $#)); echo "$1"; }

CONTROLLER="$CONTROLLER_PROXY_ADDRESS"
SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")
HOOK=$(call "$CONTROLLER" "hook()(address)")
VAULT=$(call "$CONTROLLER" "vault()(address)")
MIN_FEE=$(call "$HOOK" "MIN_MEME_FEE_BIPS()(uint256)" | first)
MAX_FEE=$(call "$HOOK" "MAX_MEME_FEE_BIPS()(uint256)" | first)
read -ra ASSETS <<< "$(call "$VAULT" "allowedAssets()(address[])" | tr -d '[],')"
[ "${#ASSETS[@]}" -gt 0 ] || { echo "Vault $VAULT has no allowed reward assets" >&2; exit 1; }
MAX_PICK=$((${#ASSETS[@]} < 4 ? ${#ASSETS[@]} : 4))

echo "Controller $CONTROLLER, vault $VAULT, sender $SENDER"
echo "Fee ${MIN_FEE}..${MAX_FEE} bips, ${#ASSETS[@]} allowed assets, $COUNT Memes$([ "$DRY_RUN" = true ] && echo ', DRY RUN')"

ADJECTIVES=(Based Moon Turbo Giga Lazy Happy Angry Cosmic Golden Sleepy Crazy Tiny Mega Wild
    Frozen Electric Shiny Spicy Royal Dark Pixel Lucky Hyper Ultra Sneaky Fluffy Rich Brave)
NOUNS=(Pepe Doge Cat Frog Shiba Ape Bull Bear Panda Whale Rocket Banana Penguin Hamster
    Otter Duck Goblin Wizard Dragon Taco Pizza Cookie Llama Tiger Koala Unicorn Robot Alien)
TAGLINES=("to the moon" "community owned" "no roadmap just vibes" "the people's meme"
    "built different" "for degens by degens" "pure memetic energy" "wagmi" "send it")

SIG="deployToken(((string,string,(string,string,string,string),string,string,(address,bool)[]),(uint256,address,address),(address,uint16)[],uint16,(uint256,uint256)))"

ok=0 failed=0
for i in $(seq 1 "$COUNT"); do
    adj=$(pick "${ADJECTIVES[@]}")
    noun=$(pick "${NOUNS[@]}")
    name="$adj $noun"
    symbol=$(echo "${adj:0:2}${noun:0:3}$(rand 0 99)" | tr '[:lower:]' '[:upper:]')
    description="$name - $(pick "${TAGLINES[@]}")"
    handle=$(echo "$adj$noun" | tr '[:upper:]' '[:lower:]')
    image="https://api.dicebear.com/9.x/shapes/svg?seed=$symbol"
    fee=$(rand "$MIN_FEE" "$MAX_FEE")
    # Creator share of the vault fees: 0%..50% in 5% steps.
    share=$(($(rand 0 10) * 500))

    # Distinct random assets, weights: random cuts of 10000 with every part at least 1.
    n=$(rand 1 "$MAX_PICK")
    read -ra chosen <<< "$(printf '%s\n' "${ASSETS[@]}" | awk -v seed="$RANDOM$i" 'BEGIN{srand(seed)} {print rand() "\t" $0}' \
        | sort -n | cut -f2 | head -n "$n" | tr '\n' ' ')"
    left=10000 assets=""
    for j in $(seq 0 $((n - 1))); do
        if [ "$j" -eq $((n - 1)) ]; then
            w=$left
        else
            w=$(rand 1 $((left - (n - 1 - j))))
        fi
        left=$((left - w))
        assets="$assets${assets:+,}(${chosen[$j]},$w)"
    done

    config="(($image,$description,(@$handle,@$handle,t.me/$handle,https://$handle.xyz),$name,$symbol,[($SENDER,true)]),($fee,$SENDER,$SENDER),[$assets],$share,(0,0))"
    label="[$i/$COUNT] $symbol \"$name\" fee $fee, creator share $share, $n asset(s)"
    if [ "$DRY_RUN" = true ]; then
        echo "  $label: $config"
        continue
    fi
    # Retries only when the RPC fails before sending (gas estimation): after a receipt timeout the
    # transaction may have landed and a retry would create a second Meme.
    for attempt in 1 2 3; do
        out=$(cast send "$CONTROLLER" "$SIG" "$config" --rpc-url "$RPC" --private-key "$PRIVATE_KEY" \
            --json 2>&1) && sent=true || sent=false
        [ "$sent" = false ] && echo "$out" | grep -q "Failed to estimate gas: error sending request" \
            || break
        sleep $((attempt * 5))
    done
    if [ "$sent" = true ]; then
        # TokenCreated(address indexed tokenAddress, ...) is emitted by the controller
        topic=$(cast keccak "TokenCreated(address,address,uint256,address,string,string)")
        token=$(echo "$out" | jq -r --arg c "$(echo "$CONTROLLER" | tr '[:upper:]' '[:lower:]')" \
            --arg t "$topic" '.logs[] | select((.address | ascii_downcase) == $c and .topics[0] == $t)
            | .topics[1]' | head -1)
        echo "  $label: $(cast parse-bytes32-address "$token")"
        ok=$((ok + 1))
    else
        echo "  $label: FAILED $(echo "$out" | tail -1)"
        failed=$((failed + 1))
    fi
done

echo
echo "Created $ok, failed $failed"
[ "$failed" -eq 0 ]
