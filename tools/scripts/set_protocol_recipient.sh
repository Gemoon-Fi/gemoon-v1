#!/usr/bin/env bash
# Sets the receiver of the protocol share of every swap fee on the vault
# (Vault.setProtocolRecipient). The hooks send the whole fee to the vault, the vault splits it and
# sends the protocol share to this recipient inside `notifyFees`. Only the vault owner can change
# it; it applies from the next payout on.
#
# Usage:
#   tools/scripts/set_protocol_recipient.sh [<recipient>] [--vault <vault>] [--dry-run] [--force]
#   make set-protocol-recipient [RECIPIENT=<recipient>] [VAULT=<vault>] [DRY_RUN=1] [FORCE=1]
#
# Defaults: <recipient> = REFERRALS_PROXY_ADDRESS, <vault> = VAULT_PROXY_ADDRESS.
# A recipient with code is notified by the vault (IProtocolFeeReceiver.notifyFee) and must accept
# it, otherwise every payout fails and the fees stay accrued in the hooks: such a recipient must be
# the Referrals contract of this vault (its vault() and pairToken() match). --force skips that
# check. An EOA is accepted as is. --dry-run checks everything and sends nothing.
#
# From env/$ENVIRONMENT.mk: RPC, PRIVATE_KEY, VAULT_PROXY_ADDRESS / REFERRALS_PROXY_ADDRESS
# (defaults). The sender must be the vault owner.
set -euo pipefail

usage() {
    echo "Usage: $0 [<recipient>] [--vault <vault>] [--dry-run] [--force]" >&2
    exit 1
}

RECIPIENT=""
VAULT=""
DRY_RUN=false
FORCE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --vault) [ $# -ge 2 ] || usage; VAULT="$2"; shift ;;
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
VAULT="${VAULT:-${VAULT_PROXY_ADDRESS:-}}"
RECIPIENT="${RECIPIENT:-${REFERRALS_PROXY_ADDRESS:-}}"
[ -n "$VAULT" ] || { echo "No vault: pass --vault or set VAULT_PROXY_ADDRESS" >&2; usage; }
[ -n "$RECIPIENT" ] || { echo "No recipient: pass it or set REFERRALS_PROXY_ADDRESS" >&2; usage; }

ZERO=0x0000000000000000000000000000000000000000

is_address() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
call() { cast call "$@" --rpc-url "$RPC"; }
has_code() { [ "$(cast codesize "$1" --rpc-url "$RPC" 2>/dev/null || echo 0)" -gt 0 ]; }

is_address "$VAULT" || { echo "vault is not an address: $VAULT" >&2; usage; }
is_address "$RECIPIENT" || { echo "recipient is not an address: $RECIPIENT" >&2; usage; }
[ "$(lower "$RECIPIENT")" != "$ZERO" ] || { echo "recipient is the zero address" >&2; exit 1; }

# ------------------------------------------------------------------------------------------------
# Vault checks
# ------------------------------------------------------------------------------------------------

has_code "$VAULT" || { echo "Vault $VAULT has no code on this network" >&2; exit 1; }
CURRENT=$(call "$VAULT" "protocolRecipient()(address)" 2>/dev/null) || {
    echo "Vault $VAULT has no protocolRecipient(): upgrade it to the implementation that splits fees" >&2
    exit 1
}
PAIR_TOKEN=$(call "$VAULT" "usdg()(address)")
SHARE=$(call "$VAULT" "protocolShareBps()(uint256)" | awk '{print $1}')
OWNER=$(call "$VAULT" "owner()(address)")
SENDER=$(cast wallet address --private-key "$PRIVATE_KEY")

echo "Vault $VAULT, owner $OWNER, pair token $PAIR_TOKEN, protocol share $SHARE bps$([ "$DRY_RUN" = true ] && echo ', DRY RUN')"
echo "Protocol recipient: $CURRENT -> $RECIPIENT"

if [ "$(lower "$OWNER")" != "$(lower "$SENDER")" ]; then
    PENDING=$(call "$VAULT" "pendingOwner()(address)")
    echo "Vault owner is $OWNER, PRIVATE_KEY is $SENDER: only the owner can set the recipient." >&2
    [ "$(lower "$PENDING")" = "$(lower "$SENDER")" ] && \
        echo "You are the pending owner: call Vault.acceptOwnership() first." >&2
    [ "$DRY_RUN" = true ] || exit 1
fi

if [ "$(lower "$CURRENT")" = "$(lower "$RECIPIENT")" ]; then
    echo "Already set, nothing to do."
    exit 0
fi

# ------------------------------------------------------------------------------------------------
# Recipient checks
# ------------------------------------------------------------------------------------------------

if has_code "$RECIPIENT"; then
    REF_VAULT=$(call "$RECIPIENT" "vault()(address)" 2>/dev/null || echo "")
    REF_PAIR=$(call "$RECIPIENT" "pairToken()(address)" 2>/dev/null || echo "")
    if [ "$(lower "$REF_VAULT")" = "$(lower "$VAULT")" ] && \
        [ "$(lower "$REF_PAIR")" = "$(lower "$PAIR_TOKEN")" ]; then
        echo "Recipient is Referrals of this vault (owner $(call "$RECIPIENT" "owner()(address)")," \
            "ref share $(call "$RECIPIENT" "refShareBips()(uint256)" | awk '{print $1}') bips)"
    elif [ "$FORCE" = true ]; then
        echo "WARNING: recipient has code but is not Referrals of this vault (vault() '$REF_VAULT'," \
            "pairToken() '$REF_PAIR'), --force." >&2
        echo "WARNING: the vault notifies contract recipients: payouts fail unless it" \
            "implements notifyFee(address,uint256) and accepts the vault." >&2
    else
        echo "Recipient $RECIPIENT has code but is not Referrals of this vault" \
            "(vault() '$REF_VAULT', pairToken() '$REF_PAIR')." >&2
        echo "The vault would call notifyFee on it and every payout would fail." >&2
        echo "Fix Referrals.setVault / pick the right address, or pass --force." >&2
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

cast send "$VAULT" "setProtocolRecipient(address)" "$RECIPIENT" \
    --rpc-url "$RPC" --private-key "$PRIVATE_KEY" >/dev/null
NEW=$(call "$VAULT" "protocolRecipient()(address)")
[ "$(lower "$NEW")" = "$(lower "$RECIPIENT")" ] || {
    echo "protocolRecipient() is $NEW after the transaction, expected $RECIPIENT" >&2
    exit 1
}
echo "Protocol recipient set: $NEW"
