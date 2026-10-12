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
        info|信息)               linux_info ;;
        update|更新)             linux_update ;;
        clean|清理)              linux_clean ;;
        tools|工具)              linux_tools ;;
        docker)                  docker_menu ;;
        bbr)                     linux_bbr ;;
        warp)                    linux_warp ;;
        test|check|测试)         linux_test ;;
        settings|设置)           linux_settings ;;
        dd|reinstall|重装)       vps_dd_menu ;;
        sshkey|key)              vps_ssh_key_menu ;;
        dns)                     vps_dns_menu ;;
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
        help|-h|--help)          vps_help ;;
        *)                       vps_help ;;
    esac
  fi
}
