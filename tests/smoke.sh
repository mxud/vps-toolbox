#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/src/main.sh"
while IFS= read -r module || [[ -n "$module" ]]; do
    [[ -z "$module" || "$module" == \#* ]] && continue
    bash -n "$ROOT/src/$module"
done < "$ROOT/build/modules.txt"
bash "$ROOT/build/build.sh"
bash -n "$ROOT/dist/vps-toolbox.sh"
dev_help="$(bash "$ROOT/src/main.sh" help)"
dist_help="$(bash "$ROOT/dist/vps-toolbox.sh" help)"
[[ "$dev_help" == "$dist_help" ]]
dev_functions="$(bash -c 'source "$1"; declare -F | wc -l' _ "$ROOT/dist/vps-toolbox.sh")"
[[ -n "$dev_functions" ]]
echo 'PASS: syntax, build and help parity'
