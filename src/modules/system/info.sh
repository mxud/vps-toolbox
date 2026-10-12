# ============ 系统信息 ============

output_status() {
    output=$(awk '
        function hum(x) {
            if (x > 1073741824) return sprintf("%.2fG", x/1073741824)
            if (x > 1048576) return sprintf("%.2fM", x/1048576)
            if (x > 1024) return sprintf("%.2fK", x/1024)
            return sprintf("%dB", x)
        }
        BEGIN { rx = 0; tx = 0 }
        $1 ~ /:$/ && $1 !~ /^(lo|docker|veth|br-)/ { rx += $2; tx += $10 }
        END {
            printf("%s %s\n", hum(rx), hum(tx))
        }' /proc/net/dev)
    rx=$(echo "$output" | awk '{print $1}')
    tx=$(echo "$output" | awk '{print $2}')
}

current_timezone() {
    if command -v timedatectl &>/dev/null; then
        timedatectl | grep "Time zone" | awk '{print $3}'
    else
        date +"%Z %z"
    fi
}

linux_info() {
    clear
    echo -e "${gl_kjlan}正在查询系统信息...${gl_bai}"

    local ipv4_address ipv6_address output rx tx
    local cpu_info cpu_usage cpu_cores cpu_freq mem_info swap_info disk_info
    local os_info kernel hostname uptime_str load timezone current_time
    local congestion queue dns_servers tcp_conn udp_conn

    ip_address

    # 1. CPU 采集 (彻底解决 Debian 下 lscpu 缺失/语言匹配失败)
    cpu_info=$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    [ -z "$cpu_info" ] && cpu_info=$(grep -m1 -E 'Hardware|Processor' /proc/cpuinfo | cut -d: -f2 | sed 's/^[ \t]*//')
    [ -z "$cpu_info" ] && cpu_info="未知型号"

    cpu_cores=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    cpu_freq=$(grep -m1 -i "cpu MHz" /proc/cpuinfo | awk '{printf "%.1f GHz", $4/1000}')
    [ -z "$cpu_freq" ] && cpu_freq="虚拟化/不可用"

    cpu_usage=$(awk '{idle=$5+$6; total=0; for(i=2;i<=9;i++)total+=$i; if(NR==1){idle1=idle; total1=total;} else {dt=total-total1; printf "%.0f\n", (dt>0 ? (dt-(idle-idle1))*100/dt : 0)}}' \
        <(grep 'cpu ' /proc/stat) <(sleep 1; grep 'cpu ' /proc/stat))

    # 2. 内存与 Swap 采集 (统一走 /proc/meminfo，精准无误)
    local mem_total mem_avail mem_used mem_p
    mem_total=$(awk '/MemTotal:/ {print int($2/1024)}' /proc/meminfo)
    mem_avail=$(awk '/MemAvailable:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    if [ -z "$mem_avail" ] || [ "$mem_avail" -eq 0 ]; then
        local mem_free buffers cached
        mem_free=$(awk '/MemFree:/ {print int($2/1024)}' /proc/meminfo)
        buffers=$(awk '/Buffers:/ {print int($2/1024)}' /proc/meminfo)
        cached=$(awk '/^Cached:/ {print int($2/1024)}' /proc/meminfo)
        mem_avail=$((mem_free + buffers + cached))
    fi
    mem_used=$((mem_total - mem_avail))
    mem_p=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN {printf "%.1f", (t>0 ? u*100/t : 0)}')
    mem_info="${mem_used}M/${mem_total}M (${mem_p}%)"

    local s_total s_free s_used s_p
    s_total=$(awk '/SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    s_free=$(awk '/SwapFree:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    s_used=$((s_total - s_free))
    if [ "${s_total:-0}" -gt 0 ]; then
        s_p=$(awk -v u="$s_used" -v t="$s_total" 'BEGIN {printf "%.1f", u*100/t}')
        swap_info="${s_used}M/${s_total}M (${s_p}%)"
    else
        swap_info="未启用"
    fi

    # 3. 基础系统参数
    disk_info=$(df -h | awk '$NF=="/"{printf "%s/%s (%s)", $3, $2, $5}')
    os_info=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d '=' -f2 | tr -d '"')
    kernel=$(uname -r)
    hostname=$(uname -n)
    uptime_str=$(awk -F. '{d=int($1/86400); h=int(($1%86400)/3600); m=int(($1%3600)/60); if(d>0)printf "%d天 ",d; if(h>0)printf "%d时 ",h; printf "%d分",m}' /proc/uptime)
    load=$(uptime | awk '{print $(NF-2), $(NF-1), $NF}')
    timezone=$(current_timezone)
    current_time=$(date "+%Y-%m-%d %H:%M:%S")
    congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    queue=$(sysctl -n net.core.default_qdisc 2>/dev/null)

    # 4. 融合指标：连接数与当前生效 DNS
    tcp_conn=$(ss -H -t 2>/dev/null | wc -l)
    udp_conn=$(ss -H -u 2>/dev/null | wc -l)
    dns_servers=$(awk '/^nameserver/ {printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)

    output_status

    clear
    echo -e "${gl_kjlan}==================== 系统信息 ====================${gl_bai}"
    echo -e "${gl_kjlan}主机名:        ${gl_bai}$hostname"
    echo -e "${gl_kjlan}系统版本:      ${gl_bai}$os_info"
    echo -e "${gl_kjlan}内核版本:      ${gl_bai}$kernel"
    echo -e "${gl_kjlan}系统架构:      ${gl_bai}$(uname -m)"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}CPU 型号:      ${gl_bai}$cpu_info"
    echo -e "${gl_kjlan}核心 / 频率:   ${gl_bai}$cpu_cores 核 / $cpu_freq"
    echo -e "${gl_kjlan}CPU 使用率:    ${gl_bai}${cpu_usage}%"
    echo -e "${gl_kjlan}系统负载:      ${gl_bai}$load"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}物理内存:      ${gl_bai}$mem_info"
    echo -e "${gl_kjlan}虚拟内存:      ${gl_bai}$swap_info"
    echo -e "${gl_kjlan}系统硬盘:      ${gl_bai}$disk_info"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}TCP/UDP 连接:  ${gl_bai}${tcp_conn} | ${udp_conn}"
    echo -e "${gl_kjlan}总接收/发送:   ${gl_bai}$rx / $tx"
    echo -e "${gl_kjlan}网络算法:      ${gl_bai}$congestion $queue"
    [ -n "$ipv4_address" ] && echo -e "${gl_kjlan}IPv4 地址:     ${gl_bai}$ipv4_address"
    [ -n "$ipv6_address" ] && echo -e "${gl_kjlan}IPv6 地址:     ${gl_bai}$ipv6_address"
    [ -n "$dns_servers" ]  && echo -e "${gl_kjlan}DNS 地址:      ${gl_bai}$dns_servers"
    echo -e "${gl_kjlan}--------------------------------------------------${gl_bai}"
    echo -e "${gl_kjlan}当前时区:      ${gl_bai}$timezone"
    echo -e "${gl_kjlan}系统时间:      ${gl_bai}$current_time"
    echo -e "${gl_kjlan}运行时长:      ${gl_bai}$uptime_str"
    echo -e "${gl_kjlan}==================================================${gl_bai}"
    echo ""
}

