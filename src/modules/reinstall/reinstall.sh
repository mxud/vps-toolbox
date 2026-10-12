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

