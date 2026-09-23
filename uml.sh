#!/usr/bin/env bash
# Generates UML diagrams of project contracts into docs/uml/ using sol2uml.
#
# Usage:
#   ./uml.sh                  # project diagrams + deps diagram with DEPS listed below
#   ./uml.sh <dep> [<dep>...] # deps diagram with the given dependencies instead of DEPS
#
# A dependency is a .sol file or folder, either as an import path from the code
# (resolved via remappings.txt, e.g. "@openzeppelin/contracts/access/Ownable2Step.sol")
# or as a plain path (e.g. "lib/uniswap-hooks/src/base").
# Only the listed dependencies are drawn: their own parents are not pulled in automatically.
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"

SRC_DIR="src/contracts"
OUT_DIR="$ROOT/docs/uml"
REMAPPINGS="$ROOT/remappings.txt"
# Show only relations: hide variables, functions, structs, enums, events, modifiers, constants
RELATIONS_FLAGS=(-hv -hf -hs -he -ht -hm -hc)

# Dependencies to include in contracts-deps.* (edit this list or pass deps as arguments)
DEPS=(
    "uniswap-hooks/base/BaseHook.sol"
    "@uniswap-v4-core/interfaces/IPoolManager.sol"
    "@uniswap-v4-periphery/interfaces/IPositionManager.sol"
    "@openzeppelin/contracts/access/Ownable2Step.sol"
    "@openzeppelin/contracts/utils/ReentrancyGuard.sol"
    "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol"
)
if [[ $# -gt 0 ]]; then
    DEPS=("$@")
fi

if command -v sol2uml >/dev/null 2>&1; then
    SOL2UML=(sol2uml)
else
    SOL2UML=(npx --yes sol2uml)
fi

# Resolves an import path to a file path using the longest matching remapping prefix
resolve_dep() {
    local dep="$1" best_prefix="" best_target="" prefix target
    if [[ -e "$dep" ]]; then
        echo "${dep%/}"
        return
    fi
    while IFS='=' read -r prefix target; do
        [[ -z "$prefix" || "$prefix" == \#* ]] && continue
        if [[ "$dep" == "$prefix"* && ${#prefix} -gt ${#best_prefix} ]]; then
            best_prefix="$prefix"
            best_target="$target"
        fi
    done < "$REMAPPINGS"
    local resolved="${best_target}${dep#"$best_prefix"}"
    if [[ -z "$best_prefix" || ! -e "$resolved" ]]; then
        echo "Dependency not found: $dep" >&2
        exit 1
    fi
    echo "${resolved%/}"
}

# Resolve deps before generating anything so a typo fails fast
DEP_PATHS=()
for dep in ${DEPS[@]+"${DEPS[@]}"}; do
    resolved="$(resolve_dep "$dep")"
    DEP_PATHS+=("$resolved")
done

mkdir -p "$OUT_DIR"

# Full diagram: variables, functions, events, structs, libraries
"${SOL2UML[@]}" class "$SRC_DIR" -o "$OUT_DIR/contracts.svg"

# Compact diagram: relations between contracts only
"${SOL2UML[@]}" class "$SRC_DIR" "${RELATIONS_FLAGS[@]}" -o "$OUT_DIR/contracts-relations.svg"
"${SOL2UML[@]}" class "$SRC_DIR" -f png "${RELATIONS_FLAGS[@]}" -o "$OUT_DIR/contracts-relations.png"

# Relations diagram with the selected dependencies.
# sol2uml does not support remappings, so the sources and deps are copied into a staging
# folder (same relative layout) where remapped imports are rewritten to relative paths.
if [[ ${#DEP_PATHS[@]} -gt 0 ]]; then
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT

    sources="$SRC_DIR"
    for path in "$SRC_DIR" "${DEP_PATHS[@]}"; do
        mkdir -p "$STAGE/$(dirname "$path")"
        cp -R "$path" "$STAGE/$(dirname "$path")/"
        [[ "$path" != "$SRC_DIR" ]] && sources+=",$path"
    done

    python3 - "$STAGE" "$REMAPPINGS" <<'PY'
import os, re, sys

stage, remappings_file = sys.argv[1], sys.argv[2]
remappings = []
with open(remappings_file) as f:
    for line in f:
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            prefix, target = line.split("=", 1)
            remappings.append((prefix, target))
remappings.sort(key=lambda r: len(r[0]), reverse=True)

import_re = re.compile(r'(import\s[^;]*?")([^"]+)(")', re.S)

for dirpath, _, files in os.walk(stage):
    for name in files:
        if not name.endswith(".sol"):
            continue
        file_path = os.path.join(dirpath, name)

        def rewrite(m):
            imp = m.group(2)
            for prefix, target in remappings:
                if imp.startswith(prefix):
                    abs_target = os.path.normpath(os.path.join(stage, target + imp[len(prefix):]))
                    return m.group(1) + os.path.relpath(abs_target, dirpath) + m.group(3)
            return m.group(0)

        with open(file_path) as f:
            content = f.read()
        new_content = import_re.sub(rewrite, content)
        if new_content != content:
            with open(file_path, "w") as f:
                f.write(new_content)
PY

    (
        cd "$STAGE"
        "${SOL2UML[@]}" class "$sources" -c "${RELATIONS_FLAGS[@]}" -o "$OUT_DIR/contracts-deps.svg"
        "${SOL2UML[@]}" class "$sources" -c -f png "${RELATIONS_FLAGS[@]}" -o "$OUT_DIR/contracts-deps.png"
    )
fi

echo "UML diagrams generated in $OUT_DIR"
