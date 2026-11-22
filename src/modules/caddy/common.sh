# ============ Caddy 公共工具与校验 ============

CADDY_MAIN=/etc/caddy/Caddyfile
CADDY_SITES=/etc/caddy/sites
CADDY_BACKUP=/etc/caddy/vps-toolbox-backups

caddy_need_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${gl_huang}提示: ${gl_bai}需要 root 权限" >&2; return 1; }
}

caddy_need_binary() {
    command -v caddy >/dev/null 2>&1 || { echo -e "${gl_huang}提示: ${gl_bai}请先安装 Caddy" >&2; return 1; }
}

caddy_domain_ok() {
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* && ${#1} -le 253 ]]
}

caddy_ipv4_ok() {
    local ip=$1 a b c d n
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do ((10#$n <= 255)) || return 1; done
}

caddy_port_ok() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

caddy_prepare() {
    caddy_need_root && caddy_need_binary || return 1
    mkdir -p "$CADDY_SITES" "$CADDY_BACKUP"
    [[ -f $CADDY_MAIN ]] || printf '# Managed by VPS Toolbox\nimport /etc/caddy/sites/*.caddy\n' > "$CADDY_MAIN"
    if ! grep -Eq '^[[:space:]]*import[[:space:]]+/etc/caddy/sites/\*\.caddy([[:space:]]|$)' "$CADDY_MAIN"; then
        echo -e "${gl_huang}当前 Caddyfile 尚未导入 sites/*.caddy。${gl_bai}"
        local confirm
        read -r -p '自动添加 import 到 Caddyfile 末尾？[y/N]: ' confirm || return 1
        [[ $confirm == [yY] ]] || return 1
        cp -a "$CADDY_MAIN" "$CADDY_BACKUP/Caddyfile.$(date +%Y%m%d%H%M%S).bak" || return 1
        printf '\nimport /etc/caddy/sites/*.caddy\n' >> "$CADDY_MAIN"
    fi
    caddy validate --config "$CADDY_MAIN" --adapter caddyfile || return 1
}

caddy_snapshot() {
    mkdir -p "$CADDY_BACKUP"
    local name
    name=$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$CADDY_BACKUP/$name" "$CADDY_SITES" || return 1
    cp -a "$CADDY_MAIN" "$CADDY_BACKUP/$name/Caddyfile" || return 1
    cp -a "$CADDY_SITES" "$CADDY_BACKUP/$name/sites" || return 1
    CADDY_LAST_BACKUP="$CADDY_BACKUP/$name"
}

caddy_restore_snapshot() {
    [[ -n ${CADDY_LAST_BACKUP:-} && -d $CADDY_LAST_BACKUP ]] || return 1
    cp -a "$CADDY_LAST_BACKUP/Caddyfile" "$CADDY_MAIN" || return 1
    rm -rf -- "$CADDY_SITES" || return 1
    cp -a "$CADDY_LAST_BACKUP/sites" "$CADDY_SITES"
}

caddy_apply() {
    if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile; then
        echo -e "${gl_hong}配置校验失败，正在恢复备份...${gl_bai}" >&2
        caddy_restore_snapshot
        return 1
    fi
    if ! service_action reload caddy; then
        echo -e "${gl_hong}重载失败，正在恢复备份...${gl_bai}" >&2
        caddy_restore_snapshot
        service_action reload caddy || true
        return 1
    fi
    echo -e "${gl_lv}Caddy 配置已生效。${gl_bai}"
}

caddy_select_site() {
    local prompt="${1:-请输入序号或域名 (输入 0 返回): }" input idx i=1 f
    shopt -s nullglob
    local -a files=("$CADDY_SITES"/*.caddy)
    shopt -u nullglob
    ((${#files[@]})) || { echo -e "${gl_hui}当前没有反代配置${gl_bai}"; return 1; }
    echo -e "${gl_kjlan}当前站点列表：${gl_bai}"
    for f in "${files[@]}"; do
        printf "  ${gl_kjlan}%d.${gl_bai} %s\n" "$i" "$(basename "$f" .caddy)"
        i=$((i + 1))
    done
    read -r -e -p "$prompt" input || return 1
    [ "$input" = "0" ] && return 2
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        idx=$((10#$input))
        if ((idx >= 1 && idx <= ${#files[@]})); then
            CADDY_SELECTED_FILE="${files[idx-1]}"
            CADDY_SELECTED_DOMAIN="$(basename "$CADDY_SELECTED_FILE" .caddy)"
            return 0
        fi
        echo -e "${gl_hong}序号超出范围${gl_bai}" >&2
        return 1
    fi
    caddy_domain_ok "$input" || { echo -e "${gl_hong}域名格式不正确${gl_bai}" >&2; return 1; }
    f="$CADDY_SITES/${input}.caddy"
    [[ -f $f && ! -L $f ]] || { echo -e "${gl_hong}配置不存在: $input${gl_bai}" >&2; return 1; }
    CADDY_SELECTED_FILE="$f"
    CADDY_SELECTED_DOMAIN="$input"
    return 0
}
