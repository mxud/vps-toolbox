check_swap() {
    local swap_total
    swap_total=$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${swap_total:-0}" -eq 0 ]; then
        echo "提示：系统未启用 swap，测试可能因内存不足而失败。" >&2
    fi
}

add_swap() {
    local new_swap="${1:-}" swap_file old_file created=0
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    [[ "$new_swap" =~ ^[0-9]{1,5}$ ]] || {
        echo "swap 大小请输入 128 至 32768 MB 的整数" >&2
        return 1
    }
    new_swap=$((10#$new_swap))
    ((new_swap >= 128 && new_swap <= 32768)) || {
        echo "swap 大小请输入 128 至 32768 MB 的整数" >&2
        return 1
    }
    swap_file="/swapfile-vps-${new_swap}m"
    [ ! -L "$swap_file" ] && { [ ! -e "$swap_file" ] || [ -f "$swap_file" ]; } || {
        echo "swap 路径必须是普通文件，拒绝使用符号链接或设备" >&2; return 1;
    }
    if [ ! -e "$swap_file" ]; then
        (umask 077; fallocate -l "${new_swap}M" "$swap_file" 2>/dev/null || dd if=/dev/zero of="$swap_file" bs=1M count="$new_swap") || { rm -f -- "$swap_file"; return 1; }
        created=1
        chmod 600 "$swap_file" && mkswap "$swap_file" >/dev/null || {
            rm -f -- "$swap_file"
            return 1
        }
    fi
    if ! awk 'NR > 1 {print $1}' /proc/swaps | grep -Fxq -- "$swap_file"; then
        swapon "$swap_file" || { [ "$created" -eq 0 ] || rm -f -- "$swap_file"; return 1; }
    fi
    while IFS= read -r old_file; do
        [[ "$old_file" =~ ^/swapfile-vps-[0-9]+m$ ]] || continue
        [ "$old_file" = "$swap_file" ] && continue
        if swapoff "$old_file"; then
            sed -i "\\|^${old_file}[[:space:]]|d" /etc/fstab || return 1
            rm -f -- "$old_file"
        else
            echo "旧 swap $old_file 仍在使用，已保留" >&2
        fi
    done < <(awk 'NR > 1 {print $1}' /proc/swaps)
    sed -i "\\|^${swap_file}[[:space:]]|d" /etc/fstab || return 1
    printf '%s swap swap defaults 0 0\n' "$swap_file" >> /etc/fstab || return 1
    echo -e "已启用 ${gl_huang}${new_swap}M${gl_bai} 工具箱 swap；其他 swap 保持不变。"
}

server_reboot() {
    read -r -e -p "$(echo -e "${gl_huang}提示: ${gl_bai}现在重启服务器吗？(Y/N): ")" choice || return 0
    case "$choice" in
        [Yy]) echo "重启中..." ; reboot ;;
        *) echo "已取消" ;;
    esac
}

