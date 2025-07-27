#!/bin/bash

# =============================================================================
# Network Interface Diagnostic Tool (Enhanced)
# 网络接口高级诊断工具
# 
# 用于检查网络接口的错误统计、光模块信号质量、温度监控和性能分析
# 支持多种输出格式和高级诊断功能
# =============================================================================

set -euo pipefail

# 脚本信息
SCRIPT_NAME="Network Interface Diagnostic Tool"
VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# 默认配置
DEFAULT_INTERFACE="eth0"
DEFAULT_OUTPUT_FORMAT="table"
DEFAULT_CHECK_ALL=false
DEFAULT_INCLUDE_OFFLINE=false
DEFAULT_SAVE_REPORT=false
DEFAULT_VERBOSE=false

# 全局变量
INTERFACE=""
OUTPUT_FORMAT=""
CHECK_ALL=false
INCLUDE_OFFLINE=false
SAVE_REPORT=false
VERBOSE=false
REPORT_FILE=""
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# =============================================================================
# 工具函数
# =============================================================================

log() {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        ERROR)   echo -e "${RED}[ERROR]${NC} $*" >&2 ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $*" ;;
        INFO)    echo -e "${GREEN}[INFO]${NC} $*" ;;
        DEBUG)   [[ $VERBOSE == true ]] && echo -e "${BLUE}[DEBUG]${NC} $*" ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $*" ;;
    esac
}

print_separator() {
    echo "========================================================================================"
}

print_table_header() {
    local title="$1"
    echo
    echo -e "${CYAN}=== $title ===${NC}"
    print_separator
}

# 格式化数值
format_number() {
    local num=$1
    if [[ $num -gt 1000000 ]]; then
        echo "$(echo "scale=1; $num/1000000" | bc)M"
    elif [[ $num -gt 1000 ]]; then
        echo "$(echo "scale=1; $num/1000" | bc)K"
    else
        echo "$num"
    fi
}

# 状态颜色化
colorize_status() {
    local status=$1
    local value=$2
    
    case $status in
        "UP"|"RUNNING"|"yes") echo -e "${GREEN}$value${NC}" ;;
        "DOWN"|"no") echo -e "${RED}$value${NC}" ;;
        "WARNING") echo -e "${YELLOW}$value${NC}" ;;
        *) echo "$value" ;;
    esac
}

# =============================================================================
# 帮助和版本信息
# =============================================================================

show_help() {
    cat << EOF
${SCRIPT_NAME} v${VERSION}

用法: $0 [选项] [接口名]

必需参数:
  接口名                    要检查的网络接口 (默认: $DEFAULT_INTERFACE)

可选参数:
  -a, --all                 检查所有可用网络接口
  -o, --output FORMAT       输出格式 [table|json|csv|report] (默认: table)
  -i, --include-offline     包含离线接口
  -s, --save FILE           保存报告到文件
  -v, --verbose             详细输出
  -t, --temperature         显示温度信息 (需要lm-sensors)
  -p, --performance         显示性能统计
  -e, --errors-only         仅显示有错误的项目
  -c, --compact             紧凑输出模式 (兼容旧版本)
  -h, --help                显示帮助信息
  -V, --version             显示版本信息

输出格式:
  table                     表格格式 (默认，易读)
  json                      JSON格式 (便于解析)
  csv                       CSV格式 (便于导入)
  report                    详细报告格式

检查类型:
  基础信息                  接口状态、速度、双工模式
  错误统计                  RX/TX错误、丢包统计
  光模块信息                功率、温度、信号质量
  性能统计                  吞吐量、PPS统计
  温度监控                  硬件温度传感器

示例:
  $0 eth0                   检查单个接口 (表格输出)
  $0 -a                     检查所有接口
  $0 -a -o json             检查所有接口 (JSON输出)
  $0 eth0 -s report.txt     检查并保存报告
  $0 -a -i -p              检查所有接口包含离线和性能
  $0 -e                     仅显示有错误的接口
  $0 --temperature eth0     显示温度信息

注意:
  - 某些功能需要root权限
  - 光模块检查需要支持的硬件
  - 性能统计可能需要特定驱动支持

EOF
}

show_version() {
    echo "${SCRIPT_NAME} v${VERSION}"
    echo "Enhanced network interface diagnostic tool"
}

# =============================================================================
# 参数解析
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--all)
                CHECK_ALL=true
                shift
                ;;
            -o|--output)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -i|--include-offline)
                INCLUDE_OFFLINE=true
                shift
                ;;
            -s|--save)
                SAVE_REPORT=true
                REPORT_FILE="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -t|--temperature)
                SHOW_TEMPERATURE=true
                shift
                ;;
            -p|--performance)
                SHOW_PERFORMANCE=true
                shift
                ;;
            -e|--errors-only)
                ERRORS_ONLY=true
                shift
                ;;
            -c|--compact)
                # 兼容旧版本的紧凑模式
                OUTPUT_FORMAT="compact"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -V|--version)
                show_version
                exit 0
                ;;
            -*)
                log ERROR "未知选项: $1"
                show_help
                exit 1
                ;;
            *)
                if [[ -z "$INTERFACE" ]]; then
                    INTERFACE="$1"
                else
                    log ERROR "只能指定一个网络接口"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # 设置默认值
    INTERFACE="${INTERFACE:-$DEFAULT_INTERFACE}"
    OUTPUT_FORMAT="${OUTPUT_FORMAT:-$DEFAULT_OUTPUT_FORMAT}"
    CHECK_ALL="${CHECK_ALL:-$DEFAULT_CHECK_ALL}"
    INCLUDE_OFFLINE="${INCLUDE_OFFLINE:-$DEFAULT_INCLUDE_OFFLINE}"
    SAVE_REPORT="${SAVE_REPORT:-$DEFAULT_SAVE_REPORT}"
    VERBOSE="${VERBOSE:-$DEFAULT_VERBOSE}"
    SHOW_TEMPERATURE="${SHOW_TEMPERATURE:-false}"
    SHOW_PERFORMANCE="${SHOW_PERFORMANCE:-false}"
    ERRORS_ONLY="${ERRORS_ONLY:-false}"
}

# =============================================================================
# 系统检查
# =============================================================================

check_dependencies() {
    local missing_deps=()
    
    # 检查必需工具
    if ! command -v ethtool &> /dev/null; then
        missing_deps+=("ethtool")
    fi
    
    if ! command -v ip &> /dev/null; then
        missing_deps+=("iproute2")
    fi
    
    # 检查可选工具
    if [[ $SHOW_TEMPERATURE == true ]] && ! command -v sensors &> /dev/null; then
        log WARN "lm-sensors未安装，无法显示温度信息"
        log INFO "安装命令: sudo apt-get install lm-sensors"
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log ERROR "缺少必需工具: ${missing_deps[*]}"
        log INFO "安装命令: sudo apt-get install ${missing_deps[*]}"
        exit 1
    fi
}

# 获取所有网络接口
get_interfaces() {
    local interfaces=()
    
    if [[ $CHECK_ALL == true ]]; then
        # 获取所有接口
        while IFS= read -r iface; do
            local status=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
            if [[ $INCLUDE_OFFLINE == true ]] || [[ "$status" == "up" ]]; then
                interfaces+=("$iface")
            fi
        done < <(ls /sys/class/net/ | grep -E '^(eth|ens|enp|eno|bond|team)' | sort)
    else
        # 检查指定接口是否存在
        if [[ ! -d "/sys/class/net/$INTERFACE" ]]; then
            log ERROR "网络接口 $INTERFACE 不存在"
            log INFO "可用接口: $(ls /sys/class/net/ | grep -E '^(eth|ens|enp|eno)' | tr '\n' ' ')"
            exit 1
        fi
        interfaces=("$INTERFACE")
    fi
    
    echo "${interfaces[@]}"
}

# =============================================================================
# 接口信息收集
# =============================================================================

get_interface_basic_info() {
    local iface=$1
    local info=()
    
    # 基本状态
    local operstate=$(cat /sys/class/net/$iface/operstate 2>/dev/null || echo "unknown")
    local carrier=$(cat /sys/class/net/$iface/carrier 2>/dev/null || echo "0")
    
    # ethtool信息
    local ethtool_info=$(ethtool "$iface" 2>/dev/null || echo "")
    local speed=$(echo "$ethtool_info" | grep "Speed:" | awk '{print $2}' | sed 's/Mb\/s//')
    local duplex=$(echo "$ethtool_info" | grep "Duplex:" | awk '{print $2}')
    local link_detected=$(echo "$ethtool_info" | grep "Link detected:" | awk '{print $3}')
    
    # IP地址
    local ip_addr=$(ip -4 addr show "$iface" | grep inet | awk '{print $2}' | cut -d'/' -f1 | head -1)
    
    # MAC地址
    local mac_addr=$(cat /sys/class/net/$iface/address 2>/dev/null || echo "unknown")
    
    # 驱动信息
    local driver=$(ethtool -i "$iface" 2>/dev/null | grep "driver:" | awk '{print $2}' || echo "unknown")
    local driver_version=$(ethtool -i "$iface" 2>/dev/null | grep "version:" | awk '{print $2}' || echo "unknown")
    
    echo "$iface|$operstate|$carrier|$speed|$duplex|$link_detected|$ip_addr|$mac_addr|$driver|$driver_version"
}

get_interface_errors() {
    local iface=$1
    local stats=$(ethtool -S "$iface" 2>/dev/null || echo "")
    
    # 计算各类错误
    local rx_errors=0
    local tx_errors=0
    local rx_dropped=0
    local tx_dropped=0
    local collisions=0
    
    if [[ -n "$stats" ]]; then
        rx_errors=$(echo "$stats" | grep -i "rx.*error\|rx.*err" | awk '{s+=$2} END {print s+0}')
        tx_errors=$(echo "$stats" | grep -i "tx.*error\|tx.*err" | awk '{s+=$2} END {print s+0}')
        rx_dropped=$(echo "$stats" | grep -i "rx.*drop" | awk '{s+=$2} END {print s+0}')
        tx_dropped=$(echo "$stats" | grep -i "tx.*drop" | awk '{s+=$2} END {print s+0}')
        collisions=$(echo "$stats" | grep -i "collision" | awk '{s+=$2} END {print s+0}')
    fi
    
    echo "$rx_errors|$tx_errors|$rx_dropped|$tx_dropped|$collisions"
}

get_optical_info() {
    local iface=$1
    local module_info=$(ethtool -m "$iface" 2>/dev/null || echo "")
    
    local rx_power="N/A"
    local tx_power="N/A" 
    local temperature="N/A"
    local vendor="N/A"
    local part_number="N/A"
    
    if [[ -n "$module_info" ]]; then
        # 提取光功率 (dBm)
        rx_power=$(echo "$module_info" | grep -i "receiver.*power\|rx.*power" | head -1 | grep -o '\-\?[0-9.]\+\s*dBm' | head -1 || echo "N/A")
        tx_power=$(echo "$module_info" | grep -i "laser.*power\|tx.*power" | head -1 | grep -o '\-\?[0-9.]\+\s*dBm' | head -1 || echo "N/A")
        
        # 提取温度
        temperature=$(echo "$module_info" | grep -i "module temperature" | grep -o '[0-9.]\+' | head -1 || echo "N/A")
        [[ "$temperature" != "N/A" ]] && temperature="${temperature}°C"
        
        # 提取厂商信息
        vendor=$(echo "$module_info" | grep -i "vendor name" | cut -d':' -f2 | xargs || echo "N/A")
        part_number=$(echo "$module_info" | grep -i "vendor pn" | cut -d':' -f2 | xargs || echo "N/A")
    fi
    
    echo "$rx_power|$tx_power|$temperature|$vendor|$part_number"
}

get_performance_stats() {
    local iface=$1
    local stats_file="/proc/net/dev"
    
    local rx_bytes=0
    local tx_bytes=0
    local rx_packets=0
    local tx_packets=0
    
    if [[ -f "$stats_file" ]]; then
        local line=$(grep "$iface:" "$stats_file" | head -1)
        if [[ -n "$line" ]]; then
            # /proc/net/dev格式解析
            local values=($(echo "$line" | awk '{print $2,$10,$3,$11}'))
            rx_bytes=${values[0]:-0}
            tx_bytes=${values[1]:-0}
            rx_packets=${values[2]:-0}
            tx_packets=${values[3]:-0}
        fi
    fi
    
    echo "$rx_bytes|$tx_bytes|$rx_packets|$tx_packets"
}

# =============================================================================
# 输出格式化
# =============================================================================

format_table_output() {
    local interfaces=("$@")
    
    print_table_header "网络接口诊断报告"
    
    # 基本信息表格
    printf "%-10s %-8s %-6s %-8s %-8s %-15s %-17s %-12s\n" \
        "接口" "状态" "链路" "速度" "双工" "IP地址" "MAC地址" "驱动"
    print_separator
    
    for iface in "${interfaces[@]}"; do
        local basic_info=$(get_interface_basic_info "$iface")
        IFS='|' read -r name operstate carrier speed duplex link_detected ip_addr mac_addr driver driver_version <<< "$basic_info"
        
        # 状态着色
        local status_color=""
        local link_color=""
        
        if [[ "$operstate" == "up" && "$link_detected" == "yes" ]]; then
            status_color="${GREEN}"
            link_color="${GREEN}"
        else
            status_color="${RED}"
            link_color="${RED}"
        fi
        
        printf "%-10s ${status_color}%-8s${NC} ${link_color}%-6s${NC} %-8s %-8s %-15s %-17s %-12s\n" \
            "$name" "$operstate" "${link_detected:-no}" "${speed:-N/A}" "${duplex:-N/A}" "${ip_addr:-N/A}" "$mac_addr" "$driver"
    done
    
    echo
    
    # 错误统计表格
    print_table_header "错误统计"
    printf "%-10s %-10s %-10s %-10s %-10s %-10s\n" \
        "接口" "RX错误" "TX错误" "RX丢包" "TX丢包" "冲突"
    print_separator
    
    for iface in "${interfaces[@]}"; do
        local error_info=$(get_interface_errors "$iface")
        IFS='|' read -r rx_errors tx_errors rx_dropped tx_dropped collisions <<< "$error_info"
        
        # 如果仅显示错误且无错误则跳过
        if [[ $ERRORS_ONLY == true ]] && [[ $rx_errors -eq 0 && $tx_errors -eq 0 && $rx_dropped -eq 0 && $tx_dropped -eq 0 && $collisions -eq 0 ]]; then
            continue
        fi
        
        # 错误数着色
        local rx_err_color=""
        local tx_err_color=""
        [[ $rx_errors -gt 0 ]] && rx_err_color="${RED}" || rx_err_color="${GREEN}"
        [[ $tx_errors -gt 0 ]] && tx_err_color="${RED}" || tx_err_color="${GREEN}"
        
        printf "%-10s ${rx_err_color}%-10s${NC} ${tx_err_color}%-10s${NC} %-10s %-10s %-10s\n" \
            "$iface" "$(format_number $rx_errors)" "$(format_number $tx_errors)" \
            "$(format_number $rx_dropped)" "$(format_number $tx_dropped)" "$(format_number $collisions)"
    done
    
    echo
    
    # 光模块信息表格
    print_table_header "光模块信息"
    printf "%-10s %-12s %-12s %-12s %-15s %-15s\n" \
        "接口" "RX功率" "TX功率" "温度" "厂商" "型号"
    print_separator
    
    for iface in "${interfaces[@]}"; do
        local optical_info=$(get_optical_info "$iface")
        IFS='|' read -r rx_power tx_power temperature vendor part_number <<< "$optical_info"
        
        # 仅显示有光模块的接口
        if [[ "$rx_power" != "N/A" || "$tx_power" != "N/A" ]]; then
            printf "%-10s %-12s %-12s %-12s %-15s %-15s\n" \
                "$iface" "$rx_power" "$tx_power" "$temperature" "$vendor" "$part_number"
        fi
    done
    
    # 性能统计表格
    if [[ $SHOW_PERFORMANCE == true ]]; then
        echo
        print_table_header "性能统计"
        printf "%-10s %-12s %-12s %-12s %-12s\n" \
            "接口" "RX字节" "TX字节" "RX包数" "TX包数"
        print_separator
        
        for iface in "${interfaces[@]}"; do
            local perf_info=$(get_performance_stats "$iface")
            IFS='|' read -r rx_bytes tx_bytes rx_packets tx_packets <<< "$perf_info"
            
            printf "%-10s %-12s %-12s %-12s %-12s\n" \
                "$iface" "$(format_number $rx_bytes)" "$(format_number $tx_bytes)" \
                "$(format_number $rx_packets)" "$(format_number $tx_packets)"
        done
    fi
}

format_json_output() {
    local interfaces=("$@")
    
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"hostname\": \"$(hostname)\","
    echo "  \"interfaces\": ["
    
    local first=true
    for iface in "${interfaces[@]}"; do
        [[ $first == false ]] && echo ","
        first=false
        
        local basic_info=$(get_interface_basic_info "$iface")
        local error_info=$(get_interface_errors "$iface")
        local optical_info=$(get_optical_info "$iface")
        local perf_info=$(get_performance_stats "$iface")
        
        IFS='|' read -r name operstate carrier speed duplex link_detected ip_addr mac_addr driver driver_version <<< "$basic_info"
        IFS='|' read -r rx_errors tx_errors rx_dropped tx_dropped collisions <<< "$error_info"
        IFS='|' read -r rx_power tx_power temperature vendor part_number <<< "$optical_info"
        IFS='|' read -r rx_bytes tx_bytes rx_packets tx_packets <<< "$perf_info"
        
        cat << EOF
    {
      "name": "$name",
      "status": {
        "operstate": "$operstate",
        "carrier": "$carrier",
        "link_detected": "$link_detected"
      },
      "config": {
        "speed": "$speed",
        "duplex": "$duplex",
        "ip_address": "$ip_addr",
        "mac_address": "$mac_addr"
      },
      "driver": {
        "name": "$driver",
        "version": "$driver_version"
      },
      "errors": {
        "rx_errors": $rx_errors,
        "tx_errors": $tx_errors,
        "rx_dropped": $rx_dropped,
        "tx_dropped": $tx_dropped,
        "collisions": $collisions
      },
      "optical": {
        "rx_power": "$rx_power",
        "tx_power": "$tx_power",
        "temperature": "$temperature",
        "vendor": "$vendor",
        "part_number": "$part_number"
      },
      "performance": {
        "rx_bytes": $rx_bytes,
        "tx_bytes": $tx_bytes,
        "rx_packets": $rx_packets,
        "tx_packets": $tx_packets
      }
    }
EOF
    done
    
    echo
    echo "  ]"
    echo "}"
}

format_csv_output() {
    local interfaces=("$@")
    
    # CSV头部
    echo "interface,operstate,carrier,speed,duplex,link_detected,ip_address,mac_address,driver,driver_version,rx_errors,tx_errors,rx_dropped,tx_dropped,collisions,rx_power,tx_power,temperature,vendor,part_number,rx_bytes,tx_bytes,rx_packets,tx_packets"
    
    for iface in "${interfaces[@]}"; do
        local basic_info=$(get_interface_basic_info "$iface")
        local error_info=$(get_interface_errors "$iface")
        local optical_info=$(get_optical_info "$iface")
        local perf_info=$(get_performance_stats "$iface")
        
        echo "$basic_info,$error_info,$optical_info,$perf_info"
    done
}

format_report_output() {
    local interfaces=("$@")
    
    cat << EOF

================================================================================
                    网络接口诊断报告
================================================================================

生成时间: $(date)
主机名: $(hostname)
检查接口: ${interfaces[*]}

EOF

    for iface in "${interfaces[@]}"; do
        local basic_info=$(get_interface_basic_info "$iface")
        local error_info=$(get_interface_errors "$iface")
        local optical_info=$(get_optical_info "$iface")
        
        IFS='|' read -r name operstate carrier speed duplex link_detected ip_addr mac_addr driver driver_version <<< "$basic_info"
        IFS='|' read -r rx_errors tx_errors rx_dropped tx_dropped collisions <<< "$error_info"
        IFS='|' read -r rx_power tx_power temperature vendor part_number <<< "$optical_info"
        
        cat << EOF
接口: $name
----------------------------------------
状态: $operstate
链路: $link_detected
速度: $speed Mbps
双工: $duplex
IP地址: $ip_addr
MAC地址: $mac_addr
驱动: $driver ($driver_version)

错误统计:
  RX错误: $rx_errors
  TX错误: $tx_errors
  RX丢包: $rx_dropped
  TX丢包: $tx_dropped
  冲突: $collisions

EOF

        if [[ "$rx_power" != "N/A" || "$tx_power" != "N/A" ]]; then
            cat << EOF
光模块信息:
  RX功率: $rx_power
  TX功率: $tx_power
  温度: $temperature
  厂商: $vendor
  型号: $part_number

EOF
        fi
    done
    
    cat << EOF
诊断建议:
================================================================================
1. 定期监控错误统计，持续增长的错误可能表示硬件问题
2. 对于光纤连接，确保光功率在正常范围内 (-20dBm 到 0dBm)
3. 温度过高(>70°C)可能影响模块寿命和性能
4. 大量丢包可能表示网络拥塞或配置问题
5. 定期检查驱动版本，保持更新以获得最佳性能

EOF
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    # 解析参数
    parse_arguments "$@"
    
    # 系统检查
    check_dependencies
    
    # 获取要检查的接口
    local interfaces=($(get_interfaces))
    
    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log ERROR "没有找到要检查的网络接口"
        exit 1
    fi
    
    log INFO "检查 ${#interfaces[@]} 个网络接口: ${interfaces[*]}"
    
    # 生成输出
    local output=""
    case "$OUTPUT_FORMAT" in
        table|compact)
            output=$(format_table_output "${interfaces[@]}")
            ;;
        json)
            output=$(format_json_output "${interfaces[@]}")
            ;;
        csv)
            output=$(format_csv_output "${interfaces[@]}")
            ;;
        report)
            output=$(format_report_output "${interfaces[@]}")
            ;;
        *)
            log ERROR "不支持的输出格式: $OUTPUT_FORMAT"
            exit 1
            ;;
    esac
    
    # 显示输出
    echo "$output"
    
    # 保存报告
    if [[ $SAVE_REPORT == true ]]; then
        echo "$output" > "$REPORT_FILE"
        log SUCCESS "报告已保存到: $REPORT_FILE"
    fi
    
    log SUCCESS "诊断完成"
}

# 脚本入口
main "$@"
