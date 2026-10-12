#!/usr/bin/env bash
# Development launcher. The release is assembled by build/build.sh.
set -o pipefail
VPS_SRC_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Explicit ordering mirrors build/modules.txt. Keep this list in sync by loading manifest.
source "$VPS_SRC_DIR/config/constants.sh"
while IFS= read -r module || [[ -n "$module" ]]; do
    [[ -z "$module" || "$module" == \#* ]] && continue
    source "$VPS_SRC_DIR/$module" || exit 1
done < "$VPS_SRC_DIR/../build/modules.txt"
vps_main "$@"
