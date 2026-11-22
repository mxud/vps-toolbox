vps_help() {
    cat <<EOF
VPS 工具箱 v$sh_v

用法:
  $VPS_DEFAULT_SHORTCUT                启动交互菜单
  $VPS_DEFAULT_SHORTCUT info [--plain] 显示系统信息（--plain 纯文本输出）
  $VPS_DEFAULT_SHORTCUT update         系统更新
  $VPS_DEFAULT_SHORTCUT clean          系统清理
  $VPS_DEFAULT_SHORTCUT tools          基础工具管理
  $VPS_DEFAULT_SHORTCUT docker         Docker 管理
  $VPS_DEFAULT_SHORTCUT caddy          Caddy 管理
  $VPS_DEFAULT_SHORTCUT tailscale      Tailscale 组网管理 (别名: ts)
  $VPS_DEFAULT_SHORTCUT bbr            BBR 管理
  $VPS_DEFAULT_SHORTCUT warp           WARP 管理
  $VPS_DEFAULT_SHORTCUT test           测试脚本合集
  $VPS_DEFAULT_SHORTCUT settings       系统工具
  $VPS_DEFAULT_SHORTCUT dd             一键重装系统
  $VPS_DEFAULT_SHORTCUT sshkey         用户密钥登录模式
  $VPS_DEFAULT_SHORTCUT fail2ban       SSH 防爆破 (Fail2ban)
  $VPS_DEFAULT_SHORTCUT firewall       防火墙管理 (UFW/Firewalld)
  $VPS_DEFAULT_SHORTCUT diag [--quick] 磁盘与负载排查
  $VPS_DEFAULT_SHORTCUT optimize       一键系统优化 (别名: opt)
  $VPS_DEFAULT_SHORTCUT dns            优化 DNS 地址
  $VPS_DEFAULT_SHORTCUT install <包>   安装软件
  $VPS_DEFAULT_SHORTCUT remove <包>    卸载软件
  $VPS_DEFAULT_SHORTCUT swap <MB>      设置虚拟内存
  $VPS_DEFAULT_SHORTCUT time <时区>    设置时区
  $VPS_DEFAULT_SHORTCUT reboot         重启服务器
  $VPS_DEFAULT_SHORTCUT shortcut       设置快捷键
  $VPS_DEFAULT_SHORTCUT upgrade        更新工具箱脚本
  $VPS_DEFAULT_SHORTCUT uninstall-self 卸载工具箱脚本
  $VPS_DEFAULT_SHORTCUT help           显示此帮助

服务管理:
  $VPS_DEFAULT_SHORTCUT start <服务>
  $VPS_DEFAULT_SHORTCUT stop <服务>
  $VPS_DEFAULT_SHORTCUT restart <服务>
  $VPS_DEFAULT_SHORTCUT status <服务>
  $VPS_DEFAULT_SHORTCUT enable <服务>
EOF
}

