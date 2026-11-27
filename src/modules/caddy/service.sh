# ============ Caddy 安装、服务与维护 ============

caddy_ensure_firewall_ports() {
    local ans
    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        if ! LC_ALL=C ufw status 2>/dev/null | grep -Eq '^80(/tcp)?[[:space:]]+ALLOW' ||
           ! LC_ALL=C ufw status 2>/dev/null | grep -Eq '^443(/tcp)?[[:space:]]+ALLOW'; then
            echo -e "${gl_huang}检测到 UFW 防火墙已启用，但尚未完整放行 80/443 (HTTP/HTTPS/HTTP3) 端口。${gl_bai}"
            read -r -p "是否自动在 UFW 中放行 80/tcp、443/tcp 与 443/udp？[Y/n]: " ans || return 0
            if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
                ufw allow 80/tcp >/dev/null && ufw allow 443/tcp >/dev/null && ufw allow 443/udp >/dev/null &&
                    echo -e "${gl_lv}已在 UFW 放行 80/tcp、443/tcp、443/udp${gl_bai}"
            fi
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        if ! firewall-cmd --query-port=80/tcp >/dev/null 2>&1 ||
           ! firewall-cmd --query-port=443/tcp >/dev/null 2>&1; then
            echo -e "${gl_huang}检测到 Firewalld 防火墙运行中，但尚未完整放行 80/443 端口。${gl_bai}"
            read -r -p "是否自动在 Firewalld 中放行 80/tcp、443/tcp 与 443/udp？[Y/n]: " ans || return 0
            if [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]; then
                firewall-cmd --add-port=80/tcp --add-port=443/tcp --add-port=443/udp >/dev/null &&
                    firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp --add-port=443/udp >/dev/null &&
                    echo -e "${gl_lv}已在 Firewalld 放行 80/tcp、443/tcp、443/udp${gl_bai}"
            fi
        fi
    fi
}

caddy_install() {
    caddy_need_root || return 1
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1
        local tmp
        tmp=$(mktemp) || return 1
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$tmp" || { rm -f "$tmp"; return 1; }
        gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$tmp" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list || return 1
        chmod a+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
        apt-get update && apt-get install -y caddy || return 1
    elif command -v dnf >/dev/null 2>&1; then
        if command -v caddy >/dev/null 2>&1; then
            dnf upgrade -y caddy || return 1
        else
            dnf install -y 'dnf-command(copr)' && dnf copr enable -y @caddy/caddy && dnf install -y caddy || return 1
        fi
    elif command -v apk >/dev/null 2>&1; then
        apk update || return 1
        if command -v caddy >/dev/null 2>&1; then
            apk upgrade caddy || return 1
        else
            apk add caddy || return 1
        fi
    else
        echo -e "${gl_hong}当前仅支持 Debian/Ubuntu (apt)、RHEL/Rocky/Alma/Fedora (dnf) 与 Alpine (apk) 自动安装 Caddy。${gl_bai}" >&2
        return 1
    fi
    enable caddy || true
    start caddy && echo -e "${gl_lv}Caddy 已就绪: $(caddy version)${gl_bai}"
    caddy_ensure_firewall_ports
}

caddy_uninstall_keep_config() {
    caddy_need_root || return 1
    local answer
    echo -e "${gl_huang}将卸载 Caddy 软件包，但保留 /etc/caddy 配置和证书数据，方便之后迁移或重新安装。${gl_bai}"
    read -r -p '输入 UNINSTALL 确认：' answer || return 0
    [[ $answer == UNINSTALL ]] || { echo '已取消'; return 0; }
    service_action stop caddy 2>/dev/null || true
    if [ -d /run/systemd/system ]; then
        systemctl disable caddy 2>/dev/null || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update del caddy default 2>/dev/null || true
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y caddy
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y caddy
    elif command -v apk >/dev/null 2>&1; then
        apk del caddy
    else
        echo -e "${gl_hong}当前系统暂不支持自动卸载 Caddy，请使用对应包管理器手动卸载${gl_bai}" >&2
        return 1
    fi
    echo -e "${gl_lv}Caddy 已卸载（配置与证书已保留）。${gl_bai}"
}

caddy_reset() {
    caddy_prepare || return 1
    local answer f
    echo -e "${gl_huang}此操作将清空 Caddyfile 和所有 sites/*.caddy 配置，保留备份。${gl_bai}"
    read -r -p '输入 RESET 确认：' answer || return 1
    [[ $answer == RESET ]] || { echo '已取消'; return 0; }
    caddy_snapshot || return 1
    printf '# Managed by VPS Toolbox\nimport /etc/caddy/sites/*.caddy\n' > "$CADDY_MAIN"
    for f in "$CADDY_SITES"/*.caddy; do [[ -f $f ]] && rm -- "$f"; done
    caddy_apply
}

caddy_list() {
    caddy_need_root && caddy_need_binary || return 1
    echo -e "${gl_kjlan}========== Caddy 服务状态 ==========${gl_bai}"
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status caddy 2>/dev/null | sed -n '1,8p' || true
    else
        service_action status caddy 2>/dev/null || true
    fi
    echo ""
    echo -e "${gl_kjlan}========== 站点与反代摘要 ==========${gl_bai}"
    if [[ -d $CADDY_SITES ]]; then
        local f idx=1 domain stype target extra show_raw
        shopt -s nullglob
        local files=("$CADDY_SITES"/*.caddy)
        shopt -u nullglob
        if ((${#files[@]})); then
            printf " %-4s %-28s %-14s %s\n" "序号" "域名" "类型" "后端目标 / 规则"
            echo "----------------------------------------------------------------------------"
            for f in "${files[@]}"; do
                domain=$(basename "$f" .caddy)
                stype="自定义"
                target="-"
                extra=""
                if grep -q '^[[:space:]]*redir[[:space:]]\+' "$f" 2>/dev/null; then
                    stype="301重定向"
                    target=$(awk '$1=="redir" {print $2; exit}' "$f")
                elif grep -q '^[[:space:]]*reverse_proxy[[:space:]]\+' "$f" 2>/dev/null; then
                    stype="反向代理"
                    target=$(awk '$1=="reverse_proxy" {print $2; exit}' "$f")
                    if grep -q 'tls_insecure_skip_verify' "$f" 2>/dev/null; then
                        extra=" (跳过后端证书校验)"
                    elif grep -q 'tls_server_name' "$f" 2>/dev/null; then
                        extra=" (SNI: $(awk '$1=="tls_server_name" {print $2; exit}' "$f"))"
                    fi
                fi
                printf " %-4s %-28s %-14s %s%s\n" "${idx}." "$domain" "$stype" "$target" "$extra"
                idx=$((idx + 1))
            done
            echo "----------------------------------------------------------------------------"
            read -r -e -p "是否展开全部配置文件原文？[y/N]: " show_raw || return 0
            if [[ "$show_raw" =~ ^[Yy]$ ]]; then
                for f in "${files[@]}"; do
                    echo -e "\n${gl_huang}--- $(basename "$f") ---${gl_bai}"
                    sed -n '1,120p' "$f"
                done
            fi
        else
            echo -e "${gl_hui}目前没有由工具箱管理的反代配置。${gl_bai}"
        fi
    else
        echo -e "${gl_hui}站点配置目录尚不存在。${gl_bai}"
    fi
}

caddy_check_reload() {
    caddy_prepare || return 1
    echo -e "${gl_kjlan}正在格式化并校验 Caddyfile...${gl_bai}"
    caddy fmt --overwrite "$CADDY_MAIN" || return 1
    local f
    shopt -s nullglob
    local files=("$CADDY_SITES"/*.caddy)
    shopt -u nullglob
    for f in "${files[@]}"; do caddy fmt --overwrite "$f" || return 1; done
    caddy validate --config "$CADDY_MAIN" --adapter caddyfile || return 1
    service_action reload caddy || { echo -e "${gl_hong}重载失败，请检查 Caddy 服务状态与日志${gl_bai}" >&2; return 1; }
    echo -e "${gl_lv}格式检查、配置校验和重载均已完成。${gl_bai}"
}

caddy_logs() {
    caddy_need_root && caddy_need_binary || return 1
    local log_mode
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        read -r -e -p "日志模式 [1: 最近 100 行(默认) / 2: 实时追踪 -f]: " log_mode || return 0
        clear
        if [ "$log_mode" = "2" ]; then
            echo -e "${gl_huang}按 Ctrl+C 退出实时日志...${gl_bai}"
            journalctl -u caddy -n 50 -f || true
        else
            journalctl -u caddy -n 100 --no-pager
        fi
    else
        echo -e "${gl_hui}当前系统未使用 systemd journald，请直接查看 /var/log/caddy/ 或 OpenRC 日志。${gl_bai}"
    fi
}
