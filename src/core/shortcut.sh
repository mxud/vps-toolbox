vps_set_shortcut() {
    root_use || return
    while true; do
        clear
        read -r -e -p "请输入快捷键名（输入 0 退出）: " key || return 0
        [ "$key" = "0" ] && return

        if [[ ! "$key" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
            echo "快捷键只能包含字母、数字、点、下划线和短横线"
            break_end
            continue
        fi

        if command -v "$key" >/dev/null 2>&1 && [ "$(readlink -f "$(command -v "$key")")" != "$VPS_INSTALL_PATH" ]; then
            echo "错误: 名称 [$key] 与系统现有命令冲突，请更换一个名字！" >&2
            break_end
            continue
        fi

        local source_path
        source_path="$(readlink -f "${BASH_SOURCE[0]}")"
        if { [ -e "/usr/local/bin/$key" ] || [ -L "/usr/local/bin/$key" ]; } &&
           [ "$(readlink -f "/usr/local/bin/$key")" != "$VPS_INSTALL_PATH" ]; then
            echo "快捷键 $key 已被其他程序使用" >&2
            break_end
            continue
        fi
        [ -f "$source_path" ] || {
            echo "无法从当前启动方式安装，请先下载脚本文件后运行" >&2
            break_end
            continue
        }
        vps_ensure_install "$source_path" || return 1
        if [ "/usr/local/bin/$key" != "$VPS_INSTALL_PATH" ]; then
            ln -sfnT "$VPS_INSTALL_PATH" "/usr/local/bin/$key" || return 1
        fi
        echo -e "${gl_lv}快捷键已设置${gl_bai}: 输入 ${gl_huang}$key${gl_bai} 启动脚本"
        break_end
        return
    done
}

# ============ 脚本更新 ============

