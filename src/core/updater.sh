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
    local tmp_file sha_file expected_sha actual_sha new_ver new_value current_ver="$sh_v" current_value result=0 installed_ver
    if [ -e "$VPS_INSTALL_PATH" ] || [ -L "$VPS_INSTALL_PATH" ]; then
        vps_is_toolbox "$VPS_INSTALL_PATH" || { echo "安装文件无效，未更新" >&2; return 1; }
        installed_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2)
        if [ "$(vps_version_value "$installed_ver" || echo 0)" -gt "$(vps_version_value "$current_ver")" ]; then
            current_ver="$installed_ver"
        fi
    fi
    current_value=$(vps_version_value "$current_ver") || return 1
    tmp_file=$(mktemp /tmp/vps-toolbox.XXXXXX) || return 1
    sha_file=$(mktemp /tmp/vps-toolbox-sha.XXXXXX) || { rm -f -- "$tmp_file"; return 1; }

    echo "正在下载更新..."
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 -o "$tmp_file" "$VPS_UPDATE_URL" \
       && [ -s "$tmp_file" ] \
       && head -1 "$tmp_file" | grep -q '^#!/bin/bash' \
       && vps_is_toolbox "$tmp_file"; then

        if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
            if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 -o "$sha_file" "${VPS_UPDATE_URL}.sha256"; then
                rm -f -- "$tmp_file" "$sha_file"
                echo -e "${gl_hong}更新失败：无法下载 SHA256 校验文件${gl_bai}" >&2
                break_end
                return 1
            fi
            expected_sha=$(awk '{print $1; exit}' "$sha_file")
            if command -v sha256sum >/dev/null 2>&1; then
                actual_sha=$(sha256sum "$tmp_file" | awk '{print $1}')
            else
                actual_sha=$(shasum -a 256 "$tmp_file" | awk '{print $1}')
            fi
            if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || [[ "${expected_sha,,}" != "${actual_sha,,}" ]]; then
                rm -f -- "$tmp_file" "$sha_file"
                echo -e "${gl_hong}更新失败：SHA256 完整性校验未通过${gl_bai}" >&2
                break_end
                return 1
            fi
        fi

        new_ver=$(grep '^sh_v=' "$tmp_file" | head -1 | cut -d'"' -f2)
        if ! new_value=$(vps_version_value "$new_ver"); then
            rm -f -- "$tmp_file" "$sha_file"
            echo "更新失败：新脚本缺少有效版本号" >&2
            break_end
            return 1
        fi

        if [ "$new_value" -le "$current_value" ]; then
            echo "下载版本 v$new_ver 不高于当前版本 v$current_ver，已保留当前版本"
            rm -f -- "$tmp_file" "$sha_file"
            break_end
            return
        fi

        if ! vps_atomic_install "$tmp_file" "$VPS_INSTALL_PATH"; then
            rm -f -- "$tmp_file" "$sha_file"
            echo "更新失败：无法写入安装目录" >&2
            break_end
            return 1
        fi
        rm -f -- "$tmp_file" "$sha_file"
        echo -e "${gl_lv}脚本已更新到 v$new_ver${gl_bai}（SHA256 校验通过）"
        echo "旧版本备份: ${VPS_INSTALL_PATH}.bak（可使用 '$VPS_DEFAULT_SHORTCUT rollback' 一键回滚）"
        if [ -t 0 ] && [ -t 1 ] && vps_is_toolbox "$VPS_INSTALL_PATH"; then
            echo -e "${gl_kjlan}正在热重载切换至新版本 v$new_ver...${gl_bai}"
            sleep 1
            exec bash "$VPS_INSTALL_PATH"
        fi
    else
        rm -f -- "$tmp_file" "$sha_file"
        echo -e "${gl_hong}更新失败：下载或校验未通过${gl_bai}"
        result=1
    fi
    break_end
    return "$result"
}

vps_rollback() {
    clear
    echo "脚本版本回滚"
    echo "------------------------"
    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 权限才能回滚版本" >&2
        break_end
        return 1
    fi
    local bak_file="${VPS_INSTALL_PATH}.bak" current_ver="$sh_v" bak_ver staged install_dir confirm
    if [ ! -f "$bak_file" ] || [ -L "$bak_file" ]; then
        echo "未找到可回滚的备份文件: $bak_file" >&2
        break_end
        return 1
    fi
    if ! vps_is_toolbox "$bak_file"; then
        echo "备份文件校验未通过，拒绝回滚: $bak_file" >&2
        break_end
        return 1
    fi
    if [ -f "$VPS_INSTALL_PATH" ] && [ ! -L "$VPS_INSTALL_PATH" ]; then
        current_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2 || echo "$sh_v")
    fi
    bak_ver=$(grep '^sh_v=' "$bak_file" | head -1 | cut -d'"' -f2)
    echo -e "当前版本: ${gl_huang}v${current_ver}${gl_bai}"
    echo -e "备份版本: ${gl_lv}v${bak_ver:-未知}${gl_bai} ($bak_file)"
    echo "------------------------"
    read -r -p "确认回滚到备份版本 v${bak_ver}？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消回滚"; break_end; return 0; }

    install_dir=$(dirname -- "$VPS_INSTALL_PATH")
    staged=$(mktemp "$install_dir/.vps-rollback.XXXXXX") || return 1
    if ! command install -m 755 "$bak_file" "$staged" || ! vps_is_toolbox "$staged"; then
        rm -f -- "$staged"
        echo "回滚准备失败，原文件未修改" >&2
        break_end
        return 1
    fi
    if ! mv -fT -- "$staged" "$VPS_INSTALL_PATH"; then
        rm -f -- "$staged"
        echo "回滚替换失败" >&2
        break_end
        return 1
    fi
    echo -e "${gl_lv}已成功回滚至 v${bak_ver}${gl_bai}"
    if [ -t 0 ] && [ -t 1 ] && vps_is_toolbox "$VPS_INSTALL_PATH"; then
        echo -e "${gl_kjlan}正在热重载切换至 v${bak_ver}...${gl_bai}"
        sleep 1
        exec bash "$VPS_INSTALL_PATH"
    fi
    break_end
}

# ============ 主菜单 ============

