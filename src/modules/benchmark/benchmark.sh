# ============ 测试脚本 ============

linux_test() {
    while true; do
        clear
        echo -e "${gl_kjlan}==================== 测试脚本合集 ====================${gl_bai}"
        echo -e "${gl_huang}【 IP 与解锁检测 】${gl_bai}"
        echo "1. IP 质量与风控体检 (IPQuality)"
        echo "2. 流媒体服务解锁检测 (RegionRestrictionCheck)"
        echo ""
        echo -e "${gl_huang}【 网络线路与测速 】${gl_bai}"
        echo "3. BestTrace 三网回程延迟路由"
        echo "4. 三网回程多路线检测 (backtrace)"
        echo "5. 泰尔网速三网测速 (TaiErSpeedtest)"
        echo "6. TCP 重传率与网络质量探测 (TcpQuality)"
        echo ""
        echo -e "${gl_huang}【 硬件性能测试 】${gl_bai}"
        echo "7. YABS 性能基准测试 (CPU/FIO/带宽)"
        echo "8. 硬件性能质量体检 (HardwareQuality)"
        echo ""
        echo -e "${gl_huang}【 综合大满贯评测 】${gl_bai}"
        echo "9. 融合怪综合测评 (ECS) ★"
        echo "10. NodeQuality 全功能综合评测"
        echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
        echo "0. 返回主菜单"
        echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
        read -r -e -p "请输入你的选择: " choice || return 0

        case $choice in
            1)  run_remote_bash https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh ;;
            2)  run_remote_bash https://github.com/lmc999/RegionRestrictionCheck/raw/main/check.sh ;;
            3)  run_remote_bash "https://git.io/besttrace" ;;
            4)  run_remote_bash https://raw.githubusercontent.com/zhanghanyun/backtrace/main/install.sh ;;
            5)  run_remote_bash "https://raw.githubusercontent.com/MiaM1ku/taierspeedtest/main/taierspeedtest.sh" ;;
            6)  run_remote_bash "https://raw.githubusercontent.com/ibsgss/TcpQuality/main/runTcpQuality.sh" ;;
            7)  check_swap; run_remote_bash https://yabs.sh -i -5 ;;
            8)  check_swap; run_remote_bash "https://raw.githubusercontent.com/xykt/HardwareQuality/main/hq.sh" ;;
            9)  run_remote_bash https://github.com/spiritLHLS/ecs/raw/main/ecs.sh ;;
            10) run_remote_bash "https://run.NodeQuality.com" ;;
            0)  break ;;
            *)  echo "无效选择" ; sleep 1 ;;
        esac
        break_end
    done
}

