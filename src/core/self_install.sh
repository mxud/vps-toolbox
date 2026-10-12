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

