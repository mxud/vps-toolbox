# ============ 命令行入口 ============

vps_main() {
  if [ "$#" -eq 0 ]; then
    if [ "$(id -u)" -eq 0 ] && vps_self_install; then
        source_path=$(readlink -f "${BASH_SOURCE[0]}")
        if [ "$source_path" != "$VPS_INSTALL_PATH" ] && vps_is_toolbox "$VPS_INSTALL_PATH"; then
            exec bash "$VPS_INSTALL_PATH"
        fi
    fi
    vps_menu
  else
    case "$1" in
        -v|--version|version)    printf 'v%s\n' "$sh_v" ;;
        info|信息)               shift; linux_info "$@" ;;
        update|更新)             linux_update ;;
        clean|清理)              linux_clean ;;
        tools|工具)              linux_tools ;;
        docker)                  docker_menu ;;
        caddy)                   caddy_menu ;;
        ts|tailscale)            vps_tailscale_menu ;;
        bbr)                     shift; linux_bbr "$@" ;;
        warp)                    linux_warp ;;
        test|check|测试)         linux_test ;;
        settings|设置)           linux_settings ;;
        dd|reinstall|重装)       vps_dd_menu ;;
        sshkey|key)              shift; vps_ssh_key_menu "$@" ;;
        sshport|ssh-port)        shift; change_ssh_port "$@" ;;
        f2b|fail2ban)            vps_fail2ban_menu ;;
        fw|firewall|防火墙)      shift; vps_firewall_menu "$@" ;;
        diag|disk|排查)          shift; vps_diag_menu "$@" ;;
        opt|optimize|优化)       vps_optimize_menu ;;
        dns)                     shift; vps_dns_menu "$@" ;;
        mirror|换源)             vps_switch_mirror ;;
        install|add|安装)        shift; pkg_install "$@" ;;
        remove|uninstall|卸载)   shift; pkg_remove "$@" ;;
        swap)                    shift; add_swap "$@" ;;
        time|时区)               shift; set_timedate "$@" ;;
        reboot|重启)             server_reboot ;;
        start|启动)              shift; start "$@" ;;
        stop|停止)               shift; stop "$@" ;;
        restart|服务重启)        shift; restart "$@" ;;
        status|状态)             shift; status "$@" ;;
        enable|自启)             shift; enable "$@" ;;
        shortcut|快捷键)         vps_set_shortcut ;;
        upgrade|update-self)     vps_update ;;
        rollback|回滚)           vps_rollback ;;
        uninstall-self|remove-self) vps_uninstall ;;
        help|-h|--help)          vps_help ;;
        *)                       vps_help ;;
    esac
  fi
}
