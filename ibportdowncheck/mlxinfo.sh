#!/bin/bash

# MLXLink信息收集脚本 - 增强版
# 支持多种参数和配置选项

# 默认配置
DEFAULT_USERNAME="root"
DEFAULT_PASSWORD=""
DEFAULT_DEVICES="mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7,mlx5_8,mlx5_9"
DEFAULT_TIMEOUT=10
DEFAULT_OUTPUT="mlxlink_info_$(date +%Y%m%d_%H%M%S).csv"

# 全局变量
USERNAME="$DEFAULT_USERNAME"
PASSWORD="$DEFAULT_PASSWORD"
DEVICES="$DEFAULT_DEVICES"
TIMEOUT="$DEFAULT_TIMEOUT"
OUTPUT_CSV="$DEFAULT_OUTPUT"
LOG_FILE="collection_$(date +%Y%m%d_%H%M%S).log"
SINGLE_HOST=""
HOST_FILE=""
HOSTS_LIST=()
USE_SSH_KEY=true
VERBOSE=false
PARALLEL_JOBS=10

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 显示帮助信息
show_help() {
    cat << EOF
MLXLink信息收集工具 - 增强版

用法: $0 [选项]

主机选项:
  -H, --host HOST           单个主机IP地址
  -f, --file FILE           主机列表文件 (每行一个IP)
  -r, --range START-END     IP范围，如: 10.0.100.1-112

认证选项:
  -u, --username USER       SSH用户名 (默认: $DEFAULT_USERNAME)
  -p, --password PASS       SSH密码 (默认: 使用SSH密钥)
  -k, --use-key             强制使用SSH密钥认证
  -t, --timeout SEC         SSH连接超时时间 (默认: $DEFAULT_TIMEOUT秒)

设备选项:
  -d, --devices LIST        要查询的MLX设备列表，逗号分隔
                           (默认: $DEFAULT_DEVICES)
  -a, --auto-detect         自动检测MLX设备

输出选项:
  -o, --output FILE         输出CSV文件名 (默认: 自动生成)
  -j, --parallel NUM        并行处理数量 (默认: $PARALLEL_JOBS)
  -v, --verbose             详细输出
  -q, --quiet               静默模式

其他选项:
  -h, --help                显示此帮助信息
  --version                 显示版本信息

示例:
  $0 -H 10.0.100.1                           # 查询单个主机
  $0 -f hosts.txt                            # 从文件读取主机列表
  $0 -r 10.0.100.1-112                       # 查询IP范围
  $0 -H 10.0.100.1 -u admin -p password      # 使用用户名密码
  $0 -f hosts.txt -d mlx5_4,mlx5_5           # 只查询指定设备
  $0 -H 10.0.100.1 -a                        # 自动检测设备
  $0 -f hosts.txt -j 20 -v                   # 20个并行任务，详细输出

主机文件格式:
  # 普通格式 (每行一个IP)
  10.0.100.1
  10.0.100.2
  192.168.1.100
  # 注释行会被忽略

  # Ansible inventory 格式
  [webservers]
  10.0.100.1
  10.0.100.2

  [databases]
  10.0.100.10
  10.0.100.11

  [gpu]
  10.0.100.[1:112]    # 支持范围格式

  [gpu:vars]
  ansible_user=root   # 变量行会被忽略
  ansible_ssh_pass=password
EOF
}

# 显示版本信息
show_version() {
    echo "MLXLink信息收集工具 v2.0"
    echo "作者: AI Assistant"
    echo "日期: $(date +%Y-%m-%d)"
}

# 日志函数
log() {
    local level=$1
    shift
    local msg="$*"
    local timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"

    case $level in
        ERROR)
            echo -e "${RED}${timestamp} [ERROR] $msg${NC}" | tee -a "$LOG_FILE"
            ;;
        WARN)
            echo -e "${YELLOW}${timestamp} [WARN] $msg${NC}" | tee -a "$LOG_FILE"
            ;;
        INFO)
            echo -e "${GREEN}${timestamp} [INFO] $msg${NC}" | tee -a "$LOG_FILE"
            ;;
        DEBUG)
            if [ "$VERBOSE" = true ]; then
                echo -e "${BLUE}${timestamp} [DEBUG] $msg${NC}" | tee -a "$LOG_FILE"
            else
                echo "${timestamp} [DEBUG] $msg" >> "$LOG_FILE"
            fi
            ;;
    esac
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -H|--host)
                SINGLE_HOST="$2"
                shift 2
                ;;
            -f|--file)
                HOST_FILE="$2"
                shift 2
                ;;
            -r|--range)
                parse_range "$2"
                shift 2
                ;;
            -u|--username)
                USERNAME="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
                USE_SSH_KEY=false
                shift 2
                ;;
            -k|--use-key)
                USE_SSH_KEY=true
                shift
                ;;
            -t|--timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -d|--devices)
                DEVICES="$2"
                shift 2
                ;;
            -a|--auto-detect)
                DEVICES="AUTO"
                shift
                ;;
            -o|--output)
                OUTPUT_CSV="$2"
                shift 2
                ;;
            -j|--parallel)
                PARALLEL_JOBS="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -q|--quiet)
                VERBOSE=false
                exec 1>/dev/null
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            --version)
                show_version
                exit 0
                ;;
            *)
                log ERROR "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# 解析IP范围
parse_range() {
    local range=$1
    if [[ $range =~ ^(.+)-([0-9]+)$ ]]; then
        local prefix="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"

        # 提取起始IP的最后一位数字
        if [[ $prefix =~ ^(.+\.)([0-9]+)$ ]]; then
            local ip_prefix="${BASH_REMATCH[1]}"
            local start="${BASH_REMATCH[2]}"

            for i in $(seq $start $end); do
                HOSTS_LIST+=("${ip_prefix}${i}")
            done
        else
            log ERROR "无效的IP范围格式: $range"
            exit 1
        fi
    else
        log ERROR "无效的IP范围格式: $range"
        exit 1
    fi
}

# 读取主机文件
read_host_file() {
    if [ ! -f "$HOST_FILE" ]; then
        log ERROR "主机文件不存在: $HOST_FILE"
        exit 1
    fi

    local in_group=false
    local current_group=""

    while IFS= read -r line; do
        # 跳过空行和注释行
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # 检查是否是组定义 [groupname]
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            current_group="${BASH_REMATCH[1]}"
            in_group=true
            log DEBUG "发现主机组: $current_group"
            continue
        fi

        # 检查是否是组变量 [groupname:vars]
        if [[ "$line" =~ ^\[([^\]]+):vars\]$ ]]; then
            in_group=false
            log DEBUG "跳过变量组: ${BASH_REMATCH[1]}:vars"
            continue
        fi

        # 如果不在组中，直接处理为主机
        if [ "$in_group" = false ]; then
            # 提取IP地址（忽略变量）
            if [[ "$line" =~ ^([^[:space:]]+) ]]; then
                local host="${BASH_REMATCH[1]}"
                parse_host_entry "$host"
            else
                parse_host_entry "$line"
            fi
        else
            # 在组中，处理主机条目
            parse_host_entry "$line"
        fi
    done < "$HOST_FILE"
}

# 解析主机条目
parse_host_entry() {
    local entry="$1"

    # 跳过变量行（包含=的行）
    if [[ "$entry" =~ = ]]; then
        return
    fi

    # 提取主机名/IP（第一个单词）
    if [[ "$entry" =~ ^([^[:space:]]+) ]]; then
        local host="${BASH_REMATCH[1]}"
    else
        local host="$entry"
    fi

    # 处理主机范围格式，如 10.0.100.[1:112]
    if [[ "$host" =~ ^(.+)\[([0-9]+):([0-9]+)\](.*)$ ]]; then
        local prefix="${BASH_REMATCH[1]}"
        local start="${BASH_REMATCH[2]}"
        local end="${BASH_REMATCH[3]}"
        local suffix="${BASH_REMATCH[4]}"

        log DEBUG "解析主机范围: $prefix[$start:$end]$suffix"

        for i in $(seq $start $end); do
            HOSTS_LIST+=("$prefix$i$suffix")
        done
    else
        # 普通主机条目
        HOSTS_LIST+=("$host")
        log DEBUG "添加主机: $host"
    fi
}

# 准备主机列表
prepare_hosts() {
    if [ -n "$SINGLE_HOST" ]; then
        HOSTS_LIST=("$SINGLE_HOST")
    elif [ -n "$HOST_FILE" ]; then
        read_host_file
    elif [ ${#HOSTS_LIST[@]} -eq 0 ]; then
        log ERROR "请指定主机: -H <host> 或 -f <file> 或 -r <range>"
        show_help
        exit 1
    fi

    if [ ${#HOSTS_LIST[@]} -eq 0 ]; then
        log ERROR "没有找到有效的主机"
        exit 1
    fi

    log INFO "准备查询 ${#HOSTS_LIST[@]} 个主机"
}

# 创建CSV头部
create_csv_header() {
    echo "Host,Hostname,Bond_IP_1,Bond_IP_2,MLX_Device,Vendor_Name,Vendor_Part_Number,Vendor_Serial_Number,Device_Status,Collection_Time" > "$OUTPUT_CSV"
}

# 构建SSH命令
build_ssh_cmd() {
    local host=$1
    local cmd=""

    if [ "$USE_SSH_KEY" = true ]; then
        cmd="ssh -o ConnectTimeout=$TIMEOUT -o StrictHostKeyChecking=no $USERNAME@$host"
    else
        cmd="sshpass -p '$PASSWORD' ssh -o ConnectTimeout=$TIMEOUT -o StrictHostKeyChecking=no $USERNAME@$host"
    fi

    echo "$cmd"
}

# 从主机收集信息
collect_host_info() {
    local host=$1
    local temp_file="/tmp/host_${host//\./_}_info.tmp"
    local ssh_cmd=$(build_ssh_cmd "$host")

    log DEBUG "开始收集主机 $host 的信息"

    # 构建设备查询命令
    local device_query=""
    # 不需要这个变量了，因为我们在远程脚本中直接处理

    # 执行远程命令
    $ssh_cmd "
        collection_time=\$(date '+%Y-%m-%d %H:%M:%S')
        echo \"COLLECTION_TIME=\$collection_time\"

        # 获取主机名
        echo \"HOSTNAME=\$(hostname)\"

        # 获取bond接口IP
        bond_ips=\$(ip a s | grep \"bond\" | grep inet | awk '{print \$2}' | head -2)
        ip_count=1
        while IFS= read -r ip; do
            if [ -n \"\$ip\" ]; then
                echo \"BOND_IP_\${ip_count}=\$ip\"
                ((ip_count++))
            fi
        done <<< \"\$bond_ips\"

        # 查询MLX设备
        if [ \"$DEVICES\" = \"AUTO\" ]; then
            # 自动检测模式：查询实际存在的设备
            mlx_devices=\$(ls /sys/class/infiniband/ 2>/dev/null | grep mlx5)
            if [ -n \"\$mlx_devices\" ]; then
                for device in \$mlx_devices; do
                    if [ -n \"\$device\" ]; then
                        echo \"MLX_DEVICE=\$device\"
                        # 获取MLXLink信息
                        mlxlink_info=\$(mlxlink -d \"\$device\" -m 2>/dev/null | grep \"Vendor\")
                        if [ -n \"\$mlxlink_info\" ]; then
                            echo \"\$mlxlink_info\" | while IFS= read -r line; do
                                if [[ \"\$line\" =~ Vendor\ Name.*:\ (.*) ]]; then
                                    echo \"VENDOR_NAME=\${BASH_REMATCH[1]// /}\"
                                elif [[ \"\$line\" =~ Vendor\ Part\ Number.*:\ (.*) ]]; then
                                    echo \"VENDOR_PART=\${BASH_REMATCH[1]// /}\"
                                elif [[ \"\$line\" =~ Vendor\ Serial\ Number.*:\ (.*) ]]; then
                                    echo \"VENDOR_SERIAL=\${BASH_REMATCH[1]// /}\"
                                fi
                            done
                            echo \"DEVICE_STATUS=Success\"
                        else
                            echo \"VENDOR_NAME=MLXLink_Failed\"
                            echo \"VENDOR_PART=MLXLink_Failed\"
                            echo \"VENDOR_SERIAL=MLXLink_Failed\"
                            echo \"DEVICE_STATUS=MLXLink_Error\"
                        fi
                        echo \"MLX_DEVICE_END\"
                    fi
                done
            else
                echo \"MLX_DEVICE=N/A\"
                echo \"VENDOR_NAME=No_MLX_Device\"
                echo \"VENDOR_PART=No_MLX_Device\"
                echo \"VENDOR_SERIAL=No_MLX_Device\"
                echo \"DEVICE_STATUS=No_Device\"
                echo \"MLX_DEVICE_END\"
            fi
        else
            # 指定设备模式：必须查询所有指定的设备
            device_list=\"${DEVICES//,/ }\"
            for device in \$device_list; do
                if [ -n \"\$device\" ]; then
                    echo \"MLX_DEVICE=\$device\"
                    # 检查设备是否存在于系统中
                    if [ -e \"/sys/class/infiniband/\$device\" ]; then
                        # 设备存在，尝试获取MLXLink信息
                        mlxlink_info=\$(mlxlink -d \"\$device\" -m 2>/dev/null | grep \"Vendor\")
                        if [ -n \"\$mlxlink_info\" ]; then
                            echo \"\$mlxlink_info\" | while IFS= read -r line; do
                                if [[ \"\$line\" =~ Vendor\ Name.*:\ (.*) ]]; then
                                    echo \"VENDOR_NAME=\${BASH_REMATCH[1]// /}\"
                                elif [[ \"\$line\" =~ Vendor\ Part\ Number.*:\ (.*) ]]; then
                                    echo \"VENDOR_PART=\${BASH_REMATCH[1]// /}\"
                                elif [[ \"\$line\" =~ Vendor\ Serial\ Number.*:\ (.*) ]]; then
                                    echo \"VENDOR_SERIAL=\${BASH_REMATCH[1]// /}\"
                                fi
                            done
                            echo \"DEVICE_STATUS=Success\"
                        else
                            echo \"VENDOR_NAME=MLXLink_Failed\"
                            echo \"VENDOR_PART=MLXLink_Failed\"
                            echo \"VENDOR_SERIAL=MLXLink_Failed\"
                            echo \"DEVICE_STATUS=MLXLink_Error\"
                        fi
                    else
                        # 设备不存在
                        echo \"VENDOR_NAME=Device_Not_Found\"
                        echo \"VENDOR_PART=Device_Not_Found\"
                        echo \"VENDOR_SERIAL=Device_Not_Found\"
                        echo \"DEVICE_STATUS=Device_Missing\"
                    fi
                    echo \"MLX_DEVICE_END\"
                fi
            done
        fi
    " 2>/dev/null > "$temp_file"

    if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
        log DEBUG "主机 $host 信息收集成功"
        echo "$temp_file"
    else
        log WARN "主机 $host 信息收集失败"
        echo ""
    fi
}

# 解析主机信息并写入CSV
parse_and_write_csv() {
    local host=$1
    local info_file=$2

    if [ ! -f "$info_file" ] || [ ! -s "$info_file" ]; then
        echo "$host,ERROR,N/A,N/A,N/A,N/A,N/A,N/A,Connection_Failed,$(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_CSV"
        return
    fi

    # 解析信息
    local hostname=""
    local bond_ip_1=""
    local bond_ip_2=""
    local collection_time=""
    local current_device=""
    local vendor_name=""
    local vendor_part=""
    local vendor_serial=""
    local device_status=""
    local has_data=false

    while IFS= read -r line; do
        case "$line" in
            COLLECTION_TIME=*)
                collection_time="${line#COLLECTION_TIME=}"
                ;;
            HOSTNAME=*)
                hostname="${line#HOSTNAME=}"
                ;;
            BOND_IP_1=*)
                bond_ip_1="${line#BOND_IP_1=}"
                ;;
            BOND_IP_2=*)
                bond_ip_2="${line#BOND_IP_2=}"
                ;;
            MLX_DEVICE=*)
                current_device="${line#MLX_DEVICE=}"
                ;;
            VENDOR_NAME=*)
                vendor_name="${line#VENDOR_NAME=}"
                ;;
            VENDOR_PART=*)
                vendor_part="${line#VENDOR_PART=}"
                ;;
            VENDOR_SERIAL=*)
                vendor_serial="${line#VENDOR_SERIAL=}"
                ;;
            DEVICE_STATUS=*)
                device_status="${line#DEVICE_STATUS=}"
                ;;
            MLX_DEVICE_END)
                # 写入一行数据
                echo "$host,$hostname,$bond_ip_1,$bond_ip_2,$current_device,$vendor_name,$vendor_part,$vendor_serial,$device_status,$collection_time" >> "$OUTPUT_CSV"
                has_data=true
                # 重置变量
                current_device=""
                vendor_name=""
                vendor_part=""
                vendor_serial=""
                device_status=""
                ;;
        esac
    done < "$info_file"

    # 如果没有数据，写入基本信息
    if [ "$has_data" = false ] && [ -n "$hostname" ]; then
        echo "$host,$hostname,$bond_ip_1,$bond_ip_2,N/A,N/A,N/A,N/A,Connection_Error,$collection_time" >> "$OUTPUT_CSV"
    fi
}

# 处理单个主机
process_host() {
    local host=$1
    local info_file=$(collect_host_info "$host")

    if [ -n "$info_file" ]; then
        parse_and_write_csv "$host" "$info_file"
        rm -f "$info_file"
        return 0
    else
        echo "$host,ERROR,N/A,N/A,N/A,N/A,N/A,N/A,Connection_Failed,$(date '+%Y-%m-%d %H:%M:%S')" >> "$OUTPUT_CSV"
        return 1
    fi
}

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local bar_length=50
    local filled_length=$((percent * bar_length / 100))

    if [ "$VERBOSE" = true ]; then
        return
    fi

    printf "\r["
    for ((i=0; i<filled_length; i++)); do printf "="; done
    for ((i=filled_length; i<bar_length; i++)); do printf " "; done
    printf "] %d%% (%d/%d)" "$percent" "$current" "$total"
}

# 主收集函数
collect_all_hosts() {
    log INFO "开始收集主机信息..."

    local total_hosts=${#HOSTS_LIST[@]}
    local current_host=0
    local success_count=0
    local failed_count=0
    local pids=()

    # 并行处理
    for host in "${HOSTS_LIST[@]}"; do
        # 控制并行数量
        while [ ${#pids[@]} -ge $PARALLEL_JOBS ]; do
            for i in "${!pids[@]}"; do
                if ! kill -0 "${pids[i]}" 2>/dev/null; then
                    wait "${pids[i]}"
                    if [ $? -eq 0 ]; then
                        ((success_count++))
                    else
                        ((failed_count++))
                    fi
                    unset pids[i]
                fi
            done
            pids=("${pids[@]}")  # 重新索引数组
            sleep 0.1
        done

        # 启动新的后台任务
        (process_host "$host") &
        pids+=($!)

        ((current_host++))
        show_progress $current_host $total_hosts

        log DEBUG "已启动主机 $host 的收集任务 (PID: $!)"
    done

    # 等待所有任务完成
    for pid in "${pids[@]}"; do
        wait "$pid"
        if [ $? -eq 0 ]; then
            ((success_count++))
        else
            ((failed_count++))
        fi
    done

    echo "" # 新行
    log INFO "收集完成！成功: $success_count, 失败: $failed_count"
}

# 生成统计报告
generate_summary() {
    log INFO "生成统计报告..."

    local total_lines=$(wc -l < "$OUTPUT_CSV")
    local success_lines=$(grep -c "Success" "$OUTPUT_CSV")
    local failed_lines=$(grep -c "Connection_Failed" "$OUTPUT_CSV")
    local device_missing=$(grep -c "Device_Missing" "$OUTPUT_CSV")
    local mlxlink_error=$(grep -c "MLXLink_Error" "$OUTPUT_CSV")

    echo -e "\n${BLUE}=== 收集统计报告 ===${NC}"
    echo -e "${GREEN}总记录数: $((total_lines - 1))${NC}"
    echo -e "${GREEN}成功设备: $success_lines${NC}"
    echo -e "${RED}连接失败: $failed_lines${NC}"
    echo -e "${YELLOW}设备缺失: $device_missing${NC}"
    echo -e "${YELLOW}MLXLink错误: $mlxlink_error${NC}"
    echo -e "${BLUE}CSV文件: $OUTPUT_CSV${NC}"
    echo -e "${BLUE}日志文件: $LOG_FILE${NC}"

    # 额外的设备统计
    if [ $device_missing -gt 0 ] || [ $mlxlink_error -gt 0 ]; then
        echo -e "\n${YELLOW}=== 异常设备详情 ===${NC}"
        if [ $device_missing -gt 0 ]; then
            echo -e "${RED}设备缺失的主机:${NC}"
            grep "Device_Missing" "$OUTPUT_CSV" | cut -d',' -f1,5 | sort -u | while IFS=',' read -r host device; do
                echo "  $host: $device"
            done
        fi
        if [ $mlxlink_error -gt 0 ]; then
            echo -e "${RED}MLXLink错误的主机:${NC}"
            grep "MLXLink_Error" "$OUTPUT_CSV" | cut -d',' -f1,5 | sort -u | while IFS=',' read -r host device; do
                echo "  $host: $device"
            done
        fi
    fi
}

# 显示CSV预览
preview_csv() {
    if [ "$VERBOSE" = false ]; then
        return
    fi

    echo -e "\n${BLUE}=== CSV文件预览 (前10行) ===${NC}"
    head -10 "$OUTPUT_CSV" | column -t -s ','

    if [ $(wc -l < "$OUTPUT_CSV") -gt 10 ]; then
        echo -e "\n${YELLOW}... 更多数据请查看文件: $OUTPUT_CSV${NC}"
    fi
}

# 验证依赖
check_dependencies() {
    local missing_deps=()

    if [ "$USE_SSH_KEY" = false ] && ! command -v sshpass &> /dev/null; then
        missing_deps+=("sshpass")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log ERROR "缺少依赖: ${missing_deps[*]}"
        echo "请安装: sudo apt install ${missing_deps[*]}"
        exit 1
    fi
}

# 清理临时文件
cleanup() {
    rm -f /tmp/host_*_info.tmp
}

# 主函数
main() {
    parse_args "$@"

    echo -e "${BLUE}=== MLXLink信息收集工具 v2.0 ===${NC}"

    prepare_hosts
    check_dependencies

    echo -e "${YELLOW}主机数量: ${#HOSTS_LIST[@]}${NC}"
    echo -e "${YELLOW}用户名: $USERNAME${NC}"
    echo -e "${YELLOW}认证方式: $([ "$USE_SSH_KEY" = true ] && echo "SSH密钥" || echo "密码")${NC}"
    echo -e "${YELLOW}设备列表: $DEVICES${NC}"
    echo -e "${YELLOW}并行任务: $PARALLEL_JOBS${NC}"
    echo -e "${YELLOW}输出文件: $OUTPUT_CSV${NC}"
    echo ""

    if [ "$VERBOSE" = true ]; then
        read -p "确认开始收集？(y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "取消操作"
            exit 0
        fi
    fi

    create_csv_header
    collect_all_hosts
    generate_summary
    preview_csv
    cleanup

    echo -e "\n${GREEN}=== 完成！ ===${NC}"
    echo -e "${BLUE}数据文件: $OUTPUT_CSV${NC}"
    echo -e "${BLUE}日志文件: $LOG_FILE${NC}"
}

# 捕获退出信号，清理临时文件
trap cleanup EXIT

# 运行主函数
main "$@"
