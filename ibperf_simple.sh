#!/bin/bash
# IB 性能测试集成脚本 (IBPerf) —— 普通用户版
# 支持延时测试 (ib_write_lat) 和带宽测试 (ib_write_bw)
# 支持大规模集群（如 128 台服务器）的并发测试
#
# 与 root 版的差异：
#   1. 不执行 mst start / mst status（需要 root）
#   2. 不设置 CPU 性能模式（需要 root），改用 -F 忽略主频告警
#   3. 默认 SSH 用户 = 当前登录用户，而非 root
#   4. 默认关闭 NUMA 绑定；如需绑定用 --numa，通过 sysfs 读取（无需 root）
#   5. pkill 只终止当前用户自己的进程
#   6. 增加 memlock / uverbs 权限预检（普通用户跑 RDMA 最常见的坑）

# 默认参数
SERVER_FILE=""
CLIENT_FILE=""
HOSTFILE=""              # 单文件主机列表（自动配对模式）
HCA_LIST="mlx5_20,mlx5_21,mlx5_22,mlx5_23,mlx5_24,mlx5_25,mlx5_26,mlx5_27"
SSH_USER="$(id -un)"     # 默认使用当前用户（不再写死 root）
DURATION=""
ITERATIONS=""
SIZE=2
IB_PORT=1
BASE_TCP_PORT=18515
PERFORM_WARMUP=true
REPORT_HISTOGRAM=false
REPORT_UNSORTED=false
MAX_CONCURRENT_BATCH=32  # 最大并发启动批次大小
PAIRING_MODE=""   # 主机配对模式（稍后根据模式设置默认值）
# 双文件模式 (--server_file + --client_file): forward, reverse, random
# 单文件模式 (--hostfile): consecutive, split_half, odd_even, random
HCA_PAIRING_MODE="forward"  # 网卡配对模式: forward(正序), reverse(倒序), random(随机)

# 测试模式相关参数
TEST_MODE="latency"  # 测试模式: latency(延时) 或 bandwidth(带宽)

# 带宽测试特有参数
BIDIRECTIONAL=false  # 双向带宽测试
ALL_SIZES=false      # 测试从 2 到 2^23 的所有大小
REPORT_GBITS=true    # 以 Gbit/s 报告结果（带宽测试默认启用）
TX_DEPTH=128         # 发送队列深度
QP_NUM=2             # QP 数量（默认2）
MTU=""               # MTU 大小
NO_PEAK=false        # 取消峰值带宽计算
RUN_INFINITELY=false # 无限运行测试
REVERSED=false       # 反向流量（服务器发送到客户端）

# NUMA 绑定（普通用户版默认关闭）
ENABLE_NUMA_BINDING=false

# 预检开关
SKIP_PRECHECK=false

# 远程 PATH 前缀：非交互式 SSH 的 PATH 常常不含 /usr/local/bin 等
REMOTE_PATH_PREFIX='export PATH="$PATH:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"; '

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 帮助函数
show_help() {
    echo -e "${BOLD}用法:${NC}"
    echo "  模式1 (双文件): $0 --server_file <文件> --client_file <文件> [选项]"
    echo "  模式2 (单文件): $0 --hostfile <文件> [选项]"
    echo ""
    echo -e "${BOLD}必需参数 (二选一):${NC}"
    echo -e "  ${BOLD}模式1 - 双文件模式:${NC}"
    echo "    --server_file FILE        服务器端主机列表文件"
    echo "    --client_file FILE        客户端主机列表文件"
    echo ""
    echo -e "  ${BOLD}模式2 - 单文件模式:${NC}"
    echo "    --hostfile FILE           单个主机列表文件（自动配对）"
    echo ""
    echo -e "${BOLD}测试模式:${NC}"
    echo "  --mode <latency|bandwidth> 测试模式 (默认: latency)"
    echo "                            latency   - 延时测试 (使用 ib_write_lat)"
    echo "                            bandwidth - 带宽测试 (使用 ib_write_bw)"
    echo ""
    echo -e "${BOLD}通用参数:${NC}"
    echo "  --hca_list HCA1,HCA2,...  指定要测试的HCA设备列表"
    echo "                            (默认: $HCA_LIST)"
    echo "  --user USER               SSH用户名 (默认: 当前用户 $(id -un))"
    echo "  --duration SECONDS        测试持续时间（秒），与 --iterations 二选一"
    echo "  --iterations N            测试迭代次数，与 --duration 二选一 (默认: duration 600)"
    echo "  --size BYTES              消息大小（字节）(默认: latency=2, bandwidth=65536)"
    echo "  --ib_port PORT            IB 端口号 (默认: 1)"
    echo "  --base_port PORT          基础 TCP 端口 (默认: 18515，普通用户须 >1024)"
    echo "  --max_batch SIZE          最大并发启动批次大小 (默认: 32)"
    echo "  --pairing MODE            主机配对模式（根据使用模式不同）:"
    echo "                            双文件模式 (默认: forward):"
    echo "                              forward     - 正序配对 (server[1]↔client[1], ...)"
    echo "                              reverse     - 倒序配对 (server[1]↔client[n], ...)"
    echo "                              random      - 随机配对 (客户端随机打乱)"
    echo "                            单文件模式 (默认: consecutive):"
    echo "                              consecutive - 顺序两两配对 (1->2, 3->4, ...)"
    echo "                              split_half  - 前后分半配对 (1->n/2+1, 2->n/2+2, ...)"
    echo "                              odd_even    - 奇偶配对 (1,3,5...->2,4,6...)"
    echo "                              random      - 随机分组配对"
    echo "  --hca_pairing MODE        网卡配对模式: forward(正序), reverse(倒序), random(随机)"
    echo "                            (默认: forward)"
    echo "  --perform_warm_up         启用预热测试 (默认: 启用)"
    echo "  --no_warmup               禁用预热测试"
    echo "  --numa                    启用 NUMA 绑定 (默认: 关闭；通过 sysfs 读取，无需 root)"
    echo "  --skip_precheck           跳过 memlock / uverbs 权限预检"
    echo ""
    echo -e "${BOLD}延时测试专用参数:${NC}"
    echo "  --histogram               启用延时直方图输出 (-H 参数)"
    echo "  --unsorted                启用未排序结果输出 (-U 参数)"
    echo ""
    echo -e "${BOLD}带宽测试专用参数:${NC}"
    echo "  --bidirectional           双向带宽测试 (默认: 单向)"
    echo "  --all_sizes               测试从 2 到 2^23 的所有大小"
    echo "  --no_report_gbits         以 MiB/s 报告结果 (默认: Gbit/s)"
    echo "  --tx_depth N              发送队列深度 (默认: 128)"
    echo "  --qp N                    QP 数量 (默认: 2)"
    echo "  --mtu SIZE                MTU 大小: 256-4096"
    echo "  --no_peak                 取消峰值带宽计算"
    echo "  --reversed                反向流量（服务器发送到客户端）"
    echo ""
    echo "  --help                    显示此帮助信息"
    echo ""
    echo -e "${BOLD}普通用户运行前提:${NC}"
    echo "  1. 各节点已配置免密 SSH（当前用户）"
    echo "  2. /dev/infiniband/uverbs* 对普通用户可读写（rdma-core udev 规则默认满足）"
    echo "  3. memlock 限制足够大，建议 /etc/security/limits.conf 中配置:"
    echo "       * soft memlock unlimited"
    echo "       * hard memlock unlimited"
    echo "  4. 未设置 CPU 性能模式（需 root），延时结果可能略高于 root 版"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo ""
    echo -e "  ${BOLD}【单文件模式】${NC}"
    echo "  $0 --hostfile hosts.txt --pairing consecutive --duration 600"
    echo "  $0 --hostfile hosts.txt --pairing split_half --duration 600"
    echo "  $0 --hostfile hosts.txt --pairing random --mode bandwidth --duration 600"
    echo ""
    echo -e "  ${BOLD}【双文件模式】${NC}"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --duration 600"
    exit 0
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --server_file) SERVER_FILE="$2"; shift 2 ;;
        --client_file) CLIENT_FILE="$2"; shift 2 ;;
        --hostfile) HOSTFILE="$2"; shift 2 ;;
        --mode) TEST_MODE="$2"; shift 2 ;;
        --hca_list) HCA_LIST="$2"; shift 2 ;;
        --user) SSH_USER="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --iterations) ITERATIONS="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --ib_port) IB_PORT="$2"; shift 2 ;;
        --base_port) BASE_TCP_PORT="$2"; shift 2 ;;
        --max_batch) MAX_CONCURRENT_BATCH="$2"; shift 2 ;;
        --pairing) PAIRING_MODE="$2"; shift 2 ;;
        --hca_pairing) HCA_PAIRING_MODE="$2"; shift 2 ;;
        --perform_warm_up) PERFORM_WARMUP=true; shift ;;
        --no_warmup) PERFORM_WARMUP=false; shift ;;
        --numa) ENABLE_NUMA_BINDING=true; shift ;;
        --no_numa) ENABLE_NUMA_BINDING=false; shift ;;
        --skip_precheck) SKIP_PRECHECK=true; shift ;;
        --histogram) REPORT_HISTOGRAM=true; shift ;;
        --unsorted) REPORT_UNSORTED=true; shift ;;
        # 带宽测试专用参数
        --bidirectional) BIDIRECTIONAL=true; shift ;;
        --all_sizes) ALL_SIZES=true; shift ;;
        --report_gbits) REPORT_GBITS=true; shift ;;
        --no_report_gbits) REPORT_GBITS=false; shift ;;
        --tx_depth) TX_DEPTH="$2"; shift 2 ;;
        --qp) QP_NUM="$2"; shift 2 ;;
        --mtu) MTU="$2"; shift 2 ;;
        --no_peak) NO_PEAK=true; shift ;;
        --reversed) REVERSED=true; shift ;;
        --help) show_help ;;
        *) echo -e "${RED}错误:${NC} 未知选项 $1"; show_help ;;
    esac
done

# ============================================================================
# 参数验证
# ============================================================================
if [ -n "$HOSTFILE" ] && { [ -n "$SERVER_FILE" ] || [ -n "$CLIENT_FILE" ]; }; then
    echo -e "${RED}错误:${NC} 不能同时使用 --hostfile 和 --server_file/--client_file"
    echo "请选择其中一种模式："
    echo "  模式1 (双文件): --server_file + --client_file"
    echo "  模式2 (单文件): --hostfile"
    exit 1
fi

if [ -z "$HOSTFILE" ] && { [ -z "$SERVER_FILE" ] || [ -z "$CLIENT_FILE" ]; }; then
    echo -e "${RED}错误:${NC} 必须指定以下模式之一："
    echo "  模式1 (双文件): --server_file + --client_file"
    echo "  模式2 (单文件): --hostfile"
    exit 1
fi

if [ -n "$HOSTFILE" ]; then
    if [ ! -f "$HOSTFILE" ]; then
        echo -e "${RED}错误:${NC} 文件 $HOSTFILE 不存在"
        exit 1
    fi
else
    for file in "$SERVER_FILE" "$CLIENT_FILE"; do
        if [ ! -f "$file" ]; then
            echo -e "${RED}错误:${NC} 文件 $file 不存在"
            exit 1
        fi
    done
fi

if [ -z "$DURATION" ] && [ -z "$ITERATIONS" ]; then
    DURATION=600
fi

if [ -n "$DURATION" ] && [ -n "$ITERATIONS" ]; then
    echo -e "${RED}错误:${NC} --duration 和 --iterations 只能指定其中一个"
    exit 1
fi

# 普通用户不能绑定 <1024 的特权端口
if [ "$(id -u)" -ne 0 ] && [ "$BASE_TCP_PORT" -lt 1024 ]; then
    echo -e "${RED}错误:${NC} 普通用户无法绑定小于 1024 的端口，请调整 --base_port"
    exit 1
fi

# 设置配对模式的默认值
if [ -z "$PAIRING_MODE" ]; then
    if [ -n "$HOSTFILE" ]; then
        PAIRING_MODE="consecutive"
    else
        PAIRING_MODE="forward"
    fi
fi

# 验证主机配对模式
if [ -n "$HOSTFILE" ]; then
    if [[ "$PAIRING_MODE" != "consecutive" && "$PAIRING_MODE" != "split_half" && "$PAIRING_MODE" != "odd_even" && "$PAIRING_MODE" != "random" ]]; then
        echo -e "${RED}错误:${NC} 单文件模式下 --pairing 必须是 consecutive / split_half / odd_even / random"
        echo "当前值: $PAIRING_MODE"
        exit 1
    fi
else
    if [[ "$PAIRING_MODE" != "forward" && "$PAIRING_MODE" != "reverse" && "$PAIRING_MODE" != "random" ]]; then
        echo -e "${RED}错误:${NC} 双文件模式下 --pairing 必须是 forward / reverse / random"
        echo "当前值: $PAIRING_MODE"
        exit 1
    fi
fi

if [[ "$HCA_PAIRING_MODE" != "forward" && "$HCA_PAIRING_MODE" != "reverse" && "$HCA_PAIRING_MODE" != "random" ]]; then
    echo -e "${RED}错误:${NC} --hca_pairing 参数必须是 forward, reverse 或 random"
    echo "当前值: $HCA_PAIRING_MODE"
    exit 1
fi

if [[ "$TEST_MODE" != "latency" && "$TEST_MODE" != "bandwidth" ]]; then
    echo -e "${RED}错误:${NC} --mode 参数必须是 latency 或 bandwidth"
    echo "当前值: $TEST_MODE"
    exit 1
fi

# 根据测试模式确定命令（必须在打印配置之前确定）
if [ "$TEST_MODE" = "latency" ]; then
    TEST_CMD="ib_write_lat"
else
    TEST_CMD="ib_write_bw"
fi

# 根据测试模式设置默认 SIZE
if [ "$SIZE" = "2" ] && [ "$TEST_MODE" = "bandwidth" ]; then
    SIZE=65536
fi

# ============================================================================
# 主机配对
# ============================================================================
if [ -n "$HOSTFILE" ]; then
    # ==================== 单文件模式 ====================
    HOSTS_ALL=()
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && HOSTS_ALL+=("$line")
    done < "$HOSTFILE"

    if [ ${#HOSTS_ALL[@]} -eq 0 ]; then
        echo -e "${RED}错误:${NC} 主机列表为空"
        exit 1
    fi

    SERVERS=()
    CLIENTS=()

    if [ $((${#HOSTS_ALL[@]} % 2)) -ne 0 ]; then
        echo -e "${RED}错误:${NC} $PAIRING_MODE 模式需要偶数个主机"
        echo "当前主机数量: ${#HOSTS_ALL[@]}"
        exit 1
    fi

    case "$PAIRING_MODE" in
        consecutive)
            for (( i=0; i<${#HOSTS_ALL[@]}; i+=2 )); do
                SERVERS+=("${HOSTS_ALL[$i]}")
                CLIENTS+=("${HOSTS_ALL[$i+1]}")
            done
            ;;
        split_half)
            half=$((${#HOSTS_ALL[@]} / 2))
            for (( i=0; i<half; i++ )); do
                SERVERS+=("${HOSTS_ALL[$i]}")
                CLIENTS+=("${HOSTS_ALL[$i+$half]}")
            done
            ;;
        odd_even)
            for (( i=0; i<${#HOSTS_ALL[@]}; i+=2 )); do
                SERVERS+=("${HOSTS_ALL[$i]}")
            done
            for (( i=1; i<${#HOSTS_ALL[@]}; i+=2 )); do
                CLIENTS+=("${HOSTS_ALL[$i]}")
            done
            ;;
        random)
            indices=()
            for (( i=0; i<${#HOSTS_ALL[@]}; i++ )); do
                indices+=($i)
            done
            for (( i=${#indices[@]}-1; i>0; i-- )); do
                j=$((RANDOM % (i+1)))
                tmp=${indices[$i]}
                indices[$i]=${indices[$j]}
                indices[$j]=$tmp
            done
            half=$((${#indices[@]} / 2))
            for (( i=0; i<half; i++ )); do
                SERVERS+=("${HOSTS_ALL[${indices[$i]}]}")
                CLIENTS+=("${HOSTS_ALL[${indices[$i+$half]}]}")
            done
            ;;
    esac
else
    # ==================== 双文件模式 ====================
    SERVERS_RAW=()
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && SERVERS_RAW+=("$line")
    done < "$SERVER_FILE"

    CLIENTS_RAW=()
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && CLIENTS_RAW+=("$line")
    done < "$CLIENT_FILE"

    if [ ${#SERVERS_RAW[@]} -ne ${#CLIENTS_RAW[@]} ]; then
        echo -e "${RED}错误:${NC} 服务器和客户端主机数量不一致"
        echo "服务器数量: ${#SERVERS_RAW[@]}, 客户端数量: ${#CLIENTS_RAW[@]}"
        exit 1
    fi

    if [ ${#SERVERS_RAW[@]} -eq 0 ]; then
        echo -e "${RED}错误:${NC} 主机列表为空"
        exit 1
    fi

    SERVERS=()
    CLIENTS=()

    case "$PAIRING_MODE" in
        forward)
            SERVERS=("${SERVERS_RAW[@]}")
            CLIENTS=("${CLIENTS_RAW[@]}")
            ;;
        reverse)
            SERVERS=("${SERVERS_RAW[@]}")
            for (( i=${#CLIENTS_RAW[@]}-1; i>=0; i-- )); do
                CLIENTS+=("${CLIENTS_RAW[$i]}")
            done
            ;;
        random)
            SERVERS=("${SERVERS_RAW[@]}")
            indices=()
            for (( i=0; i<${#CLIENTS_RAW[@]}; i++ )); do
                indices+=($i)
            done
            for (( i=${#indices[@]}-1; i>0; i-- )); do
                j=$((RANDOM % (i+1)))
                tmp=${indices[$i]}
                indices[$i]=${indices[$j]}
                indices[$j]=$tmp
            done
            for idx in "${indices[@]}"; do
                CLIENTS+=("${CLIENTS_RAW[$idx]}")
            done
            ;;
    esac
fi

# 配对自检
echo -e "${BOLD}[配对自检]${NC} 验证主机配对..."

declare -A server_check
for server in "${SERVERS[@]}"; do
    if [ -n "${server_check[$server]}" ]; then
        echo -e "${RED}错误:${NC} 服务器列表中发现重复: $server"
        exit 1
    fi
    server_check[$server]=1
done

declare -A client_check
for client in "${CLIENTS[@]}"; do
    if [ -n "${client_check[$client]}" ]; then
        echo -e "${RED}错误:${NC} 客户端列表中发现重复: $client"
        exit 1
    fi
    client_check[$client]=1
done

if [ -z "$HOSTFILE" ]; then
    for server in "${SERVERS_RAW[@]}"; do
        if [ -z "${server_check[$server]}" ]; then
            echo -e "${RED}错误:${NC} 服务器 $server 未被配对"
            exit 1
        fi
    done
    for client in "${CLIENTS_RAW[@]}"; do
        if [ -z "${client_check[$client]}" ]; then
            echo -e "${RED}错误:${NC} 客户端 $client 未被配对"
            exit 1
        fi
    done
fi

echo -e "${GREEN}[通过]${NC} 配对自检通过，所有 ${#SERVERS[@]} 对主机已正确配对"
echo ""

PAIR_COUNT=${#SERVERS[@]}
IFS=',' read -ra HCAS_RAW <<< "$HCA_LIST"
HCA_COUNT=${#HCAS_RAW[@]}

# 网卡配对
SERVER_HCAS=()
CLIENT_HCAS=()

case "$HCA_PAIRING_MODE" in
    forward)
        SERVER_HCAS=("${HCAS_RAW[@]}")
        CLIENT_HCAS=("${HCAS_RAW[@]}")
        ;;
    reverse)
        SERVER_HCAS=("${HCAS_RAW[@]}")
        for (( i=${#HCAS_RAW[@]}-1; i>=0; i-- )); do
            CLIENT_HCAS+=("${HCAS_RAW[$i]}")
        done
        ;;
    random)
        SERVER_HCAS=("${HCAS_RAW[@]}")
        hca_indices=()
        for (( i=0; i<${#HCAS_RAW[@]}; i++ )); do
            hca_indices+=($i)
        done
        for (( i=${#hca_indices[@]}-1; i>0; i-- )); do
            j=$((RANDOM % (i+1)))
            tmp=${hca_indices[$i]}
            hca_indices[$i]=${hca_indices[$j]}
            hca_indices[$j]=$tmp
        done
        for idx in "${hca_indices[@]}"; do
            CLIENT_HCAS+=("${HCAS_RAW[$idx]}")
        done
        ;;
esac

# ============================================================================
# 目录与日志
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -n "$HOSTFILE" ]; then
    HOSTFILE_BASE=$(basename "$HOSTFILE" | sed 's/\.[^.]*$//')
    SERVER_FILE_BASE="hostfile_${HOSTFILE_BASE}"
    CLIENT_FILE_BASE="${PAIRING_MODE}"
else
    SERVER_FILE_BASE=$(basename "$SERVER_FILE" | sed 's/\.[^.]*$//')
    CLIENT_FILE_BASE=$(basename "$CLIENT_FILE" | sed 's/\.[^.]*$//')
fi

if [ -n "$DURATION" ]; then
    DURATION_LABEL="${DURATION}s"
else
    DURATION_LABEL="${ITERATIONS}iters"
fi

RESULTS_BASE_DIR="${SCRIPT_DIR}/results"
if ! mkdir -p "$RESULTS_BASE_DIR" 2>/dev/null; then
    # 脚本目录不可写（普通用户常见），退回到 $HOME
    RESULTS_BASE_DIR="${HOME}/ibperf_results"
    mkdir -p "$RESULTS_BASE_DIR" || { echo -e "${RED}错误:${NC} 无法创建结果目录"; exit 1; }
    echo -e "${YELLOW}[提示]${NC} 脚本目录不可写，结果保存到 $RESULTS_BASE_DIR"
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DIR_NAME="${TIMESTAMP}_ibperf_${TEST_MODE}_${SERVER_FILE_BASE}_${CLIENT_FILE_BASE}_${PAIRING_MODE}"
if [ "$HCA_PAIRING_MODE" != "forward" ]; then
    DIR_NAME="${DIR_NAME}_hca${HCA_PAIRING_MODE}"
fi
DIR_NAME="${DIR_NAME}_${DURATION_LABEL}"

LOG_DIR="${RESULTS_BASE_DIR}/${DIR_NAME}"
mkdir -p "$LOG_DIR"

SUMMARY_FILE="$LOG_DIR/results_summary.txt"
# 远程目录带用户名，避免多人同时测试互相覆盖/权限冲突
REMOTE_LOG_DIR="/tmp/ib_test_$(id -un)_${TIMESTAMP}"

# ============================================================================
# 打印测试配置
# ============================================================================
echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
if [ "$TEST_MODE" = "latency" ]; then
    echo -e "${BOLD}║      IB 多主机对并发延时测试 (IBPerf · 普通用户版)           ║${NC}"
else
    echo -e "${BOLD}║      IB 多主机对并发带宽测试 (IBPerf · 普通用户版)           ║${NC}"
fi
echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}[配置]${NC} 测试参数:"
echo "  运行用户: $(id -un) (uid=$(id -u))"
echo "  SSH 用户: $SSH_USER"
echo "  测试模式: $TEST_MODE (使用 $TEST_CMD)"
if [ -n "$HOSTFILE" ]; then
    echo "  主机文件: $HOSTFILE (${#HOSTS_ALL[@]} 台，单文件模式)"
    echo "  配对后数量: ${#SERVERS[@]} 对"
else
    echo "  服务器列表: $SERVER_FILE (${#SERVERS[@]} 台)"
    echo "  客户端列表: $CLIENT_FILE (${#CLIENTS[@]} 台)"
fi
echo "  主机对数量: $PAIR_COUNT"

if [ -n "$HOSTFILE" ]; then
    case "$PAIRING_MODE" in
        consecutive) echo "  主机配对模式: 顺序两两配对 (1->2, 3->4, 5->6...)" ;;
        split_half)  echo "  主机配对模式: 前后分半配对 (前半->后半)" ;;
        odd_even)    echo "  主机配对模式: 奇偶配对 (1,3,5...->2,4,6...)" ;;
        random)      echo "  主机配对模式: 随机分组配对" ;;
    esac
else
    case "$PAIRING_MODE" in
        forward) echo "  主机配对模式: 正序配对 (server[1]↔client[1], server[2]↔client[2]...)" ;;
        reverse) echo "  主机配对模式: 倒序配对 (server[1]↔client[n], server[2]↔client[n-1]...)" ;;
        random)  echo "  主机配对模式: 随机配对 (客户端随机打乱)" ;;
    esac
fi

case "$HCA_PAIRING_MODE" in
    forward) echo "  网卡配对模式: 正序配对 (server_hca[1]↔client_hca[1]...)" ;;
    reverse) echo "  网卡配对模式: 倒序配对 (server_hca[1]↔client_hca[n]...)" ;;
    random)  echo "  网卡配对模式: 随机配对 (客户端网卡随机打乱)" ;;
esac

echo "  每对测试网卡: ${HCA_COUNT} 张 ($HCA_LIST)"
echo "  总测试数: $((PAIR_COUNT * HCA_COUNT))"
if [ -n "$ITERATIONS" ]; then
    echo "  测试模式: 迭代次数 ($ITERATIONS 次)"
else
    echo "  测试模式: 持续时间 ($DURATION 秒 = $(awk "BEGIN {printf \"%.1f\", $DURATION/60}") 分钟)"
fi
echo "  消息大小: $SIZE 字节"
echo "  NUMA 绑定: $([ "$ENABLE_NUMA_BINDING" = true ] && echo "启用 (sysfs 检测)" || echo "禁用")"
echo "  CPU 性能模式: 未设置 (需 root，已用 -F 忽略主频告警)"
echo "  最大并发批次: $MAX_CONCURRENT_BATCH"
echo "  输出目录: $LOG_DIR"
echo ""

echo -e "${BOLD}[主机配对详情]${NC} 主机配对清单:"
for (( i=0; i<PAIR_COUNT; i++ )); do
    printf "  主机对 %3d: %-15s ↔ %-15s\n" "$((i+1))" "${SERVERS[$i]}" "${CLIENTS[$i]}"
done
echo ""

echo -e "${BOLD}[网卡配对详情]${NC} 网卡配对清单 (应用于每对主机):"
for (( i=0; i<HCA_COUNT; i++ )); do
    printf "  网卡对 %2d: %-10s ↔ %-10s\n" "$((i+1))" "${SERVER_HCAS[$i]}" "${CLIENT_HCAS[$i]}"
done
echo ""

# ============================================================================
# SSH 封装（本机直接执行，不走 SSH）
# ============================================================================
LOCAL_HOSTNAME=$(hostname)
LOCAL_IPS=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^$' || ifconfig 2>/dev/null | grep 'inet ' | awk '{print $2}' | grep -v '127.0.0.1')

is_local_host() {
    local target="$1"
    [ "$target" = "localhost" ] && return 0
    [ "$target" = "127.0.0.1" ] && return 0
    [ "$target" = "$LOCAL_HOSTNAME" ] && return 0
    echo "$LOCAL_IPS" | grep -qx "$target" && return 0
    return 1
}

ssh_cmd() {
    local target="$1"
    local cmd="$2"
    if is_local_host "$target"; then
        bash -c "${REMOTE_PATH_PREFIX}${cmd}" 2>/dev/null
    else
        ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
            "$SSH_USER@$target" "${REMOTE_PATH_PREFIX}${cmd}" 2>/dev/null
    fi
}

# 获取所有唯一主机
unique_hosts=()
declare -A host_seen
for h in "${SERVERS[@]}" "${CLIENTS[@]}"; do
    if [ -z "${host_seen[$h]}" ]; then
        unique_hosts+=("$h")
        host_seen[$h]=1
    fi
done

# ============================================================================
# 环境预检：SSH 连通性 + 测试工具 + memlock + uverbs 权限
# ============================================================================
echo -e "${BOLD}[预检]${NC} 并行检查各主机运行环境..."

CHECK_TMP_DIR=$(mktemp -d "/tmp/ibperf_check_XXXXXX")
check_count=0

for host in "${unique_hosts[@]}"; do
    (
        out=$(ssh_cmd "$host" "command -v ${TEST_CMD} >/dev/null 2>&1 && echo CMD_OK || echo CMD_FAIL; echo MEMLOCK=\$(ulimit -l); ls /dev/infiniband/uverbs* >/dev/null 2>&1 && echo UVERBS_OK || echo UVERBS_FAIL; [ -r /dev/infiniband/uverbs0 ] && [ -w /dev/infiniband/uverbs0 ] && echo UVERBS_RW || echo UVERBS_NORW")
        echo "$out" > "$CHECK_TMP_DIR/${host}.chk"
    ) &

    check_count=$((check_count + 1))
    if [ $((check_count % 64)) -eq 0 ]; then
        wait
        echo -e "  ${CYAN}已检查 ${check_count}/${#unique_hosts[@]} 个主机...${NC}"
    fi
done
wait

precheck_failed=false
memlock_warn=()
echo ""
echo -e "${BOLD}[结果]${NC} 主机环境状态:"
printf "  %-18s %-10s %-14s %-10s\n" "主机" "测试工具" "memlock" "uverbs权限"
for host in "${unique_hosts[@]}"; do
    chk=$(cat "$CHECK_TMP_DIR/${host}.chk" 2>/dev/null)

    if [ -z "$chk" ]; then
        printf "  %-18s ${RED}%-10s${NC} %-14s %-10s\n" "$host" "SSH失败" "-" "-"
        precheck_failed=true
        continue
    fi

    if echo "$chk" | grep -q "CMD_OK"; then
        cmd_txt="${GREEN}✓${NC}"
    else
        cmd_txt="${RED}✗ 缺失${NC}"
        precheck_failed=true
    fi

    memlock=$(echo "$chk" | grep '^MEMLOCK=' | cut -d= -f2)
    if [ "$memlock" = "unlimited" ]; then
        memlock_txt="${GREEN}unlimited${NC}"
    elif [[ "$memlock" =~ ^[0-9]+$ ]] && [ "$memlock" -ge 1048576 ]; then
        memlock_txt="${GREEN}${memlock}KB${NC}"
    else
        memlock_txt="${YELLOW}${memlock:-未知}${NC}"
        memlock_warn+=("$host")
    fi

    if echo "$chk" | grep -q "UVERBS_RW"; then
        uverbs_txt="${GREEN}✓${NC}"
    elif echo "$chk" | grep -q "UVERBS_OK"; then
        uverbs_txt="${RED}✗ 无读写权限${NC}"
        precheck_failed=true
    else
        uverbs_txt="${RED}✗ 设备不存在${NC}"
        precheck_failed=true
    fi

    printf "  %-18s " "$host"
    echo -e "$cmd_txt\t$memlock_txt\t$uverbs_txt"
done
rm -rf "$CHECK_TMP_DIR"
echo ""

if [ ${#memlock_warn[@]} -gt 0 ]; then
    echo -e "${YELLOW}[警告]${NC} 以下 ${#memlock_warn[@]} 台主机 memlock 限制偏低，可能导致注册内存失败:"
    echo -e "  ${memlock_warn[*]}"
    echo -e "  ${YELLOW}修复方式（需管理员）: /etc/security/limits.conf 增加${NC}"
    echo "    * soft memlock unlimited"
    echo "    * hard memlock unlimited"
    echo ""
fi

if [ "$precheck_failed" = true ] && [ "$SKIP_PRECHECK" != true ]; then
    echo -e "${RED}[失败]${NC} 环境预检未通过，测试终止"
    echo -e "  如确认可忽略，可使用 ${BOLD}--skip_precheck${NC} 强制继续"
    rmdir "$LOG_DIR" 2>/dev/null
    exit 1
fi

echo -e "${GREEN}[成功]${NC} 环境预检通过"
echo ""

# ============================================================================
# NUMA 检测（可选，通过 sysfs，无需 root / mst）
# ============================================================================
declare -A NUMA_MAP
NUMA_AVAILABLE=false

if [ "$ENABLE_NUMA_BINDING" = true ]; then
    echo -e "${BOLD}[NUMA检测]${NC} 通过 sysfs 读取网卡 NUMA 节点..."

    NUMA_TMP_DIR=$(mktemp -d "/tmp/ibperf_numa_XXXXXX")
    numa_check_count=0
    HCA_SPACE_LIST="${HCA_LIST//,/ }"

    for host in "${unique_hosts[@]}"; do
        (
            ssh_cmd "$host" "command -v numactl >/dev/null 2>&1 && echo 'NUMACTL_OK'; for d in ${HCA_SPACE_LIST}; do n=\$(cat /sys/class/infiniband/\$d/device/numa_node 2>/dev/null); [ -n \"\$n\" ] && echo \"\$d \$n\"; done" > "$NUMA_TMP_DIR/${host}.numa"
        ) &
        numa_check_count=$((numa_check_count + 1))
        if [ $((numa_check_count % 64)) -eq 0 ]; then
            wait
        fi
    done
    wait

    for host in "${unique_hosts[@]}"; do
        [ -f "$NUMA_TMP_DIR/${host}.numa" ] || continue
        host_has_numactl=false
        while IFS= read -r line; do
            if [ "$line" = "NUMACTL_OK" ]; then
                host_has_numactl=true
                continue
            fi
            dev=$(echo "$line" | awk '{print $1}')
            node=$(echo "$line" | awk '{print $2}')
            # numa_node 为 -1 表示无有效映射，跳过
            if [ -n "$dev" ] && [ -n "$node" ] && [ "$node" != "-1" ] && [ "$host_has_numactl" = true ]; then
                NUMA_MAP["${host}_${dev}"]="$node"
                NUMA_AVAILABLE=true
            fi
        done < "$NUMA_TMP_DIR/${host}.numa"
    done
    rm -rf "$NUMA_TMP_DIR"

    if [ "$NUMA_AVAILABLE" = true ]; then
        echo -e "${GREEN}[完成]${NC} 已检测到 ${#NUMA_MAP[@]} 个网卡的 NUMA 映射"
    else
        echo -e "${YELLOW}[跳过]${NC} 未获取到有效 NUMA 映射或缺少 numactl，本次不做绑定"
    fi
    echo ""
fi

# ============================================================================
# 创建远程日志目录
# ============================================================================
echo -e "${BOLD}[准备]${NC} 创建远程日志目录..."
prep_count=0
for host in "${unique_hosts[@]}"; do
    ssh_cmd "$host" "mkdir -p $REMOTE_LOG_DIR" &
    prep_count=$((prep_count + 1))
    if [ $((prep_count % 64)) -eq 0 ]; then
        wait
    fi
done
wait
echo -e "${GREEN}[完成]${NC} 远程目录创建完成"
echo ""

# ============================================================================
# 构建测试参数
# ============================================================================
BASE_PARAMS="-i ${IB_PORT} -s ${SIZE} -F"
[ "$PERFORM_WARMUP" = true ] && BASE_PARAMS="$BASE_PARAMS --perform_warm_up"

if [ "$TEST_MODE" = "latency" ]; then
    [ "$REPORT_HISTOGRAM" = true ] && BASE_PARAMS="$BASE_PARAMS -H"
    [ "$REPORT_UNSORTED" = true ] && BASE_PARAMS="$BASE_PARAMS -U"
fi

if [ "$TEST_MODE" = "bandwidth" ]; then
    [ "$BIDIRECTIONAL" = true ] && BASE_PARAMS="$BASE_PARAMS -b"
    [ "$ALL_SIZES" = true ] && BASE_PARAMS="$BASE_PARAMS -a"
    [ "$REPORT_GBITS" = true ] && BASE_PARAMS="$BASE_PARAMS --report_gbits"
    [ "$NO_PEAK" = true ] && BASE_PARAMS="$BASE_PARAMS -N"
    [ "$REVERSED" = true ] && BASE_PARAMS="$BASE_PARAMS --reversed"
    [ -n "$MTU" ] && BASE_PARAMS="$BASE_PARAMS -m ${MTU}"
    BASE_PARAMS="$BASE_PARAMS -t ${TX_DEPTH} -q ${QP_NUM}"
fi

SERVER_TEST_PARAMS="$BASE_PARAMS"
if [ -z "$ITERATIONS" ]; then
    SERVER_TEST_PARAMS="$SERVER_TEST_PARAMS --run_infinitely"
fi

CLIENT_TEST_PARAMS="$BASE_PARAMS"
if [ -n "$ITERATIONS" ]; then
    CLIENT_TEST_PARAMS="$CLIENT_TEST_PARAMS -n ${ITERATIONS}"
else
    CLIENT_TEST_PARAMS="$CLIENT_TEST_PARAMS --run_infinitely"
fi

# 组装启动命令（可选 NUMA 前缀）
build_cmd() {
    local host="$1" hca="$2" params="$3" port="$4" peer="$5"
    local prefix=""
    if [ "$ENABLE_NUMA_BINDING" = true ]; then
        local node="${NUMA_MAP["${host}_${hca}"]}"
        if [ -n "$node" ]; then
            prefix="numactl --cpunodebind=${node} --membind=${node} "
        fi
    fi
    echo "${prefix}${TEST_CMD} -d ${hca} ${params} -p ${port} ${peer}"
}

# ============================================================================
# 启动服务端
# ============================================================================
echo -e "${BOLD}[启动]${NC} 分批启动所有服务器端..."
server_count=0

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"

    for hca_idx in "${!SERVER_HCAS[@]}"; do
        server_hca="${SERVER_HCAS[$hca_idx]}"
        tcp_port=$((BASE_TCP_PORT + pair_idx * 100 + hca_idx))
        log_file="${REMOTE_LOG_DIR}/server_pair${pair_idx}_${server_hca}.log"

        start_cmd=$(build_cmd "$server" "$server_hca" "$SERVER_TEST_PARAMS" "$tcp_port" "")

        ssh_cmd "$server" "nohup ${start_cmd} > ${log_file} 2>&1 < /dev/null &" &

        server_count=$((server_count + 1))
        if [ $((server_count % MAX_CONCURRENT_BATCH)) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已启动 ${server_count}/$((PAIR_COUNT * HCA_COUNT)) 个服务端进程...${NC}"
            sleep 1
        fi
    done
done
wait
echo -e "${GREEN}[完成]${NC} 所有服务器端已启动 (共 $((PAIR_COUNT * HCA_COUNT)) 个进程)"
echo -e "${YELLOW}[等待]${NC} 等待服务器端初始化 (5秒)..."
sleep 5
echo ""

# ============================================================================
# 启动客户端
# ============================================================================
echo -e "${BOLD}[启动]${NC} 分批启动所有客户端..."
client_count=0

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"
    client="${CLIENTS[$pair_idx]}"

    for hca_idx in "${!CLIENT_HCAS[@]}"; do
        client_hca="${CLIENT_HCAS[$hca_idx]}"
        tcp_port=$((BASE_TCP_PORT + pair_idx * 100 + hca_idx))
        log_file="${REMOTE_LOG_DIR}/client_pair${pair_idx}_${client_hca}.log"

        start_cmd=$(build_cmd "$client" "$client_hca" "$CLIENT_TEST_PARAMS" "$tcp_port" "$server")

        ssh_cmd "$client" "nohup ${start_cmd} > ${log_file} 2>&1 < /dev/null &" &

        client_count=$((client_count + 1))
        if [ $((client_count % MAX_CONCURRENT_BATCH)) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已启动 ${client_count}/$((PAIR_COUNT * HCA_COUNT)) 个客户端进程...${NC}"
            sleep 1
        fi
    done
done
wait
echo -e "${GREEN}[完成]${NC} 所有客户端已启动 (共 $((PAIR_COUNT * HCA_COUNT)) 个进程)"
echo ""

echo -e "${BOLD}${GREEN}[运行中]${NC}${BOLD} 所有测试正在并发执行！${NC}"
echo -e "  主机对数: $PAIR_COUNT"
echo -e "  每对网卡数: $HCA_COUNT"
echo -e "  并发测试总数: $((PAIR_COUNT * HCA_COUNT))"
if [ -n "$ITERATIONS" ]; then
    echo -e "  测试迭代: $ITERATIONS 次"
else
    echo -e "  测试时长: $DURATION 秒 ($(awk "BEGIN {printf \"%.1f\", $DURATION/60}") 分钟)"
    echo -e "  预计完成: $(date -d "+${DURATION} seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v+${DURATION}S "+%Y-%m-%d %H:%M:%S" 2>/dev/null)"
fi
echo ""
echo -e "${YELLOW}[提示]${NC} 测试进行中，请勿中断..."
echo ""

# ============================================================================
# 等待测试完成
# ============================================================================
if [ -n "$DURATION" ]; then
    start_time=$(date +%s)
    bar_width=50

    while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))
        [ $elapsed -ge "$DURATION" ] && elapsed=$DURATION

        pct=$((elapsed * 100 / DURATION))
        filled=$((elapsed * bar_width / DURATION))
        empty=$((bar_width - filled))

        bar="["
        for ((j=0; j<filled; j++)); do bar+="█"; done
        for ((j=0; j<empty; j++)); do bar+="░"; done
        bar+="]"

        remaining=$((DURATION - elapsed))
        printf "\r  ${CYAN}进度:${NC} %s ${GREEN}%3d%%${NC} | 已用: %02d:%02d | 剩余: %02d:%02d " \
            "$bar" "$pct" "$((elapsed / 60))" "$((elapsed % 60))" "$((remaining / 60))" "$((remaining % 60))"

        if [ $elapsed -ge "$DURATION" ]; then
            echo ""
            break
        fi
        sleep 1
    done
else
    # 迭代模式：轮询客户端进程，直到全部退出（或超时）
    echo -e "${YELLOW}[等待]${NC} 等待迭代测试完成（轮询客户端进程状态）..."
    ITER_TIMEOUT=${ITER_TIMEOUT:-3600}
    spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    elapsed=0
    spin_idx=0

    while [ $elapsed -lt $ITER_TIMEOUT ]; do
        running=0
        for host in "${unique_hosts[@]}"; do
            cnt=$(ssh_cmd "$host" "pgrep -u \$(id -u) -x ${TEST_CMD} 2>/dev/null | wc -l")
            running=$((running + ${cnt:-0}))
        done

        if [ "$running" -eq 0 ]; then
            echo ""
            echo -e "${GREEN}[完成]${NC} 所有测试进程已退出"
            break
        fi

        printf "\r  ${YELLOW}${spinner[$spin_idx]}${NC} 测试进行中... (剩余 %d 个进程, 已等待 %d 秒)  " "$running" "$elapsed"
        spin_idx=$(( (spin_idx + 1) % ${#spinner[@]} ))
        sleep 10
        elapsed=$((elapsed + 10))
    done

    if [ $elapsed -ge $ITER_TIMEOUT ]; then
        echo ""
        echo -e "${YELLOW}[超时]${NC} 达到 ${ITER_TIMEOUT} 秒超时，强制停止"
    fi
fi

# ============================================================================
# 停止所有远程测试进程（只杀自己的进程）
# ============================================================================
echo -e "${BOLD}[停止]${NC} 停止所有远程测试进程..."
stop_count=0
for host in "${unique_hosts[@]}"; do
    # -u 限定当前用户，-x 精确匹配进程名，避免误杀 SSH 包装进程
    ssh_cmd "$host" "pkill -u \$(id -u) -x ${TEST_CMD} 2>/dev/null; true" &
    stop_count=$((stop_count + 1))
    if [ $((stop_count % 64)) -eq 0 ]; then
        wait
    fi
done
wait
echo -e "${GREEN}[完成]${NC} 所有测试进程已停止"

echo -e "${YELLOW}[等待]${NC} 等待日志写入完成 (5秒)..."
sleep 5
echo ""

# ============================================================================
# 收集日志
# ============================================================================
echo -e "${BOLD}[收集]${NC} 收集测试日志..."
collected=0
total=$((PAIR_COUNT * HCA_COUNT * 2))

SCP_TMP_DIR=$(mktemp -d "/tmp/ibperf_scp_XXXXXX")

copy_log() {
    # copy_log <host> <远程文件> <本地文件>
    local host="$1" remote="$2" local_file="$3"
    if is_local_host "$host"; then
        cp "$remote" "$local_file" 2>/dev/null
    else
        scp -o StrictHostKeyChecking=no -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10 \
            "$SSH_USER@$host:$remote" "$local_file" &>/dev/null
    fi
}

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"
    client="${CLIENTS[$pair_idx]}"

    for hca_idx in "${!SERVER_HCAS[@]}"; do
        server_hca="${SERVER_HCAS[$hca_idx]}"
        client_hca="${CLIENT_HCAS[$hca_idx]}"

        (
            copy_log "$server" "${REMOTE_LOG_DIR}/server_pair${pair_idx}_${server_hca}.log" \
                     "$LOG_DIR/${server}_${server_hca}_server.log"
            echo $? > "$SCP_TMP_DIR/server_${pair_idx}_${hca_idx}.status"
        ) &

        (
            copy_log "$client" "${REMOTE_LOG_DIR}/client_pair${pair_idx}_${client_hca}.log" \
                     "$LOG_DIR/${client}_${client_hca}_client.log"
            echo $? > "$SCP_TMP_DIR/client_${pair_idx}_${hca_idx}.status"
        ) &

        collected=$((collected + 2))
        if [ $((collected % (MAX_CONCURRENT_BATCH * 2))) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已收集 ${collected}/${total} 个日志文件...${NC}"
        fi
    done
done
wait

failed_count=0
for status_file in "$SCP_TMP_DIR"/*.status; do
    if [ -f "$status_file" ]; then
        status=$(cat "$status_file")
        [ "$status" != "0" ] && failed_count=$((failed_count + 1))
    fi
done
rm -rf "$SCP_TMP_DIR"

if [ $failed_count -gt 0 ]; then
    echo -e "${YELLOW}[警告]${NC} 日志收集完成，但有 ${failed_count} 个文件收集失败"
    echo -e "  ${YELLOW}提示: 可能是远程进程启动失败或网络问题${NC}"
else
    echo -e "${GREEN}[完成]${NC} 日志收集完成 (共 ${total} 个文件)"
fi
echo ""

# ============================================================================
# 清理远程日志
# ============================================================================
echo -e "${BOLD}[清理]${NC} 清理远程临时文件..."
clean_count=0
for host in "${unique_hosts[@]}"; do
    ssh_cmd "$host" "rm -rf $REMOTE_LOG_DIR" &
    clean_count=$((clean_count + 1))
    if [ $((clean_count % 64)) -eq 0 ]; then
        wait
    fi
done
wait
echo -e "${GREEN}[完成]${NC} 清理完成"
echo ""

# ============================================================================
# 生成测试报告
# ============================================================================
echo -e "${BOLD}[分析]${NC} 生成测试报告..."

{
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    if [ "$TEST_MODE" = "latency" ]; then
        echo "║           IB 多主机对并发延时测试结果摘要（普通用户版）              ║"
    else
        echo "║           IB 多主机对并发带宽测试结果摘要（普通用户版）              ║"
    fi
    echo "║                  $(date +"%Y-%m-%d %H:%M:%S")                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "测试配置:"
    echo "  运行用户: $(id -un)"
    echo "  测试类型: $TEST_MODE ($TEST_CMD)"
    echo "  主机对数量: $PAIR_COUNT"
    echo "  每对测试网卡数: $HCA_COUNT"
    echo "  网卡列表: $HCA_LIST"
    if [ -n "$ITERATIONS" ]; then
        echo "  测试模式: 迭代次数 ($ITERATIONS 次)"
    else
        echo "  测试模式: 持续时间 ($DURATION 秒 = $(awk "BEGIN {printf \"%.1f\", $DURATION/60}") 分钟)"
    fi
    echo "  消息大小: $SIZE 字节"
    echo "  预热测试: $([ "$PERFORM_WARMUP" = true ] && echo "启用" || echo "禁用")"
    echo "  NUMA 绑定: $([ "$ENABLE_NUMA_BINDING" = true ] && [ "$NUMA_AVAILABLE" = true ] && echo "启用" || echo "禁用")"
    echo "  CPU 性能模式: 未设置（普通用户无权限，结果可能略保守）"
    echo ""

    if [ "$TEST_MODE" = "latency" ]; then
        echo "说明: TPS = Transactions Per Second (每秒事务数/吞吐量)"
    else
        echo "说明: BW = Bandwidth (带宽), MsgRate = Message Rate (消息速率)"
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "测试结果详情"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$TEST_MODE" = "latency" ]; then
        echo "┌──────────────────────────────────────────────────────────────────────────────────────┐"
        echo "│ 服务端IP        客户端IP        HCA配对             迭代/轮次     平均延时(us)   TPS   │"
        echo "├──────────────────────────────────────────────────────────────────────────────────────┤"
    else
        echo "┌────────────────────────────────────────────────────────────────────────────────────────────┐"
        echo "│ 服务端IP        客户端IP        HCA配对             迭代/轮次     平均带宽(Gb/s)  消息速率  │"
        echo "├────────────────────────────────────────────────────────────────────────────────────────────┤"
    fi

    global_valid_count=0
    global_total_value=0
    global_min_value=999999
    global_max_value=0
    missing_logs=()

    for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
        server="${SERVERS[$pair_idx]}"
        client="${CLIENTS[$pair_idx]}"

        for hca_idx in "${!CLIENT_HCAS[@]}"; do
            server_hca="${SERVER_HCAS[$hca_idx]}"
            client_hca="${CLIENT_HCAS[$hca_idx]}"
            hca_pair="${server_hca}↔${client_hca}"
            client_log="$LOG_DIR/${client}_${client_hca}_client.log"

            if [ -f "$client_log" ] && [ -s "$client_log" ]; then
                if [ "$TEST_MODE" = "latency" ]; then
                    result_lines=$(grep -A1 "#bytes.*#iterations.*t_avg" "$client_log" | grep -v "^#" | grep -v "^--$" | grep -E "^\s*[0-9]")
                    line_count=$(echo "$result_lines" | grep -c . 2>/dev/null || echo 0)

                    if [ -n "$result_lines" ] && [ "$line_count" -gt 0 ]; then
                        read total_iterations avg_lat avg_tps <<< $(echo "$result_lines" | awk '{
                            sum_iter += $2; sum_lat += $3; sum_tps += $4; n++
                        } END {
                            printf "%d %.2f %.0f", sum_iter, sum_lat/n, sum_tps/n
                        }')
                        tps_int=$(printf "%.0f" "$avg_tps")

                        printf "│ %-15s %-15s %-19s %-7s/%-5s %-15s %-6s │\n" \
                            "$server" "$client" "$hca_pair" "$total_iterations" "${line_count}轮" "$avg_lat" "$tps_int"

                        global_valid_count=$((global_valid_count + 1))
                        global_total_value=$(awk "BEGIN {printf \"%.2f\", $global_total_value + $avg_tps}")

                        if awk "BEGIN {exit !($avg_lat < $global_min_value)}"; then
                            global_min_value=$avg_lat
                        fi
                        if awk "BEGIN {exit !($avg_lat > $global_max_value)}"; then
                            global_max_value=$avg_lat
                        fi
                    else
                        if grep -qE "Failed to modify QP|Unable to Connect|Unable to find|not found|Couldn't|state is Down|Permission denied|Cannot allocate memory" "$client_log"; then
                            reason=$(grep -oE "Permission denied|Cannot allocate memory" "$client_log" | head -1)
                            [ -n "$reason" ] && reason="权限/内存失败: $reason" || reason="连接/设备失败"
                            printf "│ %-15s %-15s %-19s %-40s │\n" "$server" "$client" "$hca_pair" "$reason"
                        else
                            printf "│ %-15s %-15s %-19s %-40s │\n" "$server" "$client" "$hca_pair" "解析失败"
                        fi
                    fi
                else
                    result_lines=$(grep -E "^\s*[0-9]+\s+[0-9]+\s+" "$client_log")
                    line_count=$(echo "$result_lines" | grep -c . 2>/dev/null || echo 0)

                    if [ -n "$result_lines" ] && [ "$line_count" -gt 0 ]; then
                        read total_iterations bw_avg msg_rate_avg <<< $(echo "$result_lines" | awk '{
                            sum_iter += $2; sum_bw += $4; sum_mr += $5; n++
                        } END {
                            printf "%d %.2f %.3f", sum_iter, sum_bw/n, sum_mr/n
                        }')
                        bw_formatted=$(printf "%.2f" "$bw_avg")
                        msg_rate_formatted=$(printf "%.3f" "$msg_rate_avg")

                        printf "│ %-15s %-15s %-19s %-7s/%-5s %-15s %-9s │\n" \
                            "$server" "$client" "$hca_pair" "$total_iterations" "${line_count}轮" "$bw_formatted" "$msg_rate_formatted"

                        global_valid_count=$((global_valid_count + 1))
                        global_total_value=$(awk "BEGIN {printf \"%.2f\", $global_total_value + $bw_avg}")

                        if awk "BEGIN {exit !($bw_avg < $global_min_value)}"; then
                            global_min_value=$bw_avg
                        fi
                        if awk "BEGIN {exit !($bw_avg > $global_max_value)}"; then
                            global_max_value=$bw_avg
                        fi
                    else
                        if grep -qE "Failed to modify QP|Unable to Connect|Unable to find|not found|Couldn't|state is Down|Permission denied|Cannot allocate memory" "$client_log"; then
                            reason=$(grep -oE "Permission denied|Cannot allocate memory" "$client_log" | head -1)
                            [ -n "$reason" ] && reason="权限/内存失败: $reason" || reason="连接/设备失败"
                            printf "│ %-15s %-15s %-19s %-46s │\n" "$server" "$client" "$hca_pair" "$reason"
                        else
                            printf "│ %-15s %-15s %-19s %-46s │\n" "$server" "$client" "$hca_pair" "解析失败"
                        fi
                    fi
                fi
            else
                missing_logs+=("${server} ↔ ${client} (${hca_pair})")
                if [ "$TEST_MODE" = "latency" ]; then
                    printf "│ %-15s %-15s %-19s %-40s │\n" "$server" "$client" "$hca_pair" "日志为空或不存在"
                else
                    printf "│ %-15s %-15s %-19s %-46s │\n" "$server" "$client" "$hca_pair" "日志为空或不存在"
                fi
            fi
        done
    done

    if [ "$TEST_MODE" = "latency" ]; then
        echo "└──────────────────────────────────────────────────────────────────────────────────────┘"
    else
        echo "└────────────────────────────────────────────────────────────────────────────────────────────┘"
    fi
    echo ""

    echo "全局统计:"
    expected_total=$((PAIR_COUNT * HCA_COUNT))
    echo "  预期测试数: ${expected_total}"
    echo "  成功测试数: ${global_valid_count}"

    if [ ${global_valid_count} -lt ${expected_total} ]; then
        echo "  缺失测试数: $((expected_total - global_valid_count)) ⚠"
    fi

    if [ $global_valid_count -gt 0 ]; then
        if [ "$TEST_MODE" = "latency" ]; then
            echo "  最低延时: ${global_min_value} us"
            echo "  最高延时: ${global_max_value} us"
            echo "  总 TPS: $(printf "%.0f" $global_total_value)"
            echo "  平均 TPS: $(awk "BEGIN {printf \"%.0f\", $global_total_value / $global_valid_count}")"
        else
            echo "  最低带宽: ${global_min_value} Gb/s"
            echo "  最高带宽: ${global_max_value} Gb/s"
            echo "  总带宽: $(printf "%.2f" $global_total_value) Gb/s"
            echo "  平均带宽: $(awk "BEGIN {printf \"%.2f\", $global_total_value / $global_valid_count}") Gb/s"
        fi
    else
        echo "  ⚠ 警告: 所有测试失败"
    fi
    echo ""

    if [ ${#missing_logs[@]} -gt 0 ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠ 缺失或失败的测试链路 (共 ${#missing_logs[@]} 条):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for log_entry in "${missing_logs[@]}"; do
            echo "  - ${log_entry}"
        done
        echo ""
        echo "普通用户模式常见原因:"
        echo "  1. memlock 限制过低 → 检查 ulimit -l，建议设为 unlimited"
        echo "  2. /dev/infiniband/uverbs* 无读写权限 → 检查 udev 规则与用户组"
        echo "  3. 端口被占用（同节点多人同时测试）→ 更换 --base_port"
        echo "  4. 网卡未 Active → ibstat / ibstatus 检查端口状态"
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "详细日志位置: $LOG_DIR/"
    echo "测试完成时间: $(date +"%Y-%m-%d %H:%M:%S")"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

} | tee "$SUMMARY_FILE"

echo ""
echo -e "${BOLD}${GREEN}[完成]${NC}${BOLD} 所有测试已完成！${NC}"
echo -e "结果摘要: ${BOLD}$SUMMARY_FILE${NC}"
echo -e "详细日志: ${BOLD}$LOG_DIR/${NC}"
