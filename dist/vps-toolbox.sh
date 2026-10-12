#!/bin/bash
# ============================================================
# VPS Toolbox
# SPDX-License-Identifier: Apache-2.0
# ============================================================

sh_v="0.1.0"

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
VPS_UPDATE_URL="${VPS_UPDATE_URL:-}"
# Installer writes a repository identifier to allow `vps upgrade` without
# requiring an environment variable on every run. Can be overridden explicitly.
if [ -z "$VPS_UPDATE_URL" ] && [ -r /etc/vps-toolbox.repo ]; then
    IFS= read -r vps_repo < /etc/vps-toolbox.repo || true
    if [[ "$vps_repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        VPS_UPDATE_URL="https://raw.githubusercontent.com/${vps_repo}/main/dist/vps-toolbox.sh"
    fi
fi
gh_proxy="${VPS_GITHUB_PROXY:-https://}"


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


# ---- END core/self_install.sh ----

# ---- BEGIN core/utils.sh ----
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


# ---- END core/network.sh ----

# ---- BEGIN modules/system/swap.sh ----
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
        echo "5. 进入容器    6. 查看日志    7. 查看占用"
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
            6) read -r -e -p "容器名: " name || return 0; [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] && docker logs "$name"; break_end ;;
            7) docker stats --no-stream; break_end ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
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
        timedatectl | grep "Time zone" | awk '{print $3}'
    else
        date +"%Z %z"
    fi
}

linux_info() {
    clear
    echo -e "${gl_kjlan}正在查询系统信息...${gl_bai}"

    local ipv4_address ipv6_address output rx tx
    local cpu_info cpu_usage cpu_cores cpu_freq mem_info swap_info disk_info
    local os_info kernel hostname uptime_str load timezone current_time
    local congestion queue dns_servers tcp_conn udp_conn

    ip_address

    # 1. CPU 采集 (彻底解决 Debian 下 lscpu 缺失/语言匹配失败)
    cpu_info=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    [ -z "$cpu_info" ] && cpu_info=$(grep -m1 -E 'Hardware|Processor' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    [ -z "$cpu_info" ] && cpu_info="未知型号"

    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    cpu_freq=$(grep -m1 -i "cpu MHz" /proc/cpuinfo | awk '{printf "%.1f GHz", $4/1000}')
    [ -z "$cpu_freq" ] && cpu_freq="虚拟化/不可用"

    cpu_usage=$(awk '{idle=$5+$6; total=0; for(i=2;i<=9;i++)total+=$i; if(NR==1){idle1=idle; total1=total;} else {dt=total-total1; printf "%.0f\n", (dt>0 ? (dt-(idle-idle1))*100/dt : 0)}}' \
        <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

    # 2. 内存与 Swap 采集 (统一走 /proc/meminfo，精准无误)
    local mem_total mem_avail mem_used mem_p
    mem_total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [ -z "$mem_avail" ] || [ "$mem_avail" -eq 0 ]; then
        local mem_free buffers cached
        mem_free=$(awk '/MemFree:/ {print int($2/1024)}' /proc/meminfo)
        buffers=$(awk '/Buffers:/ {print int($2/1024)}' /proc/meminfo)
        cached=$(awk '/^Cached:/ {print int($2/1024)}' /proc/meminfo)
        mem_avail=$((mem_free + buffers + cached))
    fi
    mem_used=$((mem_total - mem_avail))
    mem_p=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN {printf "%.1f", (t>0 ? u*100/t : 0)}')
    mem_info="${mem_used}M/${mem_total}M (${mem_p}%)"

    local s_total s_free s_used s_p
    s_total=$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    s_free=$(awk '/SwapFree:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    s_used=$((s_total - s_free))
    if [ "${s_total:-0}" -gt 0 ]; then
        s_p=$(awk -v u="$s_used" -v t="$s_total" 'BEGIN {printf "%.1f", u*100/t}')
        swap_info="${s_used}M/${s_total}M (${s_p}%)"
    else
        swap_info="未启用"
    fi

    # 3. 基础系统参数
    disk_info=$(df -h | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')
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
            1) pkg_install "${tools[@]}" ; break_end ;;
            2)
                read -r -e -p "请输入要安装的工具（空格分隔）: " -a custom_tools || return 0
                [ ${#custom_tools[@]} -gt 0 ] && pkg_install "${custom_tools[@]}"
                break_end
                ;;
            3)
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
        echo "3. BestTrace 三网回程延迟路由"
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
            1)  run_remote_bash https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh ;;
            2)  run_remote_bash https://github.com/lmc999/RegionRestrictionCheck/raw/main/check.sh ;;
            3)  run_remote_bash "https://git.io/besttrace" ;;
            4)  run_remote_bash https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh ;;
            5)  run_remote_bash "https://raw.githubusercontent.com/MiaM1ku/taierspeedtest/main/taierspeedtest.sh" ;;
            6)  run_remote_bash "https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh" ;;
            7)  check_swap; run_remote_bash https://yabs.sh -i -5 ;;
            8)  check_swap; run_remote_bash "https://raw.githubusercontent.com/xykt/HardwareQuality/main/hq.sh" ;;
            9)  run_remote_bash https://github.com/spiritLHLS/ecs/raw/main/ecs.sh ;;
            10) run_remote_bash "https://run.NodeQuality.com" ;;
            0)  break ;;
            *)  echo "无效选择" ; sleep 1 ;;
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
                    vps_ssh_import_url "https://github.com/${username}.keys"
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

vps_dns_probe() {
    local server
    command -v nslookup >/dev/null 2>&1 || pkg_install dnsutils || return 1
    command -v timeout >/dev/null 2>&1 || pkg_install coreutils || return 1
    for server in "$@"; do
        if ! timeout 12 nslookup example.com "$server" >/dev/null 2>&1; then
            echo "DNS $server 的直接解析测试失败，未修改配置" >&2
            return 1
        fi
    done
}

vps_dns_apply() {
    local first_v4="$1" second_v4="$2" first_v6="${3:-}" second_v6="${4:-}"
    local mode backup previous candidate config dns_list=""
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }

    vps_dns_valid_ipv4 "$first_v4" && vps_dns_valid_ipv4 "$second_v4" || {
        echo "请输入有效的 IPv4 DNS 地址" >&2; return 1
    }
    dns_list="$first_v4 $second_v4"

    if [ -n "$first_v6" ]; then
        vps_dns_valid_ipv6 "$first_v6" || { echo "输入的 IPv6 DNS 格式不正确: $first_v6" >&2; return 1; }
        dns_list="$dns_list $first_v6"
    fi
    if [ -n "$second_v6" ]; then
        vps_dns_valid_ipv6 "$second_v6" || { echo "输入的 IPv6 DNS 格式不正确: $second_v6" >&2; return 1; }
        dns_list="$dns_list $second_v6"
    fi

    mode=$(vps_dns_mode) || return 1
    vps_dns_probe "$first_v4" "$second_v4" || return 1
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
                read -r -e -p "首选 IPv4 DNS: " first_v4 || return 0
                read -r -e -p "备用 IPv4 DNS: " second_v4 || return 0
                read -r -e -p "首选 IPv6 DNS (可选，直接回车跳过): " first_v6 || return 0
                read -r -e -p "备用 IPv6 DNS (可选，直接回车跳过): " second_v6 || return 0
                vps_dns_apply "$first_v4" "$second_v4" "$first_v6" "$second_v6"
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


# ---- END modules/system/timezone.sh ----

# ---- BEGIN modules/reinstall/reinstall.sh ----
vps_dd_execute() {
    local os_cmd="$1" is_windows="${2:-false}"
    local default_port="22" default_user="root"
    [ "$is_windows" = true ] && { default_port="3389"; default_user="Administrator"; }

    clear
    echo -e "${gl_kjlan}==================== 重装系统参数配置 ====================${gl_bai}"
    echo -e "目标系统: ${gl_huang}${os_cmd}${gl_bai}"
    echo -e "${gl_hong}警告: 重装系统会彻底格式化主硬盘，请确保所有重要数据已备份！${gl_bai}"
    echo "--------------------------------------------------------"

    local auth_display="" auth_type="password"
    local -a auth_args=() port_args=() os_args=() final_cmd=()
    pkg_install curl ca-certificates || return 1

    if [ "$is_windows" = true ]; then
        # Windows 仅支持密码认证
        local win_pwd
        read -r -s -p "设置 Windows 密码 (回车自动生成16位高强度密码): " win_pwd || return 0
        if [ -z "$win_pwd" ]; then
            win_pwd=$(< /dev/urandom LC_ALL=C tr -dc 'A-Za-z0-9_' 2>/dev/null | head -c 16)
            [ "${#win_pwd}" -eq 16 ] || { echo "随机密码生成失败" >&2; return 1; }
        fi
        echo
        auth_args=(--password "$win_pwd")
        auth_display="密码: ${gl_huang}${win_pwd}${gl_bai}"
    else
        # Linux 支持多种凭据选择
        echo "请选择登录凭据类型:"
        echo "1. 从 GitHub 导入公钥 (推荐：输入用户名直接拉取，开机即密钥登录)"
        echo "2. 手动粘贴 SSH 公钥"
        echo "3. 设置自定义密码"
        echo "4. 自动生成 16 位强随机密码"
        echo "--------------------------------------------------------"
        local cred_choice
        read -r -e -p "请输入你的选择 [1-4，默认 1]: " cred_choice || return 0
        cred_choice=${cred_choice:-1}

        case "$cred_choice" in
            1)
                local gh_user pubkeys line valid_count=0 tmp_keys
                read -r -e -p "请输入你的 GitHub 用户名: " gh_user || return 0
                if [[ ! "$gh_user" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
                    echo "错误: GitHub 用户名格式无效！" >&2
                    break_end
                    return 1
                fi
                echo "正在拉取 GitHub 公钥..."
                tmp_keys=$(mktemp /tmp/vps-gh-keys.XXXXXX) || return 1
                if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 -o "$tmp_keys" "https://github.com/${gh_user}.keys" && [ -s "$tmp_keys" ]; then
                    local first_key=""
                    while IFS= read -r line || [ -n "$line" ]; do
                        line=${line%$'\r'}
                        if vps_ssh_valid_key "$line"; then
                            valid_count=$((valid_count + 1))
                            [ -z "$first_key" ] && first_key="$line"
                        fi
                    done < "$tmp_keys"
                    rm -f -- "$tmp_keys"
                    if [ "$valid_count" -gt 0 ]; then
                        echo -e "${gl_lv}✔ 成功获取到 $valid_count 条有效公钥！${gl_bai}"
                        auth_type="key"
                        auth_args=(--ssh-key "$first_key")
                        auth_display="【纯密钥登录】(已绑定 GitHub: $gh_user)"
                    else
                        echo "错误: 未在该 GitHub 用户主页找到合法的 SSH 公钥！" >&2
                        break_end
                        return 1
                    fi
                else
                    rm -f -- "$tmp_keys"
                    echo "错误: 无法从 GitHub 拉取公钥，请检查用户名是否正确或网络连通性！" >&2
                    break_end
                    return 1
                fi
                ;;
            2)
                local manual_key
                read -r -e -p "请粘贴你的 SSH 公钥: " manual_key || return 0
                if vps_ssh_valid_key "$manual_key"; then
                    auth_type="key"
                    auth_args=(--ssh-key "$manual_key")
                    auth_display="【纯密钥登录】(手动注入公钥)"
                else
                    echo "错误: 输入的公钥格式不正确！" >&2
                    break_end
                    return 1
                fi
                ;;
            3)
                local custom_pwd
                read -r -s -p "请输入自定义登录密码: " custom_pwd || return 0
                while [ -z "$custom_pwd" ]; do
                    read -r -s -p "密码不能为空，请重新输入: " custom_pwd || return 0
                done
                echo
                auth_args=(--password "$custom_pwd")
                auth_display="密码: ${gl_huang}${custom_pwd}${gl_bai}"
                ;;
            4)
                local rand_pwd
                rand_pwd=$(< /dev/urandom LC_ALL=C tr -dc 'A-Za-z0-9_' 2>/dev/null | head -c 16)
                [ "${#rand_pwd}" -eq 16 ] || { echo "随机密码生成失败" >&2; return 1; }
                auth_args=(--password "$rand_pwd")
                auth_display="密码: ${gl_huang}${rand_pwd}${gl_bai}"
                ;;
            *) echo "凭据类型无效，请选择 1 至 4" >&2; return 1 ;;
        esac
    fi

    # 端口输入
    local custom_port
    read -r -e -p "设置远程连接端口 (回车默认 ${default_port}): " custom_port || return 0
    custom_port=${custom_port:-$default_port}
    while ! vps_valid_port "$custom_port"; do
        read -r -e -p "端口无效，请重新输入 (1-65535): " custom_port || return 0
    done
    custom_port=$((10#$custom_port))

    if [ "$is_windows" = true ]; then
        [ "$custom_port" != "3389" ] && port_args=(--rdp-port "$custom_port")
    else
        [ "$custom_port" != "22" ] && port_args=(--ssh-port "$custom_port")
    fi
    echo -e "生效远程端口: ${gl_huang}${custom_port}${gl_bai}"

    echo "--------------------------------------------------------"
    echo -e "重装后登录信息汇总："
    echo -e "用户名:   ${gl_lv}${default_user}${gl_bai}"
    echo -e "认证方式: ${auth_display}"
    echo -e "远程端口: ${gl_lv}${custom_port}${gl_bai} (新系统开机直接生效)"
    echo "--------------------------------------------------------"
    [ "$auth_type" = "password" ] && echo -e "${gl_hong}请务必截图或保存上方密码！${gl_bai}"
    read -r -e -p "确认现在开始重装服务器吗？(输入 yes 确认): " confirm || return 0
    if [ "$confirm" != "yes" ]; then
        echo "操作已取消。"
        break_end
        return
    fi

    echo -e "${gl_kjlan}正在准备底层重装环境...${gl_bai}"
    local reinstall_sh
    reinstall_sh=$(mktemp /tmp/reinstall.XXXXXX.sh) || return 1
    if curl -fsSL --proto '=https' --proto-redir '=https' --max-time 120 --connect-timeout 15 -o "$reinstall_sh" "https://raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" && [ -s "$reinstall_sh" ] && bash -n "$reinstall_sh"; then
        read -r -a os_args <<< "$os_cmd"
        final_cmd=(bash "$reinstall_sh" "${os_args[@]}" --user "$default_user" "${auth_args[@]}" "${port_args[@]}")
        "${final_cmd[@]}"
        local rc=$?
        rm -f -- "$reinstall_sh"
        if [ "$rc" -eq 0 ]; then
            echo -e "${gl_lv}重装环境准备完毕，服务器即将重启进入自动化安装流程...${gl_bai}"
            echo -e "预计耗时 5~15 分钟，请耐心等待后使用端口 ${gl_huang}${custom_port}${gl_bai} 尝试登录！"
            sleep 3
            reboot
        else
            echo "重装脚本执行中断，请检查上方日志输出！" >&2
            break_end
        fi
    else
        rm -f -- "$reinstall_sh"
        echo "下载重装脚本失败，请检查网络连通性！" >&2
        break_end
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
                    1) vps_dd_execute "debian 13" ;;
                    2) vps_dd_execute "debian 12" ;;
                    3) vps_dd_execute "debian 11" ;;
                    4) vps_dd_execute "debian 10" ;;
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
                    1) vps_dd_execute "ubuntu 24.04" ;;
                    2) vps_dd_execute "ubuntu 22.04" ;;
                    3) vps_dd_execute "ubuntu 20.04" ;;
                    4) vps_dd_execute "ubuntu 26.04" ;;
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
                    1) vps_dd_execute "rocky 9" ;;
                    2) vps_dd_execute "rocky 10" ;;
                    3) vps_dd_execute "almalinux 9" ;;
                    4) vps_dd_execute "almalinux 10" ;;
                    5) vps_dd_execute "centos 9" ;;
                    6) vps_dd_execute "centos 10" ;;
                    7) vps_dd_execute "oracle 9" ;;
                    8) vps_dd_execute "oracle 10" ;;
                    9) vps_dd_execute "fedora 43" ;;
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
                    1) vps_dd_execute "alpine" ;;
                    2) vps_dd_execute "arch" ;;
                    3) vps_dd_execute "kali" ;;
                    4) vps_dd_execute "opensuse" ;;
                    5) vps_dd_execute "openeuler" ;;
                    *) continue ;;
                esac
                ;;
            5)
                clear
                echo "Windows 系列选择 (请确保 VPS 内存 >= 2GB):"
                echo "1. Windows 11 Pro"
                echo "2. Windows 10 Pro"
                echo "3. Windows Server 2025"
                echo "4. Windows Server 2022"
                echo "5. Windows Server 2019"
                echo "6. Windows 11 ARM64 (适用于甲骨文ARM等机型)"
                echo "0. 返回"
                read -r -e -p "请选择版本: " v_choice || return 0
                case "$v_choice" in
                    1) vps_dd_execute "windows 11" true ;;
                    2) vps_dd_execute "windows 10" true ;;
                    3) vps_dd_execute "windows 2025" true ;;
                    4) vps_dd_execute "windows 2022" true ;;
                    5) vps_dd_execute "windows 2019" true ;;
                    6) vps_dd_execute "dd --img https://r2.hotdog.eu.org/win11-arm-with-pagefile-15g.xz" true ;;
                    *) continue ;;
                esac
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
        s_total=$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
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
        printf " %-2s %-20s ${gl_hui}[命令: %s]${gl_bai}\n" "1." "设置脚本快捷键" "${VPS_DEFAULT_SHORTCUT}"
        printf " %-2s %-20s ${gl_hui}[用户: root]${gl_bai}\n" "2." "修改登录密码"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "3." "修改 SSH 端口" "${cur_port}"
        printf " %-2s %-20s ${gl_hui}[安全加固/公钥管理]${gl_bai}\n" "4." "用户密钥登录模式"
        echo ""
        echo -e "${gl_huang}【 系统与环境 】${gl_bai}"
        printf " %-2s %-20s ${gl_hui}[主机: %s]${gl_bai}\n" "5." "修改主机名" "${cur_host}"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "6." "修改虚拟内存 (Swap)" "${cur_swap}"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "7." "设置系统时区" "${cur_tz}"
        printf " %-2s %-20s ${gl_hong}[纯内存在线重装]${gl_bai}\n" "8." "一键重装系统"
        printf " %-2s %-20s\n" "9." "一键重启服务器"
        echo ""
        echo -e "${gl_huang}【 网络与规则 】${gl_bai}"
        printf " %-2s %-20s ${gl_hui}[当前: %s]${gl_bai}\n" "10." "优化 DNS 地址" "${cur_dns}"
        printf " %-2s %-20s ${gl_lv}[当前: %s]${gl_bai}\n" "11." "设置 IPv4 地址优先级" "${cur_ipc}"
        printf " %-2s %-20s ${gl_hong}[清空 IPv4 filter 表]${gl_bai}\n" "12." "开放 IPv4 防火墙端口"
        printf " %-2s %-20s ${gl_hui}[ss 监听列表]${gl_bai}\n" "13." "查看本机端口占用"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        echo " 0. 返回主菜单"
        echo -e "${gl_kjlan}--------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1) vps_set_shortcut ;;
            2) set_root_password ; break_end ;;
            3) change_ssh_port ;;
            4) vps_ssh_key_menu ;;
            5)
                root_use || continue
                read -r -e -p "请输入新主机名: " new_hostname || return 0
                [ -z "$new_hostname" ] || vps_set_hostname "$new_hostname"
                break_end
                ;;
            6)
                clear
                echo -e "当前虚拟内存: ${gl_huang}${cur_swap}${gl_bai}"
                read -r -e -p "输入新的 swap 大小 (MB，输入 0 退出): " swap_size || return 0
                [ "$swap_size" != "0" ] && [ -n "$swap_size" ] && add_swap "$swap_size"
                break_end
                ;;
            7) timezone_menu ;;
            8) vps_dd_menu ;;
            9) server_reboot ;;
            10) vps_dns_menu ;;
            11)
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
            12)
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
            13) clear; ss -tulnape; break_end ;;
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
    local tmp_file new_ver new_value current_ver="$sh_v" current_value result=0 installed_ver
    if [ -e "$VPS_INSTALL_PATH" ] || [ -L "$VPS_INSTALL_PATH" ]; then
        vps_is_toolbox "$VPS_INSTALL_PATH" || { echo "安装文件无效，未更新" >&2; return 1; }
        installed_ver=$(grep '^sh_v=' "$VPS_INSTALL_PATH" | head -1 | cut -d'"' -f2)
        if [ "$(vps_version_value "$installed_ver" || echo 0)" -gt "$(vps_version_value "$current_ver")" ]; then
            current_ver="$installed_ver"
        fi
    fi
    current_value=$(vps_version_value "$current_ver") || return 1
    tmp_file=$(mktemp /tmp/vps-toolbox.XXXXXX) || return 1

    echo "正在下载更新..."
    if curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 -o "$tmp_file" "$VPS_UPDATE_URL" \
       && [ -s "$tmp_file" ] \
       && head -1 "$tmp_file" | grep -q '^#!/bin/bash' \
       && vps_is_toolbox "$tmp_file"; then

        new_ver=$(grep '^sh_v=' "$tmp_file" | head -1 | cut -d'"' -f2)
        if ! new_value=$(vps_version_value "$new_ver"); then
            rm -f -- "$tmp_file"
            echo "更新失败：新脚本缺少有效版本号" >&2
            break_end
            return 1
        fi

        if [ "$new_value" -le "$current_value" ]; then
            echo "下载版本 v$new_ver 不高于当前版本 v$current_ver，已保留当前版本"
            rm -f "$tmp_file"
            break_end
            return
        fi

        if ! vps_atomic_install "$tmp_file" "$VPS_INSTALL_PATH"; then
            rm -f -- "$tmp_file"
            echo "更新失败：无法写入安装目录" >&2
            break_end
            return 1
        fi
        rm -f -- "$tmp_file"
        echo -e "${gl_lv}脚本已更新到 v$new_ver${gl_bai}"
        echo "重新启动 $VPS_INSTALL_PATH 后使用新版；旧版本备份: ${VPS_INSTALL_PATH}.bak（如更新前已安装）"
    else
        rm -f "$tmp_file"
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
        echo -e "${gl_kjlan}------------------------${gl_bai}"
        echo -e "${gl_kjlan}00.${gl_bai}  脚本更新"
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
            00) vps_update ;;
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
  $VPS_DEFAULT_SHORTCUT info           显示系统信息
  $VPS_DEFAULT_SHORTCUT update         系统更新
  $VPS_DEFAULT_SHORTCUT clean          系统清理
  $VPS_DEFAULT_SHORTCUT tools          基础工具管理
  $VPS_DEFAULT_SHORTCUT docker         Docker 管理
  $VPS_DEFAULT_SHORTCUT bbr            BBR 管理
  $VPS_DEFAULT_SHORTCUT warp           WARP 管理
  $VPS_DEFAULT_SHORTCUT test           测试脚本合集
  $VPS_DEFAULT_SHORTCUT settings       系统工具
  $VPS_DEFAULT_SHORTCUT dd             一键重装系统
  $VPS_DEFAULT_SHORTCUT sshkey         用户密钥登录模式
  $VPS_DEFAULT_SHORTCUT dns            优化 DNS 地址
  $VPS_DEFAULT_SHORTCUT install <包>   安装软件
  $VPS_DEFAULT_SHORTCUT remove <包>    卸载软件
  $VPS_DEFAULT_SHORTCUT swap <MB>      设置虚拟内存
  $VPS_DEFAULT_SHORTCUT time <时区>    设置时区
  $VPS_DEFAULT_SHORTCUT reboot         重启服务器
  $VPS_DEFAULT_SHORTCUT shortcut       设置快捷键
  $VPS_DEFAULT_SHORTCUT upgrade        更新工具箱脚本
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
        info|信息)               linux_info ;;
        update|更新)             linux_update ;;
        clean|清理)              linux_clean ;;
        tools|工具)              linux_tools ;;
        docker)                  docker_menu ;;
        bbr)                     linux_bbr ;;
        warp)                    linux_warp ;;
        test|check|测试)         linux_test ;;
        settings|设置)           linux_settings ;;
        dd|reinstall|重装)       vps_dd_menu ;;
        sshkey|key)              vps_ssh_key_menu ;;
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
        help|-h|--help)          vps_help ;;
        *)                       vps_help ;;
    esac
  fi
}

# ---- END entry.sh ----

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    vps_main "$@"
fi
