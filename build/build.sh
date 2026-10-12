#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src"
OUT="$ROOT/dist/vps-toolbox.sh"
mkdir -p "$ROOT/dist"
STAGED="$(mktemp "$ROOT/dist/.vps-toolbox.XXXXXXXX")"
trap 'rm -f -- "$STAGED"' EXIT
# Preserve the original shebang, license/header and installation markers.
cat "$SRC/config/constants.sh" > "$STAGED"
while IFS= read -r module || [[ -n "$module" ]]; do
    [[ -z "$module" || "$module" == \#* ]] && continue
    if [[ "$module" == /* || "$module" == *..* || ! -f "$SRC/$module" ]]; then
        printf 'Invalid or missing module: %s\n' "$module" >&2
        exit 1
    fi
    printf '\n# ---- BEGIN %s ----\n' "$module" >> "$STAGED"
    cat "$SRC/$module" >> "$STAGED"
    printf '\n# ---- END %s ----\n' "$module" >> "$STAGED"
done < "$ROOT/build/modules.txt"
printf '\nif [[ "${BASH_SOURCE[0]}" == "$0" ]]; then\n    vps_main "$@"\nfi\n' >> "$STAGED"
bash -n "$STAGED"
chmod 755 "$STAGED"
mv -f -- "$STAGED" "$OUT"
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$OUT" || echo 'ShellCheck reported existing script warnings.' >&2
fi
printf 'Built %s (%s lines)\n' "$OUT" "$(wc -l < "$OUT")"
