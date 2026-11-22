# ============ Caddy 安装、服务与维护 ============

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
    echo -e "${gl_kjlan}========== 反代配置 ==========${gl_bai}"
    if [[ -d $CADDY_SITES ]]; then
        local f
        shopt -s nullglob
        local files=("$CADDY_SITES"/*.caddy)
        shopt -u nullglob
        if ((${#files[@]})); then
            for f in "${files[@]}"; do
                echo -e "\n${gl_huang}--- $(basename "$f") ---${gl_bai}"
                sed -n '1,120p' "$f"
            done
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
