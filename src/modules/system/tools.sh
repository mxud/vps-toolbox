# ============ 基础工具管理 ============

linux_tools() {
    local tools=(curl wget sudo socat htop iftop unzip tar tmux ffmpeg btop ncdu fzf vim nano git)

    while true; do
        clear
        echo -e "基础工具"
        echo -e "${gl_kjlan}------------------------${gl_bai}"

        for ((i=0; i<${#tools[@]}; i+=2)); do
            local left right
            if command -v "${tools[i]}" >/dev/null 2>&1; then
                left=$(printf "✅ %-12s 已安装" "${tools[i]}")
            else
                left=$(printf "❌ %-12s 未安装" "${tools[i]}")
            fi

            if [ -n "${tools[i+1]:-}" ]; then
                if command -v "${tools[i+1]}" >/dev/null 2>&1; then
                    right=$(printf "✅ %-12s 已安装" "${tools[i+1]}")
                else
                    right=$(printf "❌ %-12s 未安装" "${tools[i+1]}")
                fi
                printf "%-42s %s\n" "$left" "$right"
            else
                printf "%s\n" "$left"
            fi
        done

        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo "1. 安装全部工具"
        echo "2. 安装指定工具"
        echo "3. 卸载指定工具"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1)
                root_use || continue
                local manager tool mapped
                local -a missing_tools=()
                manager=$(vps_pkg_manager) || { break_end; continue; }
                for tool in "${tools[@]}"; do
                    if ! command -v "$tool" >/dev/null 2>&1; then
                        missing_tools+=("$tool")
                    fi
                done
                if [ "${#missing_tools[@]}" -eq 0 ]; then
                    echo "所有基础工具均已安装"
                    break_end
                    continue
                fi
                echo "正在更新软件源索引..."
                case "$manager" in
                    apt-get) apt-get update || { break_end; continue; } ;;
                    apk) apk update || { break_end; continue; } ;;
                esac
                for tool in "${missing_tools[@]}"; do
                    mapped=$(vps_pkg_name "$manager" "$tool")
                    echo "正在安装: $mapped"
                    case "$manager" in
                        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        dnf|yum) "$manager" install -y "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        apk) apk add "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        pacman) pacman -S --needed --noconfirm "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        zypper) zypper --non-interactive install "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                    esac
                done
                break_end
                ;;
            2)
                root_use || continue
                read -r -e -p "请输入要安装的工具（空格分隔）: " -a custom_tools || return 0
                [ ${#custom_tools[@]} -gt 0 ] && pkg_install "${custom_tools[@]}"
                break_end
                ;;
            3)
                root_use || continue
                read -r -e -p "请输入要卸载的工具（空格分隔）: " -a remove_tools || return 0
                [ ${#remove_tools[@]} -gt 0 ] && pkg_remove "${remove_tools[@]}"
                break_end
                ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

