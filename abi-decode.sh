#!/bin/bash
set -euo pipefail

in=${1:?usage: $0 <hexdata> [signature]}
fn=${2:-}

# автодетект если сигнатура не задана
if [[ -z "$fn" ]]; then
  len=$(( (${#in} - 2) / 2 ))   # длина в байтах
  if   [[ $len -eq 32 ]]; then fn="f()(address)"
  elif [[ $len -eq 32 ]]; then fn="f()(uint256)"
  else fn="f()(string)"
  fi
fi

cast abi-decode "$fn" "$in"