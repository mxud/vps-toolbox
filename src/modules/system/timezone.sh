set_timedate() {
    local tz="${1:-}"
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    [[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ ]] && [[ "$tz" != /* && "$tz" != *//* ]] || {
        echo "无效的时区: $tz" >&2
        return 1
    }
    [ -f "/usr/share/zoneinfo/$tz" ] || pkg_install tzdata || return 1
    [ -f "/usr/share/zoneinfo/$tz" ] || { echo "找不到时区: $tz" >&2; return 1; }
    if [ -f /etc/alpine-release ]; then
        [ ! -L /etc/timezone ] || { echo "拒绝覆盖 timezone 符号链接" >&2; return 1; }
        ln -sfnT "/usr/share/zoneinfo/$tz" /etc/localtime || return 1
        printf '%s\n' "$tz" > /etc/timezone || return 1
    else
        timedatectl set-timezone "$tz" || return 1
    fi
    echo -e "${gl_lv}时区已设置为: $tz${gl_bai}"
}

timezone_menu() {
    root_use || return
    while true; do
        clear
        echo "当前时区: $(current_timezone)"
        echo "当前时间: $(date +"%Y-%m-%d %H:%M:%S")"
        echo "------------------------"
        echo "1. 上海        2. 香港        3. 东京"
        echo "4. 新加坡      5. 伦敦        6. 纽约"
        echo "7. 洛杉矶      8. UTC"
        echo "0. 返回"
        echo "------------------------"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1) set_timedate Asia/Shanghai ;;
            2) set_timedate Asia/Hong_Kong ;;
            3) set_timedate Asia/Tokyo ;;
            4) set_timedate Asia/Singapore ;;
            5) set_timedate Europe/London ;;
            6) set_timedate America/New_York ;;
            7) set_timedate America/Los_Angeles ;;
            8) set_timedate UTC ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
        break_end
    done
}

# ============ 一键重装系统 ============

