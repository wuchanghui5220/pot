#!/bin/bash

# InfiniBand Switch Information Script
# 查询所有交换机的节点描述和供应商信息，输出为CSV格式

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置变量
MAX_PORT=32  # 最大端口号
CSV_FILE="ib_switch_info.csv"

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# 检查必要的命令是否存在
check_commands() {
    local commands=("ibswitches" "smpquery" "mlxlink")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "命令 '$cmd' 未找到，请确保已安装相关软件包"
            exit 1
        fi
    done
}

# 获取交换机主机名
get_switch_hostname() {
    local lid=$1
    local hostname=""

    # 使用smpquery查询节点描述
    local node_desc=$(smpquery nd "$lid" 2>/dev/null | grep "Node Description" | sed 's/Node Description[.:]*\s*//')

    if [ -n "$node_desc" ]; then
        hostname="$node_desc"
    else
        hostname="Unknown-LID-$lid"
    fi

    echo "$hostname"
}

# 获取端口供应商信息
get_port_vendor_info() {
    local lid=$1
    local port=$2
    local vendor_name=""
    local vendor_part=""
    local vendor_serial=""

    # 查询mlxlink信息
    local mlxlink_output=$(mlxlink -d "lid-$lid" -p "$port/1" -m 2>/dev/null | grep "Vendor")

    if [ -n "$mlxlink_output" ]; then
        vendor_name=$(echo "$mlxlink_output" | grep "Vendor Name" | sed 's/.*:\s*//' | tr -d '\r\n' | xargs)
        vendor_part=$(echo "$mlxlink_output" | grep "Vendor Part Number" | sed 's/.*:\s*//' | tr -d '\r\n' | xargs)
        vendor_serial=$(echo "$mlxlink_output" | grep "Vendor Serial Number" | sed 's/.*:\s*//' | tr -d '\r\n' | xargs)
    fi

    # 如果为空，设置默认值
    [ -z "$vendor_name" ] && vendor_name="N/A"
    [ -z "$vendor_part" ] && vendor_part="N/A"
    [ -z "$vendor_serial" ] && vendor_serial="N/A"

    echo "$vendor_name,$vendor_part,$vendor_serial"
}

# 转义CSV字段（处理包含逗号、引号等特殊字符）
escape_csv_field() {
    local field="$1"
    # 如果字段包含逗号、引号或换行符，需要用双引号包围
    if [[ "$field" == *","* ]] || [[ "$field" == *"\""* ]] || [[ "$field" == *$'\n'* ]]; then
        # 转义内部的双引号
        field="${field//\"/\"\"}"
        echo "\"$field\""
    else
        echo "$field"
    fi
}

# 主函数
main() {
    log_info "开始查询InfiniBand交换机信息..."

    # 检查必要命令
    check_commands

    # 获取交换机LID列表
    log_info "获取交换机LID列表..."
    switchlids=$(ibswitches -C mlx5_0 | awk -F'lid' '{print $2}' | awk '{print $1}')

    if [ -z "$switchlids" ]; then
        log_error "未找到任何交换机LID"
        exit 1
    fi

    log_info "找到以下交换机LID: $(echo $switchlids | tr '\n' ' ')"

    # 创建CSV文件并写入表头
    echo "Switch_HostName,Port,Vendor_Name,Vendor_Part_Number,Vendor_Serial_Number" > "$CSV_FILE"

    # 遍历每个交换机LID
    local total_switches=$(echo "$switchlids" | wc -w)
    local switch_counter=1

    for lid in $switchlids; do
        log_info "处理交换机 $switch_counter/$total_switches (LID: $lid)..."

        # 获取交换机主机名
        local hostname=$(get_switch_hostname "$lid")
        log_info "交换机主机名: $hostname"

        # 遍历所有端口
        for port in $(seq 1 $MAX_PORT); do
            log_info "查询端口 $port/1..."

            # 获取端口供应商信息
            local vendor_info=$(get_port_vendor_info "$lid" "$port")

            # 如果获取到有效信息（不是全部N/A），则写入CSV
            if [ "$vendor_info" != "N/A,N/A,N/A" ]; then
                local escaped_hostname=$(escape_csv_field "$hostname")
                local escaped_port=$(escape_csv_field "$port/1")

                # 分离vendor_info
                local vendor_name=$(echo "$vendor_info" | cut -d',' -f1)
                local vendor_part=$(echo "$vendor_info" | cut -d',' -f2)
                local vendor_serial=$(echo "$vendor_info" | cut -d',' -f3)

                local escaped_vendor_name=$(escape_csv_field "$vendor_name")
                local escaped_vendor_part=$(escape_csv_field "$vendor_part")
                local escaped_vendor_serial=$(escape_csv_field "$vendor_serial")

                # 写入CSV文件
                echo "$escaped_hostname,$escaped_port,$escaped_vendor_name,$escaped_vendor_part,$escaped_vendor_serial" >> "$CSV_FILE"

                log_info "端口 $port/1 有效数据已记录"
            fi
        done

        ((switch_counter++))
    done

    log_info "查询完成！结果已保存到 $CSV_FILE"
    log_info "CSV文件记录数: $(tail -n +2 "$CSV_FILE" | wc -l)"

    # 显示前几行作为预览
    echo
    log_info "CSV文件预览:"
    head -n 6 "$CSV_FILE"

    if [ $(wc -l < "$CSV_FILE") -gt 6 ]; then
        echo "..."
        log_info "完整数据请查看文件: $CSV_FILE"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
InfiniBand Switch Information Script

用法: $0 [选项]

选项:
  -h, --help          显示此帮助信息
  -p, --max-port NUM  设置最大端口号 (默认: 32)
  -o, --output FILE   指定输出CSV文件名 (默认: ib_switch_info.csv)

示例:
  $0                           # 使用默认设置
  $0 -p 16 -o my_switches.csv  # 只查询1-16端口，输出到my_switches.csv
EOF
}

# 解析命令行参数
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -p|--max-port)
                if [[ -n "$2" ]] && [[ "$2" =~ ^[0-9]+$ ]]; then
                    MAX_PORT="$2"
                    shift 2
                else
                    log_error "错误：--max-port 需要一个数字参数"
                    exit 1
                fi
                ;;
            -o|--output)
                if [[ -n "$2" ]]; then
                    CSV_FILE="$2"
                    shift 2
                else
                    log_error "错误：--output 需要一个文件名参数"
                    exit 1
                fi
                ;;
            *)
                log_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 脚本入口
parse_arguments "$@"
main
