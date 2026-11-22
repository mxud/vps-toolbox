# ============ 一键系统优化 ============

VPS_OPT_SYSCTL="/etc/sysctl.d/99-vps-toolbox-optimize.conf"
VPS_OPT_LIMITS="/etc/security/limits.d/99-vps-toolbox.conf"
VPS_OPT_SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-vps-toolbox-limits.conf"
VPS_OPT_JOURNALD="/etc/systemd/journald.conf.d/99-vps-toolbox.conf"

vps_opt_apply_kernel() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local mem_mb rmem_max wmem_max tcp_rmem tcp_wmem candidate
    mem_mb=$(awk '/MemTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 512)

    # 按物理内存自适应缓冲区大小，防止小内存机器 OOM
    if [ "${mem_mb:-512}" -ge 2048 ]; then
        rmem_max=16777216
        wmem_max=16777216
        tcp_rmem="4096 87380 16777216"
        tcp_wmem="4096 65536 16777216"
    else
        rmem_max=4194304
        wmem_max=4194304
        tcp_rmem="4096 87380 4194304"
        tcp_wmem="4096 65536 4194304"
    fi

    bbr_on || echo "提示：BBR 开启未完全生效，继续应用其余内核优化。" >&2

    [ ! -L "$VPS_OPT_SYSCTL" ] || { echo "拒绝覆盖符号链接: $VPS_OPT_SYSCTL" >&2; return 1; }
    mkdir -p /etc/sysctl.d || return 1
    candidate=$(mktemp /etc/sysctl.d/.vps-opt.XXXXXX) || return 1
    cat > "$candidate" <<EOF
# Managed by VPS Toolbox
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF
    chmod 644 "$candidate" && mv -f -- "$candidate" "$VPS_OPT_SYSCTL" || { rm -f -- "$candidate"; return 1; }
    sysctl -p "$VPS_OPT_SYSCTL" >/dev/null 2>&1 || true

    # 提升文件描述符上限至 65535
    if [ ! -L "$VPS_OPT_LIMITS" ]; then
        mkdir -p /etc/security/limits.d || return 1
        cat > "$VPS_OPT_LIMITS" <<EOF
# Managed by VPS Toolbox
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
        chmod 644 "$VPS_OPT_LIMITS"
    fi

    if [ -d /run/systemd/system ]; then
        if [ ! -L "$VPS_OPT_SYSTEMD_LIMITS" ]; then
            mkdir -p /etc/systemd/system.conf.d || return 1
            cat > "$VPS_OPT_SYSTEMD_LIMITS" <<EOF
# Managed by VPS Toolbox
[Manager]
DefaultLimitNOFILE=65535
EOF
            chmod 644 "$VPS_OPT_SYSTEMD_LIMITS"
            systemctl daemon-reexec >/dev/null 2>&1 || true
        fi

        if [ ! -L "$VPS_OPT_JOURNALD" ]; then
            mkdir -p /etc/systemd/journald.conf.d || return 1
            cat > "$VPS_OPT_JOURNALD" <<EOF
# Managed by VPS Toolbox
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
EOF
            chmod 644 "$VPS_OPT_JOURNALD"
            service_action restart systemd-journald >/dev/null 2>&1 || true
        fi
    fi

    echo -e "${gl_lv}内核网络、BBR、文件句柄 (65535) 与日志限制 (100M/7d) 优化已完成${gl_bai}"
}

vps_opt_auto_dns() {
    local country
    country=$(curl -fsS --proto '=https' --proto-redir '=https' --max-time 3 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$country" = "CN" ]; then
        echo "检测到国内网络环境，应用国内公共 DNS (223.5.5.5 / 119.29.29.29)..."
        vps_dns_apply "223.5.5.5" "119.29.29.29" "2400:3200::1" "2400:3200:baba::1"
    else
        echo "检测到海外网络环境，应用国际公共 DNS (1.1.1.1 / 8.8.8.8)..."
        vps_dns_apply "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888"
    fi
}

vps_opt_full_init() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    clear
    echo -e "${gl_kjlan}================== 新机一键优化与初始化 ==================${gl_bai}"
    echo "即将按顺序执行以下 8 项操作："
    echo "  1. 系统更新与清理"
    echo "  2. 安装基础工具 (curl wget sudo unzip nano vim) 与 Docker"
    echo "  3. 设置虚拟内存 Swap 为 1024M (1G)"
    echo "  4. 设置系统时区为 Asia/Shanghai"
    echo "  5. 自动优化 DNS 地址 (按地区匹配)"
    echo "  6. 设置网络为 IPv4 优先"
    echo "  7. 开启 BBR 加速 + 内核/文件句柄/日志调优"
    echo "  8. 安装并启用 Fail2ban SSH 防爆破 (自动适配当前 SSH 端口)"
    echo -e "${gl_kjlan}----------------------------------------------------------${gl_bai}"
    local confirm
    read -r -p "确认开始执行一键优化？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }

    local -a ok_steps=() fail_steps=()
    local ssh_port

    echo -e "\n${gl_huang}[1/8] 正在执行系统更新与清理...${gl_bai}"
    if linux_update && linux_clean; then ok_steps+=("系统更新与清理"); else fail_steps+=("系统更新与清理"); fi

    echo -e "\n${gl_huang}[2/8] 正在安装基础工具与 Docker...${gl_bai}"
    local base_ok=1
    pkg_install curl wget sudo unzip nano vim || base_ok=0
    if install_docker; then
        if [ ! -e /etc/docker/daemon.json ] && [ ! -L /etc/docker/daemon.json ]; then
            mkdir -p /etc/docker
            local d_cand
            if d_cand=$(mktemp /etc/docker/.daemon.json.vps.XXXXXX); then
                cat > "$d_cand" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
EOF
                chmod 644 "$d_cand" && mv -f -- "$d_cand" /etc/docker/daemon.json && restart docker >/dev/null 2>&1 || rm -f -- "$d_cand"
                echo -e "${gl_lv}已自动配置 Docker 日志轮转 (max-size=20m, max-file=3)${gl_bai}"
            fi
        fi
    else
        base_ok=0
    fi
    if [ "$base_ok" -eq 1 ]; then ok_steps+=("基础工具与 Docker"); else fail_steps+=("基础工具与 Docker"); fi

    echo -e "\n${gl_huang}[3/8] 正在设置虚拟内存 (1024M)...${gl_bai}"
    if add_swap 1024; then ok_steps+=("虚拟内存 1024M"); else fail_steps+=("虚拟内存 1024M"); fi

    echo -e "\n${gl_huang}[4/8] 正在设置系统时区为 Asia/Shanghai...${gl_bai}"
    if set_timedate Asia/Shanghai; then ok_steps+=("时区 Asia/Shanghai"); else fail_steps+=("时区 Asia/Shanghai"); fi

    echo -e "\n${gl_huang}[5/8] 正在自动优化 DNS 地址...${gl_bai}"
    if vps_opt_auto_dns; then ok_steps+=("自动优化 DNS"); else fail_steps+=("自动优化 DNS"); fi

    echo -e "\n${gl_huang}[6/8] 正在设置 IPv4 优先...${gl_bai}"
    if vps_set_ip_preference 4; then ok_steps+=("IPv4 优先"); else fail_steps+=("IPv4 优先"); fi

    echo -e "\n${gl_huang}[7/8] 正在开启 BBR 加速并应用内核/句柄/日志优化...${gl_bai}"
    if vps_opt_apply_kernel; then ok_steps+=("BBR 与内核优化"); else fail_steps+=("BBR 与内核优化"); fi

    echo -e "\n${gl_huang}[8/8] 正在安装并配置 Fail2ban SSH 防爆破...${gl_bai}"
    ssh_port=$(vps_fw_ssh_port)
    if vps_f2b_apply_config "$ssh_port" 5 10m 1h; then ok_steps+=("Fail2ban (端口 $ssh_port)"); else fail_steps+=("Fail2ban"); fi

    echo -e "\n${gl_kjlan}==================== 一键优化执行汇总 ====================${gl_bai}"
    if [ "${#ok_steps[@]}" -gt 0 ]; then
        echo -e "${gl_lv}已完成 (${#ok_steps[@]}/8):${gl_bai} ${ok_steps[*]}"
    fi
    if [ "${#fail_steps[@]}" -gt 0 ]; then
        echo -e "${gl_hong}未完成/需检查 (${#fail_steps[@]}/8):${gl_bai} ${fail_steps[*]}"
    fi
    echo "提示：文件句柄 (nofile 65535) 将在新打开的 SSH 会话与新启动服务中生效。"
}

vps_opt_status() {
    local cc qd swap_m tz ipc dns_str docker_ver f2b_str nofile_lim
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    swap_m=$(awk '/SwapTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    tz=$(current_timezone)
    if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100' /etc/gai.conf 2>/dev/null; then
        ipc="IPv4 优先"
    else
        ipc="系统默认"
    fi
    dns_str=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
    docker_ver=$(docker --version 2>/dev/null || echo "未安装")
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        f2b_str="运行中"
    elif command -v fail2ban-client >/dev/null 2>&1; then
        f2b_str="已安装未运行"
    else
        f2b_str="未安装"
    fi
    nofile_lim=$(ulimit -n 2>/dev/null || echo "未知")

    echo -e "${gl_kjlan}==================== 当前优化状态 ====================${gl_bai}"
    echo -e "BBR / 队列算法:    ${gl_lv}${cc} / ${qd}${gl_bai}"
    echo -e "内核优化配置:      $([ -f "$VPS_OPT_SYSCTL" ] && echo -e "${gl_lv}已启用${gl_bai}" || echo -e "${gl_hui}未启用${gl_bai}")"
    echo -e "文件句柄限制:      当前会话 ${nofile_lim} / 配置 $([ -f "$VPS_OPT_LIMITS" ] && echo -e "${gl_lv}65535${gl_bai}" || echo -e "${gl_hui}默认${gl_bai}")"
    echo -e "日志体积限制:      $([ -f "$VPS_OPT_JOURNALD" ] && echo -e "${gl_lv}100M / 7天${gl_bai}" || echo -e "${gl_hui}系统默认${gl_bai}")"
    echo -e "虚拟内存 (Swap):   ${gl_huang}${swap_m}M${gl_bai}"
    echo -e "系统时区:          ${tz}"
    echo -e "网络优先级:        ${ipc}"
    echo -e "当前 DNS:          ${dns_str:-系统默认}"
    echo -e "Docker:            ${docker_ver}"
    echo -e "Fail2ban:          ${f2b_str}"
    echo -e "${gl_kjlan}======================================================${gl_bai}"
}

vps_opt_revert() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local confirm
    read -r -p "将移除工具箱写入的内核/句柄/日志调优配置，继续？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
    rm -f -- "$VPS_OPT_SYSCTL" "$VPS_OPT_LIMITS" "$VPS_OPT_SYSTEMD_LIMITS" "$VPS_OPT_JOURNALD"
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reexec >/dev/null 2>&1 || true
        service_action restart systemd-journald >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${gl_lv}已移除工具箱调优配置（BBR/Swap/Docker/Fail2ban 保持不变）${gl_bai}"
}

vps_optimize_menu() {
    root_use || return
    local choice
    while true; do
        clear
        echo -e "${gl_kjlan}==================== 一键系统优化 ====================${gl_bai}"
        echo -e "1. ${gl_lv}新机一键全套初始化与优化${gl_bai}"
        echo -e "   ${gl_hui}(更新清理 + 基础工具/Docker + 1G Swap + 上海时区 + DNS + IPv4优先 + BBR/内核调优 + Fail2ban)${gl_bai}"
        echo "2. 仅执行轻量内核调优 (BBR + TCP + 文件句柄 65535 + 日志限制)"
        echo "3. 查看当前优化状态"
        echo "4. 还原工具箱内核/句柄/日志调优配置"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) vps_opt_full_init; break_end ;;
            2) vps_opt_apply_kernel; break_end ;;
            3) clear; vps_opt_status; break_end ;;
            4) vps_opt_revert; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
