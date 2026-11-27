vps_switch_mirror() {
    root_use || return
    local choice country
    clear
    echo -e "${gl_kjlan}==================== 切换系统软件源 ====================${gl_bai}"
    echo "通过 LinuxMirrors 切换发行版软件源 (自动备份原配置)："
    echo "1. 中国大陆镜像源 (交互式选择阿里/华为/清华/中科大等)"
    echo "2. 海外地区镜像源 (交互式选择海外及官方源)"
    echo "3. 中国教育网镜像源 (CERNET)"
    echo "4. 按服务器位置自动静默优选 (国内用华为云，海外用官方源)"
    echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
    echo "0. 返回"
    echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
    read -r -e -p "请输入你的选择: " choice || return 0
    case "$choice" in
        1) run_remote_bash "https://linuxmirrors.cn/main.sh" ;;
        2) run_remote_bash "https://linuxmirrors.cn/main.sh" --abroad ;;
        3) run_remote_bash "https://linuxmirrors.cn/main.sh" --edu ;;
        4)
            country=$(curl -fsS --proto '=https' --proto-redir '=https' --max-time 3 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
            if [ "$country" = "CN" ]; then
                echo "检测到国内网络环境，应用华为云 HTTPS 软件源..."
                run_remote_bash "https://linuxmirrors.cn/main.sh" \
                    --source mirrors.huaweicloud.com --protocol https --use-intranet-source false \
                    --backup true --upgrade-software false --clean-cache false --ignore-backup-tips
            else
                echo "检测到海外网络环境，恢复/应用系统官方软件源..."
                run_remote_bash "https://linuxmirrors.cn/main.sh" \
                    --use-official-source true --protocol https --use-intranet-source false \
                    --backup true --upgrade-software false --clean-cache false --ignore-backup-tips
            fi
            ;;
        *) return 0 ;;
    esac
    break_end
}

linux_settings() {
    while true; do
        clear
        # 毫秒级读取当前状态，用于回显展示
        local cur_port cur_swap cur_tz cur_ipc cur_host cur_dns
        cur_port=$("$(command -v sshd || echo /usr/sbin/sshd)" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
        [ -z "$cur_port" ] && cur_port="22"

        local s_total
        s_total=$(awk '/SwapTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
        [ "$s_total" -gt 0 ] && cur_swap="${s_total}M" || cur_swap="未开启"

        cur_tz=$(current_timezone)
        cur_host=$(uname -n)

        if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100' /etc/gai.conf 2>/dev/null; then
            cur_ipc="IPv4 优先"
        else
            cur_ipc="系统默认"
        fi

        cur_dns=$(vps_current_dns | awk '{print $1,$2}')
        [ -z "$cur_dns" ] && cur_dns="系统默认"

        echo -e "${gl_kjlan}======================= 系统工具 =======================${gl_bai}"
        echo -e "${gl_huang}【 安全与访问 】${gl_bai}"
        printf " %-3s %-20s ${gl_hui}[命令: %s]${gl_bai}\n" "1." "设置脚本快捷键" "${VPS_DEFAULT_SHORTCUT}"
        printf " %-3s %-20s ${gl_hui}[用户: root]${gl_bai}\n" "2." "修改登录密码"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "3." "修改 SSH 端口" "${cur_port}"
        printf " %-3s %-20s ${gl_hui}[安全加固/公钥管理]${gl_bai}\n" "4." "用户密钥登录模式"
        printf " %-3s %-20s ${gl_hui}[防爆破/封禁管理]${gl_bai}\n" "5." "SSH 安全与 Fail2ban"
        echo ""
        echo -e "${gl_huang}【 系统与环境 】${gl_bai}"
        printf " %-3s %-20s ${gl_lv}[新机全套/内核调优]${gl_bai}\n" "6." "一键系统优化"
        printf " %-3s %-20s ${gl_hui}[主机: %s]${gl_bai}\n" "7." "修改主机名" "${cur_host}"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "8." "修改虚拟内存 (Swap)" "${cur_swap}"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "9." "设置系统时区" "${cur_tz}"
        printf " %-3s %-20s ${gl_hong}[纯内存在线重装]${gl_bai}\n" "10." "一键重装系统"
        printf " %-3s %-20s\n" "11." "一键重启服务器"
        printf " %-3s %-20s ${gl_hui}[大目录/Top 进程]${gl_bai}\n" "12." "磁盘与负载排查"
        printf " %-3s %-20s ${gl_hui}[LinuxMirrors 换源]${gl_bai}\n" "18." "切换系统软件源"
        echo ""
        echo -e "${gl_huang}【 网络与规则 】${gl_bai}"
        printf " %-3s %-20s ${gl_hui}[当前: %s]${gl_bai}\n" "13." "优化 DNS 地址" "${cur_dns}"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "14." "设置 IPv4 地址优先级" "${cur_ipc}"
        printf " %-3s %-20s ${gl_lv}[UFW / Firewalld]${gl_bai}\n" "15." "防火墙管理"
        printf " %-3s %-20s ${gl_hong}[清空 IPv4 filter 表]${gl_bai}\n" "16." "开放 IPv4 防火墙端口"
        printf " %-3s %-20s ${gl_hui}[ss 监听列表]${gl_bai}\n" "17." "查看本机端口占用"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo " 0.  返回主菜单"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1) vps_set_shortcut ;;
            2) set_root_password ; break_end ;;
            3) change_ssh_port ;;
            4) vps_ssh_key_menu ;;
            5) vps_fail2ban_menu ;;
            6) vps_optimize_menu ;;
            7)
                root_use || continue
                read -r -e -p "请输入新主机名: " new_hostname || return 0
                [ -z "$new_hostname" ] || vps_set_hostname "$new_hostname"
                break_end
                ;;
            8)
                clear
                echo -e "当前虚拟内存: ${gl_huang}${cur_swap}${gl_bai}"
                echo "提示：输入 128-32768 设置大小 (MB)，输入 d 或 off 关闭并删除工具箱 Swap，输入 0 返回"
                read -r -e -p "请输入: " swap_size || return 0
                case "$swap_size" in
                    0|"") ;;
                    d|D|off|OFF|del) remove_swap; break_end ;;
                    *) add_swap "$swap_size"; break_end ;;
                esac
                ;;
            9) timezone_menu ;;
            10) vps_dd_menu ;;
            11) server_reboot ;;
            12) vps_diag_menu ;;
            13) vps_dns_menu ;;
            14)
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
            15) vps_firewall_menu ;;
            16)
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
            17) clear; ss -tulnape; break_end ;;
            18) vps_switch_mirror ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

# ============ 快捷键设置 ============

