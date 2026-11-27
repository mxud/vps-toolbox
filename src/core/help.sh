vps_help() {
    cat <<EOF
VPS 工具箱 v$sh_v

用法:
  $VPS_DEFAULT_SHORTCUT                启动交互菜单
  $VPS_DEFAULT_SHORTCUT -v|--version   显示脚本版本号
  $VPS_DEFAULT_SHORTCUT info [--plain] 显示系统信息（--plain 纯文本输出）
  $VPS_DEFAULT_SHORTCUT update         系统更新
  $VPS_DEFAULT_SHORTCUT clean          系统清理
  $VPS_DEFAULT_SHORTCUT tools          基础工具管理
  $VPS_DEFAULT_SHORTCUT docker         Docker 管理 (容器序号选择/镜像更新检测/IPv6)
  $VPS_DEFAULT_SHORTCUT caddy          Caddy 管理
  $VPS_DEFAULT_SHORTCUT tailscale      Tailscale 组网管理 (别名: ts)
  $VPS_DEFAULT_SHORTCUT bbr [on|off|status|xanmod]
                     BBR 与 XanMod BBRv3 内核管理
  $VPS_DEFAULT_SHORTCUT warp           WARP 管理
  $VPS_DEFAULT_SHORTCUT test           测试脚本合集
  $VPS_DEFAULT_SHORTCUT settings       系统工具
  $VPS_DEFAULT_SHORTCUT dd             一键重装系统
  $VPS_DEFAULT_SHORTCUT sshkey [github <用户>|<URL>|"<公钥>"]
                     用户密钥登录管理与快捷公钥导入
  $VPS_DEFAULT_SHORTCUT sshport [端口] 修改 SSH 端口 (自动放行防火墙并同步 Fail2ban)
  $VPS_DEFAULT_SHORTCUT fail2ban       SSH 防爆破 (Fail2ban，别名: f2b)
  $VPS_DEFAULT_SHORTCUT firewall [status|ping <on|off|status>]
                     防火墙与禁 Ping (ICMP) 管理 (别名: fw)
  $VPS_DEFAULT_SHORTCUT diag [--quick] 磁盘与负载排查
  $VPS_DEFAULT_SHORTCUT optimize       一键系统优化与 4 档自适应内核调优 (别名: opt)
  $VPS_DEFAULT_SHORTCUT dns [auto|cn|global|restore|<IP...>]
                     优化或设置 DNS 地址
  $VPS_DEFAULT_SHORTCUT mirror         切换系统软件源 (LinuxMirrors)
  $VPS_DEFAULT_SHORTCUT install <包>   安装软件
  $VPS_DEFAULT_SHORTCUT remove <包>    卸载软件
  $VPS_DEFAULT_SHORTCUT swap <MB|off>  设置或关闭虚拟内存
  $VPS_DEFAULT_SHORTCUT time <时区>    设置时区
  $VPS_DEFAULT_SHORTCUT reboot         重启服务器
  $VPS_DEFAULT_SHORTCUT shortcut       设置快捷键
  $VPS_DEFAULT_SHORTCUT upgrade        更新工具箱脚本 (支持热重载)
  $VPS_DEFAULT_SHORTCUT rollback       回滚工具箱至上一备份版本 (.bak)
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

