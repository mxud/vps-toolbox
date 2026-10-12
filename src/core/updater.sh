vps_version_value() {
    local version="$1" major minor patch
    [[ "$version" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || return 1
    IFS=. read -r major minor patch <<< "$version"
    printf '%s\n' "$((10#$major * 1000000000000 + 10#$minor * 1000000 + 10#$patch))"
}

vps_update() {
    clear
    echo "脚本更新"
    echo "------------------------"
    echo -e "当前版本: ${gl_huang}v$sh_v${gl_bai}"
    echo "------------------------"

    if [ -z "$VPS_UPDATE_URL" ]; then
        echo "尚未配置在线更新地址"
        echo "请设置环境变量 VPS_UPDATE_URL 后再试"
        break_end
        return 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 权限才能更新"
        break_end
        return 1
    fi

    [[ "$VPS_UPDATE_URL" == https://* ]] || {
        echo "更新地址必须使用 HTTPS" >&2; break_end; return 1;
    }
    command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates || return 1
    local tmp_file new_ver new_value current_ver="$sh_v" current_value result=0 installed_ver
    if [ -e "$VPS_INSTALL_PATH" ] || [ -L "$VPS_INSTALL_PATH" ]; then
        vps_is_toolbox "$VPS_INSTALL_PATH" || { echo "安装文件无效，未更新" >&2; return 1; }
        installed_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2)
        if [ "$(vps_version_value "$installed_ver" || echo 0)" -gt "$(vps_version_value "$current_ver")" ]; then
            current_ver="$installed_ver"
        fi
    fi
    current_value=$(vps_version_value "$current_ver") || return 1
    tmp_file=$(mktemp /tmp/vps-toolbox.XXXXXX) || return 1

    echo "正在下载更新..."
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 -o "$tmp_file" "$VPS_UPDATE_URL" \
       && [ -s "$tmp_file" ] \
       && head -1 "$tmp_file" | grep -q '^#!/bin/bash' \
       && vps_is_toolbox "$tmp_file"; then

        new_ver=$(grep '^sh_v=' "$tmp_file" | head -1 | cut -d'"' -f2)
        if ! new_value=$(vps_version_value "$new_ver"); then
            rm -f -- "$tmp_file"
            echo "更新失败：新脚本缺少有效版本号" >&2
            break_end
            return 1
        fi

        if [ "$new_value" -le "$current_value" ]; then
            echo "下载版本 v$new_ver 不高于当前版本 v$current_ver，已保留当前版本"
            rm -f "$tmp_file"
            break_end
            return
        fi

        if ! vps_atomic_install "$tmp_file" "$VPS_INSTALL_PATH"; then
            rm -f -- "$tmp_file"
            echo "更新失败：无法写入安装目录" >&2
            break_end
            return 1
        fi
        rm -f -- "$tmp_file"
        echo -e "${gl_lv}脚本已更新到 v$new_ver${gl_bai}"
        echo "重新启动 $VPS_INSTALL_PATH 后使用新版；旧版本备份: ${VPS_INSTALL_PATH}.bak（如更新前已安装）"
    else
        rm -f "$tmp_file"
        echo -e "${gl_hong}更新失败：下载或校验未通过${gl_bai}"
        result=1
    fi
    break_end
    return "$result"
}

# ============ 主菜单 ============

