#!/usr/bin/env bash
# Verifies on Sourcify (API v2) every Meme token the GemoonController has created.
#
# Usage:
#   make -f verify.mk verify-tokens-sourcify ENVIRONMENT=prod [SOURCE_REF=<commit>]
#
# All tokens share one creation code and differ only in constructor args (Sourcify reads them from
# the creation tx), so one standard JSON input serves all of them. It is generated from the working
# tree with every changed source replaced by its SOURCE_REF version (default HEAD): the tokens on chain
# were built by the deployed controller, not by uncommitted edits. Tokens come from the TokenCreated
# events of the controller, read through the Blockscout API (no 500-block log limit as on the RPC).
# Already verified tokens are reported and skipped, so the script can be rerun for new tokens.
#
# From env/$ENVIRONMENT.mk: RPC, BLOCKSCOUT_API_KEY, CONTROLLER_PROXY_ADDRESS.
set -euo pipefail

source ./tools/scripts/load-env.sh

SOURCE_REF="${SOURCE_REF:-HEAD}"
SOURCIFY_URL="${SOURCIFY_URL:-https://sourcify.dev/server}"
SOLC_VERSION="${SOLC_VERSION:-0.8.26+commit.8a97fa7a}"
OUT_DIR="${STANDARD_JSON_DIR:-deploy-logs/standard-json}"
TOKEN_CONTRACT="src/contracts/Token.sol:GemoonToken"

for var in RPC BLOCKSCOUT_API_KEY CONTROLLER_PROXY_ADDRESS; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done

CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
TOPIC=$(cast keccak "TokenCreated(address,address,uint256,address,string,string)")

# ---- Tokens: "<address> <creation tx>" per line --------------------------------------------------
# curl -q: ignore ~/.curlrc, its extra output would break the JSON.
TOKENS=""
page=1
while :; do
    res=$(curl -q -s -m 60 "https://api.blockscout.com/v2/api?chain_id=$CHAIN_ID&apikey=$BLOCKSCOUT_API_KEY&module=logs&action=getLogs&address=$CONTROLLER_PROXY_ADDRESS&topic0=$TOPIC&fromBlock=0&toBlock=latest&page=$page&offset=1000")
    rows=$(jq -r '(.result // [])[] | "0x" + .topics[1][-40:] + " " + .transactionHash' <<<"$res") || {
        echo "Unexpected Blockscout response: $res" >&2
        exit 1
    }
    [ -z "$rows" ] && break
    TOKENS+="$rows"$'\n'
    [ "$(wc -l <<<"$rows")" -lt 1000 ] && break
    page=$((page + 1))
done
TOKENS=$(sed '/^$/d' <<<"$TOKENS")
[ -n "$TOKENS" ] || { echo "No TokenCreated events of $CONTROLLER_PROXY_ADDRESS on chain $CHAIN_ID"; exit 0; }
echo "Tokens of controller $CONTROLLER_PROXY_ADDRESS on chain $CHAIN_ID: $(wc -l <<<"$TOKENS" | tr -d ' ')"

# ---- Standard JSON input of GemoonToken at SOURCE_REF --------------------------------------------
mkdir -p "$OUT_DIR"
INPUT="$OUT_DIR/GemoonToken.json"
FIRST=$(head -n 1 <<<"$TOKENS" | cut -d' ' -f1)
forge verify-contract --show-standard-json-input "$FIRST" "$TOKEN_CONTRACT" > "$INPUT"
for path in $(jq -r '.sources | keys[]' "$INPUT"); do
    git ls-files --error-unmatch "$path" >/dev/null 2>&1 || continue
    git diff --quiet "$SOURCE_REF" -- "$path" && continue
    echo "  source from $SOURCE_REF: $path"
    jq --arg p "$path" --rawfile c <(git show "$SOURCE_REF:$path") '.sources[$p].content = $c' "$INPUT" > "$INPUT.tmp"
    mv "$INPUT.tmp" "$INPUT"
done
echo "Standard JSON input: $INPUT"

# ---- Submit every token, then wait for the jobs --------------------------------------------------
JOBS=""
while read -r token tx; do
    body=$(jq -n --slurpfile s "$INPUT" --arg v "$SOLC_VERSION" --arg c "$TOKEN_CONTRACT" --arg tx "$tx" \
        '{stdJsonInput: $s[0], compilerVersion: $v, contractIdentifier: $c, creationTransactionHash: $tx}' \
        | curl -q -s -m 60 -X POST -H 'content-type: application/json' --data @- \
            "$SOURCIFY_URL/v2/verify/$CHAIN_ID/$token")
    id=$(jq -r '.verificationId // empty' <<<"$body" 2>/dev/null || true)
    code=$(jq -r '.customCode // empty' <<<"$body" 2>/dev/null || true)
    if [ -n "$id" ]; then
        JOBS+="$token $id"$'\n'
    elif [ "$code" = "already_verified" ]; then
        echo "  $token already verified"
    else
        echo "  $token FAILED to submit: $body" >&2
    fi
done <<<"$TOKENS"

FAILED=0
while read -r token id; do
    [ -n "$token" ] || continue
    for _ in $(seq 1 30); do
        res=$(curl -q -s -m 30 "$SOURCIFY_URL/v2/verify/$id")
        [ "$(jq -r '.isJobCompleted' <<<"$res" 2>/dev/null)" = "true" ] && break
        sleep 10
    done
    match=$(jq -r '.contract.match // empty' <<<"$res" 2>/dev/null || true)
    if [ -n "$match" ]; then
        echo "  $token $match"
    else
        echo "  $token FAILED: $(jq -c '.error // .' <<<"$res" 2>/dev/null || echo "$res")" >&2
        FAILED=1
    fi
done <<<"$JOBS"

exit "$FAILED"
