# ============ 系统更新与清理 ============

fix_dpkg() {
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a
}

linux_update() {
    [ "$(id -u)" -eq 0 ] || { echo "系统更新需要 root 权限" >&2; return 1; }
    echo -e "${gl_kjlan}正在系统更新...${gl_bai}"
    if command -v apt-get &>/dev/null; then
        fix_dpkg || return 1
        DEBIAN_FRONTEND=noninteractive apt-get update &&
            DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    elif command -v dnf &>/dev/null; then
        dnf -y update
    elif command -v yum &>/dev/null; then
        yum -y update
    elif command -v apk &>/dev/null; then
        apk update && apk upgrade
    elif command -v pacman &>/dev/null; then
        pacman -Syu --noconfirm
    elif command -v zypper &>/dev/null; then
        zypper refresh && zypper update -y
    else
        echo "未知的包管理器!" >&2
        return 1
    fi
}

linux_clean() {
    [ "$(id -u)" -eq 0 ] || { echo "系统清理需要 root 权限" >&2; return 1; }
    echo -e "${gl_kjlan}正在系统清理...${gl_bai}"
    if command -v apt-get &>/dev/null; then
        fix_dpkg || return 1
        apt-get autoremove --purge -y && apt-get clean && apt-get autoclean || return 1
        local rc_pkgs
        rc_pkgs=$(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')
        if [ -n "$rc_pkgs" ]; then
            echo -e "${gl_kjlan}正在清理已卸载软件的残留配置文件...${gl_bai}"
            apt-get purge -y $rc_pkgs >/dev/null 2>&1 || dpkg --purge $rc_pkgs >/dev/null 2>&1 || return 1
        fi
    elif command -v dnf &>/dev/null; then
        dnf autoremove -y && dnf clean all || return 1
    elif command -v yum &>/dev/null; then
        yum autoremove -y && yum clean all || return 1
    elif command -v apk &>/dev/null; then
        apk cache clean || return 1
    elif command -v pacman &>/dev/null; then
        local -a orphan_pkgs=()
        mapfile -t orphan_pkgs < <(pacman -Qdtq 2>/dev/null)
        if [ "${#orphan_pkgs[@]}" -gt 0 ]; then pacman -Rns --noconfirm "${orphan_pkgs[@]}" || return 1; fi
        pacman -Scc --noconfirm || return 1
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive clean --all || return 1
    else
        echo "未知的包管理器，未执行清理" >&2; return 1
    fi

    # 通用清理
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        journalctl --vacuum-time=7d && journalctl --vacuum-size=100M || return 1
    fi
    echo -e "${gl_lv}清理完成${gl_bai}"
}

