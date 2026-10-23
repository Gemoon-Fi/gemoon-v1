#!/usr/bin/env bash
# Sets the receiver of the protocol share of every swap fee on the hook
# (HookManager.setProtocolRecipient). Only the hook owner can change it. Fees already accrued in the
# hook go to the new recipient on their next payout.
#
# Usage:
#   tools/scripts/set_protocol_recipient.sh [<recipient>] [--hook <hook>] [--dry-run] [--force]
#   make set-protocol-recipient [RECIPIENT=<recipient>] [HOOK=<hook>] [DRY_RUN=1] [FORCE=1]
#
# Defaults: <recipient> = REFERRALS_PROXY_ADDRESS, <hook> = HOOK_ADDRESS.
# A recipient with code is notified by the hook (IProtocolFeeReceiver.notifyFee) and must accept
# it, otherwise every payout of the hook fails: such a recipient must be the Referrals contract of
# this hook (its hook() and pairToken() match). --force skips that check (e.g. a Safe on an old hook
# implementation that does not notify yet). An EOA is accepted as is. --dry-run checks everything
# and sends nothing.
#
# From env/$ENVIRONMENT.mk: RPC, PRIVATE_KEY, HOOK_ADDRESS / REFERRALS_PROXY_ADDRESS (defaults). The sender
# must be the hook owner.
set -euo pipefail

usage() {
    echo "Usage: $0 [<recipient>] [--hook <hook>] [--dry-run] [--force]" >&2
    exit 1
}

RECIPIENT=""
HOOK=""
DRY_RUN=false
FORCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --hook) [ $# -ge 2 ] || usage; HOOK="$2"; shift ;;
        --dry-run) DRY_RUN=true ;;
        --force) FORCE=true ;;
        0x*) RECIPIENT="$1" ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1" >&2; usage ;;
    esac
    shift
done

cd "$(dirname "$0")/../.."

# shellcheck source=tools/scripts/load-env.sh
source tools/scripts/load-env.sh
for var in RPC PRIVATE_KEY; do
    [ -n "${!var:-}" ] || { echo "$var is empty in $ENV_FILE" >&2; exit 1; }
done
HOOK="${HOOK:-${HOOK_ADDRESS:-}}"
RECIPIENT="${RECIPIENT:-${REFERRALS_PROXY_ADDRESS:-}}"
[ -n "$HOOK" ] || { echo "No hook: pass --hook or set HOOK_ADDRESS" >&2; usage; }
[ -n "$RECIPIENT" ] || { echo "No recipient: pass it or set REFERRALS_PROXY_ADDRESS" >&2; usage; }

ZERO=0x0000000000000000000000000000000000000000

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
call() { cast call "$@" --rpc-url "$RPC"; }
has_code() { [ "$(cast codesize "$1" --rpc-url "$RPC" 2>/dev/null || echo 0)" -gt 0 ]; }

is_address "$HOOK" || { echo "hook is not an address: $HOOK" >&2; usage; }
is_address "$RECIPIENT" || { echo "recipient is not an address: $RECIPIENT" >&2; usage; }
[ "$(lower "$RECIPIENT")" != "$ZERO" ] || { echo "recipient is the zero address" >&2; exit 1; }

# ------------------------------------------------------------------------------------------------
# Hook checks
# ------------------------------------------------------------------------------------------------

has_code "$HOOK" || { echo "Hook $HOOK has no code on this network" >&2; exit 1; }
PAIR_TOKEN=$(call "$HOOK" "pairToken()(address)")
CURRENT=$(call "$HOOK" "protocolRecipient()(address)")
OWNER=$(call "$HOOK" "owner()(address)")
OVERHEAD=$(call "$HOOK" "PAYOUT_GAS_OVERHEAD()(uint256)" | awk '{print $1}')
SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")

echo "Hook $HOOK, owner $OWNER, pair token $PAIR_TOKEN$([ "$DRY_RUN" = true ] && echo ', DRY RUN')"
echo "Protocol recipient: $CURRENT -> $RECIPIENT"

if [ "$(lower "$OWNER")" != "$(lower "$SENDER")" ]; then
    PENDING=$(call "$HOOK" "pendingOwner()(address)")
    echo "Hook owner is $OWNER, PRIVATE_KEY is $SENDER: only the owner can set the recipient." >&2
    [ "$(lower "$PENDING")" = "$(lower "$SENDER")" ] && \
        echo "You are the pending owner: call HookManager.acceptOwnership() first." >&2
    [ "$DRY_RUN" = true ] || exit 1
fi

if [ "$(lower "$CURRENT")" = "$(lower "$RECIPIENT")" ]; then
    echo "Already set, nothing to do."
    exit 0
fi

# The implementation that notifies the recipient raised PAYOUT_GAS_OVERHEAD from 150k.
NOTIFIES=true
if [ "$OVERHEAD" = "150000" ]; then
    NOTIFIES=false
    echo "WARNING: hook implementation does not notify the recipient yet (old hook: deploy a new one):" >&2
    echo "         fees arrive unattributed, Referrals count them all as protocol share." >&2
fi

# ------------------------------------------------------------------------------------------------
# Recipient checks
# ------------------------------------------------------------------------------------------------

if has_code "$RECIPIENT"; then
    REF_HOOK=$(call "$RECIPIENT" "hook()(address)" 2>/dev/null || echo "")
    REF_PAIR=$(call "$RECIPIENT" "pairToken()(address)" 2>/dev/null || echo "")
    if [ "$(lower "$REF_HOOK")" = "$(lower "$HOOK")" ] && \
        [ "$(lower "$REF_PAIR")" = "$(lower "$PAIR_TOKEN")" ]; then
        echo "Recipient is Referrals of this hook (owner $(call "$RECIPIENT" "owner()(address)")," \
            "ref share $(call "$RECIPIENT" "refShareBips()(uint256)" | awk '{print $1}') bips)"
    elif [ "$FORCE" = true ]; then
        echo "WARNING: recipient has code but is not Referrals of this hook (hook() '$REF_HOOK'," \
            "pairToken() '$REF_PAIR'), --force." >&2
        [ "$NOTIFIES" = false ] || \
            echo "WARNING: this hook notifies contract recipients: payouts fail unless it" \
                "implements notifyFee(address,uint256)." >&2
    else
        echo "Recipient $RECIPIENT has code but is not Referrals of this hook" \
            "(hook() '$REF_HOOK', pairToken() '$REF_PAIR')." >&2
        echo "The hook would call notifyFee on it and every payout would fail." >&2
        echo "Fix Referrals.setHook / pick the right address, or pass --force." >&2
        exit 1
    fi
else
    echo "Recipient is an EOA: receives the protocol share directly, no referrals."
fi

# ------------------------------------------------------------------------------------------------
# Send
# ------------------------------------------------------------------------------------------------

if [ "$DRY_RUN" = true ]; then
    echo "Would call setProtocolRecipient($RECIPIENT)"
    exit 0
fi

cast send "$HOOK" "setProtocolRecipient(address)" "$RECIPIENT" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
NEW=$(call "$HOOK" "protocolRecipient()(address)")
[ "$(lower "$NEW")" = "$(lower "$RECIPIENT")" ] || {
    echo "protocolRecipient() is $NEW after the transaction, expected $RECIPIENT" >&2
    exit 1
}
echo "Protocol recipient set: $NEW"
