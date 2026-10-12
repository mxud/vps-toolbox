# ============ BBR 管理 ============

bbr_on() {
    local CONF="/etc/sysctl.d/99-vps-bbr.conf"
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }

    if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null
    fi

    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo "当前内核不支持 BBR，可能需要升级内核" >&2
        return 1
    fi

    [ ! -L "$CONF" ] || { echo "拒绝覆盖 BBR 配置符号链接" >&2; return 1; }
    mkdir -p /etc/sysctl.d || return 1
    cat > "$CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    [ "$?" -eq 0 ] || return 1
    if grep -Eq '^[[:space:]]*(net.ipv4.tcp_congestion_control|net.core.default_qdisc)[[:space:]]*=' /etc/sysctl.conf 2>/dev/null; then
        cp -p /etc/sysctl.conf "/etc/sysctl.conf.vps-backup-$(date +%Y%m%d-%H%M%S)" || return 1
        sed -i '/^[[:space:]]*net.ipv4.tcp_congestion_control[[:space:]]*=/d; /^[[:space:]]*net.core.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf || return 1
    fi
    if ! sysctl -p "$CONF" || [ "$(sysctl -n net.ipv4.tcp_congestion_control)" != bbr ] ||
       [ "$(sysctl -n net.core.default_qdisc)" != fq ]; then
        echo "BBR 未完全生效，请检查 sysctl 输出和配置: $CONF" >&2
        return 1
    fi
    echo -e "${gl_lv}BBR 已成功开启${gl_bai}"
}

linux_bbr() {
    clear
    local cc qd kver
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    kver=$(uname -r | cut -d'-' -f1)

    while true; do
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        clear
        echo -e "BBR 拥塞控制管理"
        echo -e "当前内核版本: ${gl_huang}$kver${gl_bai}"
        echo -e "当前 TCP 算法: ${gl_lv}$cc / $qd${gl_bai}"
        echo "------------------------"
        echo "1. 开启原生 BBR"
        echo "2. 关闭 BBR 配置"
        echo "3. 第三方强力内核加速脚本 (tcpx.sh)"
        echo "0. 返回"
        echo "------------------------"
        read -r -e -p "请输入你的选择: " choice || return 0
        case $choice in
            1) bbr_on ; break_end ;;
            2)
                root_use || continue
                rm -f /etc/sysctl.d/99-vps-bbr.conf || { break_end; continue; }
                echo "工具箱的 BBR 配置已移除，重启后由系统默认网络算法接管。"
                server_reboot
                ;;
            3)
                run_remote_bash "${gh_proxy}raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh"
                break_end
                ;;
            *) break ;;
        esac
    done
}

