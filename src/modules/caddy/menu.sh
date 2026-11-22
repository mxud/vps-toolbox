# ============ Caddy 管理菜单 ============

caddy_menu() {
    local choice caddy_state caddy_ver site_count=0
    local -a site_files=()
    while true; do
        clear
        site_count=0
        if [ -d "$CADDY_SITES" ]; then
            shopt -s nullglob
            site_files=("$CADDY_SITES"/*.caddy)
            shopt -u nullglob
            site_count="${#site_files[@]}"
        fi
        if command -v caddy >/dev/null 2>&1; then
            caddy_ver=$(caddy version 2>/dev/null | awk '{print $1}' || true)
            if service_action status caddy >/dev/null 2>&1; then
                caddy_state="${gl_lv}运行中${gl_bai} (${gl_huang}${caddy_ver:-已安装}${gl_bai})  反代站点: ${gl_lv}${site_count}${gl_bai}"
            else
                caddy_state="${gl_huang}已安装未运行${gl_bai} (${caddy_ver:-未知})  反代站点: ${gl_huang}${site_count}${gl_bai}"
            fi
        else
            caddy_state="${gl_hui}未安装${gl_bai}"
        fi

        echo -e "${gl_kjlan}===================== Caddy 管理 =====================${gl_bai}"
        echo -e "状态: ${caddy_state}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo -e "${gl_huang}【 站点与反代 】${gl_bai}"
        echo -e " ${gl_kjlan}1.${gl_bai}  添加反代 / 重定向"
        echo -e " ${gl_kjlan}2.${gl_bai}  查看状态与反代配置"
        echo -e " ${gl_kjlan}3.${gl_bai}  编辑反代配置 ${gl_hui}[自动校验并回滚]${gl_bai}"
        echo -e " ${gl_kjlan}4.${gl_bai}  删除反代 ${gl_hui}[支持序号选择]${gl_bai}"
        echo ""
        echo -e "${gl_huang}【 服务与维护 】${gl_bai}"
        echo -e " ${gl_kjlan}5.${gl_bai}  格式化、校验并重载配置"
        echo -e " ${gl_kjlan}6.${gl_bai}  查看 Caddy 运行日志 ${gl_hui}[最近 / 实时]${gl_bai}"
        echo -e " ${gl_kjlan}7.${gl_bai}  导出迁移备份"
        echo -e " ${gl_kjlan}8.${gl_bai}  导入迁移备份"
        echo ""
        echo -e "${gl_huang}【 安装与重置 】${gl_bai}"
        echo -e " ${gl_kjlan}9.${gl_bai}  安装 / 升级 Caddy"
        echo -e " ${gl_kjlan}10.${gl_bai} ${gl_huang}清空 / 重置反代配置${gl_bai}"
        echo -e " ${gl_kjlan}11.${gl_bai} ${gl_hong}卸载 Caddy (保留配置)${gl_bai}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo -e " ${gl_kjlan}0.${gl_bai}  返回主菜单"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) caddy_add_menu ;;
            2) clear; caddy_list; break_end ;;
            3) caddy_edit; break_end ;;
            4) caddy_delete; break_end ;;
            5) caddy_check_reload; break_end ;;
            6) caddy_logs; break_end ;;
            7) caddy_export_migration; break_end ;;
            8) caddy_import_migration; break_end ;;
            9) caddy_install; break_end ;;
            10) caddy_reset; break_end ;;
            11) caddy_uninstall_keep_config; break_end ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
