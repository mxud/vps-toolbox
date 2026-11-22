# ============ SSH 防爆破 (Fail2ban) ============

VPS_F2B_JAIL="/etc/fail2ban/jail.d/99-vps-toolbox-sshd.local"

vps_f2b_valid_ports() {
    local raw="$1" p
    local -a parts=()
    [ -n "$raw" ] || return 1
    IFS=',' read -r -a parts <<< "$raw"
    for p in "${parts[@]}"; do
        vps_valid_port "$p" || return 1
    done
}

vps_f2b_sync_port() {
    local new_port="$1"
    [ -f "$VPS_F2B_JAIL" ] && [ ! -L "$VPS_F2B_JAIL" ] || return 0
    vps_valid_port "$new_port" || return 1
    if grep -q '^port[[:space:]]*=' "$VPS_F2B_JAIL"; then
        sed -i "s|^port[[:space:]]*=.*|port = ${new_port}|" "$VPS_F2B_JAIL" || return 1
    else
        printf 'port = %s\n' "$new_port" >> "$VPS_F2B_JAIL" || return 1
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        restart fail2ban >/dev/null 2>&1 || true
    fi
    echo -e "${gl_lv}已同步更新 Fail2ban SSH 监控端口为 ${new_port}${gl_bai}"
}

vps_f2b_install_setup() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local detected_port ssh_port maxretry bantime findtime backend="auto" candidate
    detected_port=$(vps_fw_ssh_port)

    read -r -e -p "SSH 监控端口 (回车使用检测值 ${detected_port}，多端口用逗号分隔如 22,57140): " ssh_port || return 0
    ssh_port="${ssh_port:-$detected_port}"
    ssh_port="${ssh_port// /}"
    vps_f2b_valid_ports "$ssh_port" || { echo "端口格式无效: $ssh_port" >&2; return 1; }

    read -r -e -p "最大失败次数 maxretry [默认 5]: " maxretry || return 0
    maxretry="${maxretry:-5}"
    [[ "$maxretry" =~ ^[0-9]+$ ]] && ((10#$maxretry >= 1 && 10#$maxretry <= 50)) || {
        echo "maxretry 需为 1-50 的整数" >&2; return 1
    }

    read -r -e -p "检测时间窗口 findtime [默认 10m]: " findtime || return 0
    findtime="${findtime:-10m}"
    [[ "$findtime" =~ ^[0-9]+[smhdw]?$ ]] || { echo "findtime 格式无效（如 10m / 1h）" >&2; return 1; }

    read -r -e -p "封禁时长 bantime [默认 1h]: " bantime || return 0
    bantime="${bantime:-1h}"
    [[ "$bantime" =~ ^-?[0-9]+[smhdw]?$ ]] || { echo "bantime 格式无效（如 1h / 1d / -1）" >&2; return 1; }

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        pkg_install fail2ban || return 1
    fi
    # Debian 12+ / Ubuntu 24.04+ 默认仅使用 systemd journald
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        if [ ! -f /var/log/auth.log ] && [ ! -f /var/log/secure ]; then
            backend="systemd"
            if command -v apt-get >/dev/null 2>&1; then
                pkg_install python3-systemd >/dev/null 2>&1 || true
            fi
        fi
    fi

    mkdir -p /etc/fail2ban/jail.d || return 1
    [ ! -L "$VPS_F2B_JAIL" ] || { echo "拒绝覆盖符号链接: $VPS_F2B_JAIL" >&2; return 1; }
    candidate=$(mktemp /etc/fail2ban/jail.d/.vps-f2b.XXXXXX) || return 1
    cat > "$candidate" <<EOF
# Managed by VPS Toolbox
[sshd]
enabled = true
port = ${ssh_port}
backend = ${backend}
maxretry = $((10#$maxretry))
findtime = ${findtime}
bantime = ${bantime}
EOF
    chmod 644 "$candidate" && mv -f -- "$candidate" "$VPS_F2B_JAIL" || { rm -f -- "$candidate"; return 1; }

    if command -v fail2ban-client >/dev/null 2>&1 && ! fail2ban-client -t >/dev/null 2>&1; then
        echo "Fail2ban 配置校验失败，已移除新建配置" >&2
        rm -f -- "$VPS_F2B_JAIL"
        return 1
    fi

    enable fail2ban >/dev/null 2>&1 || true
    restart fail2ban || return 1
    sleep 1
    echo -e "${gl_lv}Fail2ban SSH 防爆破已启用${gl_bai}（端口: ${ssh_port}, maxretry=${maxretry}, findtime=${findtime}, bantime=${bantime}）"
    fail2ban-client status sshd 2>/dev/null || true
}

vps_f2b_unban() {
    command -v fail2ban-client >/dev/null 2>&1 || { echo "未安装 Fail2ban" >&2; return 1; }
    local ip
    read -r -e -p "请输入要解封的 IP 地址: " ip || return 0
    if ! vps_dns_valid_ipv4 "$ip" && ! vps_dns_valid_ipv6 "$ip"; then
        echo "IP 地址格式无效: $ip" >&2
        return 1
    fi
    fail2ban-client set sshd unbanip "$ip"
}

vps_ssh_failed_logs() {
    echo -e "${gl_kjlan}=== 最近 SSH 登录失败记录 (最多 20 条) ===${gl_bai}"
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u ssh -u sshd --no-pager -n 200 2>/dev/null |
            grep -E 'Failed password|Invalid user|Connection closed by authenticating user' | tail -n 20
        echo ""
        echo -e "${gl_kjlan}=== 近期高频攻击来源 IP Top 10 ===${gl_bai}"
        journalctl -u ssh -u sshd --no-pager -n 2000 2>/dev/null |
            grep -Eo '(Failed password|Invalid user).*from [0-9a-fA-F.:]+' |
            awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 10
    elif [ -r /var/log/auth.log ]; then
        grep -E 'Failed password|Invalid user' /var/log/auth.log | tail -n 20
        echo ""
        echo -e "${gl_kjlan}=== 近期高频攻击来源 IP Top 10 ===${gl_bai}"
        grep -Eo '(Failed password|Invalid user).*from [0-9a-fA-F.:]+' /var/log/auth.log |
            awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 10
    elif [ -r /var/log/secure ]; then
        grep -E 'Failed password|Invalid user' /var/log/secure | tail -n 20
        echo ""
        echo -e "${gl_kjlan}=== 近期高频攻击来源 IP Top 10 ===${gl_bai}"
        grep -Eo '(Failed password|Invalid user).*from [0-9a-fA-F.:]+' /var/log/secure |
            awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 10
    else
        echo "未找到可读的 SSH 日志源。"
    fi
}

vps_fail2ban_menu() {
    root_use || return
    local choice f2b_state banned_cnt
    while true; do
        clear
        if command -v fail2ban-client >/dev/null 2>&1; then
            if fail2ban-client ping >/dev/null 2>&1; then
                banned_cnt=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[[:space:]]/,"",$2); print $2}')
                f2b_state="${gl_lv}运行中${gl_bai} (当前封禁 IP: ${gl_huang}${banned_cnt:-0}${gl_bai})"
            else
                f2b_state="${gl_huang}已安装但未运行${gl_bai}"
            fi
        else
            f2b_state="${gl_hui}未安装${gl_bai}"
        fi

        echo -e "${gl_kjlan}================ SSH 安全与 Fail2ban ================${gl_bai}"
        echo -e "Fail2ban 状态: ${f2b_state}"
        echo -e "${gl_kjlan}-----------------------------------------------------${gl_bai}"
        echo "1. 一键安装并配置 SSH 防爆破"
        echo "2. 查看 SSH 封禁状态与被封 IP"
        echo "3. 手动解封指定 IP"
        echo "4. 查看最近 SSH 登录失败日志 & Top 10 攻击 IP"
        echo "5. 移除工具箱 Fail2ban SSH 规则"
        echo -e "${gl_kjlan}-----------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}-----------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) vps_f2b_install_setup; break_end ;;
            2)
                clear
                if command -v fail2ban-client >/dev/null 2>&1; then
                    fail2ban-client status sshd || echo "sshd jail 未启用或服务未运行"
                else
                    echo "未安装 Fail2ban"
                fi
                break_end
                ;;
            3) vps_f2b_unban; break_end ;;
            4) clear; vps_ssh_failed_logs; break_end ;;
            5)
                if [ -f "$VPS_F2B_JAIL" ]; then
                    rm -f -- "$VPS_F2B_JAIL"
                    command -v fail2ban-client >/dev/null 2>&1 && restart fail2ban 2>/dev/null || true
                    echo "已移除工具箱 Fail2ban SSH 规则"
                else
                    echo "未找到工具箱创建的 Fail2ban 规则"
                fi
                break_end
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
