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

