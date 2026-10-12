# VPS Toolbox

一个基于 Bash 开发的轻量级 Linux VPS 管理工具箱，提供常用的服务器维护、系统配置、Docker 管理和网络诊断功能。

采用模块化开发架构，最终构建为独立的 Shell 脚本，无需下载完整项目即可使用。

## 功能特性

| 功能分类    | 功能说明                                       |
| ----------- | ---------------------------------------------- |
| 系统信息    | 查看 CPU、内存、Swap、磁盘、系统负载、网络信息 |
| 系统管理    | 系统更新、软件清理、主机名与时区设置           |
| Docker 管理 | 安装、更新、容器管理、镜像管理及清理           |
| SSH 管理    | 修改 SSH 端口、配置公钥认证、管理登录方式      |
| 网络管理    | DNS 设置、IPv4 优先级、BBR 拥塞控制            |
| VPS 测试    | YABS、ECS、NodeQuality、IPQuality 等           |
| WARP        | Cloudflare WARP 第三方脚本                     |
| 系统重装    | DD 系统重装                                    |
| 常用工具    | 安装和管理常用 Linux 工具                      |
| 自更新      | 在线检查并更新工具箱                           |

## 一键安装

```
curl -fsSLO https://raw.githubusercontent.com/mxud/vps-toolbox/main/install.sh && sudo bash install.sh mxud/vps-toolbox
```

安装完成后执行：

```
vps
```

即可进入交互式管理菜单。

## 命令行使用

```
vps                 # 打开主菜单
vps info            # 查看系统信息
vps docker          # Docker 管理
vps sshkey          # SSH 密钥管理
vps dns             # DNS 管理
vps bbr             # BBR 管理
vps dd              # 系统重装
vps upgrade         # 更新工具箱
vps help            # 查看帮助
```

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
