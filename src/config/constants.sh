#!/bin/bash
# ============================================================
# VPS Toolbox
# SPDX-License-Identifier: Apache-2.0
# ============================================================

sh_v="0.1.0"

# ============ 颜色定义 ============
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

# ============ 基础配置 ============
VPS_INSTALL_PATH="/usr/local/bin/vps-toolbox"
VPS_DEFAULT_SHORTCUT="vps"
VPS_UPDATE_URL="${VPS_UPDATE_URL:-}"
# Installer writes a repository identifier to allow `vps upgrade` without
# requiring an environment variable on every run. Can be overridden explicitly.
if [ -z "$VPS_UPDATE_URL" ] && [ -r /etc/vps-toolbox.repo ]; then
    IFS= read -r vps_repo < /etc/vps-toolbox.repo || true
    if [[ "$vps_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        VPS_UPDATE_URL="https://raw.githubusercontent.com/${vps_repo}/main/dist/vps-toolbox.sh"
    fi
fi
gh_proxy="${VPS_GITHUB_PROXY:-https://}"

