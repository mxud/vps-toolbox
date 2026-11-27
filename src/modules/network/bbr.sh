# ============ BBR 管理 ============

bbr_on() {
    local CONF="/etc/sysctl.d/99-vps-bbr.conf"
    local MOD_CONF="/etc/modules-load.d/99-vps-bbr.conf"
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }

    if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null || true
    fi

    if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
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

    # 持久化 tcp_bbr 模块，确保重启后自动加载
    if [ ! -L "$MOD_CONF" ]; then
        mkdir -p /etc/modules-load.d 2>/dev/null || true
        if [ -d /etc/modules-load.d ]; then
            printf 'tcp_bbr\n' > "$MOD_CONF" 2>/dev/null || true
            chmod 644 "$MOD_CONF" 2>/dev/null || true
        fi
    fi

    if grep -Eq '^[[:space:]]*(net.ipv4.tcp_congestion_control|net.core.default_qdisc)[[:space:]]*=' /etc/sysctl.conf 2>/dev/null; then
        cp -p /etc/sysctl.conf "/etc/sysctl.conf.vps-backup-$(date +%Y%m%d-%H%M%S)" || return 1
        sed -i '/^[[:space:]]*net.ipv4.tcp_congestion_control[[:space:]]*=/d; /^[[:space:]]*net.core.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf || return 1
    fi
    if ! sysctl -p "$CONF" || [ "$(sysctl -n net.ipv4.tcp_congestion_control)" != bbr ] ||
       [ "$(sysctl -n net.core.default_qdisc)" != fq ]; then
        echo "BBR 未完全生效，请检查 sysctl 输出和配置: $CONF" >&2
        return 1
    fi
    echo -e "${gl_lv}BBR 已成功开启并设置开机持久化${gl_bai}"
}

bbr_off() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    rm -f -- /etc/sysctl.d/99-vps-bbr.conf /etc/modules-load.d/99-vps-bbr.conf || return 1
    sysctl --system >/dev/null 2>&1 || true
    echo "工具箱的 BBR 配置已移除，重启后由系统默认网络算法接管。"
}

vps_bbr_xanmod_psabi() {
    awk 'BEGIN {
        while (!/flags/) if ((getline < "/proc/cpuinfo") != 1) exit 1
        if (/lm/&&/cmov/&&/cx8/&&/fpu/&&/fxsr/&&/mmx/&&/syscall/&&/sse2/) level = 1
        if (level == 1 && /cx16/&&/lahf/&&/popcnt/&&/sse4_1/&&/sse4_2/&&/ssse3/) level = 2
        if (level == 2 && /avx/&&/avx2/&&/bmi1/&&/bmi2/&&/f16c/&&/fma/&&/abm/&&/movbe/&&/xsave/) level = 3
        if (level > 0) { print level; exit 0 }
        exit 1
    }' /proc/cpuinfo 2>/dev/null
}

vps_bbr_xanmod_install() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local arch os_id="" os_codename="" level pkg="" candidate_pkg prefix
    local keyring="/usr/share/keyrings/xanmod-archive-keyring.gpg"
    local list_file="/etc/apt/sources.list.d/xanmod-release.list"
    local avail_mb

    arch=$(uname -m)
    if [ "$arch" != "x86_64" ]; then
        echo "XanMod 官方 APT 源仅支持 x86_64 架构（当前: $arch）" >&2
        return 1
    fi
    if [ -r /etc/os-release ]; then
        os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
        os_codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
    fi
    if [[ "$os_id" != "debian" && "$os_id" != "ubuntu" ]] || ! command -v apt-get >/dev/null 2>&1; then
        echo "XanMod 官方源自动安装仅支持 Debian / Ubuntu 系统" >&2
        return 1
    fi
    case "$os_codename" in
        bookworm|trixie|forky|sid|noble|plucky|questing) ;;
        *)
            echo "XanMod 官方已停止对旧发行版 (${os_codename:-未知}) 的 APT 源支持，需 Debian 12+ 或 Ubuntu 24.04+" >&2
            return 1
            ;;
    esac

    avail_mb=$(df -Pm / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$avail_mb" ] && [ "$avail_mb" -lt 2048 ]; then
        echo "根分区可用空间不足 2GB（当前 ${avail_mb}MB），为防止内核安装失败已中止" >&2
        return 1
    fi
    check_swap

    level=$(vps_bbr_xanmod_psabi) || {
        echo "无法识别当前 CPU 的 x86-64 指令集等级" >&2
        return 1
    }

    pkg_install curl gnupg ca-certificates || return 1
    [ ! -L "$keyring" ] && [ ! -L "$list_file" ] || {
        echo "拒绝覆盖符号链接形式的 apt 源或密钥" >&2
        return 1
    }
    mkdir -p /usr/share/keyrings /etc/apt/sources.list.d || return 1

    local tmp_key
    tmp_key=$(mktemp /tmp/vps-xanmod-key.XXXXXX) || return 1
    if ! curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 "https://dl.xanmod.org/archive.key" -o "$tmp_key" ||
       ! gpg --batch --yes --dearmor -o "$keyring" "$tmp_key"; then
        rm -f -- "$tmp_key"
        echo "下载或导入 XanMod 官方 GPG 密钥失败" >&2
        return 1
    fi
    rm -f -- "$tmp_key"
    chmod 644 "$keyring" || return 1
    printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' "$keyring" "$os_codename" > "$list_file" || return 1
    chmod 644 "$list_file" || return 1

    echo "正在更新 XanMod 软件源索引..."
    apt-get update || return 1

    for prefix in linux-xanmod linux-xanmod-lts; do
        local try_level="$level"
        while [ "$try_level" -ge 1 ]; do
            candidate_pkg="${prefix}-x64v${try_level}"
            if apt-cache policy "$candidate_pkg" 2>/dev/null | grep -q 'Candidate: [^n(]'; then
                pkg="$candidate_pkg"
                break 2
            fi
            try_level=$((try_level - 1))
        done
    done

    if [ -z "$pkg" ]; then
        echo "未在软件源中找到适配当前 CPU (x64v${level}) 的 XanMod 内核包" >&2
        return 1
    fi

    echo -e "检测到 CPU 支持等级 ${gl_huang}x86-64-v${level}${gl_bai}，即将安装/更新: ${gl_lv}${pkg}${gl_bai}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" || return 1
    bbr_on || true
    echo -e "${gl_lv}XanMod BBRv3 内核 (${pkg}) 已安装完成，重启服务器后生效。${gl_bai}"
    server_reboot
}

vps_bbr_xanmod_uninstall() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local -a installed_pkgs=()
    mapfile -t installed_pkgs < <(dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep '^linux-.*xanmod' || true)
    if [ "${#installed_pkgs[@]}" -eq 0 ]; then
        echo "当前系统未检测到已安装的 XanMod 内核包"
        return 0
    fi
    echo "将卸载以下 XanMod 内核包并移除官方源: ${installed_pkgs[*]}"
    local confirm
    read -r -p "输入 UNINSTALL 确认卸载 XanMod 内核: " confirm || return 0
    [ "$confirm" = "UNINSTALL" ] || { echo "已取消"; return 0; }
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${installed_pkgs[@]}" || return 1
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
    update-grub 2>/dev/null || true
    rm -f -- /etc/apt/sources.list.d/xanmod-release.list /usr/share/keyrings/xanmod-archive-keyring.gpg
    echo -e "${gl_lv}XanMod 内核已卸载，请重启服务器切换回系统默认内核。${gl_bai}"
    server_reboot
}

linux_bbr() {
    if [ "$#" -gt 0 ]; then
        case "$1" in
            on|enable|开启) bbr_on; return $? ;;
            off|disable|关闭) bbr_off; return $? ;;
            status|状态)
                printf 'kernel: %s\n' "$(uname -r)"
                printf 'tcp_congestion_control: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
                printf 'default_qdisc: %s\n' "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
                if modinfo tcp_bbr 2>/dev/null | grep -q '^version:'; then
                    printf 'bbr_version: %s\n' "$(modinfo tcp_bbr 2>/dev/null | awk '/^version:/ {print $2; exit}')"
                fi
                return 0
                ;;
            xanmod|bbr3|bbrv3) vps_bbr_xanmod_install; return $? ;;
            *) echo "用法: $VPS_DEFAULT_SHORTCUT bbr [on|off|status|xanmod]" >&2; return 1 ;;
        esac
    fi

    local cc qd kver psabi_lvl xanmod_state
    while true; do
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
        qd=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
        kver=$(uname -r)
        psabi_lvl=$(vps_bbr_xanmod_psabi || echo "")
        if dpkg-query -W -f='${Package}\n' 'linux-*xanmod*' 2>/dev/null | grep -q '^linux-.*xanmod'; then
            xanmod_state="${gl_lv}已安装 XanMod${gl_bai}"
        else
            xanmod_state="${gl_hui}未安装${gl_bai}${psabi_lvl:+ (CPU 支持 x64v${psabi_lvl})}"
        fi
        clear
        echo -e "${gl_kjlan}================== BBR 拥塞控制管理 ==================${gl_bai}"
        echo -e "当前内核版本: ${gl_huang}$kver${gl_bai}"
        echo -e "当前 TCP 算法: ${gl_lv}$cc / $qd${gl_bai}"
        echo -e "BBRv3 内核:   ${xanmod_state}"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "1. 开启原生 BBR (fq + bbr，含模块开机持久化)"
        echo "2. 关闭工具箱 BBR 配置"
        echo "3. 安装 / 更新 XanMod 官方 BBRv3 内核 (Debian/Ubuntu x86_64)"
        echo "4. 卸载 XanMod BBRv3 内核"
        echo "5. 第三方内核加速脚本 (tcpx.sh)"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        echo "0. 返回"
        echo -e "${gl_kjlan}------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case $choice in
            1) bbr_on ; break_end ;;
            2)
                root_use || continue
                bbr_off || { break_end; continue; }
                server_reboot
                ;;
            3)
                root_use || continue
                vps_bbr_xanmod_install
                break_end
                ;;
            4)
                root_use || continue
                vps_bbr_xanmod_uninstall
                break_end
                ;;
            5)
                run_remote_bash "${gh_proxy}raw.githubusercontent.com/ylx2016/Linux-NetSpeed/master/tcpx.sh"
                break_end
                ;;
            0) break ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

