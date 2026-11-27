# ============ 防火墙管理 (UFW / Firewalld) ============

vps_fw_detect() {
    if command -v ufw >/dev/null 2>&1; then
        printf 'ufw\n'
    elif command -v firewall-cmd >/dev/null 2>&1; then
        printf 'firewalld\n'
    else
        return 1
    fi
}

vps_fw_ssh_port() {
    local sshd_bin port
    sshd_bin=$(command -v sshd || true)
    [ -n "$sshd_bin" ] || sshd_bin=/usr/sbin/sshd
    port=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
    printf '%s\n' "${port:-22}"
}

vps_fw_install() {
    local manager
    manager=$(vps_pkg_manager) || return 1
    case "$manager" in
        apt-get|pacman)
            pkg_install ufw || return 1
            ;;
        dnf|yum|zypper)
            pkg_install firewalld || return 1
            enable firewalld || true
            ;;
        *)
            echo "当前系统暂不支持自动安装防火墙管理器，请手动安装 ufw 或 firewalld" >&2
            return 1
            ;;
    esac
}

vps_fw_status() {
    local fw="$1"
    if [ "$fw" = ufw ]; then
        ufw status verbose
    else
        if firewall-cmd --state >/dev/null 2>&1; then
            echo "Firewalld 状态: 运行中 (running)"
            firewall-cmd --list-all
        else
            echo "Firewalld 状态: 未运行 (not running)"
        fi
    fi
}

vps_fw_allow_port() {
    local fw="$1" port proto
    read -r -e -p "请输入要放行的端口 (1-65535): " port || return 0
    vps_valid_port "$port" || { echo "端口无效" >&2; return 1; }
    port=$((10#$port))
    read -r -e -p "协议类型 [tcp/udp/both，默认 tcp]: " proto || return 0
    proto="${proto:-tcp}"
    case "$proto" in
        tcp|udp)
            if [ "$fw" = ufw ]; then
                ufw allow "${port}/${proto}"
            else
                firewall-cmd --add-port="${port}/${proto}" &&
                    firewall-cmd --permanent --add-port="${port}/${proto}"
            fi
            ;;
        both)
            if [ "$fw" = ufw ]; then
                ufw allow "${port}/tcp" && ufw allow "${port}/udp"
            else
                firewall-cmd --add-port="${port}/tcp" && firewall-cmd --add-port="${port}/udp" &&
                    firewall-cmd --permanent --add-port="${port}/tcp" && firewall-cmd --permanent --add-port="${port}/udp"
            fi
            ;;
        *)
            echo "无效协议，请输入 tcp、udp 或 both" >&2
            return 1
            ;;
    esac
}

vps_fw_deny_port() {
    local fw="$1" port proto ssh_port confirm
    ssh_port=$(vps_fw_ssh_port)
    read -r -e -p "请输入要关闭/移除规则的端口 (1-65535): " port || return 0
    vps_valid_port "$port" || { echo "端口无效" >&2; return 1; }
    port=$((10#$port))
    if [ "$port" = "$ssh_port" ]; then
        echo -e "${gl_hong}警告：端口 $port 是当前 SSH 端口，关闭可能导致失联！${gl_bai}"
        read -r -p "如确认关闭，请输入 CLOSE-SSH: " confirm || return 0
        [ "$confirm" = CLOSE-SSH ] || { echo "已取消"; return 0; }
    fi
    read -r -e -p "协议类型 [tcp/udp/both，默认 tcp]: " proto || return 0
    proto="${proto:-tcp}"
    case "$proto" in
        tcp|udp)
            if [ "$fw" = ufw ]; then
                ufw delete allow "${port}/${proto}"
            else
                firewall-cmd --remove-port="${port}/${proto}" &&
                    firewall-cmd --permanent --remove-port="${port}/${proto}"
            fi
            ;;
        both)
            if [ "$fw" = ufw ]; then
                ufw delete allow "${port}/tcp" ; ufw delete allow "${port}/udp"
            else
                firewall-cmd --remove-port="${port}/tcp" ; firewall-cmd --remove-port="${port}/udp"
                firewall-cmd --permanent --remove-port="${port}/tcp" ; firewall-cmd --permanent --remove-port="${port}/udp"
            fi
            ;;
        *)
            echo "无效协议，请输入 tcp、udp 或 both" >&2
            return 1
            ;;
    esac
}

vps_fw_allow_ip() {
    local fw="$1" ip family="ipv4"
    read -r -e -p "请输入要放行的来源 IP (IPv4 或 IPv6): " ip || return 0
    if vps_dns_valid_ipv4 "$ip"; then
        family="ipv4"
    elif vps_dns_valid_ipv6 "$ip"; then
        family="ipv6"
    else
        echo "IP 地址格式无效: $ip" >&2
        return 1
    fi
    if [ "$fw" = ufw ]; then
        ufw allow from "$ip"
    else
        local rule="rule family=\"${family}\" source address=\"${ip}\" accept"
        firewall-cmd --add-rich-rule="$rule" && firewall-cmd --permanent --add-rich-rule="$rule"
    fi
}

vps_fw_enable() {
    local fw="$1" ssh_port
    ssh_port=$(vps_fw_ssh_port)
    echo -e "启用前将自动放行当前 SSH 端口: ${gl_huang}${ssh_port}/tcp${gl_bai}"
    if [ "$fw" = ufw ]; then
        ufw allow "${ssh_port}/tcp" || return 1
        ufw --force enable
    else
        enable firewalld || true
        start firewalld || return 1
        firewall-cmd --add-port="${ssh_port}/tcp" &&
            firewall-cmd --permanent --add-port="${ssh_port}/tcp"
    fi
}

vps_fw_ping_status() {
    if [ "$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo 0)" = "1" ]; then
        printf 'disabled\n'
    else
        printf 'enabled\n'
    fi
}

vps_fw_set_ping() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local mode="${1:-}" conf="/etc/sysctl.d/99-vps-icmp.conf" candidate
    [ ! -L "$conf" ] || { echo "拒绝覆盖符号链接: $conf" >&2; return 1; }
    case "$mode" in
        off|disable|禁ping)
            mkdir -p /etc/sysctl.d || return 1
            candidate=$(mktemp /etc/sysctl.d/.vps-icmp.XXXXXX) || return 1
            cat > "$candidate" <<EOF
# Managed by VPS Toolbox (ICMP Ping block)
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
EOF
            chmod 644 "$candidate" && mv -f -- "$candidate" "$conf" || { rm -f -- "$candidate"; return 1; }
            sysctl -w net.ipv4.icmp_echo_ignore_all=1 >/dev/null 2>&1 || return 1
            sysctl -w net.ipv6.icmp.echo_ignore_all=1 >/dev/null 2>&1 || true
            echo -e "${gl_lv}已开启禁 Ping (忽略所有 IPv4/IPv6 ICMP Echo 请求)${gl_bai}"
            ;;
        on|enable|允许)
            rm -f -- "$conf"
            sysctl -w net.ipv4.icmp_echo_ignore_all=0 >/dev/null 2>&1 || return 1
            sysctl -w net.ipv6.icmp.echo_ignore_all=0 >/dev/null 2>&1 || true
            echo -e "${gl_lv}已恢复允许 Ping (正常响应 ICMP Echo 请求)${gl_bai}"
            ;;
        status|状态)
            if [ "$(vps_fw_ping_status)" = "disabled" ]; then
                echo "当前 Ping 状态: 已禁 Ping (net.ipv4.icmp_echo_ignore_all=1)"
            else
                echo "当前 Ping 状态: 允许 Ping (net.ipv4.icmp_echo_ignore_all=0)"
            fi
            ;;
        *)
            echo "用法: $VPS_DEFAULT_SHORTCUT fw ping [on|off|status]" >&2
            return 1
            ;;
    esac
}

vps_fw_disable() {
    local fw="$1" confirm
    read -r -p "确认停用防火墙？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
    if [ "$fw" = ufw ]; then
        ufw disable
    else
        stop firewalld
    fi
}

vps_firewall_menu() {
    if [ "$#" -gt 0 ]; then
        case "$1" in
            ping)
                shift
                vps_fw_set_ping "${1:-status}"
                return $?
                ;;
            status|状态)
                local cli_fw
                cli_fw=$(vps_fw_detect || true)
                [ -n "$cli_fw" ] && vps_fw_status "$cli_fw" || echo "未检测到 UFW 或 Firewalld"
                vps_fw_set_ping status
                return 0
                ;;
            *)
                echo "用法: $VPS_DEFAULT_SHORTCUT fw [status | ping <on|off|status>]" >&2
                return 1
                ;;
        esac
    fi
    root_use || return
    local fw choice state_str ping_str
    while true; do
        clear
        if [ "$(vps_fw_ping_status)" = "disabled" ]; then
            ping_str="${gl_huang}已禁 Ping${gl_bai}"
        else
            ping_str="${gl_lv}允许 Ping${gl_bai}"
        fi
        fw=$(vps_fw_detect || true)
        if [ -z "$fw" ]; then
            echo -e "${gl_kjlan}===================== 防火墙管理 =====================${gl_bai}"
            echo -e "未检测到 UFW 或 Firewalld。    ICMP 状态: ${ping_str}"
            echo "1. 自动安装推荐防火墙 (Debian/Ubuntu: ufw, RHEL系: firewalld)"
            echo "7. 一键开启 / 关闭禁 Ping (ICMP)"
            echo "0. 返回上一级"
            echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
            read -r -e -p "请输入你的选择: " choice || return 0
            case "$choice" in
                1) vps_fw_install; break_end ;;
                7)
                    if [ "$(vps_fw_ping_status)" = "disabled" ]; then
                        vps_fw_set_ping on
                    else
                        vps_fw_set_ping off
                    fi
                    break_end
                    ;;
                0) break ;;
                *) echo "无效选择"; sleep 1 ;;
            esac
            continue
        fi

        if [ "$fw" = ufw ]; then
            if LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
                state_str="${gl_lv}运行中 (UFW)${gl_bai}"
            else
                state_str="${gl_huang}未启用 (UFW)${gl_bai}"
            fi
        else
            if firewall-cmd --state >/dev/null 2>&1; then
                state_str="${gl_lv}运行中 (Firewalld)${gl_bai}"
            else
                state_str="${gl_huang}未运行 (Firewalld)${gl_bai}"
            fi
        fi

        echo -e "${gl_kjlan}===================== 防火墙管理 =====================${gl_bai}"
        echo -e "当前状态: ${state_str}    SSH 端口: ${gl_huang}$(vps_fw_ssh_port)${gl_bai}    ICMP: ${ping_str}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "1. 查看防火墙状态与规则"
        echo "2. 放行端口 (TCP/UDP)"
        echo "3. 关闭/移除端口规则"
        echo "4. 放行指定 IP (白名单)"
        echo "5. 启用防火墙 (自动放行当前 SSH 端口)"
        echo "6. 停用防火墙"
        echo -e "7. 一键切换禁 Ping (ICMP) [当前: ${ping_str}]"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) clear; vps_fw_status "$fw"; break_end ;;
            2) vps_fw_allow_port "$fw"; break_end ;;
            3) vps_fw_deny_port "$fw"; break_end ;;
            4) vps_fw_allow_ip "$fw"; break_end ;;
            5) vps_fw_enable "$fw"; break_end ;;
            6) vps_fw_disable "$fw"; break_end ;;
            7)
                if [ "$(vps_fw_ping_status)" = "disabled" ]; then
                    vps_fw_set_ping on
                else
                    vps_fw_set_ping off
                fi
                break_end
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
