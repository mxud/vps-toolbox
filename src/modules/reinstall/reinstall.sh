vps_dd_execute() {
    local os_cmd="$1" is_windows="${2:-false}"
    local default_port="22" default_user="root"
    [ "$is_windows" = true ] && { default_port="3389"; default_user="Administrator"; }

    # 自动获取当前 SSH 端口
    local current_port
    current_port=$("$(command -v sshd || echo /usr/sbin/sshd)" -T 2>/dev/null | awk '$1=="port" {print $2; exit}')
    [ -n "$current_port" ] && default_port="$current_port"

    clear
    echo -e "${gl_kjlan}==================== 重装系统参数配置 ====================${gl_bai}"
    echo -e "目标系统: ${gl_huang}${os_cmd}${gl_bai}"
    echo -e "${gl_hong}警告: 重装系统会彻底格式化主硬盘，一旦确认不可逆转！${gl_bai}"
    echo "--------------------------------------------------------"

    local auth_display="" auth_type="password"
    local -a auth_args=() port_args=() os_args=() final_cmd=()
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
        local cred_choice
        read -r -p "请选择 [1-3]: " cred_choice
        cred_choice=${cred_choice:-1}

        case "$cred_choice" in
            3)
                local gh_user tmp_keys valid_count=0 key_list=""
                read -r -p "请输入你的 GitHub 用户名: " gh_user
                echo "正在拉取 GitHub 公钥..."
                tmp_keys=$(mktemp)
                curl -fsSL "${gh_proxy}github.com/${gh_user}.keys" -o "$tmp_keys"
                while IFS= read -r line || [ -n "$line" ]; do
                    line=${line%$'
'}
                    if vps_ssh_valid_key "$line"; then
                        valid_count=$((valid_count + 1))
                        # 兼容多公钥传入方式（用逗号或多条参数，根据底层重装脚本特性，多数仅取首行，但我们尽可能注入）
                        [ -n "$line" ] && auth_args+=(--ssh-key "$line")
                    fi
                done < "$tmp_keys"
                rm -f -- "$tmp_keys"
                if [ "$valid_count" -gt 0 ]; then
                    auth_type="key"
                    auth_display="【纯密钥登录】(已绑定 GitHub: $gh_user 共 $valid_count 把公钥)"
                else
                    echo "错误: 未找到有效的公钥！" >&2; break_end; return 1
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
    reinstall_sh=$(mktemp)
    if curl -fsSL "${gh_proxy}raw.githubusercontent.com/bin456789/reinstall/main/reinstall.sh" -o "$reinstall_sh"; then
        read -r -a os_args <<< "$os_cmd"
        # 修正 DD 镜像不接受 user/password 的问题
        if [[ "$os_cmd" == dd\ --img* ]]; then
            final_cmd=(bash "$reinstall_sh" "${os_args[@]}" "${port_args[@]}")
        else
            final_cmd=(bash "$reinstall_sh" "${os_args[@]}" --user "$default_user" "${auth_args[@]}" "${port_args[@]}")
        fi
        
        "${final_cmd[@]}"
        if [ $? -eq 0 ]; then
            echo -e "${gl_lv}准备完毕，服务器将自动重启安装...${gl_bai}"
            sleep 3; reboot
        else
            echo "重装脚本执行失败！" >&2; break_end
        fi
    else
        echo "下载重装脚本失败！" >&2; break_end
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

