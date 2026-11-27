# ============ Caddy 站点与反代管理 ============

caddy_add() {
    local mode=$1 domain upstream target port ip sni filename skip_tls="n"
    caddy_prepare || return 1
    read -r -e -p '站点域名（例如 app.example.com）: ' domain || return 1
    caddy_domain_ok "$domain" || { echo -e "${gl_hong}域名格式不正确${gl_bai}" >&2; return 1; }
    filename="$CADDY_SITES/${domain}.caddy"
    [[ ! -e $filename && ! -L $filename ]] || { echo -e "${gl_huang}此域名的配置文件已存在，不会覆盖（请使用编辑功能）${gl_bai}" >&2; return 1; }
    if [[ $mode == standard ]]; then
        read -r -e -p '目标地址（直接输入端口号如 3000 将自动转为 127.0.0.1:3000，或输入 http(s)://地址）: ' upstream || return 1
        if caddy_port_ok "$upstream"; then
            upstream="127.0.0.1:$((10#$upstream))"
            echo -e "已自动补全目标地址: ${gl_huang}${upstream}${gl_bai}"
        elif [[ $upstream =~ ^https?://[a-zA-Z0-9.:-]+$ || $upstream =~ ^[a-zA-Z0-9.:-]+$ ]]; then
            if [[ $upstream == https://* ]]; then
                read -r -e -p '后端是否为自签名 HTTPS 证书（忽略证书校验 tls_insecure_skip_verify）？[y/N]: ' skip_tls || return 1
            fi
        else
            echo -e "${gl_hong}地址格式不正确（暂不支持路径、IPv6 字面量）${gl_bai}" >&2
            return 1
        fi
    elif [[ $mode == redirect ]]; then
        read -r -e -p '跳转目标域名（例如 example.com，不含 https://）: ' target || return 1
        caddy_domain_ok "$target" || { echo -e "${gl_hong}目标域名格式不正确${gl_bai}" >&2; return 1; }
    else
        read -r -e -p '源站 IPv4: ' ip || return 1
        caddy_ipv4_ok "$ip" || { echo -e "${gl_hong}IPv4 格式不正确${gl_bai}" >&2; return 1; }
        read -r -e -p '源站 HTTPS 端口 [443]: ' port || return 1
        port=${port:-443}
        caddy_port_ok "$port" || { echo -e "${gl_hong}端口不正确${gl_bai}" >&2; return 1; }
        read -r -e -p '源站证书域名 / SNI（必须与证书匹配）: ' sni || return 1
        caddy_domain_ok "$sni" || { echo -e "${gl_hong}SNI 域名格式不正确${gl_bai}" >&2; return 1; }
    fi
    caddy_snapshot || return 1
    if [[ $mode == standard ]]; then
        if [[ $skip_tls =~ ^[Yy]$ ]]; then
            cat > "$filename" <<EOC
$domain {
    encode zstd gzip
    reverse_proxy $upstream {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOC
        else
            printf '%s {\n    encode zstd gzip\n    reverse_proxy %s\n}\n' "$domain" "$upstream" > "$filename"
        fi
    elif [[ $mode == redirect ]]; then
        printf '%s {\n    redir https://%s{uri} permanent\n}\n' "$domain" "$target" > "$filename"
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
    if caddy_apply; then
        caddy_ensure_firewall_ports
    else
        return 1
    fi
}

caddy_edit() {
    caddy_prepare || return 1
    local editor="" rc=0
    caddy_select_site "请输入要编辑的站点序号或域名 (0 返回): " || rc=$?
    [ "$rc" -eq 0 ] || return 0
    if [ -n "${EDITOR:-}" ] && command -v "$EDITOR" >/dev/null 2>&1; then
        editor="$EDITOR"
    elif command -v nano >/dev/null 2>&1; then
        editor="nano"
    elif command -v vim >/dev/null 2>&1; then
        editor="vim"
    elif command -v vi >/dev/null 2>&1; then
        editor="vi"
    else
        echo -e "${gl_hong}未找到可用编辑器 (nano/vim/vi)，请先安装编辑器${gl_bai}" >&2
        return 1
    fi
    caddy_snapshot || return 1
    "$editor" "$CADDY_SELECTED_FILE" || {
        echo -e "${gl_huang}编辑取消或失败，已保留原配置${gl_bai}"
        caddy_restore_snapshot
        return 1
    }
    caddy fmt --overwrite "$CADDY_SELECTED_FILE" 2>/dev/null || true
    caddy_apply
}

caddy_delete() {
    caddy_prepare || return 1
    local answer rc=0
    caddy_select_site "请输入要删除的站点序号或域名 (0 返回): " || rc=$?
    [ "$rc" -eq 0 ] || return 0
    read -r -p "确认删除 ${CADDY_SELECTED_DOMAIN}？输入 DELETE: " answer || return 1
    [[ $answer == DELETE ]] || { echo '已取消'; return 0; }
    caddy_snapshot && rm -- "$CADDY_SELECTED_FILE" && caddy_apply
}

caddy_add_menu() {
    local choice
    while true; do
        clear
        echo -e "${gl_kjlan}================== 添加站点 / 反向代理 ==================${gl_bai}"
        echo -e "${gl_kjlan}1.${gl_bai} 标准反代 (支持直接填端口号，或 HTTP/HTTPS 地址)"
        echo -e "${gl_kjlan}2.${gl_bai} HTTPS 指定源站 IP (自定义 SNI / Host)"
        echo -e "${gl_kjlan}3.${gl_bai} 301 永久重定向 (例如 www -> 主域名)"
        echo -e "${gl_kjlan}---------------------------------------------------------${gl_bai}"
        echo -e "${gl_kjlan}0.${gl_bai} 返回上一级"
        echo -e "${gl_kjlan}---------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) caddy_add standard; break_end; return 0 ;;
            2) caddy_add realip; break_end; return 0 ;;
            3) caddy_add redirect; break_end; return 0 ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
