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

    local auth_key ts_host raw_tags tags use_ssh accept_routes use_exit adv_routes
    local -a args=()

    echo -e "${gl_kjlan}=== Tailscale 登录 / 启动配置 ===${gl_bai}"
    read -r -s -p "Auth Key (留空则使用浏览器交互式登录): " auth_key || return 0
    echo ""
    if [ -n "$auth_key" ]; then
        args+=(--auth-key="$auth_key")
    fi

    read -r -e -p "自定义节点名称 --hostname (留空使用系统主机名): " ts_host || return 0
    if [ -n "$ts_host" ]; then
        vps_valid_hostname "$ts_host" || { echo "节点名称格式无效" >&2; return 1; }
        args+=(--hostname="$ts_host")
    fi

    read -r -e -p "节点标签 --advertise-tags (逗号分隔，如 vps,prod；留空跳过): " raw_tags || return 0
    if [ -n "$raw_tags" ]; then
        tags=$(vps_ts_format_tags "$raw_tags") || return 1
        args+=(--advertise-tags="$tags")
        echo -e "${gl_huang}提示：使用标签前请确保已在 Tailscale 控制台 ACL 的 tagOwners 中配置对应标签。${gl_bai}"
    fi

    read -r -e -p "开启 Tailscale SSH？[y/N]: " use_ssh || return 0
    [[ "$use_ssh" =~ ^[Yy]$ ]] && args+=(--ssh)

    read -r -e -p "接受其他节点广播的子网路由 (--accept-routes)？[y/N]: " accept_routes || return 0
    [[ "$accept_routes" =~ ^[Yy]$ ]] && args+=(--accept-routes)

    read -r -e -p "作为出口节点 (--advertise-exit-node)？[y/N]: " use_exit || return 0
    if [[ "$use_exit" =~ ^[Yy]$ ]]; then
        vps_ts_enable_forwarding || return 1
        args+=(--advertise-exit-node)
    fi

    read -r -e -p "广播子网路由 --advertise-routes (如 10.0.0.0/24；留空跳过): " adv_routes || return 0
    if [ -n "$adv_routes" ]; then
        [[ "$adv_routes" =~ ^[0-9A-Fa-f.:/,]+$ ]] || { echo "子网路由格式无效" >&2; return 1; }
        vps_ts_enable_forwarding || return 1
        args+=(--advertise-routes="$adv_routes")
    fi

    echo "正在执行 tailscale up..."
    tailscale up "${args[@]}"
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
