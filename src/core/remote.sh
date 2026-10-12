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

