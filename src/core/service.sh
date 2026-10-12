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

