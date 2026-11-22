# ============ 磁盘与负载排查 ============

vps_diag_disk_overview() {
    echo -e "${gl_kjlan}=== 磁盘分区使用率 ===${gl_bai}"
    df -PhT 2>/dev/null || df -Ph
    echo ""
    echo -e "${gl_kjlan}=== Inode 使用率 ===${gl_bai}"
    df -Phi 2>/dev/null || df -i
}

vps_diag_disk_top() {
    local target="${1:-/}"
    if [ ! -d "$target" ]; then
        echo "目录不存在: $target" >&2
        return 1
    fi
    echo -e "${gl_kjlan}=== 占用空间 Top 15 (${target}，不跨文件系统) ===${gl_bai}"
    du -xh --max-depth=2 "$target" 2>/dev/null | sort -hr | head -n 15
}

vps_diag_cpu_top() {
    echo -e "${gl_kjlan}=== CPU 占用 Top 10 进程 ===${gl_bai}"
    ps -eo pid,ppid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 11 ||
        ps aux 2>/dev/null | sort -k3 -rn | head -n 11
}

vps_diag_mem_top() {
    echo -e "${gl_kjlan}=== 内存占用 Top 10 进程 ===${gl_bai}"
    ps -eo pid,ppid,user,%mem,%cpu,rss,comm --sort=-%mem 2>/dev/null | head -n 11 ||
        ps aux 2>/dev/null | sort -k4 -rn | head -n 11
}

vps_diag_quick() {
    vps_diag_disk_overview
    echo ""
    vps_diag_cpu_top
    echo ""
    vps_diag_mem_top
}

vps_diag_menu() {
    local choice scan_dir
    if [ "${1:-}" = "--quick" ] || [ "${1:-}" = "-q" ]; then
        vps_diag_quick
        return 0
    fi
    while true; do
        clear
        echo -e "${gl_kjlan}================== 磁盘与负载排查 ==================${gl_bai}"
        echo "1. 磁盘分区与 Inode 使用率总览"
        echo "2. 扫描大目录 Top 15 (默认 /，支持自定义路径)"
        echo "3. CPU 占用 Top 10 进程"
        echo "4. 内存占用 Top 10 进程"
        echo "5. 一键综合排查 (磁盘 + CPU + 内存)"
        echo -e "${gl_kjlan}----------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}----------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) clear; vps_diag_disk_overview; break_end ;;
            2)
                read -r -e -p "请输入要扫描的目录 [默认 /]: " scan_dir || return 0
                clear
                vps_diag_disk_top "${scan_dir:-/}"
                break_end
                ;;
            3) clear; vps_diag_cpu_top; break_end ;;
            4) clear; vps_diag_mem_top; break_end ;;
            5) clear; vps_diag_quick; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}
