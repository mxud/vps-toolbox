#!/usr/bin/env bash
# Usage: bash install.sh OWNER/vps-toolbox [branch]
set -euo pipefail
repo="${1:-}"
branch="${2:-main}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || [[ ! "$branch" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo 'Usage: bash install.sh OWNER/vps-toolbox [branch]' >&2
    exit 2
fi
if [[ "${EUID}" -ne 0 ]]; then
    echo 'Please run with sudo/root.' >&2
    exit 1
fi
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 1; }
command -v install >/dev/null || { echo 'coreutils install is required' >&2; exit 1; }
tmp="$(mktemp /tmp/vps-toolbox-download.XXXXXXXX)"
sha_tmp="$(mktemp /tmp/vps-toolbox-sha256.XXXXXXXX)"
trap 'rm -f -- "$tmp" "$sha_tmp"' EXIT
gh_proxy="${VPS_GITHUB_PROXY:-https://}"
url="${gh_proxy}raw.githubusercontent.com/${repo}/${branch}/dist/vps-toolbox.sh"
echo "Downloading $url"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 90 "$url" -o "$tmp"
if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 "${url}.sha256" -o "$sha_tmp"
    expected_sha="$(awk '{print $1; exit}' "$sha_tmp")"
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
    else
        actual_sha="$(shasum -a 256 "$tmp" | awk '{print $1}')"
    fi
    if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || [[ "${expected_sha,,}" != "${actual_sha,,}" ]]; then
        echo 'SHA256 checksum verification failed.' >&2
        exit 1
    fi
fi
[[ -s "$tmp" ]] && head -n1 "$tmp" | grep -qx '#!/bin/bash' && grep -qx '# VPS Toolbox' "$tmp" && bash -n "$tmp" || {
    echo 'Downloaded file failed sanity checks.' >&2; exit 1;
}
target=/usr/local/bin/vps-toolbox
if [[ -L "$target" ]] || { [[ -e "$target" ]] && ! grep -qx '# VPS Toolbox' "$target"; }; then
    echo "Refusing to overwrite unrelated file or symlink: $target" >&2
    exit 1
fi
if [[ -e "$target" ]]; then
    cp -p -- "$target" "${target}.bak"
fi
install -m 755 "$tmp" "$target"
shortcut=/usr/local/bin/vps
if [[ -e "$shortcut" && ! -L "$shortcut" ]]; then
    echo 'Installed toolbox; /usr/local/bin/vps belongs to another program, shortcut not created.' >&2
elif [[ -L "$shortcut" && "$(readlink "$shortcut")" != "$target" ]]; then
    echo 'Installed toolbox; existing vps symlink points elsewhere, shortcut not changed.' >&2
else
    ln -sfn "$target" "$shortcut"
fi
# Update URL persistence currently follows main branch. For other branches,
# supply VPS_UPDATE_URL explicitly when upgrading.
if [[ "$branch" == main ]]; then
    printf '%s\n' "$repo" > /etc/vps-toolbox.repo
    chmod 644 /etc/vps-toolbox.repo
fi
echo 'Installation complete. Run: vps'
