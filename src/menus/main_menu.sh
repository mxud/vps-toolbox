vps_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}"
        echo "╦  ╦╔═╗╔═╗  ╔╦╗╔═╗╔═╗╦  ╔╗ ╔═╗═╗ ╦"
        echo "╚╗╔╝╠═╝╚═╗   ║ ║ ║║ ║║  ╠╩╗║ ║╔╩╦╝"
        echo " ╚╝ ╩  ╚═╝   ╩ ╚═╝╚═╝╩═╝╚═╝╚═╝╩ ╚═"
        echo -e "${gl_bai}VPS 工具箱 v$sh_v"
        if command -v "$VPS_DEFAULT_SHORTCUT" >/dev/null 2>&1; then
            echo -e "命令行输入 ${gl_huang}${VPS_DEFAULT_SHORTCUT}${gl_bai} 可快速启动"
        else
            echo "可在系统工具中设置快捷键"
        fi
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo -e "${gl_kjlan}1.${gl_bai}   系统信息查询"
        echo -e "${gl_kjlan}2.${gl_bai}   系统更新"
        echo -e "${gl_kjlan}3.${gl_bai}   系统清理"
        echo -e "${gl_kjlan}4.${gl_bai}   基础工具"
        echo -e "${gl_kjlan}5.${gl_bai}   BBR 管理"
        echo -e "${gl_kjlan}6.${gl_bai}   Docker 管理"
        echo -e "${gl_kjlan}7.${gl_bai}   WARP 管理"
        echo -e "${gl_kjlan}8.${gl_bai}   测试脚本合集"
        echo -e "${gl_kjlan}9.${gl_bai}   系统工具"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo -e "${gl_kjlan}00.${gl_bai}  脚本更新"
        echo -e "${gl_kjlan}0.${gl_bai}   退出脚本"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1)  linux_info ; break_end ;;
            2)  clear ; linux_update ; break_end ;;
            3)  clear ; linux_clean ; break_end ;;
            4)  linux_tools ;;
            5)  linux_bbr ;;
            6)  docker_menu ;;
            7)  linux_warp ;;
            8)  linux_test ;;
            9)  linux_settings ;;
            00) vps_update ;;
            0)  clear ; exit 0 ;;
            *)  echo "无效的输入" ; sleep 1 ;;
        esac
    done
}

# ============ 命令行帮助 ============

