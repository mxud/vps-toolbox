linux_settings() {
    while true; do
        clear
        # 毫秒级读取当前状态，用于回显展示
        local cur_port cur_swap cur_tz cur_ipc cur_host cur_dns
        cur_port=$("$(command -v sshd || echo /usr/sbin/sshd)" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
        [ -z "$cur_port" ] && cur_port="22"

        local s_total
        s_total=$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
        [ "$s_total" -gt 0 ] && cur_swap="${s_total}M" || cur_swap="未开启"

        cur_tz=$(current_timezone)
        cur_host=$(uname -n)

        if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100' /etc/gai.conf 2>/dev/null; then
            cur_ipc="IPv4 优先"
        else
            cur_ipc="系统默认"
        fi

        cur_dns=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | awk '{print $1,$2}')
        [ -z "$cur_dns" ] && cur_dns="系统默认"

        echo -e "${gl_kjlan}======================= 系统工具 =======================${gl_bai}"
        echo -e "${gl_huang}【 安全与访问 】${gl_bai}"
        printf " %-2s %-20s ${gl_hui}[命令: %s]${gl_bai}\n" "1." "设置脚本快捷键" "${VPS_DEFAULT_SHORTCUT}"
        printf " %-2s %-20s ${gl_hui}[用户: root]${gl_bai}\n" "2." "修改登录密码"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "3." "修改 SSH 端口" "${cur_port}"
        printf " %-2s %-20s ${gl_hui}[安全加固/公钥管理]${gl_bai}\n" "4." "用户密钥登录模式"
        echo ""
        echo -e "${gl_huang}【 系统与环境 】${gl_bai}"
        printf " %-2s %-20s ${gl_hui}[主机: %s]${gl_bai}\n" "5." "修改主机名" "${cur_host}"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "6." "修改虚拟内存 (Swap)" "${cur_swap}"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "7." "设置系统时区" "${cur_tz}"
        printf " %-2s %-20s ${gl_hong}[纯内存在线重装]${gl_bai}\n" "8." "一键重装系统"
        printf " %-2s %-20s\n" "9." "一键重启服务器"
        echo ""
        echo -e "${gl_huang}【 网络与规则 】${gl_bai}"
        printf " %-2s %-20s ${gl_hui}[当前: %s]${gl_bai}\n" "10." "优化 DNS 地址" "${cur_dns}"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "11." "设置 IPv4 地址优先级" "${cur_ipc}"
        printf " %-2s %-20s ${gl_hong}[清空 IPv4 filter 表]${gl_bai}\n" "12." "开放 IPv4 防火墙端口"
        printf " %-2s %-20s ${gl_hui}[ss 监听列表]${gl_bai}\n" "13." "查看本机端口占用"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo " 0. 返回主菜单"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1) vps_set_shortcut ;;
            2) set_root_password ; break_end ;;
            3) change_ssh_port ;;
            4) vps_ssh_key_menu ;;
            5)
                root_use || continue
                read -r -e -p "请输入新主机名: " new_hostname || return 0
                [ -z "$new_hostname" ] || vps_set_hostname "$new_hostname"
                break_end
                ;;
            6)
                clear
                echo -e "当前虚拟内存: ${gl_huang}${cur_swap}${gl_bai}"
                read -r -e -p "输入新的 swap 大小 (MB，输入 0 退出): " swap_size || return 0
                [ "$swap_size" != "0" ] && [ -n "$swap_size" ] && add_swap "$swap_size"
                break_end
                ;;
            7) timezone_menu ;;
            8) vps_dd_menu ;;
            9) server_reboot ;;
            10) vps_dns_menu ;;
            11)
                root_use || continue
                clear
                echo -e "当前优先级: ${gl_huang}${cur_ipc}${gl_bai}"
                echo "1. IPv4 优先    2. 移除工具箱的 IPv4 优先设置"
                read -r -e -p "请选择: " ipc || return 0
                case $ipc in
                    1) vps_set_ip_preference 4 ;;
                    2) vps_set_ip_preference default ;;
                esac
                break_end
                ;;
            12)
                root_use || continue
                if command -v docker >/dev/null 2>&1 || command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
                    echo "检测到 Docker 或防火墙管理器，请通过对应管理器调整端口，避免破坏现有规则。"
                    break_end
                    continue
                fi
                echo "仅清空 IPv4 iptables filter 表；IPv6、nftables 和云安全组需单独管理。"
                read -r -p "输入 OPEN 清空 IPv4 filter 规则并放行: " confirm || return 0
                [ "$confirm" = OPEN ] || continue
                pkg_install iptables || continue
                local firewall_backup
                firewall_backup=$(mktemp /root/vps-iptables.XXXXXX.rules) || continue
                chmod 600 "$firewall_backup"
                if ! iptables-save > "$firewall_backup"; then
                    echo "备份失败，未修改规则" >&2
                elif iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F; then
                    echo "IPv4 filter 规则已开放；备份: $firewall_backup"
                else
                    if iptables-restore < "$firewall_backup"; then
                        echo "修改失败，已恢复备份" >&2
                    else
                        echo "恢复失败，请通过控制台使用备份: $firewall_backup" >&2
                    fi
                fi
                break_end
                ;;
            13) clear; ss -tulnape; break_end ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

# ============ 快捷键设置 ============

