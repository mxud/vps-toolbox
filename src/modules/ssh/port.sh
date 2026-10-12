# ============ SSH 端口修改 ============

change_ssh_port() {
    root_use || return
    local new_port current_port config=/etc/ssh/sshd_config backup candidate sshd_bin

    sshd_bin=$(command -v sshd || true)
    [ -n "$sshd_bin" ] || sshd_bin=/usr/sbin/sshd
    [ -f "$config" ] && [ ! -L "$config" ] && [ -x "$sshd_bin" ] || {
        echo "未找到 SSH 服务配置或 sshd，未做修改" >&2
        return 1
    }
    command -v ss >/dev/null 2>&1 || pkg_install iproute2 || return 1

    while true; do
        clear
        current_port=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
        echo -e "当前 SSH 端口: ${gl_huang}${current_port:-22}${gl_bai}"
        echo "端口范围: 1-65535（输入 0 退出）"
        read -r -e -p "请输入新的 SSH 端口: " new_port || return 0

        if [ "$new_port" = "0" ]; then
            break
        fi

        if vps_valid_port "$new_port"; then
            new_port=$((10#$new_port))
            if [ "$new_port" = "$current_port" ]; then echo "当前已使用该端口"; break_end; return 0; fi
            if ss -H -ltn | awk -v port="$new_port" '{n=split($4,a,":"); if(a[n]==port)found=1} END {exit !found}'; then
                echo "端口 $new_port 已被监听，请选择其他端口" >&2
                break_end
                continue
            fi
            if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status | grep -q '^Status: active'; then
                ufw allow "$new_port/tcp" || { echo "放行新端口失败，未修改 SSH" >&2; return 1; }
            fi
            if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
                firewall-cmd --add-port="$new_port/tcp" && firewall-cmd --permanent --add-port="$new_port/tcp" || {
                    echo "放行新端口失败，未修改 SSH" >&2; return 1;
                }
            fi
            backup=$(mktemp /etc/ssh/sshd_config.vps-backup.XXXXXX) || return 1
            cp -p -- "$config" "$backup" || { rm -f -- "$backup"; return 1; }
            candidate=$(mktemp /etc/ssh/.sshd-port.vps.XXXXXX) || { rm -f -- "$backup"; return 1; }
            if ! { printf 'Port %s\n' "$new_port"; sed '/^[[:space:]]*Port[[:space:]]\+[0-9]\+/d' "$config"; } > "$candidate" ||
               ! "$sshd_bin" -t -f "$candidate"; then
                rm -f -- "$candidate"
                echo "新 SSH 配置校验失败，未替换原配置；备份: $backup" >&2
                return 1
            fi
            if ! chown root:root "$candidate" || ! chmod 600 "$candidate" || ! mv -f -- "$candidate" "$config"; then
                rm -f -- "$candidate"
                echo "替换 SSH 配置失败；备份: $backup" >&2
                return 1
            fi
            if ! vps_ssh_reload; then
                if cp -p -- "$backup" "$config" && vps_ssh_reload; then
                    echo "SSH 重载失败，原配置已恢复；备份: $backup" >&2
                else
                    echo "SSH 自动恢复未完成，请通过控制台检查；备份: $backup" >&2
                fi
                return 1
            fi
            if ! ss -H -ltn | awk -v port="$new_port" '{n=split($4,a,":"); if(a[n]==port)found=1} END {exit !found}'; then
                if cp -p -- "$backup" "$config" && vps_ssh_reload; then
                    echo "新端口未监听，已恢复原配置；备份: $backup" >&2
                else
                    echo "新端口未监听且自动恢复未完成；备份: $backup" >&2
                fi
                return 1
            fi
            echo -e "${gl_lv}SSH 已在端口 $new_port 监听${gl_bai}；备份: $backup"
            echo "请确认云服务商安全组/防火墙已放行新端口，并在断开当前连接前新建连接测试。"
            echo "已保留 sshd_config.d 中的配置；其中的 Port 设置也可能继续生效。"
            break_end
            break
        else
            echo "端口无效"
            break_end
        fi
    done
}

