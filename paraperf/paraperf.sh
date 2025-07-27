#!/bin/bash

# =============================================================================
# ParaPerf - 并行网络性能测试工具
# 基于iperf3的集群带宽测试脚本
# 支持Ubuntu 22.04.5及更新版本
# =============================================================================

set -euo pipefail

# 脚本信息
SCRIPT_NAME="ParaPerf"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 配置文件和日志
CONFIG_DIR="${SCRIPT_DIR}/.paraperf"
LOG_DIR="${CONFIG_DIR}/logs"
IPERF3_OFFLINE_DIR="${SCRIPT_DIR}/paraperf-offline"
TEMP_DIR="${CONFIG_DIR}/temp"

# 默认参数
DEFAULT_USERNAME=""
DEFAULT_PASSWORD=""
DEFAULT_HOSTFILE=""
DEFAULT_PAIRING="full"        # full, ring, star, pair
DEFAULT_CONCURRENT=5
DEFAULT_DURATION=10
DEFAULT_THREADS=1             # iperf3 parallel threads
DEFAULT_PORT=5201
DEFAULT_PROTOCOL="tcp"        # tcp, udp
DEFAULT_OUTPUT_FORMAT="table" # table, json, csv

# 全局变量
USERNAME=""
PASSWORD=""
HOSTFILE=""
PAIRING_MODE=""
CONCURRENT_LIMIT=""
TEST_DURATION=""
IPERF3_THREADS=""
IPERF3_PORT=""
PROTOCOL=""
OUTPUT_FORMAT=""
VERBOSE=false
DRY_RUN=false
FORCE_INSTALL=false

# SSH选项
SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============================================================================
# 工具函数
# =============================================================================

log() {
    local level=$1
    shift
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_file="${LOG_DIR}/paraperf.log"
    
    case $level in
        ERROR)   echo -e "${RED}[ERROR]${NC} $*" >&2; echo "[$timestamp] [ERROR] $*" >> "$log_file" ;;
        WARN)    echo -e "${YELLOW}[WARN]${NC} $*" >&2; echo "[$timestamp] [WARN] $*" >> "$log_file" ;;
        INFO)    echo -e "${GREEN}[INFO]${NC} $*"; echo "[$timestamp] [INFO] $*" >> "$log_file" ;;
        DEBUG)   [[ $VERBOSE == true ]] && echo -e "${BLUE}[DEBUG]${NC} $*"; echo "[$timestamp] [DEBUG] $*" >> "$log_file" ;;
        SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} $*"; echo "[$timestamp] [SUCCESS] $*" >> "$log_file" ;;
    esac
}

cleanup() {
    # 只在脚本异常退出或明确调用时清理
    log DEBUG "清理临时文件..."
    [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    log DEBUG "清理完成"
}

# 仅在异常情况下自动清理
trap cleanup ERR

# =============================================================================
# 帮助和版本信息
# =============================================================================

show_help() {
    cat << EOF
${SCRIPT_NAME} v${VERSION} - 并行网络性能测试工具

用法: $0 [选项]

必需参数:
  -u, --username USERNAME     SSH连接用户名
  -p, --password PASSWORD     SSH连接密码
  -f, --hostfile FILE         主机列表文件 (每行一个IP/主机名)

可选参数:
  -m, --pairing MODE          配对模式 [full|ring|star|pair|opposite] (默认: full)
  -c, --concurrent NUM        并发测试数量 (默认: 5)
  -d, --duration SECONDS      每次测试持续时间 (默认: 10)
  -j, --threads NUM           iperf3并行线程数 (默认: 1, 范围: 1-128)
  -P, --port PORT             iperf3端口 (默认: 5201)
  -t, --protocol PROTO        协议类型 [tcp|udp] (默认: tcp)
  -o, --output FORMAT         输出格式 [table|json|csv] (默认: table)
  -v, --verbose               详细输出
  -n, --dry-run               试运行模式 (不执行实际测试)
  -F, --force-install         强制重新安装iperf3
  -h, --help                  显示此帮助信息
  -V, --version               显示版本信息

配对模式说明:
  full     - 全连接模式: 每个主机与其他所有主机测试
  ring     - 环形模式: 主机按顺序环形测试 (A->B->C->A)
  star     - 星形模式: 第一个主机作为中心与其他主机测试
  pair     - 对模式: 相邻主机配对测试 (A-B, C-D, ...)
  opposite - 对称模式: 首尾配对测试 (1-6, 2-5, 3-4, 适合独立网络路径)

线程数说明:
  1线程    - 标准单流测试，获得基线性能
  2-4线程  - 推荐用于10G/25G网络，充分利用网络带宽
  8+线程   - 适用于40G/100G高速网络

示例:
  $0 -u admin -p password123 -f hosts.txt
  $0 -u admin -p password123 -f hosts.txt -m ring -c 3 -d 30
  $0 -u admin -p password123 -f hosts.txt -m star -o json -v
  $0 -u admin -p password123 -f hosts.txt -m opposite -j 4 -d 60  # 25G网络4线程测试

EOF
}

show_version() {
    echo "${SCRIPT_NAME} v${VERSION}"
}

# =============================================================================
# 参数解析
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--username)
                USERNAME="$2"
                shift 2
                ;;
            -p|--password)
                PASSWORD="$2"
                shift 2
                ;;
            -f|--hostfile)
                HOSTFILE="$2"
                shift 2
                ;;
            -m|--pairing)
                PAIRING_MODE="$2"
                shift 2
                ;;
            -c|--concurrent)
                CONCURRENT_LIMIT="$2"
                shift 2
                ;;
            -d|--duration)
                TEST_DURATION="$2"  
                shift 2
                ;;
            -j|--threads)
                IPERF3_THREADS="$2"
                shift 2
                ;;
            -P|--port)
                IPERF3_PORT="$2"
                shift 2
                ;;
            -t|--protocol)
                PROTOCOL="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -n|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -F|--force-install)
                FORCE_INSTALL=true
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
            *)
                log ERROR "未知参数: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # 设置默认值
    USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
    PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
    HOSTFILE="${HOSTFILE:-$DEFAULT_HOSTFILE}"
    PAIRING_MODE="${PAIRING_MODE:-$DEFAULT_PAIRING}"
    CONCURRENT_LIMIT="${CONCURRENT_LIMIT:-$DEFAULT_CONCURRENT}"
    TEST_DURATION="${TEST_DURATION:-$DEFAULT_DURATION}"
    IPERF3_THREADS="${IPERF3_THREADS:-$DEFAULT_THREADS}"
    IPERF3_PORT="${IPERF3_PORT:-$DEFAULT_PORT}"
    PROTOCOL="${PROTOCOL:-$DEFAULT_PROTOCOL}"
    OUTPUT_FORMAT="${OUTPUT_FORMAT:-$DEFAULT_OUTPUT_FORMAT}"
}

# =============================================================================
# 参数验证
# =============================================================================

validate_arguments() {
    # 检查必需参数
    if [[ -z "$USERNAME" ]]; then
        log ERROR "缺少用户名参数 (-u/--username)"
        exit 1
    fi

    if [[ -z "$PASSWORD" ]]; then
        log ERROR "缺少密码参数 (-p/--password)"
        exit 1
    fi

    if [[ -z "$HOSTFILE" ]]; then
        log ERROR "缺少主机文件参数 (-f/--hostfile)"
        exit 1
    fi

    # 检查主机文件是否存在
    if [[ ! -f "$HOSTFILE" ]]; then
        log ERROR "主机文件不存在: $HOSTFILE"
        exit 1
    fi

    # 验证配对模式
    case "$PAIRING_MODE" in
        full|ring|star|pair|opposite|symmetric)
            ;;
        *)
            log ERROR "无效的配对模式: $PAIRING_MODE (支持: full, ring, star, pair, opposite)"
            exit 1
            ;;
    esac

    # 验证并发数
    if ! [[ "$CONCURRENT_LIMIT" =~ ^[0-9]+$ ]] || [[ "$CONCURRENT_LIMIT" -lt 1 ]]; then
        log ERROR "无效的并发数: $CONCURRENT_LIMIT"
        exit 1
    fi

    # 验证测试持续时间
    if ! [[ "$TEST_DURATION" =~ ^[0-9]+$ ]] || [[ "$TEST_DURATION" -lt 1 ]]; then
        log ERROR "无效的测试持续时间: $TEST_DURATION"
        exit 1
    fi

    # 验证线程数
    if ! [[ "$IPERF3_THREADS" =~ ^[0-9]+$ ]] || [[ "$IPERF3_THREADS" -lt 1 ]] || [[ "$IPERF3_THREADS" -gt 128 ]]; then
        log ERROR "无效的线程数: $IPERF3_THREADS (范围: 1-128)"
        exit 1
    fi

    # 验证端口
    if ! [[ "$IPERF3_PORT" =~ ^[0-9]+$ ]] || [[ "$IPERF3_PORT" -lt 1 ]] || [[ "$IPERF3_PORT" -gt 65535 ]]; then
        log ERROR "无效的端口号: $IPERF3_PORT"
        exit 1
    fi

    # 验证协议
    case "$PROTOCOL" in
        tcp|udp)
            ;;
        *)
            log ERROR "无效的协议: $PROTOCOL (支持: tcp, udp)"
            exit 1
            ;;
    esac

    # 验证输出格式
    case "$OUTPUT_FORMAT" in
        table|json|csv)
            ;;
        *)
            log ERROR "无效的输出格式: $OUTPUT_FORMAT (支持: table, json, csv)"
            exit 1
            ;;
    esac
}

# =============================================================================
# 初始化
# =============================================================================

initialize() {
    log INFO "初始化 ${SCRIPT_NAME} v${VERSION}..."
    
    # 创建必需目录
    mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$TEMP_DIR"
    
    # 检查系统要求
    if ! command -v sshpass &> /dev/null; then
        log WARN "sshpass 未安装，正在安装..."
        if [[ $DRY_RUN == false ]]; then
            sudo apt-get update && sudo apt-get install -y sshpass
        fi
    fi

    # 检查并准备iperf3离线包
    prepare_iperf3_offline_package

    log INFO "初始化完成"
}

# =============================================================================
# iperf3离线安装包管理
# =============================================================================

prepare_iperf3_offline_package() {
    mkdir -p "$IPERF3_OFFLINE_DIR"
    
    # 检查是否已存在离线包
    if ls "${IPERF3_OFFLINE_DIR}/iperf3_"*.deb 1> /dev/null 2>&1 && [[ $FORCE_INSTALL == false ]]; then
        log DEBUG "iperf3离线安装包已存在，跳过下载"
        return 0
    fi
    
    log INFO "准备iperf3离线安装包..."
    
    if [[ $FORCE_INSTALL == true ]]; then
        log INFO "强制重新下载iperf3离线安装包..."
    else
        log INFO "首次下载iperf3离线安装包..."
    fi
    
    if [[ $DRY_RUN == false ]]; then
        cd "$IPERF3_OFFLINE_DIR"
        
        # 下载iperf3及其依赖
        apt-get download iperf3 2>/dev/null || {
            log WARN "无法通过apt下载，尝试从官方源下载..."
            # 备用下载方法
            local arch=$(dpkg --print-architecture)
            local ubuntu_version=$(lsb_release -rs)
            wget -q "http://archive.ubuntu.com/ubuntu/pool/universe/i/iperf3/iperf3_3.9-1_${arch}.deb" -O "iperf3_3.9-1_${arch}.deb" || {
                log ERROR "无法下载iperf3安装包"
                exit 1
            }
        }
        
        # 下载依赖包
        apt-get download libiperf0 2>/dev/null || true
        
        cd "$SCRIPT_DIR"
    fi
    
    log SUCCESS "iperf3离线安装包准备完成"
}

# =============================================================================
# 主机管理
# =============================================================================

load_hosts() {
    local hosts=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 跳过空行和注释行
        line=$(echo "$line" | sed 's/#.*//' | xargs)
        [[ -n "$line" ]] && hosts+=("$line")
    done < "$HOSTFILE"
    
    if [[ ${#hosts[@]} -eq 0 ]]; then
        log ERROR "主机文件为空或无有效主机"
        exit 1
    fi
    
    log INFO "加载了 ${#hosts[@]} 个主机" >&2
    printf '%s\n' "${hosts[@]}"
}

check_host_connectivity() {
    local host=$1
    local timeout=5
    
    log DEBUG "检查主机连通性: $host"
    
    # 网络连通性检查
    if ! ping -c 1 -W "$timeout" "$host" &>/dev/null; then
        log WARN "主机不可达: $host"
        return 1
    fi
    
    # SSH连通性检查
    if ! sshpass -p "$PASSWORD" ssh $SSH_OPTS -o ConnectTimeout="$timeout" "$USERNAME@$host" "echo 'connected'" &>/dev/null; then
        log WARN "SSH连接失败: $host"
        return 1
    fi
    
    log DEBUG "主机连通性正常: $host"
    return 0
}

# =============================================================================
# iperf3安装和管理
# =============================================================================

install_iperf3_on_host() {
    local host=$1
    
    if [[ $DRY_RUN == true ]]; then
        log DEBUG "[DRY-RUN] 跳过 $host 上的iperf3安装检查"
        return 0
    fi
    
    # 首先检查是否已安装
    if sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$host" "command -v iperf3" &>/dev/null; then
        if [[ $FORCE_INSTALL == false ]]; then
            log DEBUG "iperf3已安装在 $host 上"
            return 0
        else
            log INFO "强制重新安装iperf3在 $host 上..."
        fi
    else
        log INFO "在主机 $host 上安装iperf3..."
    fi
    
    # 上传安装包
    log DEBUG "上传iperf3安装包到 $host"
    sshpass -p "$PASSWORD" scp $SCP_OPTS -r "$IPERF3_OFFLINE_DIR" "$USERNAME@$host:/tmp/" || {
        log ERROR "上传安装包失败: $host"
        return 1
    }
    
    # 远程安装
    sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$host" "
        cd /tmp/paraperf-offline
        sudo dpkg -i *.deb 2>/dev/null || {
            sudo apt-get update
            sudo apt-get install -f -y
            sudo dpkg -i *.deb
        }
        rm -rf /tmp/paraperf-offline
    " || {
        log ERROR "iperf3安装失败: $host"
        return 1
    }
    
    log SUCCESS "iperf3安装成功: $host"
    return 0
}

# =============================================================================
# 网络接口检测
# =============================================================================

get_host_network_info() {
    local host=$1
    
    local info=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$host" "
        # 获取主机名
        hostname=\$(hostname -s 2>/dev/null || echo 'unknown')
        
        # 查找对应测试IP的网卡接口
        test_ip=\"$host\"
        iface=\$(ip addr | grep -B2 \"inet \$test_ip/\" | grep -o '^[0-9]*: [^:]*' | cut -d' ' -f2 | head -1)
        
        # 如果没找到，使用默认路由接口
        if [[ -z \"\$iface\" ]]; then
            iface=\$(ip route | grep default | awk '{print \$5}' | head -1)
            # 获取默认接口的IP
            if [[ -n \"\$iface\" ]]; then
                test_ip=\$(ip addr show \"\$iface\" | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1 | head -1)
            fi
        fi
        
        if [[ -n \"\$iface\" ]]; then
            echo \"\$hostname|\$iface|\$test_ip\"
        else
            echo \"\$hostname|unknown|$host\"
        fi
    " 2>/dev/null)
    
    echo "$info"
}

# =============================================================================
# 测试配对生成
# =============================================================================

generate_test_pairs() {
    local hosts=("$@")
    local pairs=()
    
    case "$PAIRING_MODE" in
        full)
            # 全连接：每个主机与其他所有主机测试
            for ((i=0; i<${#hosts[@]}; i++)); do
                for ((j=i+1; j<${#hosts[@]}; j++)); do
                    pairs+=("${hosts[i]},${hosts[j]}")
                done
            done
            ;;
        ring)
            # 环形：A->B->C->A
            for ((i=0; i<${#hosts[@]}; i++)); do
                local next=$(( (i+1) % ${#hosts[@]} ))
                pairs+=("${hosts[i]},${hosts[next]}")
            done
            ;;
        star)
            # 星形：第一个主机作为中心
            local center="${hosts[0]}"
            for ((i=1; i<${#hosts[@]}; i++)); do
                pairs+=("$center,${hosts[i]}")
            done
            ;;
        pair)
            # 对模式：相邻配对
            for ((i=0; i<${#hosts[@]}; i+=2)); do
                if [[ $((i+1)) -lt ${#hosts[@]} ]]; then
                    pairs+=("${hosts[i]},${hosts[i+1]}")
                fi
            done
            ;;
        opposite|symmetric)
            # 对称配对：1对n, 2对n-1, 3对n-2 (适合独立网络路径测试)
            local host_count=${#hosts[@]}
            local paired_hosts=()
            
            # 首先进行对称配对
            for ((i=0; i<host_count/2; i++)); do
                local opposite_index=$((host_count-1-i))
                pairs+=("${hosts[i]},${hosts[opposite_index]}")
                paired_hosts+=("${hosts[i]}" "${hosts[opposite_index]}")
            done
            
            # 如果主机数量是奇数，找到未配对的主机
            if ((host_count % 2 == 1)); then
                local unpaired_host=""
                for host in "${hosts[@]}"; do
                    local found=false
                    for paired in "${paired_hosts[@]}"; do
                        if [[ "$host" == "$paired" ]]; then
                            found=true
                            break
                        fi
                    done
                    if [[ "$found" == false ]]; then
                        unpaired_host="$host"
                        break
                    fi
                done
                
                # 随机选择一个已配对的主机与未配对主机进行测试
                if [[ -n "$unpaired_host" ]]; then
                    local random_index=$((RANDOM % ${#paired_hosts[@]}))
                    local random_paired_host="${paired_hosts[random_index]}"
                    pairs+=("$unpaired_host,$random_paired_host")
                fi
            fi
            ;;
    esac
    
    # 将日志输出到stderr，避免混入结果
    log INFO "生成了 ${#pairs[@]} 个测试对 (模式: $PAIRING_MODE)" >&2
    printf '%s\n' "${pairs[@]}"
}

# =============================================================================
# iperf3测试执行
# =============================================================================

run_iperf3_test() {
    local server_host=$1
    local client_host=$2
    local test_id=$3
    
    log INFO "执行测试 #$test_id: $client_host -> $server_host" >&2
    
    if [[ $DRY_RUN == true ]]; then
        log INFO "[DRY-RUN] 测试 #$test_id: $client_host -> $server_host ($PROTOCOL, ${TEST_DURATION}s)" >&2
        # 创建模拟结果文件
        local result_file="${TEMP_DIR}/test_${test_id}_result.json"
        echo "DRY_RUN_RESULT" > "$result_file"
        echo "$result_file"
        return 0
    fi
    
    local result_file="${TEMP_DIR}/test_${test_id}_result.json"
    
    # 启动iperf3服务器
    log DEBUG "在 $server_host 上启动iperf3服务器" >&2
    
    # 先清理旧进程
    sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$server_host" "pkill -f iperf3 2>/dev/null || true" &>/dev/null
    
    # 为每个测试分配唯一端口，避免并发冲突
    local unique_port=$((IPERF3_PORT + test_id))
    
    # 启动服务器（在后台运行）
    sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$server_host" "nohup iperf3 -s -p $unique_port &" &>/dev/null &
    
    # 等待服务器启动
    sleep 4
    
    # 验证服务器是否运行，增加重试机制
    local server_started=false
    for i in {1..3}; do
        if sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$server_host" "pgrep -f 'iperf3.*-s' >/dev/null" 2>/dev/null; then
            log DEBUG "iperf3服务器在 $server_host 上启动成功 (尝试 $i/3)" >&2
            server_started=true
            break
        fi
        log DEBUG "等待服务器启动... (尝试 $i/3)" >&2
        sleep 2
    done
    
    if [[ $server_started == false ]]; then
        log ERROR "启动iperf3服务器失败: $server_host (3次尝试后仍然失败)" >&2
        # 创建错误结果文件
        echo '{"error": "server_start_failed", "server": "'$server_host'"}' > "$result_file"
        echo "$result_file"
        return 0
    fi
    
    # 测量RTT（通过ping）
    local rtt_result=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$client_host" "ping -c 3 -W 2 $server_host 2>/dev/null | grep 'avg' | awk -F'/' '{print \$5}'" 2>/dev/null || echo "N/A")
    
    # 运行客户端测试
    log DEBUG "从 $client_host 连接到 $server_host 执行测试 (端口: $unique_port, 线程数: $IPERF3_THREADS)" >&2
    local client_cmd="iperf3 -c $server_host -p $unique_port -t $TEST_DURATION -P $IPERF3_THREADS -J"
    [[ "$PROTOCOL" == "udp" ]] && client_cmd+=" -u"
    
    local test_result=$(sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$client_host" "$client_cmd" 2>/dev/null)
    local exit_code=$?
    
    # 停止服务器（停止特定端口的iperf3进程）
    sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$server_host" "pkill -f 'iperf3.*-p $unique_port' 2>/dev/null || true" &>/dev/null
    
    if [[ $exit_code -ne 0 ]] || [[ -z "$test_result" ]]; then
        log ERROR "测试失败 #$test_id: $client_host -> $server_host (退出码: $exit_code)" >&2
        # 创建错误结果文件，以便后续处理能够识别
        echo '{"error": "test_failed", "exit_code": '$exit_code'}' > "$result_file"
        echo "$result_file"
        return 0  # 返回0以便继续处理其他测试
    fi
    
    # 保存结果，将RTT作为额外信息保存到单独文件
    echo "$test_result" > "$result_file"
    
    # 将ping RTT保存到独立文件
    if [[ "$rtt_result" != "N/A" ]]; then
        echo "$rtt_result" > "${result_file}.rtt"
    fi
    
    echo "$result_file"
}

# =============================================================================
# 并发测试管理
# =============================================================================

run_concurrent_tests() {
    local pairs=("$@")
    local total_tests=${#pairs[@]}
    local temp_result_files=()
    
    log INFO "开始并发测试 (并发数: $CONCURRENT_LIMIT, 总测试数: $total_tests)" >&2
    
    # 创建临时结果文件
    for ((i=0; i<$total_tests; i++)); do
        local temp_file="${TEMP_DIR}/concurrent_result_$i.tmp"
        temp_result_files+=("$temp_file")
    done
    
    # 分批处理测试
    for ((batch_start=0; batch_start<$total_tests; batch_start+=CONCURRENT_LIMIT)); do
        local batch_end=$((batch_start + CONCURRENT_LIMIT))
        [[ $batch_end -gt $total_tests ]] && batch_end=$total_tests
        
        local batch_pids=()
        
        # 启动这一批测试
        for ((i=batch_start; i<batch_end; i++)); do
            local pair="${pairs[i]}"
            IFS=',' read -r server client <<< "$pair"
            local test_id=$((i+1))
            local temp_file="${temp_result_files[i]}"
            
            {
                local result=$(run_iperf3_test "$server" "$client" "$test_id")
                log DEBUG "测试 #$test_id 结果: $result" >&2
                echo "$test_id|$server|$client|$result" > "$temp_file"
                log DEBUG "写入临时文件: $temp_file" >&2
            } &
            
            batch_pids+=($!)
            log DEBUG "启动测试 #$test_id (PID: $!)" >&2
        done
        
        # 等待这一批完成
        for pid in "${batch_pids[@]}"; do
            wait "$pid"
        done
        
        log INFO "批次 $((batch_start/CONCURRENT_LIMIT + 1)) 完成" >&2
    done
    
    # 收集所有结果
    for temp_file in "${temp_result_files[@]}"; do
        if [[ -f "$temp_file" ]]; then
            cat "$temp_file"
            rm -f "$temp_file"
        fi
    done
    
    log SUCCESS "所有测试完成 (共 $total_tests 个)" >&2
}

# =============================================================================
# 结果处理和输出
# =============================================================================

parse_iperf3_result() {
    local result_file=$1
    
    if [[ ! -f "$result_file" ]]; then
        echo "ERROR|无法读取结果文件"
        return 1
    fi
    
    if [[ "$(cat "$result_file")" == "DRY_RUN_RESULT" ]]; then
        # 生成随机的模拟性能数据
        local random_bandwidth=$((800 + RANDOM % 400))  # 800-1200 Mbps
        local random_rtt=$(echo "scale=1; (5 + ($RANDOM % 20)) / 10" | bc)  # 0.5-2.5 ms
        echo "SUCCESS|$random_bandwidth|Mbps|$random_rtt|ms"
        return 0
    fi
    
    # 检查是否是错误结果文件
    local error_check=$(jq -r '.error // "none"' "$result_file" 2>/dev/null)
    if [[ "$error_check" == "test_failed" ]]; then
        local exit_code=$(jq -r '.exit_code // "unknown"' "$result_file" 2>/dev/null)
        echo "ERROR|测试失败 (退出码: $exit_code)|N/A|N/A|N/A"
        return 1
    elif [[ "$error_check" == "server_start_failed" ]]; then
        local server=$(jq -r '.server // "unknown"' "$result_file" 2>/dev/null)
        echo "ERROR|服务器启动失败 ($server)|N/A|N/A|N/A"
        return 1
    fi
    
    # 解析JSON结果
    local bandwidth_bps=$(jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second // 0' "$result_file" 2>/dev/null)
    
    # 获取延迟信息
    local rtt_ms="N/A"
    
    # 优先使用ping RTT（从独立文件读取）
    if [[ -f "${result_file}.rtt" ]]; then
        rtt_ms=$(cat "${result_file}.rtt" 2>/dev/null)
        rm -f "${result_file}.rtt"  # 清理临时文件
    elif [[ "$PROTOCOL" == "udp" ]]; then
        # UDP测试从iperf3获取RTT
        rtt_ms=$(jq -r '.end.streams[0].udp.mean_rtt // "N/A"' "$result_file" 2>/dev/null)
    fi
    
    if [[ "$bandwidth_bps" == "0" ]] || [[ "$bandwidth_bps" == "null" ]]; then
        echo "ERROR|测试失败或结果解析失败"
        return 1
    fi
    
    # 转换带宽单位
    local bandwidth_mbps
    if [[ "$bandwidth_bps" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        bandwidth_mbps=$(echo "scale=2; $bandwidth_bps / 1000000" | bc 2>/dev/null || echo "0")
    else
        bandwidth_mbps="0"
    fi
    
    # 格式化RTT，确保小数点前有0
    if [[ "$rtt_ms" != "N/A" ]] && [[ "$rtt_ms" != "null" ]] && [[ "$rtt_ms" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        rtt_ms=$(printf "%.3f" "$rtt_ms" 2>/dev/null || echo "N/A")
    fi
    
    echo "SUCCESS|$bandwidth_mbps|Mbps|$rtt_ms|ms"
}

format_output() {
    local test_results=("$@")
    
    case "$OUTPUT_FORMAT" in
        table)
            format_table_output "${test_results[@]}"
            ;;
        json)
            format_json_output "${test_results[@]}"
            ;;
        csv)
            format_csv_output "${test_results[@]}"
            ;;
    esac
}

format_table_output() {
    local test_results=("$@")
    
    echo
    echo "=========================================="
    echo "           网络性能测试报告"
    echo "=========================================="
    echo
    printf "%-4s %-10s %-6s %-10s %-6s %-15s %-15s %-12s %s\n" \
        "ID" "服务器" "网卡" "客户端" "网卡" "服务器IP" "客户端IP" "带宽" "延迟"
    echo "----------------------------------------------------------------------------------------------------------------------"
    
    for result_line in "${test_results[@]}"; do
        IFS='|' read -r test_id server client result_file <<< "$result_line"
        
        if [[ -z "$result_file" ]]; then
            log DEBUG "跳过无效结果行: $result_line"
            continue
        fi
        
        # 获取网络信息 
        local server_hostname="$server"
        local client_hostname="$client"
        local server_ip="$server"
        local client_ip="$client"
        local server_iface="eth0"
        local client_iface="eth0"
        
        if [[ $DRY_RUN == false ]]; then
            local server_info=$(get_host_network_info "$server")
            local client_info=$(get_host_network_info "$client")
            
            IFS='|' read -r server_hostname server_iface server_ip <<< "$server_info"
            IFS='|' read -r client_hostname client_iface client_ip <<< "$client_info"
            
            # 如果获取主机名失败，回退到IP
            [[ "$server_hostname" == "unknown" ]] && server_hostname="$server"
            [[ "$client_hostname" == "unknown" ]] && client_hostname="$client"
            [[ "$server_iface" == "unknown" ]] && server_iface="N/A"
            [[ "$client_iface" == "unknown" ]] && client_iface="N/A"
        fi
        
        # 解析测试结果
        local parsed_result=$(parse_iperf3_result "$result_file")
        IFS='|' read -r status bandwidth unit rtt rtt_unit <<< "$parsed_result"
        
        if [[ "$status" == "SUCCESS" ]]; then
            printf "%-4s %-10s %-6s %-10s %-6s %-15s %-15s %-12s %s\n" \
                "$test_id" "$server_hostname" "$server_iface" "$client_hostname" "$client_iface" "$server_ip" "$client_ip" \
                "${bandwidth} ${unit}" "${rtt} ${rtt_unit}"
        else
            printf "%-4s %-10s %-6s %-10s %-6s %-15s %-15s %-12s %s\n" \
                "$test_id" "$server_hostname" "$server_iface" "$client_hostname" "$client_iface" "$server_ip" "$client_ip" \
                "FAILED" "N/A"
        fi
    done
    
    echo "----------------------------------------------------------------------------------------------------------------------"
    echo
}

format_json_output() {
    local test_results=("$@")
    
    echo "{"
    echo "  \"test_info\": {"
    echo "    \"timestamp\": \"$(date -Iseconds)\","
    echo "    \"pairing_mode\": \"$PAIRING_MODE\","
    echo "    \"protocol\": \"$PROTOCOL\","
    echo "    \"duration\": $TEST_DURATION,"
    echo "    \"port\": $IPERF3_PORT"
    echo "  },"
    echo "  \"results\": ["
    
    local first=true
    for result_line in "${test_results[@]}"; do
        IFS='|' read -r test_id server client result_file <<< "$result_line"
        
        if [[ -z "$result_file" ]]; then
            continue
        fi
        
        [[ $first == false ]] && echo ","
        first=false
        
        # 获取网络信息
        local server_info=$(get_host_network_info "$server")
        local client_info=$(get_host_network_info "$client")
        
        IFS='|' read -r server_hostname server_iface server_ip <<< "$server_info"
        IFS='|' read -r client_hostname client_iface client_ip <<< "$client_info"
        
        # 如果获取主机名失败，回退到IP
        [[ "$server_hostname" == "unknown" ]] && server_hostname="$server"
        [[ "$client_hostname" == "unknown" ]] && client_hostname="$client"
        
        # 解析测试结果
        local parsed_result=$(parse_iperf3_result "$result_file")
        IFS='|' read -r status bandwidth unit rtt rtt_unit <<< "$parsed_result"
        
        echo "    {"
        echo "      \"test_id\": $test_id,"
        echo "      \"server\": {"
        echo "        \"hostname\": \"$server_hostname\","
        echo "        \"ip\": \"$server_ip\","
        echo "        \"interface\": \"$server_iface\""
        echo "      },"
        echo "      \"client\": {"
        echo "        \"hostname\": \"$client_hostname\","
        echo "        \"ip\": \"$client_ip\","
        echo "        \"interface\": \"$client_iface\""
        echo "      },"
        echo "      \"result\": {"
        echo "        \"status\": \"$status\","
        echo "        \"bandwidth\": \"$bandwidth\","
        echo "        \"bandwidth_unit\": \"$unit\","
        echo "        \"rtt\": \"$rtt\","
        echo "        \"rtt_unit\": \"$rtt_unit\""
        echo "      }"
        echo -n "    }"
    done
    
    echo
    echo "  ]"
    echo "}"
}

format_csv_output() {
    local test_results=("$@")
    
    echo "test_id,server_hostname,client_hostname,server_ip,client_ip,server_interface,client_interface,bandwidth_mbps,rtt_ms,status"
    
    for result_line in "${test_results[@]}"; do
        IFS='|' read -r test_id server client result_file <<< "$result_line"
        
        if [[ -z "$result_file" ]]; then
            continue
        fi
        
        # 获取网络信息
        local server_info=$(get_host_network_info "$server")
        local client_info=$(get_host_network_info "$client")
        
        IFS='|' read -r server_hostname server_iface server_ip <<< "$server_info"
        IFS='|' read -r client_hostname client_iface client_ip <<< "$client_info"
        
        # 如果获取主机名失败，回退到IP
        [[ "$server_hostname" == "unknown" ]] && server_hostname="$server"
        [[ "$client_hostname" == "unknown" ]] && client_hostname="$client"
        
        # 解析测试结果
        local parsed_result=$(parse_iperf3_result "$result_file")
        IFS='|' read -r status bandwidth unit rtt rtt_unit <<< "$parsed_result"
        
        echo "$test_id,$server_hostname,$client_hostname,$server_ip,$client_ip,$server_iface,$client_iface,$bandwidth,$rtt,$status"
    done
}

# =============================================================================
# 主函数
# =============================================================================

main() {
    # 解析和验证参数
    parse_arguments "$@"
    validate_arguments
    
    # 初始化
    initialize
    
    log INFO "开始网络性能测试..."
    log INFO "配置: 用户=$USERNAME, 配对模式=$PAIRING_MODE, 并发数=$CONCURRENT_LIMIT, 线程数=$IPERF3_THREADS, 协议=$PROTOCOL"
    
    # 加载主机列表
    local hosts=()
    while IFS= read -r host; do
        hosts+=("$host")
    done < <(load_hosts)
    
    if [[ ${#hosts[@]} -lt 2 ]]; then
        log ERROR "至少需要2个主机进行测试"
        exit 1
    fi
    
    # 检查主机连通性
    local reachable_hosts=()
    local unreachable_hosts=()
    log INFO "检查主机连通性..."
    for host in "${hosts[@]}"; do
        if check_host_connectivity "$host" >/dev/null 2>&1; then
            reachable_hosts+=("$host")
        else
            unreachable_hosts+=("$host")
        fi
    done
    
    # 显示离线主机信息
    if [[ ${#unreachable_hosts[@]} -gt 0 ]]; then
        for offline_host in "${unreachable_hosts[@]}"; do
            [[ -n "$offline_host" ]] && echo "[WARN] 主机离线: $offline_host" >&2
        done
    fi
    
    if [[ ${#reachable_hosts[@]} -lt 2 ]]; then
        log ERROR "可达主机数量不足 (需要至少2个): ${#reachable_hosts[@]}"
        exit 1
    fi
    
    log SUCCESS "发现 ${#reachable_hosts[@]} 个可达主机"
    
    # 安装iperf3 
    log INFO "检查并安装iperf3..."
    local need_install=()
    
    # 先检查哪些主机需要安装
    for host in "${reachable_hosts[@]}"; do
        if [[ $DRY_RUN == false ]]; then
            if ! sshpass -p "$PASSWORD" ssh $SSH_OPTS "$USERNAME@$host" "command -v iperf3" &>/dev/null || [[ $FORCE_INSTALL == true ]]; then
                need_install+=("$host")
            fi
        fi
    done
    
    if [[ ${#need_install[@]} -gt 0 ]]; then
        log INFO "需要安装iperf3的主机: ${need_install[*]}"
        for host in "${need_install[@]}"; do
            install_iperf3_on_host "$host" &
        done
        wait
    else
        log DEBUG "所有主机已安装iperf3，跳过安装步骤"
    fi
    
    # 生成测试对
    local test_pairs=()
    while IFS= read -r pair; do
        [[ -n "$pair" ]] && test_pairs+=("$pair")
    done < <(generate_test_pairs "${reachable_hosts[@]}")
    
    if [[ ${#test_pairs[@]} -eq 0 ]]; then
        log ERROR "没有生成测试对"
        exit 1
    fi
    
    # 执行并发测试
    local test_results=()
    while IFS= read -r result_line; do
        [[ -n "$result_line" ]] && test_results+=("$result_line")
    done < <(run_concurrent_tests "${test_pairs[@]}")
    
    # 输出结果
    if [[ ${#test_results[@]} -gt 0 ]]; then
        format_output "${test_results[@]}"
    else
        log WARN "没有测试结果"
    fi
    
    log SUCCESS "测试完成！"
    
    # 清理临时文件
    cleanup
}

# =============================================================================
# 脚本入口
# =============================================================================

# 检查依赖和初始化目录
check_dependencies() {
    # 先创建基本目录，以便日志功能可以工作
    mkdir -p "${SCRIPT_DIR}/.paraperf/logs" "${SCRIPT_DIR}/.paraperf/temp"
    
    local missing_deps=()
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if ! command -v bc &> /dev/null; then
        missing_deps+=("bc")
    fi
    
    if ! command -v sshpass &> /dev/null; then
        missing_deps+=("sshpass")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "错误: 缺少必需的工具: ${missing_deps[*]}"
        echo "安装命令: sudo apt-get install -y ${missing_deps[*]}"
        exit 1
    fi
}

# 检查依赖
check_dependencies

# 运行主函数
main "$@"
