# VPS Toolbox

一个基于 Bash 开发的轻量级 Linux VPS 管理工具箱，提供常用的服务器维护、系统配置、Docker 管理和网络诊断功能。

采用模块化开发架构，最终构建为独立的 Shell 脚本，无需下载完整项目即可使用。

## 功能特性

| 功能分类    | 功能说明                                       |
| ----------- | ---------------------------------------------- |
| 系统信息    | 查看 CPU、内存、Swap、磁盘、系统负载、网络信息（支持 `--plain` 纯文本） |
| 系统管理    | 系统更新、软件清理、新机一键优化、主机名与时区设置、磁盘与负载排查      |
| Docker 管理 | 安装、更新、容器/镜像管理、日志轮转与镜像加速、清理                     |
| Caddy 管理  | 安装（APT/DNF/APK）、反代配置、校验重载及迁移备份/导入                  |
| Tailscale   | 安装/升级、登录、标签 (Tags)、Exit Node、子网路由、Tailscale SSH 与诊断 |
| SSH 与安全  | 修改 SSH 端口、公钥认证、Fail2ban 防爆破、UFW/Firewalld 防火墙管理      |
| 网络管理    | DNS 设置、IPv4 优先级、BBR 拥塞控制                                     |
| VPS 测试    | YABS、ECS、NodeQuality、IPQuality、MTR 回程路由等                       |
| WARP        | Cloudflare WARP 第三方脚本                                              |
| 系统重装    | 在线重装 Linux / Windows（支持自定义端口、SSH 密钥与自定义发行版）      |
| 常用工具    | 安装和管理常用 Linux 工具                                               |
| 自更新      | 在线检查并更新工具箱                                                    |

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/mxud/vps-toolbox/main/install.sh | sudo bash -s -- mxud/vps-toolbox
```

安装完成后执行：

```
vps
```

即可进入交互式管理菜单。

## 命令行使用

```
vps                 # 打开主菜单
vps info            # 查看系统信息（支持 vps info --plain）
vps docker          # Docker 管理
vps caddy           # Caddy 管理
vps tailscale       # Tailscale 组网管理（别名 vps ts）
vps sshkey          # SSH 密钥管理
vps fail2ban        # SSH 防爆破 (Fail2ban，别名 vps f2b)
vps firewall        # 防火墙管理 (UFW / Firewalld，别名 vps fw)
vps diag            # 磁盘与负载排查（支持 vps diag --quick）
vps optimize        # 新机一键优化与内核调优（别名 vps opt）
vps dns             # DNS 管理
vps bbr             # BBR 管理
vps dd              # 系统重装
vps upgrade         # 更新工具箱
vps uninstall-self  # 卸载工具箱
vps help            # 查看帮助
```

### 可选环境变量

- `VPS_GITHUB_PROXY`：自定义 GitHub 加速前缀（默认 `https://`，例如 `https://gh-proxy.com/https://`），用于国内网络环境下载更新与第三方脚本。
- `VPS_UPDATE_URL`：自定义 `vps upgrade` 的 HTTPS 更新地址（默认使用安装时记录的仓库 `main` 分支）。

## 开发与构建

项目采用模块化架构，源代码位于 `src/` 目录。

```
git clone https://github.com/mxud/vps-toolbox.git
cd vps-toolbox

make build
make test
```

构建结果位于：

```
dist/vps-toolbox.sh
```

## 系统支持

主要面向 Debian、Ubuntu 等 Linux 发行版，部分功能兼容 Alpine、Rocky Linux、AlmaLinux、Arch Linux 等系统。

不同发行版的功能支持程度可能存在差异。

## 注意事项

涉及 SSH、网络配置、防火墙和系统重装的操作可能影响服务器连接或数据，请在执行前做好备份。

部分功能需要 root 权限，并依赖第三方开源项目。

## 开源协议

Apache License 2.0
