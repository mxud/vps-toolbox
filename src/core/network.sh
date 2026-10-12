# ============ 网络工具 ============

vps_valid_port() {
    [[ "${1:-}" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

vps_valid_hostname() {
    local value="${1:-}" label
    local -a labels=()
    [ "${#value}" -le 253 ] && [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$ ]] || return 1
    IFS=. read -r -a labels <<< "$value"
    for label in "${labels[@]}"; do
        [ "${#label}" -le 63 ] && [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

vps_set_hostname() {
    local new_name="${1:-}" old_name backup candidate
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    vps_valid_hostname "$new_name" || { echo "主机名格式无效" >&2; return 1; }
    [ ! -L /etc/hosts ] && [ ! -L /etc/hostname ] || { echo "拒绝覆盖主机配置的符号链接" >&2; return 1; }
    old_name=$(hostname) || return 1
    backup=$(mktemp -d /etc/.vps-hostname.XXXXXX) || return 1
    cp -p -- /etc/hosts "$backup/hosts" || { rmdir "$backup"; return 1; }
    if [ -e /etc/hostname ]; then
        cp -p -- /etc/hostname "$backup/hostname" || { rm -f -- "$backup/hosts"; rmdir "$backup"; return 1; }
    fi
    candidate="$backup/hosts.new"
    if awk -v name="$new_name" '
        $1=="127.0.1.1" {$2=name; found=1}
        {print}
        END {if(!found)print "127.0.1.1\t" name}' /etc/hosts > "$candidate" &&
       cp -- "$candidate" /etc/hosts && printf '%s\n' "$new_name" > /etc/hostname; then
        if [ -d /run/systemd/system ] && command -v hostnamectl >/dev/null 2>&1; then
            hostnamectl set-hostname "$new_name"
        else
            hostname "$new_name"
        fi
        if [ "$?" -eq 0 ]; then
            rm -f -- "$backup/hosts" "$backup/hostname" "$candidate"
            rmdir "$backup"
            echo "主机名已修改为: $new_name"
            return 0
        fi
    fi
    if cp -p -- "$backup/hosts" /etc/hosts &&
       { if [ -e "$backup/hostname" ]; then cp -p -- "$backup/hostname" /etc/hostname; else rm -f -- /etc/hostname; fi; } &&
       { if [ -d /run/systemd/system ] && command -v hostnamectl >/dev/null 2>&1; then hostnamectl set-hostname "$old_name"; else hostname "$old_name"; fi; }; then
        rm -f -- "$backup/hosts" "$backup/hostname" "$candidate"
        rmdir "$backup"
        echo "修改主机名失败，已恢复原配置" >&2
    else
        echo "修改主机名失败且自动恢复未完成；备份目录: $backup" >&2
    fi
    return 1
}

vps_set_ip_preference() {
    local mode="$1" config=/etc/gai.conf candidate backup
    [ "$(id -u)" -eq 0 ] || return 1
    [[ "$mode" == 4 || "$mode" == default ]] || return 1
    [ ! -L "$config" ] || { echo "拒绝覆盖 gai.conf 符号链接" >&2; return 1; }
    candidate=$(mktemp /etc/.gai.vps.XXXXXX) || return 1
    # 只管理带有工具箱标记的配置，保留管理员原有优先级设置。
    if [ -f "$config" ]; then
        if ! sed '/^# VPS Toolbox IPv4 priority$/d; /[[:space:]]# VPS Toolbox IPv4 priority$/d' "$config" > "$candidate"; then
            rm -f -- "$candidate"; return 1
        fi
        backup=$(mktemp /etc/gai.conf.vps-backup.XXXXXX) || { rm -f -- "$candidate"; return 1; }
        cp -p -- "$config" "$backup" || { rm -f -- "$candidate" "$backup"; return 1; }
    fi
    if [ "$mode" = 4 ]; then
        printf '\nprecedence ::ffff:0:0/96  100 # VPS Toolbox IPv4 priority\n' >> "$candidate" || { rm -f -- "$candidate"; return 1; }
    fi
    chmod 644 "$candidate" && mv -f -- "$candidate" "$config" || { rm -f -- "$candidate"; return 1; }
    echo "地址优先级配置已更新${backup:+；备份: $backup}。管理员原有配置保持不变。"
    [ "$mode" != default ] || echo "已移除工具箱设置；如仍优先 IPv4，请检查原有 precedence 配置。"
}

ip_address() {
    local isp_info
    isp_info=$(curl -fsS --max-time 3 https://ipinfo.io/org 2>/dev/null || echo "")

    if echo "$isp_info" | grep -Eiq 'CHINANET|mobile|unicom|telecom'; then
        ipv4_address=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[^ ]+' || \
                       hostname -I 2>/dev/null | awk '{print $1}')
    else
        ipv4_address=$(curl -s --max-time 3 https://ipinfo.io/ip 2>/dev/null)
    fi

    ipv6_address=$(curl -s --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null)
}

