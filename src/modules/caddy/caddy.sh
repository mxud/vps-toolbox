# Caddy management module for VPS Toolbox
CADDY_MAIN=/etc/caddy/Caddyfile
CADDY_SITES=/etc/caddy/sites
CADDY_BACKUP=/etc/caddy/vps-toolbox-backups

caddy_need_root() { [[ $EUID -eq 0 ]] || { echo '需要 root 权限'; return 1; }; }
caddy_need_binary() { command -v caddy >/dev/null 2>&1 || { echo '请先安装 Caddy'; return 1; }; }
caddy_pause() { read -r -p '按回车键继续...' _ || :; }
caddy_domain_ok() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* && ${#1} -le 253 ]]; }
caddy_ipv4_ok() {
    local ip=$1 a b c d n
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do ((10#$n <= 255)) || return 1; done
}
caddy_port_ok() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
caddy_prepare() {
    caddy_need_root && caddy_need_binary || return 1
    mkdir -p "$CADDY_SITES" "$CADDY_BACKUP"
    [[ -f $CADDY_MAIN ]] || printf '# Managed by VPS Toolbox\nimport /etc/caddy/sites/*.caddy\n' > "$CADDY_MAIN"
    if ! grep -Eq '^[[:space:]]*import[[:space:]]+/etc/caddy/sites/\*\.caddy([[:space:]]|$)' "$CADDY_MAIN"; then
        echo '当前 Caddyfile 尚未导入 sites/*.caddy。'
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
        echo '配置校验失败，正在恢复备份...'; caddy_restore_snapshot; return 1
    fi
    if ! systemctl reload caddy; then
        echo '重载失败，正在恢复备份...'
        caddy_restore_snapshot
        systemctl reload caddy || true
        return 1
    fi
    echo 'Caddy 配置已生效。'
}
caddy_install() {
    caddy_need_root || return 1
    command -v apt-get >/dev/null 2>&1 || { echo '当前仅支持 Debian / Ubuntu 的官方 APT 安装方式。'; return 1; }
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
    systemctl enable --now caddy && caddy version
}
caddy_add() {
    local mode=$1 domain upstream port ip sni filename
    caddy_prepare || return 1
    read -r -p '反代域名（例如 app.example.com）: ' domain || return 1
    caddy_domain_ok "$domain" || { echo '域名格式不正确'; return 1; }
    filename="$CADDY_SITES/${domain}.caddy"
    [[ ! -e $filename && ! -L $filename ]] || { echo '此域名的配置文件已存在，不会覆盖'; return 1; }
    if [[ $mode == standard ]]; then
        read -r -p '目标地址（例如 127.0.0.1:3000 或 https://backend.example.com）: ' upstream || return 1
        if [[ $upstream =~ ^https?://[a-zA-Z0-9.:-]+$ || $upstream =~ ^[a-zA-Z0-9.:-]+$ ]]; then :; else echo '地址格式不正确（暂不支持路径、IPv6 字面量）'; return 1; fi
    else
        read -r -p '源站 IPv4: ' ip || return 1
        caddy_ipv4_ok "$ip" || { echo 'IPv4 格式不正确'; return 1; }
        read -r -p '源站 HTTPS 端口 [443]: ' port || return 1
        port=${port:-443}
        caddy_port_ok "$port" || { echo '端口不正确'; return 1; }
        read -r -p '源站证书域名 / SNI（必须与证书匹配）: ' sni || return 1
        caddy_domain_ok "$sni" || { echo 'SNI 域名格式不正确'; return 1; }
    fi
    caddy_snapshot || return 1
    if [[ $mode == standard ]]; then
        printf '%s {\n    encode zstd gzip\n    reverse_proxy %s\n}\n' "$domain" "$upstream" > "$filename"
    else
        cat > "$filename" <<EOC
$domain {
    encode zstd gzip
    reverse_proxy $ip:$port {
        header_up Host $sni
        transport http {
            tls
            tls_server_name $sni
        }
    }
}
EOC
    fi
    caddy_apply
}
caddy_delete() {
    caddy_prepare || return 1
    local f domain
    shopt -s nullglob
    local files=("$CADDY_SITES"/*.caddy)
    shopt -u nullglob
    ((${#files[@]})) || { echo '没有反代配置'; return 0; }
    printf '当前反代域名：\n'
    for f in "${files[@]}"; do echo "  $(basename "$f" .caddy)"; done
    read -r -p '输入要删除的域名: ' domain || return 1
    caddy_domain_ok "$domain" || return 1
    f="$CADDY_SITES/${domain}.caddy"
    [[ -f $f && ! -L $f ]] || { echo '配置不存在'; return 1; }
    read -r -p "确认删除 $domain？输入 DELETE: " answer || return 1
    [[ $answer == DELETE ]] || return 0
    caddy_snapshot && rm -- "$f" && caddy_apply
}
caddy_view() {
    caddy_prepare || return 1
    caddy fmt "$CADDY_MAIN" || return 1
    echo '========== /etc/caddy/Caddyfile =========='
    local f
    for f in "$CADDY_SITES"/*.caddy; do
        [[ -f $f ]] || continue
        caddy fmt "$f" || return 1
        echo "========== $f =========="
        caddy fmt "$f"
    done
}
caddy_reset() {
    caddy_prepare || return 1
    echo '此操作将清空 Caddyfile 和所有 sites/*.caddy 配置，保留备份。'
    read -r -p '输入 RESET 确认：' answer || return 1
    [[ $answer == RESET ]] || return 0
    caddy_snapshot || return 1
    printf '# Managed by VPS Toolbox\nimport /etc/caddy/sites/*.caddy\n' > "$CADDY_MAIN"
    local f
    for f in "$CADDY_SITES"/*.caddy; do [[ -f $f ]] && rm -- "$f"; done
    caddy_apply
}
caddy_uninstall() {
    caddy_need_root || return 1
    command -v apt-get >/dev/null 2>&1 || { echo '当前仅支持通过 APT 卸载 Caddy'; return 1; }
    echo '危险：将卸载 Caddy，并删除 /etc/caddy 中的全部配置（包括非本工具管理的配置）。'
    read -r -p '输入 UNINSTALL 确认：' answer || return 1
    [[ $answer == UNINSTALL ]] || return 0
    local dest="/root/caddy-backup-$(date +%Y%m%d-%H%M%S)-$$.tar.gz"
    [[ ! -d /etc/caddy ]] || tar -C /etc -czf "$dest" caddy || return 1
    systemctl disable --now caddy 2>/dev/null || true
    apt-get remove -y caddy || return 1
    rm -rf -- /etc/caddy
    echo "Caddy 已卸载；配置备份（如果存在）: $dest"
}
caddy_list() {
    caddy_need_root && caddy_need_binary || return 1
    echo '========== Caddy 服务状态 =========='
    systemctl --no-pager --full status caddy 2>/dev/null | sed -n '1,8p' || true
    echo
    echo '========== 反代配置 =========='
    if [[ -d $CADDY_SITES ]]; then
        local f
        shopt -s nullglob
        local files=("$CADDY_SITES"/*.caddy)
        shopt -u nullglob
        if ((${#files[@]})); then
            for f in "${files[@]}"; do
                printf '\n--- %s ---\n' "$(basename "$f")"
                sed -n '1,120p' "$f"
            done
        else
            echo '目前没有由工具箱管理的反代配置。'
        fi
    else
        echo '站点配置目录尚不存在。'
    fi
}

caddy_check_reload() {
    caddy_prepare || return 1
    echo '检查 Caddyfile 格式...'
    caddy fmt --overwrite "$CADDY_MAIN" || return 1
    local f
    shopt -s nullglob
    local files=("$CADDY_SITES"/*.caddy)
    shopt -u nullglob
    for f in "${files[@]}"; do caddy fmt --overwrite "$f" || return 1; done
    caddy validate --config "$CADDY_MAIN" --adapter caddyfile || return 1
    systemctl reload caddy || { echo '重载失败，请检查 systemctl status caddy 和 journalctl -u caddy'; return 1; }
    echo '格式检查、配置校验和重载均已完成。'
}

caddy_export_migration() {
    caddy_need_root || return 1
    command -v tar >/dev/null 2>&1 || { echo '需要 tar'; return 1; }
    local dest="${1:-/root/caddy-migration-$(date +%Y%m%d-%H%M%S).tar.gz}"
    [[ ! -e $dest && ! -L $dest ]] || { echo "文件已存在，不覆盖：$dest"; return 1; }
    [[ -f $CADDY_MAIN ]] || { echo "$CADDY_MAIN 不存在，尚未安装或没有配置"; return 1; }
    local -a paths=(etc/caddy)
    [[ ! -d /var/lib/caddy/.local/share/caddy ]] || paths+=(var/lib/caddy/.local/share/caddy)
    # Avoid packing this tool's historical snapshots into every migration archive.
    tar --exclude='etc/caddy/vps-toolbox-backups' -C / -czpf "$dest" "${paths[@]}" || {
        rm -f -- "$dest"
        echo '导出失败，已删除不完整的备份文件。' >&2
        return 1
    }
    chmod 600 "$dest" || { rm -f -- "$dest"; return 1; }
    echo "迁移备份已生成：$dest"
    echo '备份包含 /etc/caddy（不含工具箱历史快照），以及存在时的 Caddy ACME/证书数据。'
    echo '该文件可能包含私钥和账户凭据，请安全传输并限制访问。'
}

# Global flag used by cleanup: never delete a rollback directory if recovery failed.
CADDY_MIGRATION_PRESERVE_ROLLBACK=0

caddy_migration_cleanup() {
    local tmp=${1:-} staged=${2:-} rollback=${3:-}
    [[ -z $tmp || ! -e $tmp ]] || rm -rf -- "$tmp"
    [[ -z $staged || ! -e $staged ]] || rm -rf -- "$staged"
    if [[ -n $rollback && -e $rollback ]]; then
        if (( CADDY_MIGRATION_PRESERVE_ROLLBACK )); then
            echo "警告：为避免丢失恢复数据，保留回滚目录：$rollback" >&2
        else
            rm -rf -- "$rollback"
        fi
    fi
}

# Restore ACME data from a private rollback directory. If restoration fails,
# move the backup to /root when possible and mark it for preservation otherwise.
caddy_migration_restore_data() {
    local rollback_dir=$1 data_path=/var/lib/caddy/.local/share/caddy recovery
    [[ -n $rollback_dir && -d $rollback_dir ]] || return 0
    if ! rm -rf -- "$data_path"; then
        recovery="/root/caddy-migration-recovery-$(date +%Y%m%d-%H%M%S)-$$"
        if mv -- "$rollback_dir" "$recovery" 2>/dev/null; then
            echo "无法移除导入后的证书目录；旧数据备份保留在：$recovery" >&2
        else
            CADDY_MIGRATION_PRESERVE_ROLLBACK=1
            echo "无法移除导入后的证书目录；请勿删除回滚目录：$rollback_dir" >&2
        fi
        return 1
    fi
    if [[ -f $rollback_dir/had-data ]]; then
        if [[ ! -d $rollback_dir/caddy ]] || ! cp -a "$rollback_dir/caddy" "$data_path"; then
            recovery="/root/caddy-migration-recovery-$(date +%Y%m%d-%H%M%S)-$$"
            if mv -- "$rollback_dir" "$recovery" 2>/dev/null; then
                echo "恢复旧证书数据失败；请手动恢复此备份：$recovery" >&2
            else
                CADDY_MIGRATION_PRESERVE_ROLLBACK=1
                echo "恢复旧证书数据失败；请勿删除回滚目录：$rollback_dir" >&2
            fi
            return 1
        fi
        chown -R caddy:caddy "$data_path" 2>/dev/null || true
    fi
    return 0
}

caddy_import_migration() {
    caddy_need_root && caddy_need_binary || return 1
    command -v tar >/dev/null 2>&1 || { echo '需要 tar'; return 1; }

    local archive tmp item listing answer data_path=/var/lib/caddy/.local/share/caddy
    local rollback_dir='' staged_data='' data_in_archive=0
    CADDY_MIGRATION_PRESERVE_ROLLBACK=0
    read -r -p '迁移备份 tar.gz 的绝对路径: ' archive || return 1
    [[ -f $archive && ! -L $archive ]] || { echo '备份文件不存在或不是普通文件'; return 1; }
    tar -tzf "$archive" >/dev/null 2>&1 || { echo '备份文件不是有效的 tar.gz'; return 1; }

    # Only accept paths generated by caddy_export_migration. Reject traversal,
    # absolute paths and links so an untrusted archive cannot escape the staging dir.
    while IFS= read -r item; do
        item=${item#./}; item=${item%/}
        [[ -z $item ]] && continue
        case "$item" in
            etc/caddy|etc/caddy/*|var/lib/caddy/.local/share/caddy|var/lib/caddy/.local/share/caddy/*) ;;
            *) echo "备份包含不允许的路径：$item" >&2; return 1 ;;
        esac
        [[ $item != /* && "/$item/" != *"/../"* && $item != *$'\n'* ]] || {
            echo '备份路径不安全。' >&2; return 1;
        }
    done < <(tar -tzf "$archive") || { echo '备份路径检查失败'; return 1; }
    while IFS= read -r listing; do
        case "${listing:0:1}" in
            l|h) echo '备份包含符号链接或硬链接，出于安全考虑拒绝导入。' >&2; return 1 ;;
        esac
    done < <(tar -tvzf "$archive")

    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp" || { rm -rf -- "$tmp"; return 1; }
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp"; then
        rm -rf -- "$tmp"; echo '解压失败'; return 1
    fi
    [[ -f $tmp/etc/caddy/Caddyfile ]] || {
        rm -rf -- "$tmp"; echo '备份中缺少 etc/caddy/Caddyfile'; return 1;
    }
    if [[ -d $tmp/var/lib/caddy/.local/share/caddy ]]; then data_in_archive=1; fi

    echo '导入将替换 Caddyfile 和 sites 配置。若备份包含 ACME/证书数据，也会替换目标服务器对应数据。'
    echo '当前配置会先做快照；证书数据会另行备份，以便失败时恢复。'
    read -r -p '输入 IMPORT 确认继续: ' answer || { rm -rf -- "$tmp"; return 1; }
    [[ $answer == IMPORT ]] || { rm -rf -- "$tmp"; return 0; }

    caddy_snapshot || { rm -rf -- "$tmp"; echo '创建当前配置快照失败，未执行导入。' >&2; return 1; }

    # Stage incoming certificate data before touching the current data directory.
    if (( data_in_archive )); then
        mkdir -p "$(dirname "$data_path")" || { rm -rf -- "$tmp"; return 1; }
        staged_data="$(dirname "$data_path")/.caddy-migration-new.$$"
        [[ ! -e $staged_data && ! -L $staged_data ]] || { rm -rf -- "$tmp"; echo '临时证书目录已存在，拒绝覆盖。' >&2; return 1; }
        cp -a "$tmp/var/lib/caddy/.local/share/caddy" "$staged_data" || {
            rm -rf -- "$tmp" "$staged_data"; echo '准备新证书数据失败，未替换旧数据。' >&2; return 1;
        }
        chown -R caddy:caddy "$staged_data" 2>/dev/null || true
        rollback_dir=$(mktemp -d "$(dirname "$data_path")/.vps-toolbox-caddy-rollback.XXXXXX") || {
            rm -rf -- "$tmp" "$staged_data"; return 1;
        }
        chmod 700 "$rollback_dir" || { caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1; }
        if [[ -d $data_path ]]; then
            cp -a "$data_path" "$rollback_dir/caddy" || {
                caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; echo '备份旧证书数据失败，未执行导入。' >&2; return 1;
            }
            : > "$rollback_dir/had-data"
        fi
    fi

    # Install configuration. Every failure below restores both config and, when
    # present in the archive, the previous ACME data directory.
    if ! cp -a "$tmp/etc/caddy/Caddyfile" "$CADDY_MAIN"; then
        echo '写入 Caddyfile 失败，正在回滚。' >&2
        caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
        [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
        caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
        return 1
    fi
    if [[ -d $tmp/etc/caddy/sites ]]; then
        rm -rf -- "$CADDY_SITES" || {
            caddy_restore_snapshot || true
            [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || true
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1;
        }
        cp -a "$tmp/etc/caddy/sites" "$CADDY_SITES" || {
            echo '写入站点目录失败，正在回滚。' >&2
            caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
            [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1;
        }
    else
        mkdir -p "$CADDY_SITES" || {
            caddy_restore_snapshot || true
            [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || true
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1;
        }
        find "$CADDY_SITES" -maxdepth 1 -type f -name '*.caddy' -delete
    fi

    if (( data_in_archive )); then
        rm -rf -- "$data_path" || {
            caddy_restore_snapshot || true
            caddy_migration_restore_data "$rollback_dir" || true
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1;
        }
        mv -- "$staged_data" "$data_path" || {
            echo '安装新证书数据失败，正在回滚。' >&2
            caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
            caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1;
        }
    fi

    if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile; then
        echo '导入配置校验失败，正在恢复导入前状态。' >&2
        caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
        [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
        caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
        return 1
    fi
    if ! systemctl reload caddy; then
        echo '重载失败，正在恢复导入前状态。' >&2
        caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
        [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
        systemctl reload caddy || true
        caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
        return 1
    fi

    caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
    echo '迁移配置已导入并生效。请检查 DNS、端口、防火墙和证书状态。'
    (( data_in_archive )) || echo '迁移包不含 ACME/证书数据，目标服务器现有证书数据已保留。'
}

caddy_add_menu() {
    local choice
    while true; do
        echo
        echo '添加反向代理'
        echo '1) 标准反代（HTTP/HTTPS 域名或本机端口）'
        echo '2) HTTPS 指定源站 IP（自定义 SNI / Host）'
        echo '0) 返回'
        read -r -p '请选择：' choice || return 0
        case "$choice" in
            1) caddy_add standard; caddy_pause; return 0 ;;
            2) caddy_add realip; caddy_pause; return 0 ;;
            0) return 0 ;;
            *) echo '无效选择' ;;
        esac
    done
}

caddy_menu() {
    local choice
    while true; do
        clear
        printf '\033[36m============================\n  Caddy 管理\n============================\033[0m\n'
        printf '\033[32m1) 安装/升级 Caddy\n2) 添加反向代理\n3) 查看服务状态与反代配置\n4) 删除反代\n5) 格式化、校验并重载配置\n6) 导出迁移备份\n7) 导入迁移备份\n8) 清空/重置反代配置\n9) 卸载 Caddy（保留配置）\n0) 返回上级菜单\033[0m\n\n'
        read -r -p '请选择：' choice || return 0
        case "$choice" in
            1) caddy_install; caddy_pause ;;
            2) caddy_add_menu ;;
            3) caddy_list; caddy_pause ;;
            4) caddy_delete; caddy_pause ;;
            5) caddy_check_reload; caddy_pause ;;
            6) caddy_export_migration; caddy_pause ;;
            7) caddy_import_migration; caddy_pause ;;
            8) caddy_reset; caddy_pause ;;
            9)
                caddy_need_root || { caddy_pause; continue; }
                echo '将卸载 Caddy 软件包，但保留 /etc/caddy 配置和证书数据，方便之后迁移或重新安装。'
                read -r -p '输入 UNINSTALL 确认：' answer || return 0
                if [[ $answer == UNINSTALL ]]; then
                    systemctl disable --now caddy 2>/dev/null || true
                    if command -v apt-get >/dev/null 2>&1; then apt-get remove -y caddy; else echo '当前仅支持通过 APT 卸载 Caddy'; fi
                fi
                caddy_pause ;;
            0) return 0 ;;
            *) echo '无效选择'; caddy_pause ;;
        esac
    done
}
