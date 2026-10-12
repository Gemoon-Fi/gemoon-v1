#!/bin/bash
# Начислить ERC20 на адрес. Работает с любым токеном (mint не нужен): пишет баланс
# напрямую в storage через anvil_setStorageAt. Только anvil / anvil-форк.
#
#   ./project/mint.sh <TOKEN> <RECIPIENT> [AMOUNT]
#
#   AMOUNT  в человеческих единицах с учётом decimals (по умолчанию 1000)
#
# RPC_URL переопределяет anvil по умолчанию.
set -euo pipefail

RPC="${RPC_URL:-https://rpc-testnet.gmoon.xyz}"
TOKEN="${1:?usage: $0 <TOKEN> <RECIPIENT> [AMOUNT]}"
TO="${2:?usage: $0 <TOKEN> <RECIPIENT> [AMOUNT]}"
AMOUNT="${3:-1000}"

SYMBOL=$(cast call "$TOKEN" 'symbol()(string)' --rpc-url "$RPC" | tr -d '"')
DECIMALS=$(cast call "$TOKEN" 'decimals()(uint8)' --rpc-url "$RPC")
AMOUNT_RAW=$(python3 -c "from decimal import Decimal; print(int(Decimal('$AMOUNT')*10**$DECIMALS))")

fmt() { python3 -c "from decimal import Decimal; print(f'{Decimal($1)/10**$DECIMALS:,.${DECIMALS}f}'.rstrip('0').rstrip('.') or '0')"; }
balance() { cast call "$TOKEN" 'balanceOf(address)(uint256)' "$TO" --rpc-url "$RPC" | awk '{print $1}'; }
storage() { cast storage "$TOKEN" "$1" --rpc-url "$RPC"; }
set_storage() { cast rpc anvil_setStorageAt "$TOKEN" "$1" "$2" --rpc-url "$RPC" >/dev/null; }

BEFORE=$(balance)
echo "token     $TOKEN ($SYMBOL, decimals $DECIMALS)"
echo "to        $TO"
echo "balance   $(fmt "$BEFORE") $SYMBOL"

# Проверяет, что слот $1 это слот баланса: пишет пробное значение, читает balanceOf, откатывает.
PROBE=0x00000000000000000000000000000000000000000000000000000000deadbeef
is_balance_slot() {
  local slot=$1 orig
  orig=$(storage "$slot")
  set_storage "$slot" "$PROBE"
  local got; got=$(balance 2>/dev/null || true)
  set_storage "$slot" "$orig"
  [ "$got" = "$((16#deadbeef))" ]
}

# --- 1. ищем слот баланса ---------------------------------------------------------
# Основной способ: трассируем balanceOf и берём ключи всех SLOAD (работает для любой
# раскладки: OZ v4/v5, ERC-7201, прокси, Vyper, Solady).
CALLDATA=$(cast calldata 'balanceOf(address)' "$TO")
CANDIDATES=$(cast rpc debug_traceCall "{\"to\":\"$TOKEN\",\"data\":\"$CALLDATA\"}" latest \
    '{"disableStorage":true,"enableMemory":false}' --rpc-url "$RPC" 2>/dev/null \
  | python3 -c "
import json,sys
try: logs=json.load(sys.stdin)['structLogs']
except Exception: sys.exit(0)
seen=[]
for l in logs:
    if l['op']=='SLOAD' and l.get('stack'):
        k=l['stack'][-1]; k='0x'+k[2:].zfill(64) if k.startswith('0x') else '0x'+k.zfill(64)
        if k not in seen: seen.append(k)
print('\n'.join(seen))" || true)

SLOT=""
for c in $CANDIDATES; do
  if is_balance_slot "$c"; then SLOT=$c; break; fi
done

# Запасной способ: перебор базовых слотов mapping'а (Solidity и Vyper раскладки).
if [ -z "$SLOT" ]; then
  echo "trace didn't reveal the slot, scanning mapping base slots..."
  ERC7201_ERC20=0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00
  for base in $(seq 0 60) $ERC7201_ERC20; do
    for layout in sol vyper; do
      if [ $layout = sol ]; then enc=$(cast abi-encode 'f(address,uint256)' "$TO" "$base")
      else                        enc=$(cast abi-encode 'f(uint256,address)' "$base" "$TO"); fi
      c=$(cast keccak "$enc")
      if is_balance_slot "$c"; then SLOT=$c; break 2; fi
    done
  done
fi
[ -n "$SLOT" ] || { echo "balance slot not found"; exit 1; }
echo "slot      $SLOT"

# --- 2. пишем новый баланс ---------------------------------------------------------
NEW=$(python3 -c "print($BEFORE + $AMOUNT_RAW)")
set_storage "$SLOT" "$(cast to-uint256 "$NEW")"

# --- 3. totalSupply: подправить, если слот определяется однозначно --------------------
TS=$(cast call "$TOKEN" 'totalSupply()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
TS_CALLDATA=$(cast calldata 'totalSupply()')
TS_SLOT=$(cast rpc debug_traceCall "{\"to\":\"$TOKEN\",\"data\":\"$TS_CALLDATA\"}" latest \
    '{"disableStorage":true,"enableMemory":false}' --rpc-url "$RPC" 2>/dev/null \
  | python3 -c "
import json,sys
try: logs=json.load(sys.stdin)['structLogs']
except Exception: sys.exit(0)
ts=$TS; hits=[]
for i,l in enumerate(logs):
    if l['op']=='SLOAD' and l.get('stack') and i+1<len(logs):
        v=int(logs[i+1]['stack'][-1],16)
        if v==ts:
            k=l['stack'][-1]; k='0x'+k[2:].zfill(64) if k.startswith('0x') else '0x'+k.zfill(64)
            if k not in hits: hits.append(k)
print(hits[0] if len(hits)==1 else '')" || true)
if [ -n "$TS_SLOT" ]; then
  set_storage "$TS_SLOT" "$(cast to-uint256 "$(python3 -c "print($TS + $AMOUNT_RAW)")")"
  echo "supply    $(fmt "$TS") -> $(fmt "$(python3 -c "print($TS + $AMOUNT_RAW)")") $SYMBOL"
else
  echo "supply    slot not identified, totalSupply left as is"
fi

# --- 4. результат --------------------------------------------------------------------
AFTER=$(balance)
[ "$AFTER" = "$NEW" ] || { echo "balance mismatch: expected $NEW, got $AFTER"; exit 1; }
echo "minted    $(fmt "$AMOUNT_RAW") $SYMBOL"
echo "balance   $(fmt "$AFTER") $SYMBOL"
