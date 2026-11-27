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
if command -v sha256sum >/dev/null 2>&1; then
    (cd -- "$ROOT/dist" && sha256sum -c vps-toolbox.sh.sha256 >/dev/null)
fi
dev_help="$(bash "$ROOT/src/main.sh" help)"
dist_help="$(bash "$ROOT/dist/vps-toolbox.sh" help)"
[[ "$dev_help" == "$dist_help" ]]
dev_functions="$(bash -c 'source "$1"; declare -F | wc -l' _ "$ROOT/dist/vps-toolbox.sh")"
[[ -n "$dev_functions" ]]

# Unit tests for pure validation and version helper functions
bash -c '
set -euo pipefail
source "$1"
[[ "$(vps_main --version)" == "v$sh_v" ]]
[[ "$(vps_version_value 0.3.0)" -gt "$(vps_version_value 0.2.1)" ]]
vps_valid_port 22
vps_valid_port 65535
! vps_valid_port 0
! vps_valid_port 65536
vps_valid_hostname "node-1.example.com"
! vps_valid_hostname "-bad.example.com"
vps_dns_valid_ipv4 "1.1.1.1"
! vps_dns_valid_ipv4 "256.1.1.1"
vps_dns_valid_ipv6 "2606:4700:4700::1111"
! vps_dns_valid_ipv6 "2606:4700::1111::1"
caddy_domain_ok "app.example.com"
! caddy_domain_ok "bad..example.com"
[[ "$(vps_ts_format_tags "vps,tag:prod")" == "tag:vps,tag:prod" ]]
' _ "$ROOT/dist/vps-toolbox.sh"

echo 'PASS: syntax, build, help parity and unit checks'
