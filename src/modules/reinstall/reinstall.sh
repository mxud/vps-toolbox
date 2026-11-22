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
