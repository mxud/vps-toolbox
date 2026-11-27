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

docker_select_containers() {
    local prompt="${1:-请输入容器序号或名称 (多个用空格分隔，0 返回): }"
    local single_only="${2:-0}" raw token idx i=1
    local -a names=() statuses=() images=() tokens=()
    VPS_DOCKER_SELECTED=()

    while IFS=$'\t' read -r cname cstatus cimage; do
        [ -n "$cname" ] || continue
        names+=("$cname")
        statuses+=("$cstatus")
        images+=("$cimage")
    done < <(docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null)

    if [ "${#names[@]}" -eq 0 ]; then
        echo -e "${gl_hui}当前没有 Docker 容器${gl_bai}"
        return 1
    fi

    echo -e "${gl_kjlan}当前容器列表：${gl_bai}"
    for ((i=0; i<${#names[@]}; i++)); do
        printf "  ${gl_kjlan}%2d.${gl_bai} %-24s %-22s ${gl_hui}%s${gl_bai}\n" "$((i + 1))" "${names[i]}" "${statuses[i]}" "${images[i]}"
    done
    echo ""

    read -r -e -p "$prompt" raw || return 1
    [ -n "${raw//[[:space:]]/}" ] || return 1
    [ "$raw" = "0" ] && return 2

    read -r -a tokens <<< "$raw"
    if [ "$single_only" -eq 1 ] && [ "${#tokens[@]}" -gt 1 ]; then
        echo "该操作仅支持选择单个容器" >&2
        return 1
    fi

    for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            idx=$((10#$token))
            if ((idx >= 1 && idx <= ${#names[@]})); then
                VPS_DOCKER_SELECTED+=("${names[idx-1]}")
            else
                echo "序号超出范围: $token" >&2
                return 1
            fi
        elif [[ "$token" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
            VPS_DOCKER_SELECTED+=("$token")
        else
            echo "容器名称无效: $token" >&2
            return 1
        fi
    done
    [ "${#VPS_DOCKER_SELECTED[@]}" -gt 0 ]
}

docker_check_updates() {
    command -v docker >/dev/null 2>&1 || { echo "尚未安装 Docker" >&2; return 1; }
    command -v curl >/dev/null 2>&1 || pkg_install curl ca-certificates || return 1
    command -v jq >/dev/null 2>&1 || pkg_install jq >/dev/null 2>&1 || true

    local -a containers=()
    mapfile -t containers < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
    if [ "${#containers[@]}" -eq 0 ]; then
        echo "当前没有 Docker 容器。"
        return 0
    fi

    echo -e "${gl_kjlan}正在向镜像仓库查询容器镜像更新状态 (无需下载完整镜像)...${gl_bai}"
    printf "%-24s %-34s %s\n" "容器名称" "当前镜像" "检测结果"
    echo "--------------------------------------------------------------------------------"

    local cname info created_at full_image image_id docker_ref repo tag api_url payload remote_digest local_digest status_str
    for cname in "${containers[@]}"; do
        info=$(docker inspect --format='{{.Created}}|{{.Config.Image}}|{{.Image}}' "$cname" 2>/dev/null) || continue
        IFS='|' read -r created_at full_image image_id <<< "$info"
        status_str="${gl_hui}跳过 (非 Docker Hub 或私有镜像)${gl_bai}"

        docker_ref="${full_image#docker.io/}"
        docker_ref="${docker_ref#index.docker.io/}"
        docker_ref="${docker_ref#registry-1.docker.io/}"

        if [[ "$docker_ref" != *.io/* && "$docker_ref" != *.*/*:* && "$docker_ref" != localhost/* ]]; then
            if [[ "$docker_ref" == *@* ]]; then
                repo="${docker_ref%@*}"
                tag="latest"
            elif [[ "${docker_ref##*/}" == *:* ]]; then
                repo="${docker_ref%:*}"
                tag="${docker_ref##*:}"
            else
                repo="$docker_ref"
                tag="latest"
            fi
            [[ "$repo" == */* ]] || repo="library/$repo"
            api_url="https://hub.docker.com/v2/repositories/${repo}/tags/${tag}"
            payload=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 5 --max-time 8 "$api_url" 2>/dev/null || true)
            if [ -n "$payload" ]; then
                if command -v jq >/dev/null 2>&1; then
                    remote_digest=$(printf '%s' "$payload" | jq -r '.digest // empty' 2>/dev/null || true)
                else
                    remote_digest=$(printf '%s' "$payload" | grep -oE '"digest"[[:space:]]*:[[:space:]]*"sha256:[a-f0-9]{64}"' | head -n1 | grep -oE 'sha256:[a-f0-9]{64}' || true)
                fi
                local_digest=$(docker image inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$image_id" 2>/dev/null |
                    sed -n 's/^.*@\(sha256:[a-f0-9]\{64\}\)$/\1/p' | head -n 1)
                if [[ "$remote_digest" =~ ^sha256:[a-f0-9]{64}$ && "$local_digest" =~ ^sha256:[a-f0-9]{64}$ ]]; then
                    if [ "$remote_digest" != "$local_digest" ]; then
                        status_str="${gl_huang}发现新版本!${gl_bai}"
                    else
                        status_str="${gl_lv}已是最新${gl_bai}"
                    fi
                else
                    status_str="${gl_hui}无本地摘要可比对${gl_bai}"
                fi
            else
                status_str="${gl_hui}仓库查询超时/未公开${gl_bai}"
            fi
        fi
        printf "%-24s %-34s %b\n" "$cname" "$full_image" "$status_str"
    done
}

docker_container_menu() {
    local choice rc=0 name log_mode img confirm
    local -a VPS_DOCKER_SELECTED=()
    while true; do
        clear
        echo -e "${gl_kjlan}==================== Docker 容器管理 ====================${gl_bai}"
        docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo -e "${gl_kjlan}---------------------------------------------------------${gl_bai}"
        echo "1. 启动容器 (支持序号/多选)    2. 停止容器 (支持序号/多选)"
        echo "3. 删除容器 (支持序号/多选)    4. 重启容器 (支持序号/多选)"
        echo "5. 进入容器终端 (序号/名称)    6. 查看容器日志 (序号/名称)"
        echo "7. 查看容器资源占用 (stats)    8. 拉取容器最新镜像"
        echo "9. 检测所有容器镜像是否有更新"
        echo "0. 返回"
        echo -e "${gl_kjlan}---------------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0
        case $choice in
            1)
                rc=0; docker_select_containers "请输入要启动的容器序号或名称 (空格分隔，0 返回): " 0 || rc=$?
                [ "$rc" -eq 0 ] && docker start "${VPS_DOCKER_SELECTED[@]}" && break_end
                ;;
            2)
                rc=0; docker_select_containers "请输入要停止的容器序号或名称 (空格分隔，0 返回): " 0 || rc=$?
                [ "$rc" -eq 0 ] && docker stop "${VPS_DOCKER_SELECTED[@]}" && break_end
                ;;
            3)
                rc=0; docker_select_containers "请输入要删除的容器序号或名称 (空格分隔，0 返回): " 0 || rc=$?
                [ "$rc" -eq 0 ] || continue
                read -r -e -p "确认删除容器 [${VPS_DOCKER_SELECTED[*]}]？(Y/N): " confirm || return 0
                [[ "$confirm" =~ ^[Yy]$ ]] && docker rm -f "${VPS_DOCKER_SELECTED[@]}"
                break_end
                ;;
            4)
                rc=0; docker_select_containers "请输入要重启的容器序号或名称 (空格分隔，0 返回): " 0 || rc=$?
                [ "$rc" -eq 0 ] && docker restart "${VPS_DOCKER_SELECTED[@]}" && break_end
                ;;
            5)
                rc=0; docker_select_containers "请输入要进入的容器序号或名称 (0 返回): " 1 || rc=$?
                [ "$rc" -eq 0 ] || continue
                name="${VPS_DOCKER_SELECTED[0]}"
                if docker exec "$name" /bin/sh -c 'command -v bash' >/dev/null 2>&1; then
                    docker exec -it "$name" /bin/bash
                else
                    docker exec -it "$name" /bin/sh
                fi
                ;;
            6)
                rc=0; docker_select_containers "请输入要查看日志的容器序号或名称 (0 返回): " 1 || rc=$?
                [ "$rc" -eq 0 ] || continue
                name="${VPS_DOCKER_SELECTED[0]}"
                read -r -e -p "日志模式 [1: 最近200行(默认) / 2: 实时追踪 -f]: " log_mode || return 0
                if [ "$log_mode" = "2" ]; then
                    echo "按 Ctrl+C 退出实时日志..."
                    docker logs -f --tail 100 "$name" || true
                else
                    docker logs --tail 200 "$name"
                fi
                break_end
                ;;
            7) docker stats --no-stream; break_end ;;
            8)
                rc=0; docker_select_containers "请输入要更新镜像的容器序号或名称 (0 返回): " 1 || rc=$?
                [ "$rc" -eq 0 ] || continue
                name="${VPS_DOCKER_SELECTED[0]}"
                img=$(docker inspect --format='{{.Config.Image}}' "$name" 2>/dev/null || true)
                if [ -n "$img" ]; then
                    echo "正在拉取最新镜像: $img"
                    docker pull "$img"
                    echo "拉取完成；如需生效请通过原 compose/run 方式重建容器。"
                else
                    echo "未找到容器: $name" >&2
                fi
                break_end
                ;;
            9) clear; docker_check_updates; break_end ;;
            0) break ;;
            *) echo "无效选择" ; sleep 1 ;;
        esac
    done
}

docker_apply_daemon_candidate() {
    local candidate="$1" config="/etc/docker/daemon.json" backup=""
    if [ -f "$config" ]; then
        backup="/etc/docker/daemon.json.vps-backup-$(date +%Y%m%d-%H%M%S)"
        cp -p -- "$config" "$backup" || { rm -f -- "$candidate"; return 1; }
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
}

docker_configure_daemon() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local config=/etc/docker/daemon.json candidate max_size max_file mirror base_json="{}"
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

    read -r -e -p "镜像加速地址 (HTTPS，留空则保留现有加速配置): " mirror || return 0
    if [ -n "$mirror" ]; then
        [[ "$mirror" =~ ^https://[A-Za-z0-9._:/-]+$ ]] || { echo "镜像加速地址必须为有效的 HTTPS URL" >&2; return 1; }
    fi

    command -v jq >/dev/null 2>&1 || pkg_install jq >/dev/null 2>&1 || true
    candidate=$(mktemp /etc/docker/.daemon.json.vps.XXXXXX) || return 1

    if command -v jq >/dev/null 2>&1 && { [ ! -s "$config" ] || jq -e . "$config" >/dev/null 2>&1; }; then
        [ -s "$config" ] && base_json=$(cat "$config")
        if [ -n "$mirror" ]; then
            printf '%s\n' "$base_json" | jq \
                --arg ms "$max_size" --arg mf "$max_file" --arg mr "$mirror" \
                '. + {"log-driver": "json-file", "log-opts": ((.["log-opts"] // {}) + {"max-size": $ms, "max-file": $mf}), "registry-mirrors": [$mr]}' > "$candidate" || { rm -f -- "$candidate"; return 1; }
        else
            printf '%s\n' "$base_json" | jq \
                --arg ms "$max_size" --arg mf "$max_file" \
                '. + {"log-driver": "json-file", "log-opts": ((.["log-opts"] // {}) + {"max-size": $ms, "max-file": $mf})}' > "$candidate" || { rm -f -- "$candidate"; return 1; }
        fi
    else
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
    fi

    docker_apply_daemon_candidate "$candidate" || return 1
    echo "提示：已保留 daemon.json 中的其他自定义字段；日志轮转限制对新建容器生效。"
}

docker_toggle_ipv6() {
    [ "$(id -u)" -eq 0 ] || { echo "需要 root 权限" >&2; return 1; }
    local mode="$1" config=/etc/docker/daemon.json candidate base_json="{}" cidr
    [ ! -L "$config" ] || { echo "拒绝覆盖 daemon.json 符号链接" >&2; return 1; }
    command -v jq >/dev/null 2>&1 || pkg_install jq || return 1
    mkdir -p /etc/docker || return 1
    if [ -s "$config" ]; then
        jq -e . "$config" >/dev/null 2>&1 || { echo "现有 $config 不是有效 JSON，请先检查" >&2; return 1; }
        base_json=$(cat "$config")
    fi

    candidate=$(mktemp /etc/docker/.daemon.json.vps.XXXXXX) || return 1
    if [ "$mode" = "on" ]; then
        read -r -e -p "Docker IPv6 子网 fixed-cidr-v6 [默认 fd00:dead:beef::/64]: " cidr || { rm -f -- "$candidate"; return 0; }
        cidr="${cidr:-fd00:dead:beef::/64}"
        [[ "$cidr" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] || { rm -f -- "$candidate"; echo "IPv6 CIDR 格式无效" >&2; return 1; }
        printf '%s\n' "$base_json" | jq --arg cidr "$cidr" \
            '. + {"ipv6": true, "fixed-cidr-v6": $cidr, "experimental": true, "ip6tables": true}' > "$candidate" || { rm -f -- "$candidate"; return 1; }
    else
        printf '%s\n' "$base_json" | jq \
            'del(.["fixed-cidr-v6"], .ip6tables) | .ipv6 = false' > "$candidate" || { rm -f -- "$candidate"; return 1; }
    fi
    docker_apply_daemon_candidate "$candidate"
}

docker_menu() {
    local choice ipv6_state confirm
    while true; do
        clear
        echo -e "${gl_kjlan}====================== Docker 管理 ======================${gl_bai}"
        docker_status_overview
        if [ -f /etc/docker/daemon.json ] && grep -Eq '"ipv6"[[:space:]]*:[[:space:]]*true' /etc/docker/daemon.json 2>/dev/null; then
            ipv6_state="${gl_lv}已开启${gl_bai}"
        else
            ipv6_state="${gl_hui}未开启${gl_bai}"
        fi
        echo -e "${gl_kjlan}---------------------------------------------------------${gl_bai}"
        echo "1. 安装/更新 Docker"
        echo "2. 查看 Docker 全局状态"
        echo "3. 容器管理 (支持序号选择/多选/镜像更新检测)"
        echo "4. 镜像列表"
        echo "5. 清理停止的容器/无用镜像/网络（保留卷）"
        echo "6. 卸载 Docker"
        echo "7. 单独清理未使用的匿名数据卷"
        echo "8. 配置日志轮转与镜像加速 (无损合并 daemon.json)"
        echo -e "9. 开启 / 关闭 Docker IPv6 支持 [当前: ${ipv6_state}]"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}---------------------------------------------------------${gl_bai}"
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
            9)
                local v6_act
                read -r -e -p "Docker IPv6 [1: 开启 / 2: 关闭 / 0: 取消]: " v6_act || return 0
                case "$v6_act" in
                    1) docker_toggle_ipv6 on; break_end ;;
                    2) docker_toggle_ipv6 off; break_end ;;
                esac
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

