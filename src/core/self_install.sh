# ============ 自动安装到系统 ============
vps_is_toolbox() {
    [ -f "$1" ] && [ ! -L "$1" ] && grep -qx '# VPS Toolbox' "$1" && bash -n "$1"
}

# 临时文件与目标位于同一目录，最后通过 rename 原子替换。
vps_atomic_install() {
    local source="$1" target="$2" staged backup_stage directory
    directory=$(dirname -- "$target")
    command -v install >/dev/null 2>&1 || pkg_install coreutils || return 1
    [ ! -L "$target" ] && [ ! -L "${target}.bak" ] || {
        echo "拒绝覆盖安装文件或备份的符号链接" >&2; return 1;
    }
    if [ -e "$target" ]; then
        vps_is_toolbox "$target" || { echo "安装路径已有其他文件: $target" >&2; return 1; }
    fi
    staged=$(mktemp "$directory/.vps-install.XXXXXX") || return 1
    if ! command install -m 755 "$source" "$staged" || ! vps_is_toolbox "$staged"; then
        rm -f -- "$staged"; return 1
    fi
    if [ -e "$target" ]; then
        backup_stage=$(mktemp "$directory/.vps-backup.XXXXXX") || { rm -f -- "$staged"; return 1; }
        if ! cp -p -- "$target" "$backup_stage" || ! mv -fT -- "$backup_stage" "${target}.bak"; then
            rm -f -- "$staged" "$backup_stage"; return 1
        fi
    fi
    mv -fT -- "$staged" "$target" || { rm -f -- "$staged"; return 1; }
}

vps_ensure_install() {
    local source="$1" source_ver installed_ver source_value installed_value
    if [ -e "$VPS_INSTALL_PATH" ] || [ -L "$VPS_INSTALL_PATH" ]; then
        vps_is_toolbox "$VPS_INSTALL_PATH" || {
            echo "安装路径不是有效的工具箱脚本: $VPS_INSTALL_PATH" >&2; return 1;
        }
        source_ver=$(grep '^sh_v=' "$source" | head -1 | cut -d'"' -f2)
        installed_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2)
        source_value=$(vps_version_value "$source_ver") && installed_value=$(vps_version_value "$installed_ver") || {
            echo "脚本版本号无效，未替换已安装脚本" >&2; return 1;
        }
        if [ "$source_value" -gt "$installed_value" ]; then
            vps_atomic_install "$source" "$VPS_INSTALL_PATH" || return 1
            echo "安装版本已升级到 v$source_ver；备份: ${VPS_INSTALL_PATH}.bak"
        fi
        return 0
    fi
    vps_atomic_install "$source" "$VPS_INSTALL_PATH"
}

vps_self_install() {
    [ "$(id -u)" -eq 0 ] || return 0
    local source_path shortcut_path="$(dirname -- "$VPS_INSTALL_PATH")/$VPS_DEFAULT_SHORTCUT"
    source_path="$(readlink -f "${BASH_SOURCE[0]}")"
    [ -f "$source_path" ] || return 0
    if { [ -e "$shortcut_path" ] || [ -L "$shortcut_path" ]; } &&
       [ "$(readlink -f "$shortcut_path")" != "$VPS_INSTALL_PATH" ]; then
        echo "快捷键 $shortcut_path 已被其他程序使用，请手动选择名称" >&2
        return 1
    fi
    vps_ensure_install "$source_path" || return 1
    [ "$shortcut_path" = "$VPS_INSTALL_PATH" ] || ln -sfnT "$VPS_INSTALL_PATH" "$shortcut_path"
}

vps_uninstall() {
    clear
    echo -e "${gl_hong}卸载 VPS 工具箱${gl_bai}"
    echo "------------------------"
    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 权限才能卸载" >&2
        break_end
        return 1
    fi
    echo "将移除工具箱本体、备份、快捷软链及更新源记录："
    echo "  - $VPS_INSTALL_PATH"
    echo "  - ${VPS_INSTALL_PATH}.bak（如存在）"
    echo "  - $(dirname -- "$VPS_INSTALL_PATH") 下指向工具箱的所有快捷软链"
    echo "  - /etc/vps-toolbox.repo（如存在）"
    echo "已安装的第三方服务与系统配置（Docker/Caddy/Tailscale/SSH/BBR 等）不会被删除。"
    echo "------------------------"
    local confirm install_dir link removed_links=0
    read -r -p "输入 UNINSTALL 确认卸载: " confirm || return 0
    if [ "$confirm" != UNINSTALL ]; then
        echo "已取消卸载"
        break_end
        return 0
    fi

    install_dir=$(dirname -- "$VPS_INSTALL_PATH")
    shopt -s nullglob
    for link in "$install_dir"/*; do
        if [ -L "$link" ] && [ "$(readlink "$link" 2>/dev/null || true)" = "$VPS_INSTALL_PATH" ]; then
            rm -f -- "$link" && removed_links=$((removed_links + 1))
        fi
    done
    shopt -u nullglob

    if [ -f "${VPS_INSTALL_PATH}.bak" ] && [ ! -L "${VPS_INSTALL_PATH}.bak" ]; then
        rm -f -- "${VPS_INSTALL_PATH}.bak"
    fi
    if [ -f /etc/vps-toolbox.repo ] && [ ! -L /etc/vps-toolbox.repo ]; then
        rm -f -- /etc/vps-toolbox.repo
    fi
    if [ -f "$VPS_INSTALL_PATH" ] && [ ! -L "$VPS_INSTALL_PATH" ]; then
        rm -f -- "$VPS_INSTALL_PATH"
    fi

    echo -e "${gl_lv}VPS 工具箱已卸载干净${gl_bai}（共移除 ${removed_links} 个快捷软链）。"
    exit 0
}

