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
            1) pkg_install "${tools[@]}" ; break_end ;;
            2)
                read -r -e -p "请输入要安装的工具（空格分隔）: " -a custom_tools || return 0
                [ ${#custom_tools[@]} -gt 0 ] && pkg_install "${custom_tools[@]}"
                break_end
                ;;
            3)
                read -r -e -p "请输入要卸载的工具（空格分隔）: " -a remove_tools || return 0
                [ ${#remove_tools[@]} -gt 0 ] && pkg_remove "${remove_tools[@]}"
                break_end
                ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

