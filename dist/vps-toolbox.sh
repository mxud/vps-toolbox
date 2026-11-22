#!/bin/bash
# ============================================================
# VPS Toolbox
# SPDX-License-Identifier: Apache-2.0
# ============================================================

sh_v="0.2.1"

# ============ 颜色定义 ============
gl_hui='\e[37m'
gl_hong='\033[31m'
gl_lv='\033[32m'
gl_huang='\033[33m'
gl_lan='\033[34m'
gl_bai='\033[0m'
gl_zi='\033[35m'
gl_kjlan='\033[96m'

# ============ 基础配置 ============
VPS_INSTALL_PATH="/usr/local/bin/vps-toolbox"
VPS_DEFAULT_SHORTCUT="vps"
gh_proxy="${VPS_GITHUB_PROXY:-https://}"
VPS_UPDATE_URL="${VPS_UPDATE_URL:-}"
# Installer writes a repository identifier to allow `vps upgrade` without
# requiring an environment variable on every run. Can be overridden explicitly.
if [ -z "$VPS_UPDATE_URL" ] && [ -r /etc/vps-toolbox.repo ]; then
    IFS= read -r vps_repo < /etc/vps-toolbox.repo || true
    if [[ "$vps_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        VPS_UPDATE_URL="${gh_proxy}raw.githubusercontent.com/${vps_repo}/main/dist/vps-toolbox.sh"
    fi
fi


# ---- BEGIN core/remote.sh ----
run_remote_bash() {
    local url="$1" script_file result
    shift
    command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates || return 1
    script_file=$(mktemp /tmp/vps-remote.XXXXXX) || return 1
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 -o "$script_file" "$url" \
       && [ -s "$script_file" ] && bash -n "$script_file"; then
        bash "$script_file" "$@"
        result=$?
    else
        echo "下载或校验远程脚本失败: $url" >&2
        result=1
    fi
    rm -f -- "$script_file"
    return "$result"
}


# ---- END core/remote.sh ----

# ---- BEGIN core/self_install.sh ----
# ============ 自动安装到系统 ============
vps_is_toolbox() {
    [ -f "$1" ] && [ ! -L "$1" ] && grep -qx '# VPS Toolbox' "$1" && bash -n "$1"
}

# 临时文件与目标位于同一目录，最后通过 rename 原子替换。
vps_atomic_install() {
    local source="$1" target="$2" staged backup_stage directory
    directory=$(dirname -- "$target")
    command -v install >/dev/null 2>&1 || pkg_install coreutils || return 1
    [ ! -L "$target" ] && [ ! -L "${target}.bak" ] || {
        echo "拒绝覆盖安装文件或备份的符号链接" >&2; return 1;
    }
    if [ -e "$target" ]; then
        vps_is_toolbox "$target" || { echo "安装路径已有其他文件: $target" >&2; return 1; }
    fi
    staged=$(mktemp "$directory/.vps-install.XXXXXX") || return 1
    if ! command install -m 755 "$source" "$staged" || ! vps_is_toolbox "$staged"; then
        rm -f -- "$staged"; return 1
    fi
    if [ -e "$target" ]; then
        backup_stage=$(mktemp "$directory/.vps-backup.XXXXXX") || { rm -f -- "$staged"; return 1; }
        if ! cp -p -- "$target" "$backup_stage" || ! mv -fT -- "$backup_stage" "${target}.bak"; then
            rm -f -- "$staged" "$backup_stage"; return 1
        fi
    fi
    mv -fT -- "$staged" "$target" || { rm -f -- "$staged"; return 1; }
}

vps_ensure_install() {
    local source="$1" source_ver installed_ver source_value installed_value
    if [ -e "$VPS_INSTALL_PATH" ] || [ -L "$VPS_INSTALL_PATH" ]; then
        vps_is_toolbox "$VPS_INSTALL_PATH" || {
            echo "安装路径不是有效的工具箱脚本: $VPS_INSTALL_PATH" >&2; return 1;
        }
        source_ver=$(grep '^sh_v=' "$source" | head -1 | cut -d'"' -f2)
        installed_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2)
        source_value=$(vps_version_value "$source_ver") && installed_value=$(vps_version_value "$installed_ver") || {
            echo "脚本版本号无效，未替换已安装脚本" >&2; return 1;
        }
        if [ "$source_value" -gt "$installed_value" ]; then
            vps_atomic_install "$source" "$VPS_INSTALL_PATH" || return 1
            echo "安装版本已升级到 v$source_ver；备份: ${VPS_INSTALL_PATH}.bak"
        fi
        return 0
    fi
    vps_atomic_install "$source" "$VPS_INSTALL_PATH"
}

vps_self_install() {
    [ "$(id -u)" -eq 0 ] || return 0
    local source_path shortcut_path="$(dirname -- "$VPS_INSTALL_PATH")/$VPS_DEFAULT_SHORTCUT"
    source_path="$(readlink -f "${BASH_SOURCE[0]}")"
    [ -f "$source_path" ] || return 0
    if { [ -e "$shortcut_path" ] || [ -L "$shortcut_path" ]; } &&
       [ "$(readlink -f "$shortcut_path")" != "$VPS_INSTALL_PATH" ]; then
        echo "快捷键 $shortcut_path 已被其他程序使用，请手动选择名称" >&2
        return 1
    fi
    vps_ensure_install "$source_path" || return 1
    [ "$shortcut_path" = "$VPS_INSTALL_PATH" ] || ln -sfnT "$VPS_INSTALL_PATH" "$shortcut_path"
}

vps_uninstall() {
    clear
    echo -e "${gl_hong}卸载 VPS 工具箱${gl_bai}"
    echo "------------------------"
    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 权限才能卸载" >&2
        break_end
        return 1
    fi
    echo "将移除工具箱本体、备份、快捷软链及更新源记录："
    echo "  - $VPS_INSTALL_PATH"
    echo "  - ${VPS_INSTALL_PATH}.bak（如存在）"
    echo "  - $(dirname -- "$VPS_INSTALL_PATH") 下指向工具箱的所有快捷软链"
    echo "  - /etc/vps-toolbox.repo（如存在）"
    echo "已安装的第三方服务与系统配置（Docker/Caddy/Tailscale/SSH/BBR 等）不会被删除。"
    echo "------------------------"
    local confirm install_dir link removed_links=0
    read -r -p "输入 UNINSTALL 确认卸载: " confirm || return 0
    if [ "$confirm" != UNINSTALL ]; then
        echo "已取消卸载"
        break_end
        return 0
    fi

    install_dir=$(dirname -- "$VPS_INSTALL_PATH")
    shopt -s nullglob
    for link in "$install_dir"/*; do
        if [ -L "$link" ] && [ "$(readlink "$link" 2>/dev/null || true)" = "$VPS_INSTALL_PATH" ]; then
            rm -f -- "$link" && removed_links=$((removed_links + 1))
        fi
    done
    shopt -u nullglob

    if [ -f "${VPS_INSTALL_PATH}.bak" ] && [ ! -L "${VPS_INSTALL_PATH}.bak" ]; then
        rm -f -- "${VPS_INSTALL_PATH}.bak"
    fi
    if [ -f /etc/vps-toolbox.repo ] && [ ! -L /etc/vps-toolbox.repo ]; then
        rm -f -- /etc/vps-toolbox.repo
    fi
    if [ -f "$VPS_INSTALL_PATH" ] && [ ! -L "$VPS_INSTALL_PATH" ]; then
        rm -f -- "$VPS_INSTALL_PATH"
    fi

    echo -e "${gl_lv}VPS 工具箱已卸载干净${gl_bai}（共移除 ${removed_links} 个快捷软链）。"
    exit 0
}


# ---- END core/self_install.sh ----

# ---- BEGIN core/utils.sh ----
# ============ 通用工具函数 ============

break_end() {
    echo "已返回；操作结果以上方输出为准。"
    echo "按任意键继续..."
    read -n 1 -s -r -p "" || true
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


# ---- END core/utils.sh ----

# ---- BEGIN core/package.sh ----
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


# ---- END core/package.sh ----

# ---- BEGIN core/service.sh ----
# ============ 服务管理 ============

service_action() {
    local action="${1:-}" service_name="${2:-}"
    [[ "$action" =~ ^(start|stop|restart|reload|status)$ ]] && [[ "$service_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]] || {
        echo "请提供操作和有效服务名" >&2; return 1
    }
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        command systemctl "$action" "$service_name"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "$service_name" "$action"
    elif command -v service >/dev/null 2>&1; then
        command service "$service_name" "$action"
    else
        echo "未找到可用的服务管理器" >&2; return 1
    fi
}

vps_ssh_reload() {
    if [ -d /run/systemd/system ]; then
        if command systemctl is-active --quiet ssh.socket || command systemctl is-active --quiet sshd.socket; then
            echo "检测到 SSH socket 激活，请先手动配置 socket 监听端口；未重载服务。" >&2
            return 1
        fi
    fi
    service_action reload sshd || service_action reload ssh
}

restart() { if service_action restart "${1:-}"; then echo "$1 已重启"; else echo "重启 ${1:-} 失败" >&2; return 1; fi; }
start()   { if service_action start "${1:-}"; then echo "$1 已启动"; else echo "启动 ${1:-} 失败" >&2; return 1; fi; }
stop()    { if service_action stop "${1:-}"; then echo "$1 已停止"; else echo "停止 ${1:-} 失败" >&2; return 1; fi; }
status()  { service_action status "${1:-}"; }

enable() {
    local service_name="${1:-}"
    [[ "$service_name" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@:-]*$ ]] || { echo "服务名无效" >&2; return 1; }
    if [ -d /run/systemd/system ]; then
        command systemctl enable "$service_name" || return 1
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update add "$service_name" default || return 1
    else
        echo "该系统不支持自动配置服务自启" >&2; return 1
    fi
    echo "$service_name 已设置为开机自启"
}


# ---- END core/service.sh ----

# ---- BEGIN core/network.sh ----
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
    # 外部获取，移除容易取到 NAT 内部 IP 的路由判断
    local v4 v6
    v4=$(curl -fsS --proto '=https' --proto-redir '=https' --max-time 2 https://ipv4.ip.sb 2>/dev/null ||
         curl -fsS --proto '=https' --proto-redir '=https' --max-time 2 https://ipinfo.io/ip 2>/dev/null || true)
    v6=$(curl -fsS --proto '=https' --proto-redir '=https' --max-time 2 https://v6.ipinfo.io/ip 2>/dev/null || true)
    v4=$(printf '%s' "$v4" | tr -d '[:space:]')
    v6=$(printf '%s' "$v6" | tr -d '[:space:]')
    [[ "$v4" =~ ^[0-9.]+$ ]] && ipv4_address="$v4" || ipv4_address=""
    [[ "$v6" =~ ^[0-9A-Fa-f:.]+$ ]] && ipv6_address="$v6" || ipv6_address=""
}


# ---- END core/network.sh ----

# ---- BEGIN modules/system/swap.sh ----
check_swap() {
    local swap_total
    swap_total=$(awk '/SwapTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
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


# ---- END modules/system/swap.sh ----

# ---- BEGIN modules/docker/docker.sh ----
# ============ Docker 相关 ============

vps_docker_packages() {
    local manager="$1" package
    VPS_DOCKER_PACKAGES=()
    for package in docker docker.io docker-engine docker-compose docker-compose-v2 docker-compose-plugin \
                   docker-buildx docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras containerd.io; do
        if vps_pkg_installed "$manager" "$package"; then VPS_DOCKER_PACKAGES+=("$package"); fi
    done
}

update_docker() {
    local manager
    local -a VPS_DOCKER_PACKAGES=()
    manager=$(vps_pkg_manager) || return 1
    vps_docker_packages "$manager"
    [ "${#VPS_DOCKER_PACKAGES[@]}" -gt 0 ] || {
        echo "Docker 未由当前包管理器安装，请使用原安装方式更新" >&2; return 1;
    }
    echo "正在更新: ${VPS_DOCKER_PACKAGES[*]}"
    case "$manager" in
        apt-get) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --only-upgrade -y "${VPS_DOCKER_PACKAGES[@]}" ;;
        dnf|yum) "$manager" upgrade -y "${VPS_DOCKER_PACKAGES[@]}" ;;
        apk) apk update && apk upgrade "${VPS_DOCKER_PACKAGES[@]}" ;;
        pacman)
            echo "Arch 请通过系统更新执行完整升级，避免 Docker 局部升级造成依赖不一致" >&2
            return 1 ;;
        zypper) zypper --non-interactive update "${VPS_DOCKER_PACKAGES[@]}" ;;
    esac || return 1
    docker --version
}

remove_docker() {
    local manager
    local -a VPS_DOCKER_PACKAGES=()
    manager=$(vps_pkg_manager) || return 1
    vps_docker_packages "$manager"
    [ "${#VPS_DOCKER_PACKAGES[@]}" -gt 0 ] || {
        echo "未找到由当前包管理器安装的 Docker 组件" >&2; return 1;
    }
    pkg_remove "${VPS_DOCKER_PACKAGES[@]}"
}

install_docker() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    if command -v docker >/dev/null 2>&1; then
        update_docker
        return $?
    fi
    if ! command -v docker &>/dev/null; then
        echo -e "${gl_kjlan}正在安装 Docker...${gl_bai}"
        local country
        country=$(curl -fsS --max-time 3 https://ipinfo.io/country 2>/dev/null || echo "")

        if command -v apt-get &>/dev/null || command -v yum &>/dev/null || command -v dnf &>/dev/null; then
            if [ "$country" = "CN" ]; then
                run_remote_bash "https://linuxmirrors.cn/docker.sh" \
                    --source mirrors.huaweicloud.com/docker-ce \
                    --source-registry docker.1ms.run \
                    --protocol https \
                    --install-latest true \
                    --close-firewall false \
                    --ignore-backup-tips || return 1
            else
                run_remote_bash "https://get.docker.com" || return 1
            fi
        else
            pkg_install docker docker-compose || return 1
        fi

        command -v docker >/dev/null 2>&1 || return 1
        enable docker || return 1
        start docker || return 1
        sleep 2
    fi
}

docker_status_overview() {
    if command -v docker &>/dev/null; then
        local containers images networks volumes
        containers=$(docker ps -a -q 2>/dev/null | wc -l)
        images=$(docker images -q 2>/dev/null | wc -l)
        networks=$(docker network ls -q 2>/dev/null | wc -l)
        volumes=$(docker volume ls -q 2>/dev/null | wc -l)
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo -e "${gl_lv}已安装${gl_bai}  容器: ${gl_lv}$containers${gl_bai}  镜像: ${gl_lv}$images${gl_bai}  网络: ${gl_lv}$networks${gl_bai}  卷: ${gl_lv}$volumes${gl_bai}"
    fi
}

docker_container_menu() {
    while true; do
        clear
        echo "Docker 容器管理"
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "1. 启动容器    2. 停止容器    3. 删除容器    4. 重启容器"
        echo "5. 进入容器    6. 查看日志    7. 查看占用    8. 拉取最新镜像"
        echo "0. 返回"
        echo "------------------------"
        read -r -e -p "请输入你的选择: " choice || return 0
        case $choice in
            1) read -r -e -p "容器名: " name || return 0; [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && docker start "$name" ;;
            2) read -r -e -p "容器名: " name || return 0; [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && docker stop "$name" ;;
            3)
                read -r -e -p "要删除的容器名: " name || return 0
                [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "容器名称无效" >&2; continue; }
                read -r -e -p "确认删除容器 $name？(Y/N): " confirm || return 0
                [[ "$confirm" =~ ^[Yy]$ ]] && docker rm -f "$name"
                ;;
            4) read -r -e -p "容器名: " name || return 0; [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && docker restart "$name" ;;
            5)
                read -r -e -p "容器名: " name || return 0
                if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
                    if docker exec "$name" /bin/sh -c 'command -v bash' >/dev/null 2>&1; then
                        docker exec -it "$name" /bin/bash
                    else
                        docker exec -it "$name" /bin/sh
                    fi
                fi
                ;;
            6)
                read -r -e -p "容器名: " name || return 0
                if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
                    local log_mode
                    read -r -e -p "日志模式 [1: 最近200行(默认) / 2: 实时追踪 -f]: " log_mode || return 0
                    if [ "$log_mode" = "2" ]; then
                        echo "按 Ctrl+C 退出实时日志..."
                        docker logs -f --tail 100 "$name" || true
                    else
                        docker logs --tail 200 "$name"
                    fi
                fi
                break_end
                ;;
            7) docker stats --no-stream; break_end ;;
            8)
                read -r -e -p "容器名: " name || return 0
                if [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
                    local img
                    img=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null || true)
                    if [ -n "$img" ]; then
                        echo "正在拉取最新镜像: $img"
                        docker pull "$img"
                        echo "拉取完成；如需生效请通过原 compose/run 方式重建容器。"
                    else
                        echo "未找到容器: $name" >&2
                    fi
                fi
                break_end
                ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

docker_configure_daemon() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local config=/etc/docker/daemon.json backup="" candidate max_size max_file mirror
    [ ! -L "$config" ] || { echo "拒绝覆盖 daemon.json 符号链接" >&2; return 1; }
    mkdir -p /etc/docker || return 1

    if [ -f "$config" ]; then
        echo "当前 /etc/docker/daemon.json 内容："
        cat "$config"
        echo "------------------------"
    fi

    read -r -e -p "单日志文件上限 max-size [默认 20m]: " max_size || return 0
    max_size="${max_size:-20m}"
    [[ "$max_size" =~ ^[0-9]+[kmgKMG]$ ]] || { echo "max-size 格式无效（如 20m / 50m）" >&2; return 1; }

    read -r -e -p "日志轮转保留份数 max-file [默认 3]: " max_file || return 0
    max_file="${max_file:-3}"
    [[ "$max_file" =~ ^[1-9][0-9]?$ ]] || { echo "max-file 需为 1-99 的整数" >&2; return 1; }

    read -r -e -p "镜像加速地址 (HTTPS，留空则不配置): " mirror || return 0
    if [ -n "$mirror" ]; then
        [[ "$mirror" =~ ^https://[A-Za-z0-9._:/-]+$ ]] || { echo "镜像加速地址必须为有效的 HTTPS URL" >&2; return 1; }
    fi

    if [ -f "$config" ]; then
        backup="/etc/docker/daemon.json.vps-backup-$(date +%Y%m%d-%H%M%S)"
        cp -p -- "$config" "$backup" || return 1
    fi

    candidate=$(mktemp /etc/docker/.daemon.json.vps.XXXXXX) || return 1
    if [ -n "$mirror" ]; then
        cat > "$candidate" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${max_size}",
    "max-file": "${max_file}"
  },
  "registry-mirrors": [
    "${mirror}"
  ]
}
EOF
    else
        cat > "$candidate" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${max_size}",
    "max-file": "${max_file}"
  }
}
EOF
    fi

    chmod 644 "$candidate" && mv -f -- "$candidate" "$config" || { rm -f -- "$candidate"; return 1; }
    if ! restart docker; then
        echo "Docker 重启失败，正在恢复原配置..." >&2
        if [ -n "$backup" ] && [ -f "$backup" ]; then
            cp -p -- "$backup" "$config" && restart docker || true
        else
            rm -f -- "$config" && restart docker || true
        fi
        return 1
    fi
    echo -e "${gl_lv}Docker daemon.json 已更新并生效${gl_bai}${backup:+（旧配置备份: $backup）}"
    echo "提示：日志轮转限制对新建容器生效。"
}

docker_menu() {
    while true; do
        clear
        echo -e "Docker 管理"
        docker_status_overview
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo "1. 安装/更新 Docker"
        echo "2. 查看 Docker 全局状态"
        echo "3. 容器管理"
        echo "4. 镜像管理"
        echo "5. 清理停止的容器/无用镜像/网络（保留卷）"
        echo "6. 卸载 Docker"
        echo "7. 单独清理未使用的匿名数据卷"
        echo "8. 配置日志轮转与镜像加速 (daemon.json)"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1) install_docker ; break_end ;;
            2)
                clear
                echo "Docker 版本"
                docker -v
                docker compose version
                echo ""
                echo "镜像列表:"
                docker image ls
                echo ""
                echo "容器列表:"
                docker ps -a
                break_end
                ;;
            3) docker_container_menu ;;
            4) clear; docker image ls; break_end ;;
            5)
                read -r -e -p "会删除所有停止的容器和未使用镜像/网络，保留数据卷。继续吗？(Y/N): " confirm || return 0
                [[ "$confirm" =~ ^[Yy]$ ]] && docker system prune -af
                break_end
                ;;
            7)
                echo "未挂载的匿名卷也可能含有重要数据，请先备份。"
                read -r -p "输入 DELETE 清理未使用的匿名卷: " confirm || return 0
                if [ "$confirm" = DELETE ]; then docker volume prune -f; fi
                break_end
                ;;
            8) docker_configure_daemon ; break_end ;;
            6)
                read -r -e -p "$(echo -e "${gl_hong}确定卸载 Docker 吗？(Y/N): ${gl_bai}")" confirm || return 0
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo "卸载软件会停止服务；保留容器、镜像及数据目录，便于重新安装后恢复。"
                    remove_docker
                fi
                break_end
                ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}


# ---- END modules/docker/docker.sh ----

# ---- BEGIN modules/caddy/common.sh ----
# ============ Caddy 公共工具与校验 ============

CADDY_MAIN=/etc/caddy/Caddyfile
CADDY_SITES=/etc/caddy/sites
CADDY_BACKUP=/etc/caddy/vps-toolbox-backups

caddy_need_root() {
    [[ $EUID -eq 0 ]] || { echo -e "${gl_huang}提示: ${gl_bai}需要 root 权限" >&2; return 1; }
}

caddy_need_binary() {
    command -v caddy >/dev/null 2>&1 || { echo -e "${gl_huang}提示: ${gl_bai}请先安装 Caddy" >&2; return 1; }
}

caddy_domain_ok() {
    [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $1 == *.* && $1 != *..* && ${#1} -le 253 ]]
}

caddy_ipv4_ok() {
    local ip=$1 a b c d n
    [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$ip"
    for n in "$a" "$b" "$c" "$d"; do ((10#$n <= 255)) || return 1; done
}

caddy_port_ok() {
    [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

caddy_prepare() {
    caddy_need_root && caddy_need_binary || return 1
    mkdir -p "$CADDY_SITES" "$CADDY_BACKUP"
    [[ -f $CADDY_MAIN ]] || printf '# Managed by VPS Toolbox\nimport /etc/caddy/sites/*.caddy\n' > "$CADDY_MAIN"
    if ! grep -Eq '^[[:space:]]*import[[:space:]]+/etc/caddy/sites/\*\.caddy([[:space:]]|$)' "$CADDY_MAIN"; then
        echo -e "${gl_huang}当前 Caddyfile 尚未导入 sites/*.caddy。${gl_bai}"
        local confirm
        read -r -p '自动添加 import 到 Caddyfile 末尾？[y/N]: ' confirm || return 1
        [[ $confirm == [yY] ]] || return 1
        cp -a "$CADDY_MAIN" "$CADDY_BACKUP/Caddyfile.$(date +%Y%m%d%H%M%S).bak" || return 1
        printf '\nimport /etc/caddy/sites/*.caddy\n' >> "$CADDY_MAIN"
    fi
    caddy validate --config "$CADDY_MAIN" --adapter caddyfile || return 1
}

caddy_snapshot() {
    mkdir -p "$CADDY_BACKUP"
    local name
    name=$(date +%Y%m%d-%H%M%S)-$$
    mkdir -p "$CADDY_BACKUP/$name" "$CADDY_SITES" || return 1
    cp -a "$CADDY_MAIN" "$CADDY_BACKUP/$name/Caddyfile" || return 1
    cp -a "$CADDY_SITES" "$CADDY_BACKUP/$name/sites" || return 1
    CADDY_LAST_BACKUP="$CADDY_BACKUP/$name"
}

caddy_restore_snapshot() {
    [[ -n ${CADDY_LAST_BACKUP:-} && -d $CADDY_LAST_BACKUP ]] || return 1
    cp -a "$CADDY_LAST_BACKUP/Caddyfile" "$CADDY_MAIN" || return 1
    rm -rf -- "$CADDY_SITES" || return 1
    cp -a "$CADDY_LAST_BACKUP/sites" "$CADDY_SITES"
}

caddy_apply() {
    if ! caddy validate --config "$CADDY_MAIN" --adapter caddyfile; then
        echo -e "${gl_hong}配置校验失败，正在恢复备份...${gl_bai}" >&2
        caddy_restore_snapshot
        return 1
    fi
    if ! service_action reload caddy; then
        echo -e "${gl_hong}重载失败，正在恢复备份...${gl_bai}" >&2
        caddy_restore_snapshot
        service_action reload caddy || true
        return 1
    fi
    echo -e "${gl_lv}Caddy 配置已生效。${gl_bai}"
}

caddy_select_site() {
    local prompt="${1:-请输入序号或域名 (输入 0 返回): }" input idx i=1 f
    shopt -s nullglob
    local -a files=("$CADDY_SITES"/*.caddy)
    shopt -u nullglob
    ((${#files[@]})) || { echo -e "${gl_hui}当前没有反代配置${gl_bai}"; return 1; }
    echo -e "${gl_kjlan}当前站点列表：${gl_bai}"
    for f in "${files[@]}"; do
        printf "  ${gl_kjlan}%d.${gl_bai} %s\n" "$i" "$(basename "$f" .caddy)"
        i=$((i + 1))
    done
    read -r -e -p "$prompt" input || return 1
    [ "$input" = "0" ] && return 2
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        idx=$((10#$input))
        if ((idx >= 1 && idx <= ${#files[@]})); then
            CADDY_SELECTED_FILE="${files[idx-1]}"
            CADDY_SELECTED_DOMAIN="$(basename "$CADDY_SELECTED_FILE" .caddy)"
            return 0
        fi
        echo -e "${gl_hong}序号超出范围${gl_bai}" >&2
        return 1
    fi
    caddy_domain_ok "$input" || { echo -e "${gl_hong}域名格式不正确${gl_bai}" >&2; return 1; }
    f="$CADDY_SITES/${input}.caddy"
    [[ -f $f && ! -L $f ]] || { echo -e "${gl_hong}配置不存在: $input${gl_bai}" >&2; return 1; }
    CADDY_SELECTED_FILE="$f"
    CADDY_SELECTED_DOMAIN="$input"
    return 0
}

# ---- END modules/caddy/common.sh ----

# ---- BEGIN modules/caddy/service.sh ----
# ============ Caddy 安装、服务与维护 ============

caddy_install() {
    caddy_need_root || return 1
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update && apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg || return 1
        local tmp
        tmp=$(mktemp) || return 1
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$tmp" || { rm -f "$tmp"; return 1; }
        gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$tmp" || { rm -f "$tmp"; return 1; }
        rm -f "$tmp"
        curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o /etc/apt/sources.list.d/caddy-stable.list || return 1
        chmod a+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
        apt-get update && apt-get install -y caddy || return 1
    elif command -v dnf >/dev/null 2>&1; then
        if command -v caddy >/dev/null 2>&1; then
            dnf upgrade -y caddy || return 1
        else
            dnf install -y 'dnf-command(copr)' && dnf copr enable -y @caddy/caddy && dnf install -y caddy || return 1
        fi
    elif command -v apk >/dev/null 2>&1; then
        apk update || return 1
        if command -v caddy >/dev/null 2>&1; then
            apk upgrade caddy || return 1
        else
            apk add caddy || return 1
        fi
    else
        echo -e "${gl_hong}当前仅支持 Debian/Ubuntu (apt)、RHEL/Rocky/Alma/Fedora (dnf) 与 Alpine (apk) 自动安装 Caddy。${gl_bai}" >&2
        return 1
    fi
    enable caddy || true
    start caddy && echo -e "${gl_lv}Caddy 已就绪: $(caddy version)${gl_bai}"
}

caddy_uninstall_keep_config() {
    caddy_need_root || return 1
    local answer
    echo -e "${gl_huang}将卸载 Caddy 软件包，但保留 /etc/caddy 配置和证书数据，方便之后迁移或重新安装。${gl_bai}"
    read -r -p '输入 UNINSTALL 确认：' answer || return 0
    [[ $answer == UNINSTALL ]] || { echo '已取消'; return 0; }
    service_action stop caddy 2>/dev/null || true
    if [ -d /run/systemd/system ]; then
        systemctl disable caddy 2>/dev/null || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update del caddy default 2>/dev/null || true
    fi
    if command -v apt-get >/dev/null 2>&1; then
        apt-get remove -y caddy
    elif command -v dnf >/dev/null 2>&1; then
        dnf remove -y caddy
    elif command -v apk >/dev/null 2>&1; then
        apk del caddy
    else
        echo -e "${gl_hong}当前系统暂不支持自动卸载 Caddy，请使用对应包管理器手动卸载${gl_bai}" >&2
        return 1
    fi
    echo -e "${gl_lv}Caddy 已卸载（配置与证书已保留）。${gl_bai}"
}

caddy_reset() {
    caddy_prepare || return 1
    local answer f
    echo -e "${gl_huang}此操作将清空 Caddyfile 和所有 sites/*.caddy 配置，保留备份。${gl_bai}"
    read -r -p '输入 RESET 确认：' answer || return 1
    [[ $answer == RESET ]] || { echo '已取消'; return 0; }
    caddy_snapshot || return 1
    printf '# Managed by VPS Toolbox\nimport /etc/caddy/sites/*.caddy\n' > "$CADDY_MAIN"
    for f in "$CADDY_SITES"/*.caddy; do [[ -f $f ]] && rm -- "$f"; done
    caddy_apply
}

caddy_list() {
    caddy_need_root && caddy_need_binary || return 1
    echo -e "${gl_kjlan}========== Caddy 服务状态 ==========${gl_bai}"
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --no-pager --full status caddy 2>/dev/null | sed -n '1,8p' || true
    else
        service_action status caddy 2>/dev/null || true
    fi
    echo ""
    echo -e "${gl_kjlan}========== 反代配置 ==========${gl_bai}"
    if [[ -d $CADDY_SITES ]]; then
        local f
        shopt -s nullglob
        local files=("$CADDY_SITES"/*.caddy)
        shopt -u nullglob
        if ((${#files[@]})); then
            for f in "${files[@]}"; do
                echo -e "\n${gl_huang}--- $(basename "$f") ---${gl_bai}"
                sed -n '1,120p' "$f"
            done
        else
            echo -e "${gl_hui}目前没有由工具箱管理的反代配置。${gl_bai}"
        fi
    else
        echo -e "${gl_hui}站点配置目录尚不存在。${gl_bai}"
    fi
}

caddy_check_reload() {
    caddy_prepare || return 1
    echo -e "${gl_kjlan}正在格式化并校验 Caddyfile...${gl_bai}"
    caddy fmt --overwrite "$CADDY_MAIN" || return 1
    local f
    shopt -s nullglob
    local files=("$CADDY_SITES"/*.caddy)
    shopt -u nullglob
    for f in "${files[@]}"; do caddy fmt --overwrite "$f" || return 1; done
    caddy validate --config "$CADDY_MAIN" --adapter caddyfile || return 1
    service_action reload caddy || { echo -e "${gl_hong}重载失败，请检查 Caddy 服务状态与日志${gl_bai}" >&2; return 1; }
    echo -e "${gl_lv}格式检查、配置校验和重载均已完成。${gl_bai}"
}

caddy_logs() {
    caddy_need_root && caddy_need_binary || return 1
    local log_mode
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        read -r -e -p "日志模式 [1: 最近 100 行(默认) / 2: 实时追踪 -f]: " log_mode || return 0
        clear
        if [ "$log_mode" = "2" ]; then
            echo -e "${gl_huang}按 Ctrl+C 退出实时日志...${gl_bai}"
            journalctl -u caddy -n 50 -f || true
        else
            journalctl -u caddy -n 100 --no-pager
        fi
    else
        echo -e "${gl_hui}当前系统未使用 systemd journald，请直接查看 /var/log/caddy/ 或 OpenRC 日志。${gl_bai}"
    fi
}

# ---- END modules/caddy/service.sh ----

# ---- BEGIN modules/caddy/sites.sh ----
# ============ Caddy 站点与反代管理 ============

caddy_add() {
    local mode=$1 domain upstream target port ip sni filename
    caddy_prepare || return 1
    read -r -e -p '站点域名（例如 app.example.com）: ' domain || return 1
    caddy_domain_ok "$domain" || { echo -e "${gl_hong}域名格式不正确${gl_bai}" >&2; return 1; }
    filename="$CADDY_SITES/${domain}.caddy"
    [[ ! -e $filename && ! -L $filename ]] || { echo -e "${gl_huang}此域名的配置文件已存在，不会覆盖（请使用编辑功能）${gl_bai}" >&2; return 1; }
    if [[ $mode == standard ]]; then
        read -r -e -p '目标地址（直接输入端口号如 3000 将自动转为 127.0.0.1:3000，或输入完整地址）: ' upstream || return 1
        if caddy_port_ok "$upstream"; then
            upstream="127.0.0.1:$((10#$upstream))"
            echo -e "已自动补全目标地址: ${gl_huang}${upstream}${gl_bai}"
        elif [[ $upstream =~ ^https?://[a-zA-Z0-9.:-]+$ || $upstream =~ ^[a-zA-Z0-9.:-]+$ ]]; then
            :
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
        printf '%s {\n    encode zstd gzip\n    reverse_proxy %s\n}\n' "$domain" "$upstream" > "$filename"
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
    caddy_apply
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

# ---- END modules/caddy/sites.sh ----

# ---- BEGIN modules/caddy/migration.sh ----
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

# ---- END modules/caddy/migration.sh ----

# ---- BEGIN modules/caddy/menu.sh ----
# ============ Caddy 管理菜单 ============

caddy_menu() {
    local choice caddy_state caddy_ver site_count=0
    local -a site_files=()
    while true; do
        clear
        site_count=0
        if [ -d "$CADDY_SITES" ]; then
            shopt -s nullglob
            site_files=("$CADDY_SITES"/*.caddy)
            shopt -u nullglob
            site_count="${#site_files[@]}"
        fi
        if command -v caddy >/dev/null 2>&1; then
            caddy_ver=$(caddy version 2>/dev/null | awk '{print $1}' || true)
            if service_action status caddy >/dev/null 2>&1; then
                caddy_state="${gl_lv}运行中${gl_bai} (${gl_huang}${caddy_ver:-已安装}${gl_bai})  反代站点: ${gl_lv}${site_count}${gl_bai}"
            else
                caddy_state="${gl_huang}已安装未运行${gl_bai} (${caddy_ver:-未知})  反代站点: ${gl_huang}${site_count}${gl_bai}"
            fi
        else
            caddy_state="${gl_hui}未安装${gl_bai}"
        fi

        echo -e "${gl_kjlan}===================== Caddy 管理 =====================${gl_bai}"
        echo -e "状态: ${caddy_state}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo -e "${gl_huang}【 站点与反代 】${gl_bai}"
        echo -e " ${gl_kjlan}1.${gl_bai}  添加反代 / 重定向"
        echo -e " ${gl_kjlan}2.${gl_bai}  查看状态与反代配置"
        echo -e " ${gl_kjlan}3.${gl_bai}  编辑反代配置 ${gl_hui}[自动校验并回滚]${gl_bai}"
        echo -e " ${gl_kjlan}4.${gl_bai}  删除反代 ${gl_hui}[支持序号选择]${gl_bai}"
        echo ""
        echo -e "${gl_huang}【 服务与维护 】${gl_bai}"
        echo -e " ${gl_kjlan}5.${gl_bai}  格式化、校验并重载配置"
        echo -e " ${gl_kjlan}6.${gl_bai}  查看 Caddy 运行日志 ${gl_hui}[最近 / 实时]${gl_bai}"
        echo -e " ${gl_kjlan}7.${gl_bai}  导出迁移备份"
        echo -e " ${gl_kjlan}8.${gl_bai}  导入迁移备份"
        echo ""
        echo -e "${gl_huang}【 安装与重置 】${gl_bai}"
        echo -e " ${gl_kjlan}9.${gl_bai}  安装 / 升级 Caddy"
        echo -e " ${gl_kjlan}10.${gl_bai} ${gl_huang}清空 / 重置反代配置${gl_bai}"
        echo -e " ${gl_kjlan}11.${gl_bai} ${gl_hong}卸载 Caddy (保留配置)${gl_bai}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo -e " ${gl_kjlan}0.${gl_bai}  返回主菜单"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) caddy_add_menu ;;
            2) clear; caddy_list; break_end ;;
            3) caddy_edit; break_end ;;
            4) caddy_delete; break_end ;;
            5) caddy_check_reload; break_end ;;
            6) caddy_logs; break_end ;;
            7) caddy_export_migration; break_end ;;
            8) caddy_import_migration; break_end ;;
            9) caddy_install; break_end ;;
            10) caddy_reset; break_end ;;
            11) caddy_uninstall_keep_config; break_end ;;
            0) return 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---- END modules/caddy/menu.sh ----

# ---- BEGIN modules/system/maintenance.sh ----
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


# ---- END modules/system/maintenance.sh ----

# ---- BEGIN modules/system/info.sh ----
# ============ 系统信息 ============

output_status() {
    output=$(awk '
        function hum(x) {
            if (x > 1073741824) return sprintf("%.2fG", x/1073741824)
            if (x > 1048576) return sprintf("%.2fM", x/1048576)
            if (x > 1024) return sprintf("%.2fK", x/1024)
            return sprintf("%dB", x)
        }
        BEGIN { rx = 0; tx = 0 }
        $1 ~ /:$/ && $1 !~ /^(lo|docker|veth|br-)/ { rx += $2; tx += $10 }
        END {
            printf("%s %s\n", hum(rx), hum(tx))
        }' /proc/net/dev)
    rx=$(echo "$output" | awk '{print $1}')
    tx=$(echo "$output" | awk '{print $2}')
}

current_timezone() {
    if command -v timedatectl &>/dev/null; then
        timedatectl show -p Timezone --value 2>/dev/null || date +"%Z %z"
    else
        date +"%Z %z"
    fi
}

linux_info() {
    local plain=0
    if [ "${1:-}" = "--plain" ] || [ "${1:-}" = "-p" ]; then
        plain=1
    fi
    if [ "$plain" -eq 0 ]; then
        clear
        echo -e "${gl_kjlan}正在查询系统信息...${gl_bai}"
    fi

    local ipv4_address ipv6_address output rx tx
    local cpu_info cpu_usage cpu_cores cpu_freq mem_info swap_info disk_info
    local os_info kernel hostname uptime_str load timezone current_time
    local congestion queue dns_servers tcp_conn udp_conn

    # 开启后台并发采集网络信息
    local tmp_ip
    tmp_ip=$(mktemp /tmp/vps_ip.XXXXXX)
    (
        ip_address
        printf '%s\n%s\n' "$ipv4_address" "$ipv6_address" > "$tmp_ip"
    ) &
    local ip_pid=$!

    cpu_info=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ 	]*//')
    [ -z "$cpu_info" ] && cpu_info=$(grep -m1 -E 'Hardware|Processor' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ 	]*//')
    [ -z "$cpu_info" ] && cpu_info="未知型号"

    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    cpu_freq=$(grep -m1 -i "cpu MHz" /proc/cpuinfo | awk '{printf "%.1f GHz", $4/1000}')
    [ -z "$cpu_freq" ] && [ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ] && cpu_freq=$(awk '{printf "%.1f GHz", $1/1000000}' /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    [ -z "$cpu_freq" ] && cpu_freq="虚拟化/不可用"

    # 复用 1 秒的等待时间来做 CPU 采样，同时后台的 IP 请求也在进行
    cpu_usage=$(awk '{idle=$5+$6; total=0; for(i=2;i<=9;i++)total+=$i; if(NR==1){idle1=idle; total1=total;} else {dt=total-total1; printf "%.0f\n", (dt>0 ? (dt-(idle-idle1))*100/dt : 0)}}' \
        <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

    wait "$ip_pid" 2>/dev/null || true
    {
        IFS= read -r ipv4_address || true
        IFS= read -r ipv6_address || true
    } < "$tmp_ip"
    rm -f -- "$tmp_ip"


    # 2. 内存与 Swap 采集 (统一走 /proc/meminfo，四舍五入到 MB)
    local mem_total mem_avail mem_used mem_p
    mem_total=$(awk '/MemTotal:/ {print int(($2+512)/1024)}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null)
    if [ -z "$mem_avail" ] || [ "$mem_avail" -eq 0 ]; then
        local mem_free buffers cached
        mem_free=$(awk '/MemFree:/ {print int(($2+512)/1024)}' /proc/meminfo)
        buffers=$(awk '/Buffers:/ {print int(($2+512)/1024)}' /proc/meminfo)
        cached=$(awk '/^Cached:/ {print int(($2+512)/1024)}' /proc/meminfo)
        mem_avail=$((mem_free + buffers + cached))
    fi
    mem_used=$((mem_total - mem_avail))
    [ "$mem_used" -lt 0 ] && mem_used=0
    mem_p=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN {printf "%.1f", (t>0 ? u*100/t : 0)}')
    mem_info="${mem_used}M/${mem_total}M (${mem_p}%)"

    local s_total s_free s_used s_p
    s_total=$(awk '/SwapTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    s_free=$(awk '/SwapFree:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    s_used=$((s_total - s_free))
    [ "$s_used" -lt 0 ] && s_used=0
    if [ "${s_total:-0}" -gt 0 ]; then
        s_p=$(awk -v u="$s_used" -v t="$s_total" 'BEGIN {printf "%.1f", u*100/t}')
        swap_info="${s_used}M/${s_total}M (${s_p}%)"
    else
        swap_info="未启用"
    fi

    # 3. 基础系统参数
    disk_info=$(df -Ph | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')
    kernel=$(uname -r)
    hostname=$(uname -n)
    uptime_str=$(awk -F. '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); if(d>0)printf "%d天 ",d; if(h>0)printf "%d时 ",h; printf "%d分",m}' /proc/uptime)
    load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
    timezone=$(current_timezone)
    current_time=$(date "+%Y-%m-%d %H:%M:%S")
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    queue=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    # 4. 融合指标：连接数与当前生效 DNS
    tcp_conn=$(ss -H -t 2>/dev/null | wc -l)
    udp_conn=$(ss -H -u 2>/dev/null | wc -l)
    dns_servers=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)

    output_status

    if [ "$plain" -eq 1 ]; then
        printf 'hostname: %s\n' "$hostname"
        printf 'os: %s\n' "$os_info"
        printf 'kernel: %s\n' "$kernel"
        printf 'arch: %s\n' "$(uname -m)"
        printf 'cpu: %s\n' "$cpu_info"
        printf 'cpu_cores: %s\n' "$cpu_cores"
        printf 'cpu_freq: %s\n' "$cpu_freq"
        printf 'cpu_usage: %s%%\n' "$cpu_usage"
        printf 'load: %s\n' "$load"
        printf 'memory: %s\n' "$mem_info"
        printf 'swap: %s\n' "$swap_info"
        printf 'disk: %s\n' "$disk_info"
        printf 'connections: tcp=%s udp=%s\n' "$tcp_conn" "$udp_conn"
        printf 'traffic: rx=%s tx=%s\n' "$rx" "$tx"
        printf 'tcp_cc: %s %s\n' "$congestion" "$queue"
        [ -n "$ipv4_address" ] && printf 'ipv4: %s\n' "$ipv4_address"
        [ -n "$ipv6_address" ] && printf 'ipv6: %s\n' "$ipv6_address"
        [ -n "$dns_servers" ]  && printf 'dns: %s\n' "$dns_servers"
        printf 'timezone: %s\n' "$timezone"
        printf 'time: %s\n' "$current_time"
        printf 'uptime: %s\n' "$uptime_str"
        return 0
    fi

    clear
    echo -e "${gl_kjlan}==================== 系统信息 ====================${gl_bai}"
    echo -e "${gl_kjlan}主机名:        ${gl_bai}$hostname"
    echo -e "${gl_kjlan}系统版本:      ${gl_bai}$os_info"
    echo -e "${gl_kjlan}内核版本:      ${gl_bai}$kernel"
    echo -e "${gl_kjlan}系统架构:      ${gl_bai}$(uname -m)"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}CPU 型号:      ${gl_bai}$cpu_info"
    echo -e "${gl_kjlan}核心 / 频率:   ${gl_bai}$cpu_cores 核 / $cpu_freq"
    echo -e "${gl_kjlan}CPU 使用率:    ${gl_bai}${cpu_usage}%"
    echo -e "${gl_kjlan}系统负载:      ${gl_bai}$load"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}物理内存:      ${gl_bai}$mem_info"
    echo -e "${gl_kjlan}虚拟内存:      ${gl_bai}$swap_info"
    echo -e "${gl_kjlan}系统硬盘:      ${gl_bai}$disk_info"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}TCP/UDP 连接:  ${gl_bai}${tcp_conn} | ${udp_conn}"
    echo -e "${gl_kjlan}总接收/发送:   ${gl_bai}$rx / $tx"
    echo -e "${gl_kjlan}网络算法:      ${gl_bai}$congestion $queue"
    [ -n "$ipv4_address" ] && echo -e "${gl_kjlan}IPv4 地址:     ${gl_bai}$ipv4_address"
    [ -n "$ipv6_address" ] && echo -e "${gl_kjlan}IPv6 地址:     ${gl_bai}$ipv6_address"
    [ -n "$dns_servers" ]  && echo -e "${gl_kjlan}DNS 地址:      ${gl_bai}$dns_servers"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}当前时区:      ${gl_bai}$timezone"
    echo -e "${gl_kjlan}系统时间:      ${gl_bai}$current_time"
    echo -e "${gl_kjlan}运行时长:      ${gl_bai}$uptime_str"
    echo -e "${gl_kjlan}==================================================${gl_bai}"
    echo ""
}


# ---- END modules/system/info.sh ----

# ---- BEGIN modules/system/tools.sh ----
# ============ 基础工具管理 ============

linux_tools() {
    local tools=(curl wget sudo socat htop iftop unzip tar tmux ffmpeg btop ncdu fzf vim nano git)

    while true; do
        clear
        echo -e "基础工具"
        echo -e "${gl_kjlan}------------------------${gl_bai}"

        for ((i=0; i<${#tools[@]}; i+=2)); do
            local left right
            if command -v "${tools[i]}" >/dev/null 2>&1; then
                left=$(printf "✅ %-12s 已安装" "${tools[i]}")
            else
                left=$(printf "❌ %-12s 未安装" "${tools[i]}")
            fi

            if [ -n "${tools[i+1]:-}" ]; then
                if command -v "${tools[i+1]}" >/dev/null 2>&1; then
                    right=$(printf "✅ %-12s 已安装" "${tools[i+1]}")
                else
                    right=$(printf "❌ %-12s 未安装" "${tools[i+1]}")
                fi
                printf "%-42s %s\n" "$left" "$right"
            else
                printf "%s\n" "$left"
            fi
        done

        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo "1. 安装全部工具"
        echo "2. 安装指定工具"
        echo "3. 卸载指定工具"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1)
                root_use || continue
                local manager tool mapped
                local -a missing_tools=()
                manager=$(vps_pkg_manager) || { break_end; continue; }
                for tool in "${tools[@]}"; do
                    if ! command -v "$tool" >/dev/null 2>&1; then
                        missing_tools+=("$tool")
                    fi
                done
                if [ "${#missing_tools[@]}" -eq 0 ]; then
                    echo "所有基础工具均已安装"
                    break_end
                    continue
                fi
                echo "正在更新软件源索引..."
                case "$manager" in
                    apt-get) apt-get update || { break_end; continue; } ;;
                    apk) apk update || { break_end; continue; } ;;
                esac
                for tool in "${missing_tools[@]}"; do
                    mapped=$(vps_pkg_name "$manager" "$tool")
                    echo "正在安装: $mapped"
                    case "$manager" in
                        apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        dnf|yum) "$manager" install -y "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        apk) apk add "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        pacman) pacman -S --needed --noconfirm "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                        zypper) zypper --non-interactive install "$mapped" >/dev/null 2>&1 || echo "⚠️ 无法安装: $tool" ;;
                    esac
                done
                break_end
                ;;
            2)
                root_use || continue
                read -r -e -p "请输入要安装的工具（空格分隔）: " -a custom_tools || return 0
                [ ${#custom_tools[@]} -gt 0 ] && pkg_install "${custom_tools[@]}"
                break_end
                ;;
            3)
                root_use || continue
                read -r -e -p "请输入要卸载的工具（空格分隔）: " -a remove_tools || return 0
                [ ${#remove_tools[@]} -gt 0 ] && pkg_remove "${remove_tools[@]}"
                break_end
                ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}


# ---- END modules/system/tools.sh ----

# ---- BEGIN modules/network/bbr.sh ----
# ============ BBR 管理 ============

bbr_on() {
    local CONF="/etc/sysctl.d/99-vps-bbr.conf"
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }

    if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null
    fi

    if ! sysctl -n net.ipv4.tcp_available_congestion_control | grep -qw bbr; then
        echo "当前内核不支持 BBR，可能需要升级内核" >&2
        return 1
    fi

    [ ! -L "$CONF" ] || { echo "拒绝覆盖 BBR 配置符号链接" >&2; return 1; }
    mkdir -p /etc/sysctl.d || return 1
    cat > "$CONF" <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    [ "$?" -eq 0 ] || return 1
    if grep -Eq '^[[:space:]]*(net.ipv4.tcp_congestion_control|net.core.default_qdisc)[[:space:]]*=' /etc/sysctl.conf 2>/dev/null; then
        cp -p /etc/sysctl.conf "/etc/sysctl.conf.vps-backup-$(date +%Y%m%d-%H%M%S)" || return 1
        sed -i '/^[[:space:]]*net.ipv4.tcp_congestion_control[[:space:]]*=/d; /^[[:space:]]*net.core.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf || return 1
    fi
    if ! sysctl -p "$CONF" || [ "$(sysctl -n net.ipv4.tcp_congestion_control)" != bbr ] ||
       [ "$(sysctl -n net.core.default_qdisc)" != fq ]; then
        echo "BBR 未完全生效，请检查 sysctl 输出和配置: $CONF" >&2
        return 1
    fi
    echo -e "${gl_lv}BBR 已成功开启${gl_bai}"
}

linux_bbr() {
    clear
    local cc qd kver
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    kver=$(uname -r | cut -d'-' -f1)

    while true; do
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
        qd=$(sysctl -n net.core.default_qdisc 2>/dev/null)
        clear
        echo -e "BBR 拥塞控制管理"
        echo -e "当前内核版本: ${gl_huang}$kver${gl_bai}"
        echo -e "当前 TCP 算法: ${gl_lv}$cc / $qd${gl_bai}"
        echo "------------------------"
        echo "1. 开启原生 BBR"
        echo "2. 关闭 BBR 配置"
        echo "3. 第三方强力内核加速脚本 (tcpx.sh)"
        echo "0. 返回"
        echo "------------------------"
        read -r -e -p "请输入你的选择: " choice || return 0
        case $choice in
            1) bbr_on ; break_end ;;
            2)
                root_use || continue
                rm -f /etc/sysctl.d/99-vps-bbr.conf || { break_end; continue; }
                echo "工具箱的 BBR 配置已移除，重启后由系统默认网络算法接管。"
                server_reboot
                ;;
            3)
                run_remote_bash "${gh_proxy}raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh"
                break_end
                ;;
            *) break ;;
        esac
    done
}


# ---- END modules/network/bbr.sh ----

# ---- BEGIN modules/network/warp.sh ----
# ============ WARP ============

linux_warp() {
    clear
    run_remote_bash "https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
}


# ---- END modules/network/warp.sh ----

# ---- BEGIN modules/benchmark/benchmark.sh ----
# ============ 测试脚本 ============

linux_test() {
    while true; do
        clear
        echo -e "${gl_kjlan}==================== 测试脚本合集 ====================${gl_bai}"
        echo -e "${gl_huang}【 IP 与解锁检测 】${gl_bai}"
        echo "1. IP 质量与风控体检 (IPQuality)"
        echo "2. 流媒体服务解锁检测 (RegionRestrictionCheck)"
        echo ""
        echo -e "${gl_huang}【 网络线路与测速 】${gl_bai}"
        echo "3. 三网回程路由追踪 (MTR Trace)"
        echo "4. 三网回程多路线检测 (backtrace)"
        echo "5. 泰尔网速三网测速 (TaiErSpeedtest)"
        echo "6. TCP 重传率与网络质量探测 (TcpQuality)"
        echo ""
        echo -e "${gl_huang}【 硬件性能测试 】${gl_bai}"
        echo "7. YABS 性能基准测试 (CPU/FIO/带宽)"
        echo "8. 硬件性能质量体检 (HardwareQuality)"
        echo ""
        echo -e "${gl_huang}【 综合大满贯评测 】${gl_bai}"
        echo "9. 融合怪综合测评 (ECS) ★"
        echo "10. NodeQuality 全功能综合评测"
        echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1)  run_remote_bash "${gh_proxy}raw.githubusercontent.com/xykt/IPQuality/main/ip.sh" ;;
            2)  run_remote_bash "${gh_proxy}github.com/lmc999/RegionRestrictionCheck/raw/main/check.sh" ;;
            3)  run_remote_bash "${gh_proxy}raw.githubusercontent.com/zhucaidan/mtr_trace/main/mtr_trace.sh" ;;
            4)  run_remote_bash "${gh_proxy}raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh" ;;
            5)  run_remote_bash "${gh_proxy}raw.githubusercontent.com/MiaM1ku/taierspeedtest/main/taierspeedtest.sh" ;;
            6)  run_remote_bash "${gh_proxy}raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh" ;;
            7)  check_swap; run_remote_bash "https://yabs.sh" -i -5 ;;
            8)  check_swap; run_remote_bash "${gh_proxy}raw.githubusercontent.com/xykt/HardwareQuality/main/hq.sh" ;;
            9)  run_remote_bash "${gh_proxy}github.com/spiritLHLS/ecs/raw/main/ecs.sh" ;;
            10) run_remote_bash "https://run.NodeQuality.com" ;;
            0)  break ;;
            *)  echo "无效选择" ; sleep 1 ; continue ;;
        esac
        break_end
    done
}


# ---- END modules/benchmark/benchmark.sh ----

# ---- BEGIN modules/ssh/port.sh ----
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
            if declare -F vps_f2b_sync_port >/dev/null 2>&1; then
                vps_f2b_sync_port "$new_port" || true
            fi
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


# ---- END modules/ssh/port.sh ----

# ---- BEGIN modules/ssh/auth.sh ----
# ============ 修改密码 ============

set_root_password() {
    root_use || return
    echo "设置 root 密码"
    passwd root || return 1
    echo -e "${gl_lv}root 密码设置完毕${gl_bai}；SSH 登录策略未改变。"
}

# ============ SSH 密钥登录 ============

vps_ssh_select_user() {
    local requested="${1:-root}" entry ignored
    [[ "$requested" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || { echo "用户名无效" >&2; return 1; }
    entry=$(getent passwd "$requested" 2>/dev/null || awk -F: -v name="$requested" '$1 == name {print; exit}' /etc/passwd)
    [ -n "$entry" ] || { echo "用户不存在: $requested" >&2; return 1; }
    IFS=: read -r ignored ignored ignored ignored ignored VPS_SSH_HOME ignored <<< "$entry"
    [ -d "$VPS_SSH_HOME" ] && [[ "$VPS_SSH_HOME" == /* ]] || {
        echo "用户主目录不存在" >&2; return 1
    }
    VPS_SSH_USER="$requested"
    VPS_SSH_UID=$(id -u "$requested") || return 1
    VPS_SSH_GID=$(id -g "$requested") || return 1
    VPS_SSH_AUTH="$VPS_SSH_HOME/.ssh/authorized_keys"
}

vps_ssh_prepare_auth() {
    [ ! -L "$VPS_SSH_HOME/.ssh" ] && [ ! -L "$VPS_SSH_AUTH" ] || {
        echo "拒绝写入符号链接形式的 .ssh 或 authorized_keys" >&2; return 1
    }
    mkdir -p -- "$VPS_SSH_HOME/.ssh" || return 1
    chmod 700 "$VPS_SSH_HOME/.ssh" || return 1
    chown "$VPS_SSH_UID:$VPS_SSH_GID" "$VPS_SSH_HOME/.ssh" || return 1
    touch -- "$VPS_SSH_AUTH" || return 1
    chmod 600 "$VPS_SSH_AUTH" || return 1
    chown "$VPS_SSH_UID:$VPS_SSH_GID" "$VPS_SSH_AUTH"
}

vps_ssh_valid_key() {
    local key="$1" temp result
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[A-Za-z0-9-]+|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || return 1
    temp=$(mktemp /tmp/vps-public-key.XXXXXX) || return 1
    printf '%s\n' "$key" > "$temp"
    ssh-keygen -lf "$temp" >/dev/null 2>&1
    result=$?
    rm -f -- "$temp"
    return "$result"
}

vps_ssh_add_key() {
    local key="$1"
    vps_ssh_valid_key "$key" || { echo "公钥格式无效" >&2; return 1; }
    vps_ssh_prepare_auth || return 1
    if grep -Fxq -- "$key" "$VPS_SSH_AUTH"; then
        echo "公钥已存在"
        return 0
    fi
    printf '%s\n' "$key" >> "$VPS_SSH_AUTH" || return 1
    echo "公钥已添加到 $VPS_SSH_AUTH"
}

vps_ssh_import_url() {
    local url="$1" temp line key
    local -a keys=()
    [[ "$url" == https://* ]] || { echo "只接受 HTTPS 公钥地址" >&2; return 1; }
    temp=$(mktemp /tmp/vps-public-keys.XXXXXX) || return 1
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 -o "$temp" "$url" ||
       [ "$(wc -c < "$temp")" -gt 131072 ]; then
        rm -f -- "$temp"
        echo "公钥下载失败或文件过大" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        if ! vps_ssh_valid_key "$line" || [ "${#keys[@]}" -ge 32 ]; then
            rm -f -- "$temp"
            echo "下载内容包含无效公钥或超过 32 条" >&2
            return 1
        fi
        keys+=("$line")
    done < "$temp"
    rm -f -- "$temp"
    [ "${#keys[@]}" -gt 0 ] || { echo "未找到公钥" >&2; return 1; }
    for key in "${keys[@]}"; do vps_ssh_add_key "$key" || return 1; done
}

vps_ssh_generate_key() {
    local key_path="$VPS_SSH_HOME/.ssh/vps-toolbox-ed25519-$(date +%Y%m%d%H%M%S)"
    vps_ssh_prepare_auth || return 1
    [ ! -e "$key_path" ] || { echo "密钥文件已存在" >&2; return 1; }
    (umask 077; ssh-keygen -q -t ed25519 -N '' -C "$VPS_SSH_USER@vps-toolbox" -f "$key_path") || return 1
    chown "$VPS_SSH_UID:$VPS_SSH_GID" "$key_path" "$key_path.pub" || return 1
    vps_ssh_add_key "$(cat "$key_path.pub")" || return 1
    echo "私钥保存在 $key_path。请安全复制到登录客户端，测试成功后再关闭密码登录。"
}

vps_ssh_strip_policy() {
    local source="$1" begin end begin_line end_line
    begin=$(grep -cxF '# BEGIN VPS Toolbox SSH key mode' "$source" || true)
    end=$(grep -cxF '# END VPS Toolbox SSH key mode' "$source" || true)
    [ "$begin" -eq "$end" ] && [ "$begin" -le 1 ] || return 1
    if [ "$begin" -eq 1 ]; then
        begin_line=$(grep -nxF '# BEGIN VPS Toolbox SSH key mode' "$source" | cut -d: -f1)
        end_line=$(grep -nxF '# END VPS Toolbox SSH key mode' "$source" | cut -d: -f1)
        [ "$begin_line" -lt "$end_line" ] || return 1
    fi
    awk '$0 == "# BEGIN VPS Toolbox SSH key mode" {skip=1; next}
         $0 == "# END VPS Toolbox SSH key mode" {skip=0; next}
         !skip {print}' "$source"
}

vps_ssh_render_policy() {
    local mode="$1" source="$2"
    [[ "$mode" == on || "$mode" == stage || "$mode" == off ]] || return 1
    vps_ssh_strip_policy "$source" || return 1
    if [ "$mode" != off ]; then
        [[ "${VPS_SSH_USER:-}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || return 1
        printf '# BEGIN VPS Toolbox SSH key mode\nMatch User %s\n    PubkeyAuthentication yes\n' "$VPS_SSH_USER"
        if [ "$mode" = on ]; then
            printf '    PasswordAuthentication no\n    KbdInteractiveAuthentication no\n    AuthenticationMethods publickey\n'
        fi
        printf 'Match all\n# END VPS Toolbox SSH key mode\n'
    fi
}

vps_ssh_policy() {
    local mode="$1" config=/etc/ssh/sshd_config sshd_bin backup candidate effective auth_methods managed_user
    local client_addr=${SSH_CONNECTION%% *}
    client_addr=${client_addr:-127.0.0.1}
    [[ "$mode" == on || "$mode" == stage || "$mode" == off ]] || return 1
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    sshd_bin=$(command -v sshd || true)
    [ -n "$sshd_bin" ] || sshd_bin=/usr/sbin/sshd
    [ -f "$config" ] && [ ! -L "$config" ] && [ -x "$sshd_bin" ] || {
        echo "未找到可管理的 OpenSSH 配置" >&2; return 1
    }
    managed_user=$(awk '$0=="# BEGIN VPS Toolbox SSH key mode" {inside=1; next}
        $0=="# END VPS Toolbox SSH key mode" {inside=0}
        inside && $1=="Match" && $2=="User" {print $3; exit}' "$config")
    if [ -n "$managed_user" ] && [ "$managed_user" != "$VPS_SSH_USER" ]; then
        echo "当前工具箱策略属于 $managed_user，请选择该用户移除策略后再切换用户" >&2
        return 1
    fi
    if [ "$mode" = stage ] && awk '
        $0 == "# BEGIN VPS Toolbox SSH key mode" {inside=1; next}
        $0 == "# END VPS Toolbox SSH key mode" {inside=0; next}
         inside && $1 == "PasswordAuthentication" && $2 == "no" {found=1}
        END {exit !found}' "$config"; then
        echo "当前已是仅密钥模式；如需移除策略，请使用菜单中的恢复选项" >&2
        return 1
    fi
    backup=$(mktemp /etc/ssh/sshd_config.vps-backup.XXXXXX) || return 1
    candidate=$(mktemp /etc/ssh/.sshd_config.vps.XXXXXX) || { rm -f -- "$backup"; return 1; }
    cp -p -- "$config" "$backup" || { rm -f -- "$backup" "$candidate"; return 1; }
    if ! vps_ssh_render_policy "$mode" "$config" > "$candidate"; then
        rm -f -- "$backup" "$candidate"
        echo "SSH 工具箱配置标记不完整，未做修改" >&2
        return 1
    fi
    if ! "$sshd_bin" -t -f "$candidate"; then
        rm -f -- "$candidate"
        echo "候选 SSH 配置无效，原配置未修改；备份: $backup" >&2
        return 1
    fi
    if [ "$mode" != off ]; then
        effective=$("$sshd_bin" -T -f "$candidate" -C "user=$VPS_SSH_USER,host=localhost,addr=$client_addr") || {
            rm -f -- "$candidate"; return 1;
        }
        auth_methods=$(printf '%s\n' "$effective" | awk '$1=="authenticationmethods" {print $2; exit}')
        if ! printf '%s\n' "$effective" | grep -qx 'pubkeyauthentication yes' ||
           { [ "$VPS_SSH_USER" = root ] && ! printf '%s\n' "$effective" | grep -Eq '^permitrootlogin (yes|prohibit-password|without-password)$'; } ||
           [[ ! "${auth_methods:-any}" =~ ^(any|publickey)$ ]] ||
           { [ "$mode" = on ] && { ! printf '%s\n' "$effective" | grep -qx 'passwordauthentication no' ||
                                   ! printf '%s\n' "$effective" | grep -qx 'kbdinteractiveauthentication no'; }; }; then
            rm -f -- "$candidate"
            echo "现有 Match/认证规则阻止目标策略生效，原配置未修改；备份: $backup" >&2
            return 1
        fi
    fi
    chown root:root "$candidate" && chmod 600 "$candidate" && mv -f -- "$candidate" "$config" || {
        rm -f -- "$candidate" "$backup"
        return 1
    }
    if "$sshd_bin" -t && vps_ssh_reload; then
        if [ "$mode" != off ]; then
            effective=$("$sshd_bin" -T -C "user=$VPS_SSH_USER,host=localhost,addr=${client_addr:-127.0.0.1}" 2>/dev/null)
            auth_methods=$(printf '%s\n' "$effective" | awk '$1 == "authenticationmethods" {print $2; exit}')
            if printf '%s\n' "$effective" | grep -qx 'pubkeyauthentication yes' &&
               { [ "$VPS_SSH_USER" != root ] || printf '%s\n' "$effective" | grep -Eq '^permitrootlogin (yes|prohibit-password|without-password)$'; } &&
               { { [ "$mode" = stage ] && [[ "${auth_methods:-any}" =~ ^(any|publickey(,publickey)*)$ ]]; } || {
                   printf '%s\n' "$effective" | grep -qx 'passwordauthentication no' &&
                   printf '%s\n' "$effective" | grep -qx 'kbdinteractiveauthentication no' &&
                   [[ "${auth_methods:-any}" =~ ^(any|publickey(,publickey)*)$ ]];
               }; }; then
                if [ "$mode" = stage ]; then
                    echo "公钥认证已开启，原有密码登录策略保持不变；备份: $backup"
                    echo "请在新终端测试密钥登录，成功后再选择仅密钥模式。"
                else
                    echo "$VPS_SSH_USER 的仅密钥登录模式已开启；原配置备份: $backup"
                    echo "请保持当前连接，使用新终端再次验证密钥登录。"
                fi
                return 0
            fi
        else
            echo "工具箱的密钥登录策略已移除；修改前备份: $backup"
            return 0
        fi
    fi
    if cp -p -- "$backup" "$config" && vps_ssh_reload; then
        echo "SSH 策略未生效，已恢复原配置；备份: $backup" >&2
    else
        echo "SSH 自动恢复未完成，请通过控制台检查；备份: $backup" >&2
    fi
    return 1
}

vps_ssh_key_menu() {
    root_use || return
    local choice input username status client_addr=${SSH_CONNECTION%% *}
    read -r -e -p "管理哪个 Linux 用户的密钥？(默认 root): " input || return 0
    vps_ssh_select_user "${input:-root}" || return 1
    while true; do
        clear
        status=$("$(command -v sshd || echo /usr/sbin/sshd)" -T -C "user=$VPS_SSH_USER,host=localhost,addr=${client_addr:-127.0.0.1}" 2>/dev/null | awk '$1=="pubkeyauthentication" || $1=="passwordauthentication" {printf "%s=%s ", $1, $2}')
        echo "用户密钥登录模式：$VPS_SSH_USER"
        echo "当前策略: ${status:-无法读取}"
        echo "1. 手动添加公钥     2. 从 GitHub 导入公钥"
        echo "3. 从 HTTPS 地址导入公钥"
        echo "4. 在服务器生成 ED25519 密钥对"
        echo "5. 查看已添加公钥的指纹"
        echo "6. 开启公钥认证（保留现有密码登录策略）"
        echo "7. 开启该用户的仅密钥登录（关闭该用户的 SSH 密码登录）"
        echo "8. 移除工具箱的密钥登录策略"
        echo "0. 返回"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) read -r -e -p "粘贴 SSH 公钥: " input || return 0; vps_ssh_add_key "$input"; break_end ;;
            2)
                read -r -e -p "GitHub 用户名: " username || return 0
                if [[ "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
                    vps_ssh_import_url "${gh_proxy}github.com/${username}.keys"
                else echo "GitHub 用户名无效" >&2; fi
                break_end ;;
            3) read -r -e -p "HTTPS 公钥地址: " input || return 0; vps_ssh_import_url "$input"; break_end ;;
            4) vps_ssh_generate_key; break_end ;;
            5)
                if [ -f "$VPS_SSH_AUTH" ]; then ssh-keygen -lf "$VPS_SSH_AUTH"; else echo "暂无公钥"; fi
                break_end ;;
            6)
                if [ ! -s "$VPS_SSH_AUTH" ] || ! ssh-keygen -lf "$VPS_SSH_AUTH" >/dev/null 2>&1; then
                    echo "请先添加有效公钥" >&2
                else
                    vps_ssh_policy stage
                fi
                break_end ;;
            7)
                if [ ! -s "$VPS_SSH_AUTH" ] || ! ssh-keygen -lf "$VPS_SSH_AUTH" >/dev/null 2>&1; then
                    echo "请先添加公钥并在新连接中测试" >&2
                else
                    echo "这会关闭 $VPS_SSH_USER 的 SSH 密码登录。请保持当前连接，在另一个终端测试该用户的密钥登录。"
                    read -r -e -p "已成功测试密钥登录后，输入 已测试 继续: " input || return 0
                    [ "$input" = 已测试 ] && vps_ssh_policy on || echo "操作已取消或未成功"
                fi
                break_end ;;
            8) vps_ssh_policy off; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ============ DNS 地址 ============


# ---- END modules/ssh/auth.sh ----

# ---- BEGIN modules/network/dns.sh ----
vps_dns_valid_ipv4() {
    local value="$1" a b c d extra octet
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r a b c d extra <<< "$value"
    [ -z "$extra" ] || return 1
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "$octet" = 0 || "$octet" != 0* ]] || return 1
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$octet))" -le 255 ] || return 1
    done
}

vps_dns_valid_ipv6() {
    local value="$1" left right group compressed=0
    local -a groups=()
    [ -n "$value" ] && [ "${#value}" -le 45 ] && [[ "$value" == *:* ]] &&
        [[ "$value" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
    if [[ "$value" == *.* ]]; then
        vps_dns_valid_ipv4 "${value##*:}" || return 1
        value="${value%:*}:0:0"
    fi
    if [[ "$value" == *::* ]]; then
        compressed=1
        left=${value%%::*}
        right=${value#*::}
        [[ "$right" != *::* && "$left" != *: && "$right" != :* ]] || return 1
        value="$left"
        if [ -n "$right" ]; then value="${value:+$value:}$right"; fi
    else
        [[ "$value" != :* && "$value" != *: ]] || return 1
    fi
    if [ -n "$value" ]; then IFS=: read -r -a groups <<< "$value"; fi
    for group in "${groups[@]}"; do [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; done
    if [ "$compressed" -eq 1 ]; then [ "${#groups[@]}" -lt 8 ]; else [ "${#groups[@]}" -eq 8 ]; fi
}

vps_dns_mode() {
    local target
    if [ -L /etc/resolv.conf ]; then
        target=$(readlink -f /etc/resolv.conf) || return 1
        case "$target" in
            */systemd/resolve/*|*/systemd/resolv.conf)
                if command systemctl is-active --quiet systemd-resolved 2>/dev/null; then
                    printf 'resolved\n'
                    return 0
                fi
                ;;
        esac
        echo "resolv.conf 由其他服务管理，暂不直接改写；请在对应网络管理器中设置 DNS" >&2
        return 1
    fi
    [ -f /etc/resolv.conf ] || { echo "找不到 /etc/resolv.conf" >&2; return 1; }
    if grep -Eq '^[[:space:]]*nameserver[[:space:]]+127\.0\.0\.53([[:space:]]|$)' /etc/resolv.conf &&
       command systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        printf 'resolved\n'
        return 0
    fi
    if grep -qiE 'generated by (networkmanager|resolvconf|dhclient)' /etc/resolv.conf; then
        echo "resolv.conf 由网络管理器生成，请在网络管理器中设置 DNS" >&2
        return 1
    fi
    printf 'static\n'
}

vps_dns_test() {
    VPS_DNS_TEST_SKIPPED=0
    if command -v getent >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 12 getent hosts example.com >/dev/null 2>&1
        else
            getent hosts example.com >/dev/null 2>&1
        fi
    elif command -v nslookup >/dev/null 2>&1; then
        if command -v timeout >/dev/null 2>&1; then
            timeout 12 nslookup example.com >/dev/null 2>&1
        else
            nslookup example.com >/dev/null 2>&1
        fi
    else
        echo "没有可用的 DNS 检测工具，请手动测试域名解析" >&2
        VPS_DNS_TEST_SKIPPED=1
        return 0
    fi
}

vps_dns_apply() {
    local first_v4="${1:-}" second_v4="${2:-}" first_v6="${3:-}" second_v6="${4:-}"
    local mode backup previous candidate config dns_list=""
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }

    vps_dns_valid_ipv4 "$first_v4" || {
        echo "请输入有效的 IPv4 DNS 地址" >&2; return 1
    }
    dns_list="$first_v4"

    if [ -n "$second_v4" ]; then
        vps_dns_valid_ipv4 "$second_v4" || { echo "请输入有效的备用 IPv4 DNS 地址: $second_v4" >&2; return 1; }
        dns_list="$dns_list $second_v4"
    fi

    if [ -n "$first_v6" ]; then
        vps_dns_valid_ipv6 "$first_v6" || { echo "输入的 IPv6 DNS 格式不正确: $first_v6" >&2; return 1; }
        dns_list="$dns_list $first_v6"
    fi
    if [ -n "$second_v6" ]; then
        vps_dns_valid_ipv6 "$second_v6" || { echo "输入的 IPv6 DNS 格式不正确: $second_v6" >&2; return 1; }
        dns_list="$dns_list $second_v6"
    fi

    mode=$(vps_dns_mode) || return 1

    if [ "$mode" = resolved ]; then
        config=/etc/systemd/resolved.conf.d/99-vps-toolbox-dns.conf
        mkdir -p /etc/systemd/resolved.conf.d || return 1
        [ ! -L "$config" ] || { echo "拒绝覆盖符号链接" >&2; return 1; }
        if [ -e "$config" ] && ! grep -qx '# VPS Toolbox DNS' <(head -n 1 "$config"); then
            echo "已有同名 DNS 配置，请先手动检查 $config" >&2
            return 1
        fi
        previous=$(mktemp /etc/systemd/resolved.conf.d/.vps-dns-prev.XXXXXX) || return 1
        if [ -f "$config" ]; then
            cp -p -- "$config" "$previous" || { rm -f -- "$previous"; return 1; }
        else : > "$previous"; fi
        candidate=$(mktemp /etc/systemd/resolved.conf.d/.vps-dns-new.XXXXXX) || {
            rm -f -- "$previous"; return 1
        }
        printf '# VPS Toolbox DNS\n[Resolve]\nDNS=%s\n' "$dns_list" > "$candidate"
        chmod 644 "$candidate" && mv -f -- "$candidate" "$config" || {
            rm -f -- "$candidate" "$previous"; return 1
        }
        if ! command systemctl restart systemd-resolved || ! vps_dns_test; then
            if { if [ -s "$previous" ]; then cp -p -- "$previous" "$config"; else rm -f -- "$config"; fi; } &&
               command systemctl restart systemd-resolved; then
                rm -f -- "$previous"
                echo "DNS 校验失败，已恢复原配置" >&2
            else
                echo "DNS 校验失败且自动回滚未完成；备份: $previous" >&2
            fi
            return 1
        fi
        rm -f -- "$previous"
    else
        backup=/etc/resolv.conf.vps-toolbox.bak
        [ ! -L "$backup" ] || { echo "DNS 备份路径是符号链接，未做修改" >&2; return 1; }
        [ ! -e "$backup" ] || [ -f "$backup" ] || {
            echo "DNS 备份路径不是普通文件，未做修改" >&2; return 1
        }
        if [ ! -e "$backup" ]; then cp -p -- /etc/resolv.conf "$backup" || return 1; fi
        previous=$(mktemp /etc/.resolv.conf.vps-prev.XXXXXX) || return 1
        cp -p -- /etc/resolv.conf "$previous" || { rm -f -- "$previous"; return 1; }
        candidate=$(mktemp /etc/.resolv.conf.vps-new.XXXXXX) || { rm -f -- "$previous"; return 1; }
        {
            for ip in $dns_list; do
                printf 'nameserver %s\n' "$ip"
            done
            awk '$1 == "search" || $1 == "domain" || $1 == "options" {print}' /etc/resolv.conf
        } > "$candidate" || { rm -f -- "$candidate" "$previous"; return 1; }
        chmod 644 "$candidate" && mv -f -- "$candidate" /etc/resolv.conf || {
            rm -f -- "$candidate" "$previous"; return 1
        }
        if ! vps_dns_test; then
            if cp -p -- "$previous" /etc/resolv.conf; then
                rm -f -- "$previous"
                echo "DNS 校验失败，已恢复原配置" >&2
            else
                echo "DNS 校验失败且自动回滚未完成；备份: $previous" >&2
            fi
            return 1
        fi
        rm -f -- "$previous"
    fi
    echo "DNS 已设置为: $dns_list"
    [ "$mode" != resolved ] || echo "已写入 systemd-resolved 全局 DNS；网卡的专属 DNS 仍可能参与解析，可通过 resolvectl status 查看。"
    if [ "${VPS_DNS_TEST_SKIPPED:-0}" -eq 1 ]; then
        echo "请手动测试域名解析。"
    else
        echo "域名解析校验通过。"
    fi
}

vps_dns_restore() {
    local mode previous config=/etc/systemd/resolved.conf.d/99-vps-toolbox-dns.conf
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    mode=$(vps_dns_mode) || return 1
    if [ "$mode" = resolved ]; then
        [ -f "$config" ] && grep -qx '# VPS Toolbox DNS' <(head -n 1 "$config") || {
            echo "没有工具箱创建的 DNS 配置" >&2; return 1
        }
        previous=$(mktemp /etc/systemd/resolved.conf.d/.vps-dns-restore.XXXXXX) || return 1
        cp -p -- "$config" "$previous" || { rm -f -- "$previous"; return 1; }
        if ! rm -f -- "$config" || ! command systemctl restart systemd-resolved || ! vps_dns_test; then
            if cp -p -- "$previous" "$config" && command systemctl restart systemd-resolved; then
                rm -f -- "$previous"
                echo "恢复后的 DNS 不可用，已回到修改前配置" >&2
            else
                echo "DNS 自动回滚未完成；备份: $previous" >&2
            fi
            return 1
        fi
        rm -f -- "$previous"
    else
        [ -f /etc/resolv.conf.vps-toolbox.bak ] && [ ! -L /etc/resolv.conf.vps-toolbox.bak ] || {
            echo "没有可恢复的 DNS 备份" >&2; return 1
        }
        previous=$(mktemp /etc/.resolv.conf.vps-restore.XXXXXX) || return 1
        cp -p -- /etc/resolv.conf "$previous" || { rm -f -- "$previous"; return 1; }
        if ! cp -p -- /etc/resolv.conf.vps-toolbox.bak /etc/resolv.conf || ! vps_dns_test; then
            if cp -p -- "$previous" /etc/resolv.conf; then
                rm -f -- "$previous"
                echo "恢复 DNS 失败，已回到修改前配置" >&2
            else
                echo "DNS 自动回滚未完成；备份: $previous" >&2
            fi
            return 1
        fi
        rm -f -- "$previous"
    fi
    echo "已恢复原 DNS 配置"
}

vps_dns_menu() {
    root_use || return
    local choice first_v4 second_v4 first_v6 second_v6

    while true; do
        clear
        echo -e "${gl_kjlan}===================== 优化 DNS 地址 =====================${gl_bai}"
        echo "当前系统生效 DNS："
        if command -v resolvectl >/dev/null 2>&1 && \
           command systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            resolvectl dns 2>/dev/null
        else
            awk '/^[[:space:]]*nameserver[[:space:]]+/ {
                printf "  nameserver %s\n", $2
            }' /etc/resolv.conf 2>/dev/null
        fi
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo -e "1. ${gl_lv}国外公共 DNS${gl_bai} (Cloudflare + Google)"
        echo -e "   ${gl_hui}IPv4: 1.1.1.1 / 8.8.8.8${gl_bai}"
        echo -e "   ${gl_hui}IPv6: 2606:4700:4700::1111 / 2001:4860:4860::8888${gl_bai}"
        echo ""
        echo -e "2. ${gl_lv}国内公共 DNS${gl_bai} (阿里 DNS + 腾讯 DNSPod)"
        echo -e "   ${gl_hui}IPv4: 223.5.5.5 / 119.29.29.29${gl_bai}"
        echo -e "   ${gl_hui}IPv6: 2400:3200::1 / 2400:3200:baba::1${gl_bai}"
        echo ""
        echo "3. 自定义 DNS 地址"
        echo "4. 恢复原 DNS 备份"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case "$choice" in
            1)
                vps_dns_apply "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888"
                break_end
                ;;
            2)
                vps_dns_apply "223.5.5.5" "119.29.29.29" "2400:3200::1" "2400:3200:baba::1"
                break_end
                ;;
            3)
                local custom_dns
                read -r -p "输入新的 DNS 地址 (空格分隔，如 8.8.8.8 1.1.1.1): " custom_dns
                [ -z "$custom_dns" ] && continue
                # 简单分隔并提取前 4 个 IP
                read -r -a dns_arr <<< "$custom_dns"
                vps_dns_apply "${dns_arr[0]}" "${dns_arr[1]:-}" "${dns_arr[2]:-}" "${dns_arr[3]:-}"
                break_end
                ;;
            4)
                vps_dns_restore
                break_end
                ;;
            0)
                break
                ;;
            *)
                echo "无效选择" ; sleep 1
                ;;
        esac
    done
}

# ============ 时区设置 ============


# ---- END modules/network/dns.sh ----

# ---- BEGIN modules/network/firewall.sh ----
# ============ 防火墙管理 (UFW / Firewalld) ============

vps_fw_detect() {
    if command -v ufw >/dev/null 2>&1; then
        printf 'ufw\n'
    elif command -v firewall-cmd >/dev/null 2>&1; then
        printf 'firewalld\n'
    else
        return 1
    fi
}

vps_fw_ssh_port() {
    local sshd_bin port
    sshd_bin=$(command -v sshd || true)
    [ -n "$sshd_bin" ] || sshd_bin=/usr/sbin/sshd
    port=$("$sshd_bin" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
    printf '%s\n' "${port:-22}"
}

vps_fw_install() {
    local manager
    manager=$(vps_pkg_manager) || return 1
    case "$manager" in
        apt-get|pacman)
            pkg_install ufw || return 1
            ;;
        dnf|yum|zypper)
            pkg_install firewalld || return 1
            enable firewalld || true
            ;;
        *)
            echo "当前系统暂不支持自动安装防火墙管理器，请手动安装 ufw 或 firewalld" >&2
            return 1
            ;;
    esac
}

vps_fw_status() {
    local fw="$1"
    if [ "$fw" = ufw ]; then
        ufw status verbose
    else
        if firewall-cmd --state >/dev/null 2>&1; then
            echo "Firewalld 状态: 运行中 (running)"
            firewall-cmd --list-all
        else
            echo "Firewalld 状态: 未运行 (not running)"
        fi
    fi
}

vps_fw_allow_port() {
    local fw="$1" port proto
    read -r -e -p "请输入要放行的端口 (1-65535): " port || return 0
    vps_valid_port "$port" || { echo "端口无效" >&2; return 1; }
    port=$((10#$port))
    read -r -e -p "协议类型 [tcp/udp/both，默认 tcp]: " proto || return 0
    proto="${proto:-tcp}"
    case "$proto" in
        tcp|udp)
            if [ "$fw" = ufw ]; then
                ufw allow "${port}/${proto}"
            else
                firewall-cmd --add-port="${port}/${proto}" &&
                    firewall-cmd --permanent --add-port="${port}/${proto}"
            fi
            ;;
        both)
            if [ "$fw" = ufw ]; then
                ufw allow "${port}/tcp" && ufw allow "${port}/udp"
            else
                firewall-cmd --add-port="${port}/tcp" && firewall-cmd --add-port="${port}/udp" &&
                    firewall-cmd --permanent --add-port="${port}/tcp" && firewall-cmd --permanent --add-port="${port}/udp"
            fi
            ;;
        *)
            echo "无效协议，请输入 tcp、udp 或 both" >&2
            return 1
            ;;
    esac
}

vps_fw_deny_port() {
    local fw="$1" port proto ssh_port confirm
    ssh_port=$(vps_fw_ssh_port)
    read -r -e -p "请输入要关闭/移除规则的端口 (1-65535): " port || return 0
    vps_valid_port "$port" || { echo "端口无效" >&2; return 1; }
    port=$((10#$port))
    if [ "$port" = "$ssh_port" ]; then
        echo -e "${gl_hong}警告：端口 $port 是当前 SSH 端口，关闭可能导致失联！${gl_bai}"
        read -r -p "如确认关闭，请输入 CLOSE-SSH: " confirm || return 0
        [ "$confirm" = CLOSE-SSH ] || { echo "已取消"; return 0; }
    fi
    read -r -e -p "协议类型 [tcp/udp/both，默认 tcp]: " proto || return 0
    proto="${proto:-tcp}"
    case "$proto" in
        tcp|udp)
            if [ "$fw" = ufw ]; then
                ufw delete allow "${port}/${proto}"
            else
                firewall-cmd --remove-port="${port}/${proto}" &&
                    firewall-cmd --permanent --remove-port="${port}/${proto}"
            fi
            ;;
        both)
            if [ "$fw" = ufw ]; then
                ufw delete allow "${port}/tcp" ; ufw delete allow "${port}/udp"
            else
                firewall-cmd --remove-port="${port}/tcp" ; firewall-cmd --remove-port="${port}/udp"
                firewall-cmd --permanent --remove-port="${port}/tcp" ; firewall-cmd --permanent --remove-port="${port}/udp"
            fi
            ;;
        *)
            echo "无效协议，请输入 tcp、udp 或 both" >&2
            return 1
            ;;
    esac
}

vps_fw_allow_ip() {
    local fw="$1" ip family="ipv4"
    read -r -e -p "请输入要放行的来源 IP (IPv4 或 IPv6): " ip || return 0
    if vps_dns_valid_ipv4 "$ip"; then
        family="ipv4"
    elif vps_dns_valid_ipv6 "$ip"; then
        family="ipv6"
    else
        echo "IP 地址格式无效: $ip" >&2
        return 1
    fi
    if [ "$fw" = ufw ]; then
        ufw allow from "$ip"
    else
        local rule="rule family=\"${family}\" source address=\"${ip}\" accept"
        firewall-cmd --add-rich-rule="$rule" && firewall-cmd --permanent --add-rich-rule="$rule"
    fi
}

vps_fw_enable() {
    local fw="$1" ssh_port
    ssh_port=$(vps_fw_ssh_port)
    echo -e "启用前将自动放行当前 SSH 端口: ${gl_huang}${ssh_port}/tcp${gl_bai}"
    if [ "$fw" = ufw ]; then
        ufw allow "${ssh_port}/tcp" || return 1
        ufw --force enable
    else
        enable firewalld || true
        start firewalld || return 1
        firewall-cmd --add-port="${ssh_port}/tcp" &&
            firewall-cmd --permanent --add-port="${ssh_port}/tcp"
    fi
}

vps_fw_disable() {
    local fw="$1" confirm
    read -r -p "确认停用防火墙？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
    if [ "$fw" = ufw ]; then
        ufw disable
    else
        stop firewalld
    fi
}

vps_firewall_menu() {
    root_use || return
    local fw choice state_str
    while true; do
        clear
        fw=$(vps_fw_detect || true)
        if [ -z "$fw" ]; then
            echo -e "${gl_kjlan}===================== 防火墙管理 =====================${gl_bai}"
            echo "未检测到 UFW 或 Firewalld。"
            echo "1. 自动安装推荐防火墙 (Debian/Ubuntu: ufw, RHEL系: firewalld)"
            echo "0. 返回上一级"
            echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
            read -r -e -p "请输入你的选择: " choice || return 0
            case "$choice" in
                1) vps_fw_install; break_end ;;
                0) break ;;
                *) echo "无效选择"; sleep 1 ;;
            esac
            continue
        fi

        if [ "$fw" = ufw ]; then
            if LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
                state_str="${gl_lv}运行中 (UFW)${gl_bai}"
            else
                state_str="${gl_huang}未启用 (UFW)${gl_bai}"
            fi
        else
            if firewall-cmd --state >/dev/null 2>&1; then
                state_str="${gl_lv}运行中 (Firewalld)${gl_bai}"
            else
                state_str="${gl_huang}未运行 (Firewalld)${gl_bai}"
            fi
        fi

        echo -e "${gl_kjlan}===================== 防火墙管理 =====================${gl_bai}"
        echo -e "当前状态: ${state_str}    SSH 端口: ${gl_huang}$(vps_fw_ssh_port)${gl_bai}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "1. 查看防火墙状态与规则"
        echo "2. 放行端口 (TCP/UDP)"
        echo "3. 关闭/移除端口规则"
        echo "4. 放行指定 IP (白名单)"
        echo "5. 启用防火墙 (自动放行当前 SSH 端口)"
        echo "6. 停用防火墙"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) clear; vps_fw_status "$fw"; break_end ;;
            2) vps_fw_allow_port "$fw"; break_end ;;
            3) vps_fw_deny_port "$fw"; break_end ;;
            4) vps_fw_allow_ip "$fw"; break_end ;;
            5) vps_fw_enable "$fw"; break_end ;;
            6) vps_fw_disable "$fw"; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---- END modules/network/firewall.sh ----

# ---- BEGIN modules/network/tailscale.sh ----
# ============ Tailscale 管理 ============

vps_ts_need_binary() {
    command -v tailscale >/dev/null 2>&1 || {
        echo "尚未安装 Tailscale，请先执行安装" >&2
        return 1
    }
}

vps_ts_enable_forwarding() {
    local conf=/etc/sysctl.d/99-vps-tailscale-forward.conf
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    [ ! -L "$conf" ] || { echo "拒绝覆盖符号链接: $conf" >&2; return 1; }
    mkdir -p /etc/sysctl.d || return 1
    cat > "$conf" <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl -p "$conf" >/dev/null 2>&1 || true
    echo -e "${gl_lv}已开启内核 IPv4/IPv6 转发${gl_bai} ($conf)"
}

vps_ts_format_tags() {
    local raw="$1" item formatted=""
    local -a items=()
    raw="${raw// /}"
    [ -n "$raw" ] || return 1
    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        [ -n "$item" ] || continue
        [[ "$item" == tag:* ]] || item="tag:$item"
        [[ "$item" =~ ^tag:[A-Za-z][A-Za-z0-9-]*$ ]] || {
            echo "标签格式无效: $item（标签名需以字母开头，仅含字母、数字和短横线）" >&2
            return 1
        }
        formatted="${formatted:+${formatted},}${item}"
    done
    [ -n "$formatted" ] || return 1
    printf '%s\n' "$formatted"
}

vps_ts_install() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    if command -v tailscale >/dev/null 2>&1; then
        echo "检测到已安装 Tailscale，正在通过官方脚本检查/升级..."
    else
        echo -e "${gl_kjlan}正在通过官方脚本安装 Tailscale...${gl_bai}"
    fi
    run_remote_bash "https://tailscale.com/install.sh" || return 1
    enable tailscaled >/dev/null 2>&1 || true
    start tailscaled >/dev/null 2>&1 || true
    tailscale version
}

vps_ts_up() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    vps_ts_need_binary || return 1

    local auth_key auth_file="" ts_host raw_tags tags use_ssh accept_routes use_exit adv_routes rc=0
    local -a args=()

    echo -e "${gl_kjlan}=== Tailscale 登录 / 启动配置 ===${gl_bai}"
    read -r -s -p "Auth Key (留空则使用浏览器交互式登录): " auth_key || return 0
    echo ""
    if [ -n "$auth_key" ]; then
        auth_file=$(mktemp /tmp/vps-ts-auth.XXXXXX) || return 1
        chmod 600 "$auth_file" || { rm -f -- "$auth_file"; return 1; }
        printf '%s\n' "$auth_key" > "$auth_file" || { rm -f -- "$auth_file"; return 1; }
        args+=(--auth-key="file:${auth_file}")
    fi

    read -r -e -p "自定义节点名称 --hostname (留空使用系统主机名): " ts_host || { rm -f -- "$auth_file"; return 0; }
    if [ -n "$ts_host" ]; then
        vps_valid_hostname "$ts_host" || { rm -f -- "$auth_file"; echo "节点名称格式无效" >&2; return 1; }
        args+=(--hostname="$ts_host")
    fi

    read -r -e -p "节点标签 --advertise-tags (逗号分隔，如 vps,prod；留空跳过): " raw_tags || { rm -f -- "$auth_file"; return 0; }
    if [ -n "$raw_tags" ]; then
        tags=$(vps_ts_format_tags "$raw_tags") || { rm -f -- "$auth_file"; return 1; }
        args+=(--advertise-tags="$tags")
        echo -e "${gl_huang}提示：使用标签前请确保已在 Tailscale 控制台 ACL 的 tagOwners 中配置对应标签。${gl_bai}"
    fi

    read -r -e -p "开启 Tailscale SSH？[y/N]: " use_ssh || { rm -f -- "$auth_file"; return 0; }
    [[ "$use_ssh" =~ ^[Yy]$ ]] && args+=(--ssh)

    read -r -e -p "接受其他节点广播的子网路由 (--accept-routes)？[y/N]: " accept_routes || { rm -f -- "$auth_file"; return 0; }
    [[ "$accept_routes" =~ ^[Yy]$ ]] && args+=(--accept-routes)

    read -r -e -p "作为出口节点 (--advertise-exit-node)？[y/N]: " use_exit || { rm -f -- "$auth_file"; return 0; }
    if [[ "$use_exit" =~ ^[Yy]$ ]]; then
        vps_ts_enable_forwarding || { rm -f -- "$auth_file"; return 1; }
        args+=(--advertise-exit-node)
    fi

    read -r -e -p "广播子网路由 --advertise-routes (如 10.0.0.0/24；留空跳过): " adv_routes || { rm -f -- "$auth_file"; return 0; }
    if [ -n "$adv_routes" ]; then
        [[ "$adv_routes" =~ ^[0-9A-Fa-f.:/,]+$ ]] || { rm -f -- "$auth_file"; echo "子网路由格式无效" >&2; return 1; }
        vps_ts_enable_forwarding || { rm -f -- "$auth_file"; return 1; }
        args+=(--advertise-routes="$adv_routes")
    fi

    echo "正在执行 tailscale up..."
    tailscale up "${args[@]}" || rc=$?
    [ -z "$auth_file" ] || rm -f -- "$auth_file"
    return "$rc"
}

vps_ts_manage_options() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    vps_ts_need_binary || return 1
    local sub raw_tags tags ts_host adv_routes confirm
    while true; do
        clear
        echo -e "${gl_kjlan}============== Tailscale 标签与选项管理 ==============${gl_bai}"
        echo "1. 设置/修改节点标签 (--advertise-tags)"
        echo "2. 开启出口节点 (Exit Node，自动开启 IP 转发)"
        echo "3. 关闭出口节点 (Exit Node)"
        echo "4. 开启 Tailscale SSH"
        echo "5. 关闭 Tailscale SSH"
        echo "6. 设置子网路由广播 (--advertise-routes)"
        echo "7. 清空子网路由广播"
        echo "8. 修改节点主机名 (--hostname)"
        echo "9. 临时断开连接 (tailscale down) / 恢复连接 (tailscale up)"
        echo "10. 注销当前节点 (tailscale logout)"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " sub || return 0
        case "$sub" in
            1)
                echo "提示：多个标签用逗号分隔，可省略 tag: 前缀（如 vps,hk）。"
                echo "注意：使用标签需在 Tailscale Admin Console 的 ACL tagOwners 中提前授权。"
                read -r -e -p "请输入标签: " raw_tags || return 0
                if [ -n "$raw_tags" ]; then
                    tags=$(vps_ts_format_tags "$raw_tags") && tailscale up --advertise-tags="$tags"
                fi
                break_end
                ;;
            2)
                vps_ts_enable_forwarding && tailscale set --advertise-exit-node=true
                echo "提示：还需在 Tailscale 控制台批准该节点的 Exit Node 权限。"
                break_end
                ;;
            3) tailscale set --advertise-exit-node=false; break_end ;;
            4) tailscale set --ssh=true; break_end ;;
            5) tailscale set --ssh=false; break_end ;;
            6)
                read -r -e -p "请输入子网 CIDR（逗号分隔，如 192.168.1.0/24,10.0.0.0/24）: " adv_routes || return 0
                if [[ "$adv_routes" =~ ^[0-9A-Fa-f.:/,]+$ ]]; then
                    vps_ts_enable_forwarding && tailscale set --advertise-routes="$adv_routes"
                    echo "提示：还需在 Tailscale 控制台批准对应子网路由。"
                else
                    echo "子网格式无效" >&2
                fi
                break_end
                ;;
            7) tailscale set --advertise-routes=""; break_end ;;
            8)
                read -r -e -p "请输入新的节点主机名: " ts_host || return 0
                if vps_valid_hostname "$ts_host"; then
                    tailscale set --hostname="$ts_host"
                else
                    echo "主机名格式无效" >&2
                fi
                break_end
                ;;
            9)
                local act
                read -r -e -p "请选择 [1: 断开 down / 2: 重连 up]: " act || return 0
                case "$act" in
                    1) tailscale down ;;
                    2) tailscale up ;;
                    *) echo "已取消" ;;
                esac
                break_end
                ;;
            10)
                read -r -p "确认注销当前 Tailscale 节点登录状态？输入 LOGOUT 确认: " confirm || return 0
                [ "$confirm" = LOGOUT ] && tailscale logout || echo "已取消"
                break_end
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

vps_ts_uninstall() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local confirm clean_state
    read -r -p "确认卸载 Tailscale？输入 UNINSTALL 确认: " confirm || return 0
    [ "$confirm" = UNINSTALL ] || { echo "已取消"; return 0; }
    if command -v tailscale >/dev/null 2>&1; then
        tailscale down 2>/dev/null || true
    fi
    service_action stop tailscaled 2>/dev/null || true
    if [ -d /run/systemd/system ]; then
        systemctl disable tailscaled 2>/dev/null || true
    elif command -v rc-update >/dev/null 2>&1; then
        rc-update del tailscaled default 2>/dev/null || true
    fi
    pkg_remove tailscale || return 1
    read -r -p "是否同时清理状态目录 /var/lib/tailscale？[y/N]: " clean_state || return 0
    if [[ "$clean_state" =~ ^[Yy]$ ]]; then
        rm -rf -- /var/lib/tailscale
        echo "已清理 /var/lib/tailscale"
    fi
    echo -e "${gl_lv}Tailscale 已卸载${gl_bai}"
}

vps_tailscale_menu() {
    local choice ts_state ts_v4 ts_v6 peer
    while true; do
        clear
        if command -v tailscale >/dev/null 2>&1; then
            ts_v4=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
            ts_v6=$(tailscale ip -6 2>/dev/null | head -n 1 || true)
            if [ -n "$ts_v4" ]; then
                ts_state="${gl_lv}已连接${gl_bai}  IPv4: ${gl_huang}${ts_v4}${gl_bai}${ts_v6:+  IPv6: ${gl_hui}${ts_v6}${gl_bai}}"
            else
                ts_state="${gl_huang}已安装 (未登录/未连接)${gl_bai}"
            fi
        else
            ts_state="${gl_hui}未安装${gl_bai}"
        fi

        echo -e "${gl_kjlan}=================== Tailscale 管理 ===================${gl_bai}"
        echo -e "状态: ${ts_state}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "1. 安装 / 升级 Tailscale"
        echo "2. 登录 / 启动连接 (支持 Auth Key、标签、Exit Node、SSH)"
        echo "3. 标签与运行选项管理 (Tags / Exit Node / 路由 / SSH / 开关)"
        echo "4. 查看节点状态与列表 (tailscale status)"
        echo "5. 网络与 DERP 延迟检测 (tailscale netcheck)"
        echo "6. Ping 指定 Tailscale 节点"
        echo "7. 卸载 Tailscale"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) vps_ts_install; break_end ;;
            2) vps_ts_up; break_end ;;
            3) vps_ts_manage_options ;;
            4) clear; vps_ts_need_binary && tailscale status; break_end ;;
            5) clear; vps_ts_need_binary && tailscale netcheck; break_end ;;
            6)
                vps_ts_need_binary || { break_end; continue; }
                read -r -e -p "请输入目标节点名或 Tailscale IP: " peer || return 0
                if [[ "$peer" =~ ^[A-Za-z0-9._:-]+$ ]]; then
                    tailscale ping "$peer"
                else
                    echo "节点名或 IP 格式无效" >&2
                fi
                break_end
                ;;
            7) vps_ts_uninstall; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---- END modules/network/tailscale.sh ----

# ---- BEGIN modules/ssh/fail2ban.sh ----
# ============ SSH 防爆破 (Fail2ban) ============

VPS_F2B_JAIL="/etc/fail2ban/jail.d/99-vps-toolbox-sshd.local"

vps_f2b_valid_ports() {
    local raw="$1" p
    local -a parts=()
    [ -n "$raw" ] || return 1
    IFS=',' read -r -a parts <<< "$raw"
    for p in "${parts[@]}"; do
        vps_valid_port "$p" || return 1
    done
}

vps_f2b_sync_port() {
    local new_port="$1"
    [ -f "$VPS_F2B_JAIL" ] && [ ! -L "$VPS_F2B_JAIL" ] || return 0
    vps_valid_port "$new_port" || return 1
    if grep -q '^port[[:space:]]*=' "$VPS_F2B_JAIL"; then
        sed -i "s|^port[[:space:]]*=.*|port = ${new_port}|" "$VPS_F2B_JAIL" || return 1
    else
        printf 'port = %s\n' "$new_port" >> "$VPS_F2B_JAIL" || return 1
    fi
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        restart fail2ban >/dev/null 2>&1 || true
    fi
    echo -e "${gl_lv}已同步更新 Fail2ban SSH 监控端口为 ${new_port}${gl_bai}"
}

vps_f2b_apply_config() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local ssh_port="$1" maxretry="${2:-5}" findtime="${3:-10m}" bantime="${4:-1h}"
    local backend="auto" candidate

    vps_f2b_valid_ports "$ssh_port" || { echo "端口格式无效: $ssh_port" >&2; return 1; }
    [[ "$maxretry" =~ ^[0-9]+$ ]] && ((10#$maxretry >= 1 && 10#$maxretry <= 50)) || {
        echo "maxretry 需为 1-50 的整数" >&2; return 1
    }
    [[ "$findtime" =~ ^[0-9]+[smhdw]?$ ]] || { echo "findtime 格式无效（如 10m / 1h）" >&2; return 1; }
    [[ "$bantime" =~ ^-?[0-9]+[smhdw]?$ ]] || { echo "bantime 格式无效（如 1h / 1d / -1）" >&2; return 1; }

    if ! command -v fail2ban-client >/dev/null 2>&1; then
        pkg_install fail2ban || return 1
    fi
    # Debian 12+ / Ubuntu 24.04+ 默认仅使用 systemd journald
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        if [ ! -f /var/log/auth.log ] && [ ! -f /var/log/secure ]; then
            backend="systemd"
            if command -v apt-get >/dev/null 2>&1; then
                pkg_install python3-systemd >/dev/null 2>&1 || true
            fi
        fi
    fi

    mkdir -p /etc/fail2ban/jail.d || return 1
    [ ! -L "$VPS_F2B_JAIL" ] || { echo "拒绝覆盖符号链接: $VPS_F2B_JAIL" >&2; return 1; }
    candidate=$(mktemp /etc/fail2ban/jail.d/.vps-f2b.XXXXXX) || return 1
    cat > "$candidate" <<EOF
# Managed by VPS Toolbox
[sshd]
enabled = true
port = ${ssh_port}
backend = ${backend}
maxretry = $((10#$maxretry))
findtime = ${findtime}
bantime = ${bantime}
EOF
    chmod 644 "$candidate" && mv -f -- "$candidate" "$VPS_F2B_JAIL" || { rm -f -- "$candidate"; return 1; }

    if command -v fail2ban-client >/dev/null 2>&1 && ! fail2ban-client -t >/dev/null 2>&1; then
        echo "Fail2ban 配置校验失败，已移除新建配置" >&2
        rm -f -- "$VPS_F2B_JAIL"
        return 1
    fi

    enable fail2ban >/dev/null 2>&1 || true
    restart fail2ban || return 1
    sleep 1
    echo -e "${gl_lv}Fail2ban SSH 防爆破已启用${gl_bai}（端口: ${ssh_port}, maxretry=${maxretry}, findtime=${findtime}, bantime=${bantime}）"
    fail2ban-client status sshd 2>/dev/null || true
}

vps_f2b_install_setup() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local detected_port ssh_port maxretry bantime findtime
    detected_port=$(vps_fw_ssh_port)

    read -r -e -p "SSH 监控端口 (回车使用检测值 ${detected_port}，多端口用逗号分隔如 22,57140): " ssh_port || return 0
    ssh_port="${ssh_port:-$detected_port}"
    ssh_port="${ssh_port// /}"

    read -r -e -p "最大失败次数 maxretry [默认 5]: " maxretry || return 0
    maxretry="${maxretry:-5}"

    read -r -e -p "检测时间窗口 findtime [默认 10m]: " findtime || return 0
    findtime="${findtime:-10m}"

    read -r -e -p "封禁时长 bantime [默认 1h]: " bantime || return 0
    bantime="${bantime:-1h}"

    vps_f2b_apply_config "$ssh_port" "$maxretry" "$findtime" "$bantime"
}

vps_f2b_unban() {
    command -v fail2ban-client >/dev/null 2>&1 || { echo "未安装 Fail2ban" >&2; return 1; }
    local ip
    read -r -e -p "请输入要解封的 IP 地址: " ip || return 0
    if ! vps_dns_valid_ipv4 "$ip" && ! vps_dns_valid_ipv6 "$ip"; then
        echo "IP 地址格式无效: $ip" >&2
        return 1
    fi
    fail2ban-client set sshd unbanip "$ip"
}

vps_ssh_failed_logs() {
    echo -e "${gl_kjlan}=== 最近 SSH 登录失败记录 (最多 20 条) ===${gl_bai}"
    if [ -d /run/systemd/system ] && command -v journalctl >/dev/null 2>&1; then
        journalctl -u ssh -u sshd --no-pager -n 200 2>/dev/null |
            grep -E 'Failed password|Invalid user|Connection closed by authenticating user' | tail -n 20
        echo ""
        echo -e "${gl_kjlan}=== 近期高频攻击来源 IP Top 10 ===${gl_bai}"
        journalctl -u ssh -u sshd --no-pager -n 2000 2>/dev/null |
            grep -Eo '(Failed password|Invalid user).*from [0-9a-fA-F.:]+' |
            awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 10
    elif [ -r /var/log/auth.log ]; then
        grep -E 'Failed password|Invalid user' /var/log/auth.log | tail -n 20
        echo ""
        echo -e "${gl_kjlan}=== 近期高频攻击来源 IP Top 10 ===${gl_bai}"
        grep -Eo '(Failed password|Invalid user).*from [0-9a-fA-F.:]+' /var/log/auth.log |
            awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 10
    elif [ -r /var/log/secure ]; then
        grep -E 'Failed password|Invalid user' /var/log/secure | tail -n 20
        echo ""
        echo -e "${gl_kjlan}=== 近期高频攻击来源 IP Top 10 ===${gl_bai}"
        grep -Eo '(Failed password|Invalid user).*from [0-9a-fA-F.:]+' /var/log/secure |
            awk '{print $NF}' | sort | uniq -c | sort -rn | head -n 10
    else
        echo "未找到可读的 SSH 日志源。"
    fi
}

vps_fail2ban_menu() {
    root_use || return
    local choice f2b_state banned_cnt
    while true; do
        clear
        if command -v fail2ban-client >/dev/null 2>&1; then
            if fail2ban-client ping >/dev/null 2>&1; then
                banned_cnt=$(fail2ban-client status sshd 2>/dev/null | awk -F: '/Currently banned/ {gsub(/[[:space:]]/,"",$2); print $2}')
                f2b_state="${gl_lv}运行中${gl_bai} (当前封禁 IP: ${gl_huang}${banned_cnt:-0}${gl_bai})"
            else
                f2b_state="${gl_huang}已安装但未运行${gl_bai}"
            fi
        else
            f2b_state="${gl_hui}未安装${gl_bai}"
        fi

        echo -e "${gl_kjlan}================ SSH 安全与 Fail2ban ================${gl_bai}"
        echo -e "Fail2ban 状态: ${f2b_state}"
        echo -e "${gl_kjlan}-----------------------------------------------------${gl_bai}"
        echo "1. 一键安装并配置 SSH 防爆破"
        echo "2. 查看 SSH 封禁状态与被封 IP"
        echo "3. 手动解封指定 IP"
        echo "4. 查看最近 SSH 登录失败日志 & Top 10 攻击 IP"
        echo "5. 移除工具箱 Fail2ban SSH 规则"
        echo -e "${gl_kjlan}-----------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}-----------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) vps_f2b_install_setup; break_end ;;
            2)
                clear
                if command -v fail2ban-client >/dev/null 2>&1; then
                    fail2ban-client status sshd || echo "sshd jail 未启用或服务未运行"
                else
                    echo "未安装 Fail2ban"
                fi
                break_end
                ;;
            3) vps_f2b_unban; break_end ;;
            4) clear; vps_ssh_failed_logs; break_end ;;
            5)
                if [ -f "$VPS_F2B_JAIL" ]; then
                    rm -f -- "$VPS_F2B_JAIL"
                    command -v fail2ban-client >/dev/null 2>&1 && restart fail2ban 2>/dev/null || true
                    echo "已移除工具箱 Fail2ban SSH 规则"
                else
                    echo "未找到工具箱创建的 Fail2ban 规则"
                fi
                break_end
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---- END modules/ssh/fail2ban.sh ----

# ---- BEGIN modules/system/diagnose.sh ----
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

# ---- END modules/system/diagnose.sh ----

# ---- BEGIN modules/system/timezone.sh ----
set_timedate() {
    local tz="${1:-}"
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    [[ "$tz" =~ ^[A-Za-z0-9_+/-]+$ ]] && [[ "$tz" != /* && "$tz" != *//* ]] || {
        echo "无效的时区: $tz" >&2
        return 1
    }
    [ -f "/usr/share/zoneinfo/$tz" ] || pkg_install tzdata || return 1
    [ -f "/usr/share/zoneinfo/$tz" ] || { echo "找不到时区: $tz" >&2; return 1; }
    if [ -d /run/systemd/system ] && command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-timezone "$tz" || return 1
    else
        [ ! -L /etc/timezone ] || { echo "拒绝覆盖 timezone 符号链接" >&2; return 1; }
        ln -sfnT "/usr/share/zoneinfo/$tz" /etc/localtime || return 1
        printf '%s\n' "$tz" > /etc/timezone || return 1
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
            *) echo "无效选择" ; sleep 1 ; continue ;;
        esac
        break_end
    done
}

# ============ 一键重装系统 ============


# ---- END modules/system/timezone.sh ----

# ---- BEGIN modules/system/optimize.sh ----
# ============ 一键系统优化 ============

VPS_OPT_SYSCTL="/etc/sysctl.d/99-vps-toolbox-optimize.conf"
VPS_OPT_LIMITS="/etc/security/limits.d/99-vps-toolbox.conf"
VPS_OPT_SYSTEMD_LIMITS="/etc/systemd/system.conf.d/99-vps-toolbox-limits.conf"
VPS_OPT_JOURNALD="/etc/systemd/journald.conf.d/99-vps-toolbox.conf"

vps_opt_apply_kernel() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local mem_mb rmem_max wmem_max tcp_rmem tcp_wmem candidate
    mem_mb=$(awk '/MemTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 512)

    # 按物理内存自适应缓冲区大小，防止小内存机器 OOM
    if [ "${mem_mb:-512}" -ge 2048 ]; then
        rmem_max=16777216
        wmem_max=16777216
        tcp_rmem="4096 87380 16777216"
        tcp_wmem="4096 65536 16777216"
    else
        rmem_max=4194304
        wmem_max=4194304
        tcp_rmem="4096 87380 4194304"
        tcp_wmem="4096 65536 4194304"
    fi

    bbr_on || echo "提示：BBR 开启未完全生效，继续应用其余内核优化。" >&2

    [ ! -L "$VPS_OPT_SYSCTL" ] || { echo "拒绝覆盖符号链接: $VPS_OPT_SYSCTL" >&2; return 1; }
    mkdir -p /etc/sysctl.d || return 1
    candidate=$(mktemp /etc/sysctl.d/.vps-opt.XXXXXX) || return 1
    cat > "$candidate" <<EOF
# Managed by VPS Toolbox
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.ipv4.tcp_rmem = ${tcp_rmem}
net.ipv4.tcp_wmem = ${tcp_wmem}
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fastopen = 3
vm.swappiness = 10
EOF
    chmod 644 "$candidate" && mv -f -- "$candidate" "$VPS_OPT_SYSCTL" || { rm -f -- "$candidate"; return 1; }
    sysctl -p "$VPS_OPT_SYSCTL" >/dev/null 2>&1 || true

    # 提升文件描述符上限至 65535
    if [ ! -L "$VPS_OPT_LIMITS" ]; then
        mkdir -p /etc/security/limits.d || return 1
        cat > "$VPS_OPT_LIMITS" <<EOF
# Managed by VPS Toolbox
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
        chmod 644 "$VPS_OPT_LIMITS"
    fi

    if [ -d /run/systemd/system ]; then
        if [ ! -L "$VPS_OPT_SYSTEMD_LIMITS" ]; then
            mkdir -p /etc/systemd/system.conf.d || return 1
            cat > "$VPS_OPT_SYSTEMD_LIMITS" <<EOF
# Managed by VPS Toolbox
[Manager]
DefaultLimitNOFILE=65535
EOF
            chmod 644 "$VPS_OPT_SYSTEMD_LIMITS"
            systemctl daemon-reexec >/dev/null 2>&1 || true
        fi

        if [ ! -L "$VPS_OPT_JOURNALD" ]; then
            mkdir -p /etc/systemd/journald.conf.d || return 1
            cat > "$VPS_OPT_JOURNALD" <<EOF
# Managed by VPS Toolbox
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7day
EOF
            chmod 644 "$VPS_OPT_JOURNALD"
            service_action restart systemd-journald >/dev/null 2>&1 || true
        fi
    fi

    echo -e "${gl_lv}内核网络、BBR、文件句柄 (65535) 与日志限制 (100M/7d) 优化已完成${gl_bai}"
}

vps_opt_auto_dns() {
    local country
    country=$(curl -fsS --proto '=https' --proto-redir '=https' --max-time 3 https://ipinfo.io/country 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$country" = "CN" ]; then
        echo "检测到国内网络环境，应用国内公共 DNS (223.5.5.5 / 119.29.29.29)..."
        vps_dns_apply "223.5.5.5" "119.29.29.29" "2400:3200::1" "2400:3200:baba::1"
    else
        echo "检测到海外网络环境，应用国际公共 DNS (1.1.1.1 / 8.8.8.8)..."
        vps_dns_apply "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888"
    fi
}

vps_opt_full_init() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    clear
    echo -e "${gl_kjlan}================== 新机一键优化与初始化 ==================${gl_bai}"
    echo "即将按顺序执行以下 8 项操作："
    echo "  1. 系统更新与清理"
    echo "  2. 安装基础工具 (curl wget sudo unzip nano vim) 与 Docker"
    echo "  3. 设置虚拟内存 Swap 为 1024M (1G)"
    echo "  4. 设置系统时区为 Asia/Shanghai"
    echo "  5. 自动优化 DNS 地址 (按地区匹配)"
    echo "  6. 设置网络为 IPv4 优先"
    echo "  7. 开启 BBR 加速 + 内核/文件句柄/日志调优"
    echo "  8. 安装并启用 Fail2ban SSH 防爆破 (自动适配当前 SSH 端口)"
    echo -e "${gl_kjlan}----------------------------------------------------------${gl_bai}"
    local confirm
    read -r -p "确认开始执行一键优化？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }

    local -a ok_steps=() fail_steps=()
    local ssh_port

    echo -e "\n${gl_huang}[1/8] 正在执行系统更新与清理...${gl_bai}"
    if linux_update && linux_clean; then ok_steps+=("系统更新与清理"); else fail_steps+=("系统更新与清理"); fi

    echo -e "\n${gl_huang}[2/8] 正在安装基础工具与 Docker...${gl_bai}"
    local base_ok=1
    pkg_install curl wget sudo unzip nano vim || base_ok=0
    if install_docker; then
        if [ ! -e /etc/docker/daemon.json ] && [ ! -L /etc/docker/daemon.json ]; then
            mkdir -p /etc/docker
            local d_cand
            if d_cand=$(mktemp /etc/docker/.daemon.json.vps.XXXXXX); then
                cat > "$d_cand" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
EOF
                chmod 644 "$d_cand" && mv -f -- "$d_cand" /etc/docker/daemon.json && restart docker >/dev/null 2>&1 || rm -f -- "$d_cand"
                echo -e "${gl_lv}已自动配置 Docker 日志轮转 (max-size=20m, max-file=3)${gl_bai}"
            fi
        fi
    else
        base_ok=0
    fi
    if [ "$base_ok" -eq 1 ]; then ok_steps+=("基础工具与 Docker"); else fail_steps+=("基础工具与 Docker"); fi

    echo -e "\n${gl_huang}[3/8] 正在设置虚拟内存 (1024M)...${gl_bai}"
    if add_swap 1024; then ok_steps+=("虚拟内存 1024M"); else fail_steps+=("虚拟内存 1024M"); fi

    echo -e "\n${gl_huang}[4/8] 正在设置系统时区为 Asia/Shanghai...${gl_bai}"
    if set_timedate Asia/Shanghai; then ok_steps+=("时区 Asia/Shanghai"); else fail_steps+=("时区 Asia/Shanghai"); fi

    echo -e "\n${gl_huang}[5/8] 正在自动优化 DNS 地址...${gl_bai}"
    if vps_opt_auto_dns; then ok_steps+=("自动优化 DNS"); else fail_steps+=("自动优化 DNS"); fi

    echo -e "\n${gl_huang}[6/8] 正在设置 IPv4 优先...${gl_bai}"
    if vps_set_ip_preference 4; then ok_steps+=("IPv4 优先"); else fail_steps+=("IPv4 优先"); fi

    echo -e "\n${gl_huang}[7/8] 正在开启 BBR 加速并应用内核/句柄/日志优化...${gl_bai}"
    if vps_opt_apply_kernel; then ok_steps+=("BBR 与内核优化"); else fail_steps+=("BBR 与内核优化"); fi

    echo -e "\n${gl_huang}[8/8] 正在安装并配置 Fail2ban SSH 防爆破...${gl_bai}"
    ssh_port=$(vps_fw_ssh_port)
    if vps_f2b_apply_config "$ssh_port" 5 10m 1h; then ok_steps+=("Fail2ban (端口 $ssh_port)"); else fail_steps+=("Fail2ban"); fi

    echo -e "\n${gl_kjlan}==================== 一键优化执行汇总 ====================${gl_bai}"
    if [ "${#ok_steps[@]}" -gt 0 ]; then
        echo -e "${gl_lv}已完成 (${#ok_steps[@]}/8):${gl_bai} ${ok_steps[*]}"
    fi
    if [ "${#fail_steps[@]}" -gt 0 ]; then
        echo -e "${gl_hong}未完成/需检查 (${#fail_steps[@]}/8):${gl_bai} ${fail_steps[*]}"
    fi
    echo "提示：文件句柄 (nofile 65535) 将在新打开的 SSH 会话与新启动服务中生效。"
}

vps_opt_status() {
    local cc qd swap_m tz ipc dns_str docker_ver f2b_str nofile_lim
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
    swap_m=$(awk '/SwapTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    tz=$(current_timezone)
    if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100' /etc/gai.conf 2>/dev/null; then
        ipc="IPv4 优先"
    else
        ipc="系统默认"
    fi
    dns_str=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
    docker_ver=$(docker --version 2>/dev/null || echo "未安装")
    if command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client ping >/dev/null 2>&1; then
        f2b_str="运行中"
    elif command -v fail2ban-client >/dev/null 2>&1; then
        f2b_str="已安装未运行"
    else
        f2b_str="未安装"
    fi
    nofile_lim=$(ulimit -n 2>/dev/null || echo "未知")

    echo -e "${gl_kjlan}==================== 当前优化状态 ====================${gl_bai}"
    echo -e "BBR / 队列算法:    ${gl_lv}${cc} / ${qd}${gl_bai}"
    echo -e "内核优化配置:      $([ -f "$VPS_OPT_SYSCTL" ] && echo -e "${gl_lv}已启用${gl_bai}" || echo -e "${gl_hui}未启用${gl_bai}")"
    echo -e "文件句柄限制:      当前会话 ${nofile_lim} / 配置 $([ -f "$VPS_OPT_LIMITS" ] && echo -e "${gl_lv}65535${gl_bai}" || echo -e "${gl_hui}默认${gl_bai}")"
    echo -e "日志体积限制:      $([ -f "$VPS_OPT_JOURNALD" ] && echo -e "${gl_lv}100M / 7天${gl_bai}" || echo -e "${gl_hui}系统默认${gl_bai}")"
    echo -e "虚拟内存 (Swap):   ${gl_huang}${swap_m}M${gl_bai}"
    echo -e "系统时区:          ${tz}"
    echo -e "网络优先级:        ${ipc}"
    echo -e "当前 DNS:          ${dns_str:-系统默认}"
    echo -e "Docker:            ${docker_ver}"
    echo -e "Fail2ban:          ${f2b_str}"
    echo -e "${gl_kjlan}======================================================${gl_bai}"
}

vps_opt_revert() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local confirm
    read -r -p "将移除工具箱写入的内核/句柄/日志调优配置，继续？(Y/N): " confirm || return 0
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; return 0; }
    rm -f -- "$VPS_OPT_SYSCTL" "$VPS_OPT_LIMITS" "$VPS_OPT_SYSTEMD_LIMITS" "$VPS_OPT_JOURNALD"
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reexec >/dev/null 2>&1 || true
        service_action restart systemd-journald >/dev/null 2>&1 || true
    fi
    sysctl --system >/dev/null 2>&1 || true
    echo -e "${gl_lv}已移除工具箱调优配置（BBR/Swap/Docker/Fail2ban 保持不变）${gl_bai}"
}

vps_optimize_menu() {
    root_use || return
    local choice
    while true; do
        clear
        echo -e "${gl_kjlan}==================== 一键系统优化 ====================${gl_bai}"
        echo -e "1. ${gl_lv}新机一键全套初始化与优化${gl_bai}"
        echo -e "   ${gl_hui}(更新清理 + 基础工具/Docker + 1G Swap + 上海时区 + DNS + IPv4优先 + BBR/内核调优 + Fail2ban)${gl_bai}"
        echo "2. 仅执行轻量内核调优 (BBR + TCP + 文件句柄 65535 + 日志限制)"
        echo "3. 查看当前优化状态"
        echo "4. 还原工具箱内核/句柄/日志调优配置"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case "$choice" in
            1) vps_opt_full_init; break_end ;;
            2) vps_opt_apply_kernel; break_end ;;
            3) clear; vps_opt_status; break_end ;;
            4) vps_opt_revert; break_end ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

# ---- END modules/system/optimize.sh ----

# ---- BEGIN modules/reinstall/reinstall.sh ----
vps_dd_upstream_valid_key() {
    local key="$1"
    # bin456789/reinstall 仅接受 rsa / ed25519 / ecdsa-sha2-nistp256|384|521
    [[ "$key" =~ ^(ecdsa-sha2-nistp(256|384|521)|ssh-(ed25519|rsa))[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] &&
        vps_ssh_valid_key "$key"
}

vps_dd_execute() {
    local is_windows="$1"
    shift
    local -a os_args=("$@")
    local os_display="${os_args[*]}"
    local default_port="22" default_user="root"
    [ "$is_windows" = true ] && { default_port="3389"; default_user="Administrator"; }

    # 仅 Linux 重装时自动获取当前 SSH 端口，避免覆盖 Windows 默认 RDP 端口 (3389)
    if [ "$is_windows" != true ]; then
        local current_port
        current_port=$("$(command -v sshd || echo /usr/sbin/sshd)" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
        [ -n "$current_port" ] && default_port="$current_port"
    fi

    clear
    echo -e "${gl_kjlan}==================== 重装系统参数配置 ====================${gl_bai}"
    echo -e "目标系统: ${gl_huang}${os_display}${gl_bai}"
    echo -e "${gl_hong}警告: 重装系统会彻底格式化主硬盘，一旦确认不可逆转！${gl_bai}"
    echo "--------------------------------------------------------"

    local auth_display="" auth_type="password"
    local -a auth_args=() port_args=() final_cmd=()
    pkg_install curl ca-certificates >/dev/null 2>&1

    if [ "$is_windows" = true ]; then
        local win_pwd
        read -r -p "设置 Windows 密码 (回车自动生成16位高强度密码): " win_pwd
        if [ -z "$win_pwd" ]; then
            win_pwd=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9_' | head -c 16)
        fi
        auth_args=(--password "$win_pwd")
        auth_display="密码: ${gl_huang}${win_pwd}${gl_bai}"
    else
        echo "请选择登录凭据类型:"
        echo "1. 自动生成 16 位强随机密码 (默认)"
        echo "2. 自定义密码"
        echo "3. 从 GitHub 导入公钥 (纯密钥登录)"
        echo "4. 手动粘贴 SSH 公钥 (纯密钥登录)"
        echo "5. 沿用当前服务器 ~/.ssh/authorized_keys (纯密钥登录)"
        local cred_choice
        read -r -p "请选择 [1-5]: " cred_choice
        cred_choice=${cred_choice:-1}

        case "$cred_choice" in
            3)
                local gh_user tmp_keys valid_count=0 skipped_count=0 line
                read -r -p "请输入你的 GitHub 用户名: " gh_user
                if [[ ! "$gh_user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
                    echo "错误: GitHub 用户名无效！" >&2; break_end; return 1
                fi
                echo "正在拉取 GitHub 公钥..."
                tmp_keys=$(mktemp /tmp/vps-dd-keys.XXXXXX) || return 1
                if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 "${gh_proxy}github.com/${gh_user}.keys" -o "$tmp_keys"; then
                    rm -f -- "$tmp_keys"
                    echo "错误: 拉取 GitHub 公钥失败！" >&2; break_end; return 1
                fi
                while IFS= read -r line || [ -n "$line" ]; do
                    line=${line%$'\r'}
                    [ -z "$line" ] && continue
                    if vps_dd_upstream_valid_key "$line"; then
                        valid_count=$((valid_count + 1))
                        auth_args+=(--ssh-key "$line")
                    else
                        skipped_count=$((skipped_count + 1))
                    fi
                done < "$tmp_keys"
                rm -f -- "$tmp_keys"
                if [ "$valid_count" -gt 0 ]; then
                    auth_type="key"
                    auth_display="【纯密钥登录】(GitHub: $gh_user 共 $valid_count 把兼容公钥${skipped_count:+，已跳过 $skipped_count 把不兼容类型})"
                else
                    echo "错误: 未找到上游兼容的公钥（需为 ed25519 / rsa / ecdsa）！" >&2; break_end; return 1
                fi
                ;;
            4)
                local pasted_key
                read -r -e -p "请粘贴 SSH 公钥 (ssh-ed25519 / ssh-rsa / ecdsa): " pasted_key
                if ! vps_dd_upstream_valid_key "$pasted_key"; then
                    echo "错误: 公钥格式无效或上游脚本不支持该密钥类型！" >&2; break_end; return 1
                fi
                auth_args=(--ssh-key "$pasted_key")
                auth_type="key"
                auth_display="【纯密钥登录】(手动粘贴 1 把公钥)"
                ;;
            5)
                local local_auth="/root/.ssh/authorized_keys" valid_count=0 skipped_count=0 line
                if [ ! -f "$local_auth" ]; then
                    echo "错误: 未找到 $local_auth" >&2; break_end; return 1
                fi
                while IFS= read -r line || [ -n "$line" ]; do
                    line=${line%$'\r'}
                    [ -z "$line" ] && continue
                    [[ "$line" == \#* ]] && continue
                    if vps_dd_upstream_valid_key "$line"; then
                        valid_count=$((valid_count + 1))
                        auth_args+=(--ssh-key "$line")
                    else
                        skipped_count=$((skipped_count + 1))
                    fi
                done < "$local_auth"
                if [ "$valid_count" -gt 0 ]; then
                    auth_type="key"
                    auth_display="【纯密钥登录】(沿用本机 $valid_count 把兼容公钥${skipped_count:+，已跳过 $skipped_count 把})"
                else
                    echo "错误: $local_auth 中未找到上游兼容的公钥！" >&2; break_end; return 1
                fi
                ;;
            2)
                local custom_pwd
                read -r -s -p "请输入自定义登录密码: " custom_pwd
                echo
                auth_args=(--password "${custom_pwd:-root}")
                auth_display="密码: ${gl_huang}${custom_pwd:-root}${gl_bai}"
                ;;
            *)
                local rand_pwd
                rand_pwd=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9_' | head -c 16)
                auth_args=(--password "$rand_pwd")
                auth_display="密码: ${gl_huang}${rand_pwd}${gl_bai}"
                ;;
        esac
    fi

    local custom_port
    read -r -p "设置远程连接端口 (回车保持当前 ${default_port}): " custom_port
    custom_port=${custom_port:-$default_port}
    if ! vps_valid_port "$custom_port"; then
        echo "错误: 端口无效（需为 1-65535 的整数）！" >&2; break_end; return 1
    fi
    custom_port=$((10#$custom_port))

    if [ "$is_windows" = true ]; then
        [ "$custom_port" != "3389" ] && port_args=(--rdp-port "$custom_port")
    else
        [ "$custom_port" != "22" ] && port_args=(--ssh-port "$custom_port")
    fi

    echo "--------------------------------------------------------"
    echo -e "重装后登录信息汇总："
    echo -e "用户名:   ${gl_lv}${default_user}${gl_bai}"
    echo -e "认证方式: ${auth_display}"
    echo -e "远程端口: ${gl_lv}${custom_port}${gl_bai}"
    echo "--------------------------------------------------------"
    [ "$auth_type" = "password" ] && echo -e "${gl_hong}请务必保存上方密码！${gl_bai}"

    read -r -p "确认执行重装？(Y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "已取消"; break_end; return 0; }

    echo -e "${gl_kjlan}正在准备底层重装环境...${gl_bai}"
    local reinstall_sh
    reinstall_sh=$(mktemp /tmp/vps-reinstall.XXXXXX) || return 1
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 "${gh_proxy}raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" -o "$reinstall_sh" \
       && [ -s "$reinstall_sh" ] && bash -n "$reinstall_sh"; then
        # DD 镜像不接受 user/password 参数
        if [ "${os_args[0]:-}" = "dd" ]; then
            final_cmd=(bash "$reinstall_sh" "${os_args[@]}" "${port_args[@]}")
        else
            final_cmd=(bash "$reinstall_sh" "${os_args[@]}" --user "$default_user" "${auth_args[@]}" "${port_args[@]}")
        fi

        if "${final_cmd[@]}"; then
            rm -f -- "$reinstall_sh"
            echo -e "${gl_lv}准备完毕，服务器将自动重启安装...${gl_bai}"
            sleep 3; reboot
        else
            rm -f -- "$reinstall_sh"
            echo "重装脚本执行失败！" >&2; break_end
        fi
    else
        rm -f -- "$reinstall_sh"
        echo "下载或校验重装脚本失败！" >&2; break_end
    fi
}

vps_dd_menu() {
    root_use || return
    while true; do
        clear
        echo -e "${gl_kjlan}===================== 一键重装系统 =====================${gl_bai}"
        echo -e "${gl_hong}注意: 纯内存在线重装，会抹除系统盘全部数据，请提前备份！${gl_bai}"
        echo "--------------------------------------------------------"
        echo "1. Debian 系列     (Debian 10 / 11 / 12 / 13)"
        echo "2. Ubuntu 系列     (Ubuntu 20.04 / 22.04 / 24.04 / 26.04)"
        echo "3. RHEL / CentOS系 (Rocky / AlmaLinux / CentOS / Oracle / Fedora)"
        echo "4. 轻量与独立发行版 (Alpine / Arch / Kali / openSUSE / openEuler)"
        echo "5. Windows 全系列  (Win 10 / 11 / Server 2019 / 2022 / 2025 / ARM)"
        echo "6. 自定义发行版参数 (例如 debian 13 / fedora 44)"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo "0. 返回上一级"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        read -r -e -p "请选择系统大类: " cat_choice || return 0

        case "$cat_choice" in
            1)
                clear
                echo "Debian 系列版本选择:"
                echo "1. Debian 13 (Trixie)"
                echo "2. Debian 12 (Bookworm)"
                echo "3. Debian 11 (Bullseye)"
                echo "4. Debian 10 (Buster)"
                echo "0. 返回"
                read -r -e -p "请选择版本: " v_choice || return 0
                case "$v_choice" in
                    1) vps_dd_execute false debian 13 ;;
                    2) vps_dd_execute false debian 12 ;;
                    3) vps_dd_execute false debian 11 ;;
                    4) vps_dd_execute false debian 10 ;;
                    *) continue ;;
                esac
                ;;
            2)
                clear
                echo "Ubuntu 系列版本选择:"
                echo "1. Ubuntu 24.04 LTS (Noble)"
                echo "2. Ubuntu 22.04 LTS (Jammy)"
                echo "3. Ubuntu 20.04 LTS (Focal)"
                echo "4. Ubuntu 26.04 (Rolling)"
                echo "0. 返回"
                read -r -e -p "请选择版本: " v_choice || return 0
                case "$v_choice" in
                    1) vps_dd_execute false ubuntu 24.04 ;;
                    2) vps_dd_execute false ubuntu 22.04 ;;
                    3) vps_dd_execute false ubuntu 20.04 ;;
                    4) vps_dd_execute false ubuntu 26.04 ;;
                    *) continue ;;
                esac
                ;;
            3)
                clear
                echo "RHEL / CentOS 系列版本选择:"
                echo "1. Rocky Linux 9"
                echo "2. Rocky Linux 10"
                echo "3. AlmaLinux 9"
                echo "4. AlmaLinux 10"
                echo "5. CentOS 9 Stream"
                echo "6. CentOS 10 Stream"
                echo "7. Oracle Linux 9"
                echo "8. Oracle Linux 10"
                echo "9. Fedora 43"
                echo "0. 返回"
                read -r -e -p "请选择版本: " v_choice || return 0
                case "$v_choice" in
                    1) vps_dd_execute false rocky 9 ;;
                    2) vps_dd_execute false rocky 10 ;;
                    3) vps_dd_execute false almalinux 9 ;;
                    4) vps_dd_execute false almalinux 10 ;;
                    5) vps_dd_execute false centos 9 ;;
                    6) vps_dd_execute false centos 10 ;;
                    7) vps_dd_execute false oracle 9 ;;
                    8) vps_dd_execute false oracle 10 ;;
                    9) vps_dd_execute false fedora 43 ;;
                    *) continue ;;
                esac
                ;;
            4)
                clear
                echo "轻量与独立发行版选择:"
                echo "1. Alpine Linux (超轻量，极省内存)"
                echo "2. Arch Linux"
                echo "3. Kali Linux"
                echo "4. openSUSE Tumbleweed"
                echo "5. openEuler"
                echo "0. 返回"
                read -r -e -p "请选择版本: " v_choice || return 0
                case "$v_choice" in
                    1) vps_dd_execute false alpine ;;
                    2) vps_dd_execute false arch ;;
                    3) vps_dd_execute false kali ;;
                    4) vps_dd_execute false opensuse ;;
                    5) vps_dd_execute false openeuler ;;
                    *) continue ;;
                esac
                ;;
            5)
                clear
                echo "Windows 系列选择 (请确保 VPS 内存 >= 2GB):"
                echo "1. Windows 11 Pro (官方 ISO)"
                echo "2. Windows 10 Pro (官方 ISO)"
                echo "3. Windows Server 2025 Datacenter (官方 ISO)"
                echo "4. Windows Server 2022 Datacenter (官方 ISO)"
                echo "5. Windows Server 2019 Datacenter (官方 ISO)"
                echo "6. Windows 11 ARM64 (第三方 DD 镜像，适用于甲骨文 ARM)"
                echo "0. 返回"
                read -r -e -p "请选择版本: " v_choice || return 0
                case "$v_choice" in
                    1) vps_dd_execute true windows --image-name "Windows 11 Pro" --lang zh-cn ;;
                    2) vps_dd_execute true windows --image-name "Windows 10 Pro" --lang zh-cn ;;
                    3) vps_dd_execute true windows --image-name "Windows Server 2025 SERVERDATACENTER" --lang zh-cn ;;
                    4) vps_dd_execute true windows --image-name "Windows Server 2022 SERVERDATACENTER" --lang zh-cn ;;
                    5) vps_dd_execute true windows --image-name "Windows Server 2019 SERVERDATACENTER" --lang zh-cn ;;
                    6) vps_dd_execute true dd --img "https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz" ;;
                    *) continue ;;
                esac
                ;;
            6)
                local custom_os
                local -a custom_args=()
                read -r -e -p "输入上游 reinstall.sh 的发行版参数 (如 debian 13 或 fedora 44): " custom_os || return 0
                [ -n "$custom_os" ] || continue
                read -r -a custom_args <<< "$custom_os"
                vps_dd_execute false "${custom_args[@]}"
                ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

# ============ 系统工具菜单 ============

# ---- END modules/reinstall/reinstall.sh ----

# ---- BEGIN menus/settings.sh ----
linux_settings() {
    while true; do
        clear
        # 毫秒级读取当前状态，用于回显展示
        local cur_port cur_swap cur_tz cur_ipc cur_host cur_dns
        cur_port=$("$(command -v sshd || echo /usr/sbin/sshd)" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
        [ -z "$cur_port" ] && cur_port="22"

        local s_total
        s_total=$(awk '/SwapTotal:/ {print int(($2+512)/1024)}' /proc/meminfo 2>/dev/null || echo 0)
        [ "$s_total" -gt 0 ] && cur_swap="${s_total}M" || cur_swap="未开启"

        cur_tz=$(current_timezone)
        cur_host=$(uname -n)

        if grep -Eq '^\s*precedence\s+::ffff:0:0/96\s+100' /etc/gai.conf 2>/dev/null; then
            cur_ipc="IPv4 优先"
        else
            cur_ipc="系统默认"
        fi

        cur_dns=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null | awk '{print $1,$2}')
        [ -z "$cur_dns" ] && cur_dns="系统默认"

        echo -e "${gl_kjlan}======================= 系统工具 =======================${gl_bai}"
        echo -e "${gl_huang}【 安全与访问 】${gl_bai}"
        printf " %-3s %-20s ${gl_hui}[命令: %s]${gl_bai}\n" "1." "设置脚本快捷键" "${VPS_DEFAULT_SHORTCUT}"
        printf " %-3s %-20s ${gl_hui}[用户: root]${gl_bai}\n" "2." "修改登录密码"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "3." "修改 SSH 端口" "${cur_port}"
        printf " %-3s %-20s ${gl_hui}[安全加固/公钥管理]${gl_bai}\n" "4." "用户密钥登录模式"
        printf " %-3s %-20s ${gl_hui}[防爆破/封禁管理]${gl_bai}\n" "5." "SSH 安全与 Fail2ban"
        echo ""
        echo -e "${gl_huang}【 系统与环境 】${gl_bai}"
        printf " %-3s %-20s ${gl_lv}[新机全套/内核调优]${gl_bai}\n" "6." "一键系统优化"
        printf " %-3s %-20s ${gl_hui}[主机: %s]${gl_bai}\n" "7." "修改主机名" "${cur_host}"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "8." "修改虚拟内存 (Swap)" "${cur_swap}"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "9." "设置系统时区" "${cur_tz}"
        printf " %-3s %-20s ${gl_hong}[纯内存在线重装]${gl_bai}\n" "10." "一键重装系统"
        printf " %-3s %-20s\n" "11." "一键重启服务器"
        printf " %-3s %-20s ${gl_hui}[大目录/Top 进程]${gl_bai}\n" "12." "磁盘与负载排查"
        echo ""
        echo -e "${gl_huang}【 网络与规则 】${gl_bai}"
        printf " %-3s %-20s ${gl_hui}[当前: %s]${gl_bai}\n" "13." "优化 DNS 地址" "${cur_dns}"
        printf " %-3s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "14." "设置 IPv4 地址优先级" "${cur_ipc}"
        printf " %-3s %-20s ${gl_lv}[UFW / Firewalld]${gl_bai}\n" "15." "防火墙管理"
        printf " %-3s %-20s ${gl_hong}[清空 IPv4 filter 表]${gl_bai}\n" "16." "开放 IPv4 防火墙端口"
        printf " %-3s %-20s ${gl_hui}[ss 监听列表]${gl_bai}\n" "17." "查看本机端口占用"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo " 0.  返回主菜单"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1) vps_set_shortcut ;;
            2) set_root_password ; break_end ;;
            3) change_ssh_port ;;
            4) vps_ssh_key_menu ;;
            5) vps_fail2ban_menu ;;
            6) vps_optimize_menu ;;
            7)
                root_use || continue
                read -r -e -p "请输入新主机名: " new_hostname || return 0
                [ -z "$new_hostname" ] || vps_set_hostname "$new_hostname"
                break_end
                ;;
            8)
                clear
                echo -e "当前虚拟内存: ${gl_huang}${cur_swap}${gl_bai}"
                read -r -e -p "输入新的 swap 大小 (MB，输入 0 退出): " swap_size || return 0
                [ "$swap_size" != "0" ] && [ -n "$swap_size" ] && add_swap "$swap_size"
                break_end
                ;;
            9) timezone_menu ;;
            10) vps_dd_menu ;;
            11) server_reboot ;;
            12) vps_diag_menu ;;
            13) vps_dns_menu ;;
            14)
                root_use || continue
                clear
                echo -e "当前优先级: ${gl_huang}${cur_ipc}${gl_bai}"
                echo "1. IPv4 优先    2. 移除工具箱的 IPv4 优先设置"
                read -r -e -p "请选择: " ipc || return 0
                case $ipc in
                    1) vps_set_ip_preference 4 ;;
                    2) vps_set_ip_preference default ;;
                esac
                break_end
                ;;
            15) vps_firewall_menu ;;
            16)
                root_use || continue
                if command -v docker >/dev/null 2>&1 || command -v ufw >/dev/null 2>&1 || command -v firewall-cmd >/dev/null 2>&1; then
                    echo "检测到 Docker 或防火墙管理器，请通过对应管理器调整端口，避免破坏现有规则。"
                    break_end
                    continue
                fi
                echo "仅清空 IPv4 iptables filter 表；IPv6、nftables 和云安全组需单独管理。"
                read -r -p "输入 OPEN 清空 IPv4 filter 规则并放行: " confirm || return 0
                [ "$confirm" = OPEN ] || continue
                pkg_install iptables || continue
                local firewall_backup
                firewall_backup=$(mktemp /root/vps-iptables.XXXXXX.rules) || continue
                chmod 600 "$firewall_backup"
                if ! iptables-save > "$firewall_backup"; then
                    echo "备份失败，未修改规则" >&2
                elif iptables -P INPUT ACCEPT && iptables -P FORWARD ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F; then
                    echo "IPv4 filter 规则已开放；备份: $firewall_backup"
                else
                    if iptables-restore < "$firewall_backup"; then
                        echo "修改失败，已恢复备份" >&2
                    else
                        echo "恢复失败，请通过控制台使用备份: $firewall_backup" >&2
                    fi
                fi
                break_end
                ;;
            17) clear; ss -tulnape; break_end ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

# ============ 快捷键设置 ============


# ---- END menus/settings.sh ----

# ---- BEGIN core/shortcut.sh ----
vps_set_shortcut() {
    root_use || return
    while true; do
        clear
        read -r -e -p "请输入快捷键名（输入 0 退出）: " key || return 0
        [ "$key" = "0" ] && return

        if [[ ! "$key" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
            echo "快捷键只能包含字母、数字、点、下划线和短横线"
            break_end
            continue
        fi

        if command -v "$key" >/dev/null 2>&1 && [ "$(readlink -f "$(command -v "$key")")" != "$VPS_INSTALL_PATH" ]; then
            echo "错误: 名称 [$key] 与系统现有命令冲突，请更换一个名字！" >&2
            break_end
            continue
        fi

        local source_path
        source_path="$(readlink -f "${BASH_SOURCE[0]}")"
        if { [ -e "/usr/local/bin/$key" ] || [ -L "/usr/local/bin/$key" ]; } &&
           [ "$(readlink -f "/usr/local/bin/$key")" != "$VPS_INSTALL_PATH" ]; then
            echo "快捷键 $key 已被其他程序使用" >&2
            break_end
            continue
        fi
        [ -f "$source_path" ] || {
            echo "无法从当前启动方式安装，请先下载脚本文件后运行" >&2
            break_end
            continue
        }
        vps_ensure_install "$source_path" || return 1
        if [ "/usr/local/bin/$key" != "$VPS_INSTALL_PATH" ]; then
            ln -sfnT "$VPS_INSTALL_PATH" "/usr/local/bin/$key" || return 1
        fi
        echo -e "${gl_lv}快捷键已设置${gl_bai}: 输入 ${gl_huang}$key${gl_bai} 启动脚本"
        break_end
        return
    done
}

# ============ 脚本更新 ============


# ---- END core/shortcut.sh ----

# ---- BEGIN core/updater.sh ----
vps_version_value() {
    local version="$1" major minor patch
    [[ "$version" =~ ^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$ ]] || return 1
    IFS=. read -r major minor patch <<< "$version"
    printf '%s\n' "$((10#$major * 1000000000000 + 10#$minor * 1000000 + 10#$patch))"
}

vps_update() {
    clear
    echo "脚本更新"
    echo "------------------------"
    echo -e "当前版本: ${gl_huang}v$sh_v${gl_bai}"
    echo "------------------------"

    if [ -z "$VPS_UPDATE_URL" ]; then
        echo "尚未配置在线更新地址"
        echo "请设置环境变量 VPS_UPDATE_URL 后再试"
        break_end
        return 1
    fi

    if [ "$(id -u)" -ne 0 ]; then
        echo "需要 root 权限才能更新"
        break_end
        return 1
    fi

    [[ "$VPS_UPDATE_URL" == https://* ]] || {
        echo "更新地址必须使用 HTTPS" >&2; break_end; return 1;
    }
    command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates || return 1
    local tmp_file sha_file expected_sha actual_sha new_ver new_value current_ver="$sh_v" current_value result=0 installed_ver
    if [ -e "$VPS_INSTALL_PATH" ] || [ -L "$VPS_INSTALL_PATH" ]; then
        vps_is_toolbox "$VPS_INSTALL_PATH" || { echo "安装文件无效，未更新" >&2; return 1; }
        installed_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2)
        if [ "$(vps_version_value "$installed_ver" || echo 0)" -gt "$(vps_version_value "$current_ver")" ]; then
            current_ver="$installed_ver"
        fi
    fi
    current_value=$(vps_version_value "$current_ver") || return 1
    tmp_file=$(mktemp /tmp/vps-toolbox.XXXXXX) || return 1
    sha_file=$(mktemp /tmp/vps-toolbox-sha.XXXXXX) || { rm -f -- "$tmp_file"; return 1; }

    echo "正在下载更新..."
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 -o "$tmp_file" "$VPS_UPDATE_URL" \
       && [ -s "$tmp_file" ] \
       && head -1 "$tmp_file" | grep -q '^#!/bin/bash' \
       && vps_is_toolbox "$tmp_file"; then

        if command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1; then
            if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 -o "$sha_file" "${VPS_UPDATE_URL}.sha256"; then
                rm -f -- "$tmp_file" "$sha_file"
                echo -e "${gl_hong}更新失败：无法下载 SHA256 校验文件${gl_bai}" >&2
                break_end
                return 1
            fi
            expected_sha=$(awk '{print $1; exit}' "$sha_file")
            if command -v sha256sum >/dev/null 2>&1; then
                actual_sha=$(sha256sum "$tmp_file" | awk '{print $1}')
            else
                actual_sha=$(shasum -a 256 "$tmp_file" | awk '{print $1}')
            fi
            if [[ ! "$expected_sha" =~ ^[0-9a-fA-F]{64}$ ]] || [[ "${expected_sha,,}" != "${actual_sha,,}" ]]; then
                rm -f -- "$tmp_file" "$sha_file"
                echo -e "${gl_hong}更新失败：SHA256 完整性校验未通过${gl_bai}" >&2
                break_end
                return 1
            fi
        fi

        new_ver=$(grep '^sh_v=' "$tmp_file" | head -1 | cut -d'"' -f2)
        if ! new_value=$(vps_version_value "$new_ver"); then
            rm -f -- "$tmp_file" "$sha_file"
            echo "更新失败：新脚本缺少有效版本号" >&2
            break_end
            return 1
        fi

        if [ "$new_value" -le "$current_value" ]; then
            echo "下载版本 v$new_ver 不高于当前版本 v$current_ver，已保留当前版本"
            rm -f -- "$tmp_file" "$sha_file"
            break_end
            return
        fi

        if ! vps_atomic_install "$tmp_file" "$VPS_INSTALL_PATH"; then
            rm -f -- "$tmp_file" "$sha_file"
            echo "更新失败：无法写入安装目录" >&2
            break_end
            return 1
        fi
        rm -f -- "$tmp_file" "$sha_file"
        echo -e "${gl_lv}脚本已更新到 v$new_ver${gl_bai}（SHA256 校验通过）"
        echo "重新启动 $VPS_INSTALL_PATH 后使用新版；旧版本备份: ${VPS_INSTALL_PATH}.bak（如更新前已安装）"
    else
        rm -f -- "$tmp_file" "$sha_file"
        echo -e "${gl_hong}更新失败：下载或校验未通过${gl_bai}"
        result=1
    fi
    break_end
    return "$result"
}

# ============ 主菜单 ============


# ---- END core/updater.sh ----

# ---- BEGIN menus/main_menu.sh ----
vps_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}"
        echo "╦  ╦╔═╗╔═╗  ╔╦╗╔═╗╔═╗╦  ╔╗ ╔═╗═╗ ╦"
        echo "╚╗╔╝╠═╝╚═╗   ║ ║ ║║ ║║  ╠╩╗║ ║╔╩╦╝"
        echo " ╚╝ ╩  ╚═╝   ╩ ╚═╝╚═╝╩═╝╚═╝╚═╝╩ ╚═"
        echo -e "${gl_bai}VPS 工具箱 v$sh_v"
        if command -v "$VPS_DEFAULT_SHORTCUT" >/dev/null 2>&1; then
            echo -e "命令行输入 ${gl_huang}${VPS_DEFAULT_SHORTCUT}${gl_bai} 可快速启动"
        else
            echo "可在系统工具中设置快捷键"
        fi
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo -e "${gl_kjlan}1.${gl_bai}   系统信息查询"
        echo -e "${gl_kjlan}2.${gl_bai}   系统更新"
        echo -e "${gl_kjlan}3.${gl_bai}   系统清理"
        echo -e "${gl_kjlan}4.${gl_bai}   基础工具"
        echo -e "${gl_kjlan}5.${gl_bai}   BBR 管理"
        echo -e "${gl_kjlan}6.${gl_bai}   Docker 管理"
        echo -e "${gl_kjlan}7.${gl_bai}   WARP 管理"
        echo -e "${gl_kjlan}8.${gl_bai}   测试脚本合集"
        echo -e "${gl_kjlan}9.${gl_bai}   系统工具"
        echo -e "${gl_kjlan}10.${gl_bai}  Caddy 管理"
        echo -e "${gl_kjlan}11.${gl_bai}  Tailscale 管理"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo -e "${gl_kjlan}00.${gl_bai}  脚本更新"
        echo -e "${gl_hong}99.${gl_bai}  卸载工具箱"
        echo -e "${gl_kjlan}0.${gl_bai}   退出脚本"
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1)  linux_info ; break_end ;;
            2)  clear ; linux_update ; break_end ;;
            3)  clear ; linux_clean ; break_end ;;
            4)  linux_tools ;;
            5)  linux_bbr ;;
            6)  docker_menu ;;
            7)  linux_warp ;;
            8)  linux_test ;;
            9)  linux_settings ;;
            10) caddy_menu ;;
            11) vps_tailscale_menu ;;
            00) vps_update ;;
            99) vps_uninstall ;;
            0)  clear ; exit 0 ;;
            *)  echo "无效的输入" ; sleep 1 ;;
        esac
    done
}

# ============ 命令行帮助 ============


# ---- END menus/main_menu.sh ----

# ---- BEGIN core/help.sh ----
vps_help() {
    cat <<EOF
VPS 工具箱 v$sh_v

用法:
  $VPS_DEFAULT_SHORTCUT                启动交互菜单
  $VPS_DEFAULT_SHORTCUT info [--plain] 显示系统信息（--plain 纯文本输出）
  $VPS_DEFAULT_SHORTCUT update         系统更新
  $VPS_DEFAULT_SHORTCUT clean          系统清理
  $VPS_DEFAULT_SHORTCUT tools          基础工具管理
  $VPS_DEFAULT_SHORTCUT docker         Docker 管理
  $VPS_DEFAULT_SHORTCUT caddy          Caddy 管理
  $VPS_DEFAULT_SHORTCUT tailscale      Tailscale 组网管理 (别名: ts)
  $VPS_DEFAULT_SHORTCUT bbr            BBR 管理
  $VPS_DEFAULT_SHORTCUT warp           WARP 管理
  $VPS_DEFAULT_SHORTCUT test           测试脚本合集
  $VPS_DEFAULT_SHORTCUT settings       系统工具
  $VPS_DEFAULT_SHORTCUT dd             一键重装系统
  $VPS_DEFAULT_SHORTCUT sshkey         用户密钥登录模式
  $VPS_DEFAULT_SHORTCUT fail2ban       SSH 防爆破 (Fail2ban)
  $VPS_DEFAULT_SHORTCUT firewall       防火墙管理 (UFW/Firewalld)
  $VPS_DEFAULT_SHORTCUT diag [--quick] 磁盘与负载排查
  $VPS_DEFAULT_SHORTCUT optimize       一键系统优化 (别名: opt)
  $VPS_DEFAULT_SHORTCUT dns            优化 DNS 地址
  $VPS_DEFAULT_SHORTCUT install <包>   安装软件
  $VPS_DEFAULT_SHORTCUT remove <包>    卸载软件
  $VPS_DEFAULT_SHORTCUT swap <MB>      设置虚拟内存
  $VPS_DEFAULT_SHORTCUT time <时区>    设置时区
  $VPS_DEFAULT_SHORTCUT reboot         重启服务器
  $VPS_DEFAULT_SHORTCUT shortcut       设置快捷键
  $VPS_DEFAULT_SHORTCUT upgrade        更新工具箱脚本
  $VPS_DEFAULT_SHORTCUT uninstall-self 卸载工具箱脚本
  $VPS_DEFAULT_SHORTCUT help           显示此帮助

服务管理:
  $VPS_DEFAULT_SHORTCUT start <服务>
  $VPS_DEFAULT_SHORTCUT stop <服务>
  $VPS_DEFAULT_SHORTCUT restart <服务>
  $VPS_DEFAULT_SHORTCUT status <服务>
  $VPS_DEFAULT_SHORTCUT enable <服务>
EOF
}


# ---- END core/help.sh ----

# ---- BEGIN entry.sh ----
# ============ 命令行入口 ============

vps_main() {
  if [ "$#" -eq 0 ]; then
    if [ "$(id -u)" -eq 0 ] && vps_self_install; then
        source_path=$(readlink -f "${BASH_SOURCE[0]}")
        if [ "$source_path" != "$VPS_INSTALL_PATH" ] && vps_is_toolbox "$VPS_INSTALL_PATH"; then
            exec bash "$VPS_INSTALL_PATH"
        fi
    fi
    vps_menu
  else
    case "$1" in
        info|信息)               shift; linux_info "$@" ;;
        update|更新)             linux_update ;;
        clean|清理)              linux_clean ;;
        tools|工具)              linux_tools ;;
        docker)                  docker_menu ;;
        caddy)                   caddy_menu ;;
        ts|tailscale)            vps_tailscale_menu ;;
        bbr)                     linux_bbr ;;
        warp)                    linux_warp ;;
        test|check|测试)         linux_test ;;
        settings|设置)           linux_settings ;;
        dd|reinstall|重装)       vps_dd_menu ;;
        sshkey|key)              vps_ssh_key_menu ;;
        f2b|fail2ban)            vps_fail2ban_menu ;;
        fw|firewall|防火墙)      vps_firewall_menu ;;
        diag|disk|排查)          shift; vps_diag_menu "$@" ;;
        opt|optimize|优化)       vps_optimize_menu ;;
        dns)                     vps_dns_menu ;;
        install|add|安装)        shift; pkg_install "$@" ;;
        remove|uninstall|卸载)   shift; pkg_remove "$@" ;;
        swap)                    shift; add_swap "$@" ;;
        time|时区)               shift; set_timedate "$@" ;;
        reboot|重启)             server_reboot ;;
        start|启动)              shift; start "$@" ;;
        stop|停止)               shift; stop "$@" ;;
        restart|服务重启)        shift; restart "$@" ;;
        status|状态)             shift; status "$@" ;;
        enable|自启)             shift; enable "$@" ;;
        shortcut|快捷键)         vps_set_shortcut ;;
        upgrade|update-self)     vps_update ;;
        uninstall-self|remove-self) vps_uninstall ;;
        help|-h|--help)          vps_help ;;
        *)                       vps_help ;;
    esac
  fi
}

# ---- END entry.sh ----

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    vps_main "$@"
fi
