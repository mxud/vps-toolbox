# ============ Caddy 迁移备份与导入 ============

# Global flag used by cleanup: never delete a rollback directory if recovery failed.
CADDY_MIGRATION_PRESERVE_ROLLBACK=0

caddy_export_migration() {
    caddy_need_root || return 1
    command -v tar >/dev/null 2>&1 || { echo -e "${gl_hong}需要 tar${gl_bai}" >&2; return 1; }
    local dest="${1:-/root/caddy-migration-$(date +%Y%m%d-%H%M%S).tar.gz}"
    [[ ! -e $dest && ! -L $dest ]] || { echo -e "${gl_hong}文件已存在，不覆盖：$dest${gl_bai}" >&2; return 1; }
    [[ -f $CADDY_MAIN ]] || { echo -e "${gl_huang}$CADDY_MAIN 不存在，尚未安装或没有配置${gl_bai}" >&2; return 1; }
    local -a paths=(etc/caddy)
    [[ ! -d /var/lib/caddy/.local/share/caddy ]] || paths+=(var/lib/caddy/.local/share/caddy)
    # Avoid packing this tool's historical snapshots into every migration archive.
    tar --exclude='etc/caddy/vps-toolbox-backups' -C / -czpf "$dest" "${paths[@]}" || {
        rm -f -- "$dest"
        echo -e "${gl_hong}导出失败，已删除不完整的备份文件。${gl_bai}" >&2
        return 1
    }
    chmod 600 "$dest" || { rm -f -- "$dest"; return 1; }
    echo -e "${gl_lv}迁移备份已生成：${gl_huang}$dest${gl_bai}"
    echo '备份包含 /etc/caddy（不含工具箱历史快照），以及存在时的 Caddy ACME/证书数据。'
    echo -e "${gl_huang}该文件可能包含私钥和账户凭据，请安全传输并限制访问。${gl_bai}"
}

caddy_migration_cleanup() {
    local tmp=${1:-} staged=${2:-} rollback=${3:-}
    [[ -z $tmp || ! -e $tmp ]] || rm -rf -- "$tmp"
    [[ -z $staged || ! -e $staged ]] || rm -rf -- "$staged"
    if [[ -n $rollback && -e $rollback ]]; then
        if (( CADDY_MIGRATION_PRESERVE_ROLLBACK )); then
            echo -e "${gl_huang}警告：为避免丢失恢复数据，保留回滚目录：$rollback${gl_bai}" >&2
        else
            rm -rf -- "$rollback"
        fi
    fi
}

caddy_migration_restore_data() {
    local rollback_dir=$1 data_path=/var/lib/caddy/.local/share/caddy recovery
    [[ -n $rollback_dir && -d $rollback_dir ]] || return 0
    if ! rm -rf -- "$data_path"; then
        recovery="/root/caddy-migration-recovery-$(date +%Y%m%d-%H%M%S)-$$"
        if mv -- "$rollback_dir" "$recovery" 2>/dev/null; then
            echo -e "${gl_hong}无法移除导入后的证书目录；旧数据备份保留在：$recovery${gl_bai}" >&2
        else
            CADDY_MIGRATION_PRESERVE_ROLLBACK=1
            echo -e "${gl_hong}无法移除导入后的证书目录；请勿删除回滚目录：$rollback_dir${gl_bai}" >&2
        fi
        return 1
    fi
    if [[ -f $rollback_dir/had-data ]]; then
        if [[ ! -d $rollback_dir/caddy ]] || ! cp -a "$rollback_dir/caddy" "$data_path"; then
            recovery="/root/caddy-migration-recovery-$(date +%Y%m%d-%H%M%S)-$$"
            if mv -- "$rollback_dir" "$recovery" 2>/dev/null; then
                echo -e "${gl_hong}恢复旧证书数据失败；请手动恢复此备份：$recovery${gl_bai}" >&2
            else
                CADDY_MIGRATION_PRESERVE_ROLLBACK=1
                echo -e "${gl_hong}恢复旧证书数据失败；请勿删除回滚目录：$rollback_dir${gl_bai}" >&2
            fi
            return 1
        fi
        chown -R caddy:caddy "$data_path" 2>/dev/null || true
    fi
    return 0
}

caddy_import_migration() {
    caddy_need_root && caddy_need_binary || return 1
    command -v tar >/dev/null 2>&1 || { echo -e "${gl_hong}需要 tar${gl_bai}" >&2; return 1; }

    local archive tmp item listing answer data_path=/var/lib/caddy/.local/share/caddy
    local rollback_dir='' staged_data='' data_in_archive=0
    CADDY_MIGRATION_PRESERVE_ROLLBACK=0
    read -r -e -p '迁移备份 tar.gz 的绝对路径: ' archive || return 1
    [[ -f $archive && ! -L $archive ]] || { echo -e "${gl_hong}备份文件不存在或不是普通文件${gl_bai}" >&2; return 1; }
    tar -tzf "$archive" >/dev/null 2>&1 || { echo -e "${gl_hong}备份文件不是有效的 tar.gz${gl_bai}" >&2; return 1; }

    while IFS= read -r item; do
        item=${item#./}; item=${item%/}
        [[ -z $item ]] && continue
        case "$item" in
            etc/caddy|etc/caddy/*|var/lib/caddy/.local/share/caddy|var/lib/caddy/.local/share/caddy/*) ;;
            *) echo -e "${gl_hong}备份包含不允许的路径：$item${gl_bai}" >&2; return 1 ;;
        esac
        [[ $item != /* && "/$item/" != *"/../"* && $item != *$'\n'* ]] || {
            echo -e "${gl_hong}备份路径不安全。${gl_bai}" >&2; return 1
        }
    done < <(tar -tzf "$archive") || { echo -e "${gl_hong}备份路径检查失败${gl_bai}" >&2; return 1; }
    while IFS= read -r listing; do
        case "${listing:0:1}" in
            l|h) echo -e "${gl_hong}备份包含符号链接或硬链接，出于安全考虑拒绝导入。${gl_bai}" >&2; return 1 ;;
        esac
    done < <(tar -tvzf "$archive")

    tmp=$(mktemp -d) || return 1
    chmod 700 "$tmp" || { rm -rf -- "$tmp"; return 1; }
    if ! tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$tmp"; then
        rm -rf -- "$tmp"; echo -e "${gl_hong}解压失败${gl_bai}" >&2; return 1
    fi
    [[ -f $tmp/etc/caddy/Caddyfile ]] || {
        rm -rf -- "$tmp"; echo -e "${gl_hong}备份中缺少 etc/caddy/Caddyfile${gl_bai}" >&2; return 1
    }
    if [[ -d $tmp/var/lib/caddy/.local/share/caddy ]]; then data_in_archive=1; fi

    echo -e "${gl_huang}导入将替换 Caddyfile 和 sites 配置。若备份包含 ACME/证书数据，也会替换目标服务器对应数据。${gl_bai}"
    echo '当前配置会先做快照；证书数据会另行备份，以便失败时恢复。'
    read -r -p '输入 IMPORT 确认继续: ' answer || { rm -rf -- "$tmp"; return 1; }
    [[ $answer == IMPORT ]] || { rm -rf -- "$tmp"; echo '已取消'; return 0; }

    caddy_snapshot || { rm -rf -- "$tmp"; echo -e "${gl_hong}创建当前配置快照失败，未执行导入。${gl_bai}" >&2; return 1; }

    if (( data_in_archive )); then
        mkdir -p "$(dirname "$data_path")" || { rm -rf -- "$tmp"; return 1; }
        staged_data="$(dirname "$data_path")/.caddy-migration-new.$$"
        [[ ! -e $staged_data && ! -L $staged_data ]] || { rm -rf -- "$tmp"; echo -e "${gl_hong}临时证书目录已存在，拒绝覆盖。${gl_bai}" >&2; return 1; }
        cp -a "$tmp/var/lib/caddy/.local/share/caddy" "$staged_data" || {
            rm -rf -- "$tmp" "$staged_data"; echo -e "${gl_hong}准备新证书数据失败，未替换旧数据。${gl_bai}" >&2; return 1
        }
        chown -R caddy:caddy "$staged_data" 2>/dev/null || true
        rollback_dir=$(mktemp -d "$(dirname "$data_path")/.vps-toolbox-caddy-rollback.XXXXXX") || {
            rm -rf -- "$tmp" "$staged_data"; return 1
        }
        chmod 700 "$rollback_dir" || { caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1; }
        if [[ -d $data_path ]]; then
            cp -a "$data_path" "$rollback_dir/caddy" || {
                caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; echo -e "${gl_hong}备份旧证书数据失败，未执行导入。${gl_bai}" >&2; return 1
            }
            : > "$rollback_dir/had-data"
        fi
    fi

    if ! cp -a "$tmp/etc/caddy/Caddyfile" "$CADDY_MAIN"; then
        echo -e "${gl_hong}写入 Caddyfile 失败，正在回滚。${gl_bai}" >&2
        caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
        [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
        caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
        return 1
    fi
    if [[ -d $tmp/etc/caddy/sites ]]; then
        rm -rf -- "$CADDY_SITES" || {
            caddy_restore_snapshot || true
            [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || true
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1
        }
        cp -a "$tmp/etc/caddy/sites" "$CADDY_SITES" || {
            echo -e "${gl_hong}写入站点目录失败，正在回滚。${gl_bai}" >&2
            caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
            [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1
        }
    else
        mkdir -p "$CADDY_SITES" || {
            caddy_restore_snapshot || true
            [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || true
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1
        }
        find "$CADDY_SITES" -maxdepth 1 -type f -name '*.caddy' -delete
    fi

    if (( data_in_archive )); then
        rm -rf -- "$data_path" || {
            caddy_restore_snapshot || true
            caddy_migration_restore_data "$rollback_dir" || true
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1
        }
        mv -- "$staged_data" "$data_path" || {
            echo -e "${gl_hong}安装新证书数据失败，正在回滚。${gl_bai}" >&2
            caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
            caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
            caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"; return 1
        }
    fi

    if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile; then
        echo -e "${gl_hong}导入配置校验失败，正在恢复导入前状态。${gl_bai}" >&2
        caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
        [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
        caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
        return 1
    fi
    if ! service_action reload caddy; then
        echo -e "${gl_hong}重载失败，正在恢复导入前状态。${gl_bai}" >&2
        caddy_restore_snapshot || echo '警告：Caddy 配置快照恢复失败。' >&2
        [[ -z $rollback_dir ]] || caddy_migration_restore_data "$rollback_dir" || echo '警告：证书数据恢复失败。' >&2
        service_action reload caddy || true
        caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
        return 1
    fi

    caddy_migration_cleanup "$tmp" "$staged_data" "$rollback_dir"
    echo -e "${gl_lv}迁移配置已导入并生效。请检查 DNS、端口、防火墙和证书状态。${gl_bai}"
    (( data_in_archive )) || echo '迁移包不含 ACME/证书数据，目标服务器现有证书数据已保留。'
}
