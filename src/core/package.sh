# ============ 包管理 ============

vps_pkg_manager() {
    local manager
    for manager in apt-get dnf yum apk pacman zypper; do
        if command -v "$manager" >/dev/null 2>&1; then printf '%s\n' "$manager"; return 0; fi
    done
    echo "未找到支持的包管理器" >&2; return 1
}

vps_pkg_name() {
    local manager="$1" package="$2"
    case "$manager:$package" in
        apt-get:docker) package=docker.io ;;
        apt-get:openssh) package=openssh-server ;;
        apk:iproute2) package=iproute2 ;;
        dnf:iproute2|yum:iproute2|zypper:iproute2) package=iproute ;;
        apk:dnsutils) package=bind-tools ;;
        dnf:dnsutils|yum:dnsutils|zypper:dnsutils) package=bind-utils ;;
        pacman:dnsutils) package=bind ;;
    esac
    printf '%s\n' "$package"
}

vps_pkg_installed() {
    local manager="$1" package="$2" state
    case "$manager" in
        apt-get)
            state=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) || return 1
            [[ "$state" == *" ok installed" ]]
            ;;
        dnf|yum|zypper) rpm -q "$package" >/dev/null 2>&1 ;;
        apk) apk info -e "$package" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$package" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

vps_pkg_args() {
    local manager="$1" package mapped
    shift
    [ "$#" -gt 0 ] || { echo "未提供软件包参数" >&2; return 1; }
    VPS_PACKAGES=()
    for package in "$@"; do
        [[ "$package" =~ ^[A-Za-z0-9][A-Za-z0-9+_.:@-]*$ ]] || {
            echo "软件包名称无效: $package" >&2; return 1;
        }
        mapped=$(vps_pkg_name "$manager" "$package") || return 1
        VPS_PACKAGES+=("$mapped")
    done
}

pkg_install() {
    [ "$(id -u)" -eq 0 ] || { echo "安装软件需要 root 权限" >&2; return 1; }
    local manager package
    local -a VPS_PACKAGES=() missing=()
    manager=$(vps_pkg_manager) || return 1
    vps_pkg_args "$manager" "$@" || return 1
    for package in "${VPS_PACKAGES[@]}"; do
        vps_pkg_installed "$manager" "$package" || missing+=("$package")
    done
    [ "${#missing[@]}" -gt 0 ] || { echo "所选软件包已安装"; return 0; }
    echo "正在安装: ${missing[*]}"
    case "$manager" in
        apt-get) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
        dnf|yum) "$manager" install -y "${missing[@]}" ;;
        apk) apk update && apk add "${missing[@]}" ;;
        pacman) pacman -S --needed --noconfirm "${missing[@]}" ;;
        zypper) zypper --non-interactive install "${missing[@]}" ;;
    esac
}

pkg_remove() {
    [ "$(id -u)" -eq 0 ] || { echo "卸载软件需要 root 权限" >&2; return 1; }
    local manager package
    local -a VPS_PACKAGES=() installed=()
    manager=$(vps_pkg_manager) || return 1
    vps_pkg_args "$manager" "$@" || return 1
    for package in "${VPS_PACKAGES[@]}"; do
        if vps_pkg_installed "$manager" "$package"; then installed+=("$package"); fi
    done
    [ "${#installed[@]}" -gt 0 ] || { echo "所选软件包未安装，无需卸载"; return 0; }
    echo "正在卸载: ${installed[*]}"
    case "$manager" in
        apt-get) DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed[@]}" ;;
        dnf|yum) "$manager" remove -y "${installed[@]}" ;;
        apk) apk del "${installed[@]}" ;;
        pacman) pacman -R --noconfirm "${installed[@]}" ;;
        zypper) zypper --non-interactive remove "${installed[@]}" ;;
    esac
}

