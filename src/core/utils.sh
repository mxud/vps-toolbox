# ============ 通用工具函数 ============

break_end() {
    echo "已返回；操作结果以上方输出为准。"
    echo "按任意键继续..."
    read -n 1 -s -r -p "" || return 0
    echo ""
    clear
}

root_use() {
    clear
    if [ "$EUID" -ne 0 ]; then
        echo -e "${gl_huang}提示: ${gl_bai}该功能需要 root 用户运行！"
        break_end
        return 1
    fi
    return 0
}

