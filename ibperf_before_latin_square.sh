#!/bin/bash
# IB 性能测试集成脚本 (IBPerf)
# 支持延时测试 (ib_write_lat) 和带宽测试 (ib_write_bw)
# 支持大规模集群（如 128 台服务器）的并发测试

# 默认参数
SERVER_FILE=""
CLIENT_FILE=""
HCA_LIST="mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_6,mlx5_7,mlx5_8,mlx5_9"
USER="root"
DURATION=""
ITERATIONS=""
SIZE=2
IB_PORT=1
BASE_TCP_PORT=18515
PERFORM_WARMUP=true
REPORT_HISTOGRAM=false
REPORT_UNSORTED=false
MAX_CONCURRENT_BATCH=32  # 最大并发启动批次大小
PAIRING_MODE="forward"   # 主机配对模式: forward(正序), reverse(倒序), random(随机)
HCA_PAIRING_MODE="forward"  # 网卡配对模式: forward(正序), reverse(倒序), random(随机)

# 测试模式相关参数
TEST_MODE="latency"  # 测试模式: latency(延时) 或 bandwidth(带宽)

# 带宽测试特有参数
BIDIRECTIONAL=false  # 双向带宽测试
ALL_SIZES=false      # 测试从 2 到 2^23 的所有大小
REPORT_GBITS=true    # 以 Gbit/s 报告结果（而不是 MiB/s）- 带宽测试默认启用
TX_DEPTH=128         # 发送队列深度
QP_NUM=2             # QP 数量（默认2）
MTU=""               # MTU 大小
NO_PEAK=false        # 取消峰值带宽计算
RUN_INFINITELY=false # 无限运行测试
REVERSED=false       # 反向流量（服务器发送到客户端）

# NUMA 绑定
ENABLE_NUMA_BINDING=true  # 启用 NUMA 绑定

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
    echo -e "${BOLD}用法:${NC} $0 --server_file <文件> --client_file <文件> [选项]"
    echo ""
    echo -e "${BOLD}必需参数:${NC}"
    echo "  --server_file FILE        服务器端主机列表文件"
    echo "  --client_file FILE        客户端主机列表文件"
    echo ""
    echo -e "${BOLD}测试模式:${NC}"
    echo "  --mode <latency|bandwidth> 测试模式 (默认: latency)"
    echo "                            latency  - 延时测试 (使用 ib_write_lat)"
    echo "                            bandwidth - 带宽测试 (使用 ib_write_bw)"
    echo ""
    echo -e "${BOLD}通用参数:${NC}"
    echo "  --hca_list HCA1,HCA2,...  指定要测试的HCA设备列表"
    echo "                            (默认: mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_6,mlx5_7,mlx5_8,mlx5_9)"
    echo "  --user USER               SSH用户名 (默认: root)"
    echo "  --duration SECONDS        测试持续时间（秒），与 --iterations 二选一"
    echo "  --iterations N            测试迭代次数，与 --duration 二选一 (默认: duration 600)"
    echo "  --size BYTES              消息大小（字节）(默认: latency=2, bandwidth=65536)"
    echo "  --ib_port PORT            IB 端口号 (默认: 1)"
    echo "  --base_port PORT          基础 TCP 端口 (默认: 18515)"
    echo "  --max_batch SIZE          最大并发启动批次大小 (默认: 32)"
    echo "  --pairing MODE            主机配对模式: forward(正序), reverse(倒序), random(随机)"
    echo "                            (默认: forward)"
    echo "  --hca_pairing MODE        网卡配对模式: forward(正序), reverse(倒序), random(随机)"
    echo "                            (默认: forward)"
    echo "  --perform_warm_up         启用预热测试 (默认: 启用)"
    echo "  --no_warmup               禁用预热测试"
    echo "  --no_numa                 禁用 NUMA 绑定 (默认: 启用)"
    echo ""
    echo -e "${BOLD}延时测试专用参数:${NC}"
    echo "  --histogram               启用延时直方图输出 (-H 参数)"
    echo "  --unsorted                启用未排序结果输出 (-U 参数)"
    echo ""
    echo -e "${BOLD}带宽测试专用参数:${NC}"
    echo "  --bidirectional           双向带宽测试 (默认: 单向)"
    echo "  --all_sizes               测试从 2 到 2^23 的所有大小"
    echo "  --report_gbits            以 Gbit/s 报告结果 (默认: MiB/s)"
    echo "  --tx_depth N              发送队列深度 (默认: 128)"
    echo "  --qp N                    QP 数量 (默认: 1)"
    echo "  --mtu SIZE                MTU 大小: 256-4096"
    echo "  --no_peak                 取消峰值带宽计算"
    echo "  --run_infinitely          无限运行测试"
    echo "  --reversed                反向流量（服务器发送到客户端）"
    echo ""
    echo "  --help                    显示此帮助信息"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo "  # 延时测试（默认模式）"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --duration 600"
    echo ""
    echo "  # 带宽测试"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --mode bandwidth --duration 600"
    echo ""
    echo "  # 双向带宽测试"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --mode bandwidth --bidirectional --duration 600"
    echo ""
    echo "  # 带宽测试 + 主机随机配对"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --mode bandwidth --pairing random --duration 600"
    echo ""
    echo "  # 大规模延时测试（64对主机，1小时）"
    echo "  $0 --server_file servers.txt --client_file clients.txt --duration 3600"
    echo ""
    echo "  # 使用网卡倒序配对"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --hca_pairing reverse --duration 600"
    exit 0
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --server_file) SERVER_FILE="$2"; shift 2 ;;
        --client_file) CLIENT_FILE="$2"; shift 2 ;;
        --mode) TEST_MODE="$2"; shift 2 ;;
        --hca_list) HCA_LIST="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
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
        --no_numa) ENABLE_NUMA_BINDING=false; shift ;;
        --histogram) REPORT_HISTOGRAM=true; shift ;;
        --unsorted) REPORT_UNSORTED=true; shift ;;
        # 带宽测试专用参数
        --bidirectional) BIDIRECTIONAL=true; shift ;;
        --all_sizes) ALL_SIZES=true; shift ;;
        --report_gbits) REPORT_GBITS=true; shift ;;
        --tx_depth) TX_DEPTH="$2"; shift 2 ;;
        --qp) QP_NUM="$2"; shift 2 ;;
        --mtu) MTU="$2"; shift 2 ;;
        --no_peak) NO_PEAK=true; shift ;;
        --run_infinitely) RUN_INFINITELY=true; shift ;;
        --reversed) REVERSED=true; shift ;;
        --help) show_help ;;
        *) echo -e "${RED}错误:${NC} 未知选项 $1"; show_help ;;
    esac
done

# 参数验证
if [ -z "$SERVER_FILE" ] || [ -z "$CLIENT_FILE" ]; then
    echo -e "${RED}错误:${NC} 必须指定 --server_file 和 --client_file 参数"
    show_help
fi

for file in "$SERVER_FILE" "$CLIENT_FILE"; do
    if [ ! -f "$file" ]; then
        echo -e "${RED}错误:${NC} 文件 $file 不存在"
        exit 1
    fi
done

if [ -z "$DURATION" ] && [ -z "$ITERATIONS" ]; then
    DURATION=600
fi

if [ -n "$DURATION" ] && [ -n "$ITERATIONS" ]; then
    echo -e "${RED}错误:${NC} --duration 和 --iterations 只能指定其中一个"
    exit 1
fi

# 验证主机配对模式
if [[ "$PAIRING_MODE" != "forward" && "$PAIRING_MODE" != "reverse" && "$PAIRING_MODE" != "random" ]]; then
    echo -e "${RED}错误:${NC} --pairing 参数必须是 forward, reverse 或 random"
    echo "当前值: $PAIRING_MODE"
    exit 1
fi

# 验证网卡配对模式
if [[ "$HCA_PAIRING_MODE" != "forward" && "$HCA_PAIRING_MODE" != "reverse" && "$HCA_PAIRING_MODE" != "random" ]]; then
    echo -e "${RED}错误:${NC} --hca_pairing 参数必须是 forward, reverse 或 random"
    echo "当前值: $HCA_PAIRING_MODE"
    exit 1
fi

# 验证测试模式
if [[ "$TEST_MODE" != "latency" && "$TEST_MODE" != "bandwidth" ]]; then
    echo -e "${RED}错误:${NC} --mode 参数必须是 latency 或 bandwidth"
    echo "当前值: $TEST_MODE"
    exit 1
fi

# 根据测试模式设置默认SIZE（如果用户没有指定）
if [ "$SIZE" = "2" ]; then  # 默认值
    if [ "$TEST_MODE" = "bandwidth" ]; then
        SIZE=65536  # 带宽测试默认 64KB
    fi
    # latency 模式保持默认值 2
fi

# 读取主机列表（原始顺序）
SERVERS_RAW=()
while IFS= read -r line; do
    [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && SERVERS_RAW+=("$line")
done < "$SERVER_FILE"

CLIENTS_RAW=()
while IFS= read -r line; do
    [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && CLIENTS_RAW+=("$line")
done < "$CLIENT_FILE"

# 检查主机数量
if [ ${#SERVERS_RAW[@]} -ne ${#CLIENTS_RAW[@]} ]; then
    echo -e "${RED}错误:${NC} 服务器和客户端主机数量不一致"
    echo "服务器数量: ${#SERVERS_RAW[@]}, 客户端数量: ${#CLIENTS_RAW[@]}"
    exit 1
fi

if [ ${#SERVERS_RAW[@]} -eq 0 ]; then
    echo -e "${RED}错误:${NC} 主机列表为空"
    exit 1
fi

# 根据配对模式生成最终的主机配对
SERVERS=()
CLIENTS=()

case "$PAIRING_MODE" in
    forward)
        # 正序配对：第1个对第1个，第2个对第2个...
        SERVERS=("${SERVERS_RAW[@]}")
        CLIENTS=("${CLIENTS_RAW[@]}")
        ;;
    reverse)
        # 倒序配对：第1个对最后1个，第2个对倒数第2个...
        SERVERS=("${SERVERS_RAW[@]}")
        for (( i=${#CLIENTS_RAW[@]}-1; i>=0; i-- )); do
            CLIENTS+=("${CLIENTS_RAW[$i]}")
        done
        ;;
    random)
        # 随机配对：客户端列表随机打乱
        SERVERS=("${SERVERS_RAW[@]}")

        # 创建索引数组
        indices=()
        for (( i=0; i<${#CLIENTS_RAW[@]}; i++ )); do
            indices+=($i)
        done

        # Fisher-Yates 洗牌算法
        for (( i=${#indices[@]}-1; i>0; i-- )); do
            j=$((RANDOM % (i+1)))
            # 交换 indices[i] 和 indices[j]
            tmp=${indices[$i]}
            indices[$i]=${indices[$j]}
            indices[$j]=$tmp
        done

        # 按照打乱的索引构建客户端列表
        for idx in "${indices[@]}"; do
            CLIENTS+=("${CLIENTS_RAW[$idx]}")
        done
        ;;
esac

# 配对自检：确保没有重复和遗漏
echo -e "${BOLD}[配对自检]${NC} 验证主机配对..."

# 检查服务器列表
declare -A server_check
for server in "${SERVERS[@]}"; do
    if [ -n "${server_check[$server]}" ]; then
        echo -e "${RED}错误:${NC} 服务器列表中发现重复: $server"
        exit 1
    fi
    server_check[$server]=1
done

# 检查客户端列表
declare -A client_check
for client in "${CLIENTS[@]}"; do
    if [ -n "${client_check[$client]}" ]; then
        echo -e "${RED}错误:${NC} 客户端列表中发现重复: $client"
        exit 1
    fi
    client_check[$client]=1
done

# 检查是否所有原始主机都被配对
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

echo -e "${GREEN}[通过]${NC} 配对自检通过，所有 ${#SERVERS[@]} 对主机已正确配对"
echo ""

PAIR_COUNT=${#SERVERS[@]}
IFS=',' read -ra HCAS_RAW <<< "$HCA_LIST"
HCA_COUNT=${#HCAS_RAW[@]}

# 根据网卡配对模式生成网卡配对列表
# 注意：每对主机使用相同的网卡配对规则
SERVER_HCAS=()
CLIENT_HCAS=()

case "$HCA_PAIRING_MODE" in
    forward)
        # 正序配对：网卡对网卡
        SERVER_HCAS=("${HCAS_RAW[@]}")
        CLIENT_HCAS=("${HCAS_RAW[@]}")
        ;;
    reverse)
        # 倒序配对：第1张对最后1张
        SERVER_HCAS=("${HCAS_RAW[@]}")
        for (( i=${#HCAS_RAW[@]}-1; i>=0; i-- )); do
            CLIENT_HCAS+=("${HCAS_RAW[$i]}")
        done
        ;;
    random)
        # 随机配对：客户端网卡列表随机打乱
        SERVER_HCAS=("${HCAS_RAW[@]}")

        # 创建索引数组
        hca_indices=()
        for (( i=0; i<${#HCAS_RAW[@]}; i++ )); do
            hca_indices+=($i)
        done

        # Fisher-Yates 洗牌算法
        for (( i=${#hca_indices[@]}-1; i>0; i-- )); do
            j=$((RANDOM % (i+1)))
            # 交换 hca_indices[i] 和 hca_indices[j]
            tmp=${hca_indices[$i]}
            hca_indices[$i]=${hca_indices[$j]}
            hca_indices[$j]=$tmp
        done

        # 按照打乱的索引构建客户端网卡列表
        for idx in "${hca_indices[@]}"; do
            CLIENT_HCAS+=("${HCAS_RAW[$idx]}")
        done
        ;;
esac

# 获取脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 提取文件名（去除路径和扩展名）
SERVER_FILE_BASE=$(basename "$SERVER_FILE" | sed 's/\.[^.]*$//')
CLIENT_FILE_BASE=$(basename "$CLIENT_FILE" | sed 's/\.[^.]*$//')

# 确定测试时长标识
if [ -n "$DURATION" ]; then
    DURATION_LABEL="${DURATION}s"
else
    DURATION_LABEL="${ITERATIONS}iters"
fi

# 创建 results 目录（如果不存在）
RESULTS_BASE_DIR="${SCRIPT_DIR}/results"
mkdir -p "$RESULTS_BASE_DIR"

# 创建测试结果目录（新命名规则：日期时间作为前缀）
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 构建目录名称
DIR_NAME="${TIMESTAMP}_ibperf_${TEST_MODE}_${SERVER_FILE_BASE}_${CLIENT_FILE_BASE}_${PAIRING_MODE}"

# 如果网卡配对模式不是默认的forward，则在目录名中体现
if [ "$HCA_PAIRING_MODE" != "forward" ]; then
    DIR_NAME="${DIR_NAME}_hca${HCA_PAIRING_MODE}"
fi

# 添加时长标识
DIR_NAME="${DIR_NAME}_${DURATION_LABEL}"

LOG_DIR="${RESULTS_BASE_DIR}/${DIR_NAME}"

mkdir -p "$LOG_DIR"

SUMMARY_FILE="$LOG_DIR/results_summary.txt"
REMOTE_LOG_DIR="/tmp/ib_test_${TIMESTAMP}"

# 打印测试配置
echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
if [ "$TEST_MODE" = "latency" ]; then
    echo -e "${BOLD}║         IB 多主机对并发延时测试 (IBPerf)                     ║${NC}"
else
    echo -e "${BOLD}║         IB 多主机对并发带宽测试 (IBPerf)                     ║${NC}"
fi
echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}[配置]${NC} 测试参数:"
echo "  测试模式: $TEST_MODE (使用 $TEST_CMD)"
echo "  服务器列表: $SERVER_FILE (${#SERVERS[@]} 台)"
echo "  客户端列表: $CLIENT_FILE (${#CLIENTS[@]} 台)"
echo "  主机对数量: $PAIR_COUNT"

# 显示主机配对模式
case "$PAIRING_MODE" in
    forward)
        echo "  主机配对模式: 正序配对 (server[1]↔client[1], server[2]↔client[2]...)"
        ;;
    reverse)
        echo "  主机配对模式: 倒序配对 (server[1]↔client[n], server[2]↔client[n-1]...)"
        ;;
    random)
        echo "  主机配对模式: 随机配对 (客户端随机打乱)"
        ;;
esac

# 显示网卡配对模式
case "$HCA_PAIRING_MODE" in
    forward)
        echo "  网卡配对模式: 正序配对 (server_hca[1]↔client_hca[1]...)"
        ;;
    reverse)
        echo "  网卡配对模式: 倒序配对 (server_hca[1]↔client_hca[n]...)"
        ;;
    random)
        echo "  网卡配对模式: 随机配对 (客户端网卡随机打乱)"
        ;;
esac

echo "  每对测试网卡: ${HCA_COUNT} 张 ($HCA_LIST)"
echo "  总测试数: $((PAIR_COUNT * HCA_COUNT))"
if [ -n "$ITERATIONS" ]; then
    echo "  测试模式: 迭代次数 ($ITERATIONS 次)"
else
    echo "  测试模式: 持续时间 ($DURATION 秒 = $(echo "scale=1; $DURATION/60" | bc) 分钟)"
fi
echo "  消息大小: $SIZE 字节"
echo "  最大并发批次: $MAX_CONCURRENT_BATCH"
echo "  输出目录: $LOG_DIR"
echo ""

# 显示主机配对详情
echo -e "${BOLD}[主机配对详情]${NC} 主机配对清单:"
for (( i=0; i<PAIR_COUNT; i++ )); do
    printf "  主机对 %3d: %-15s ↔ %-15s\n" "$((i+1))" "${SERVERS[$i]}" "${CLIENTS[$i]}"
done
echo ""

# 显示网卡配对详情
echo -e "${BOLD}[网卡配对详情]${NC} 网卡配对清单 (应用于每对主机):"
for (( i=0; i<HCA_COUNT; i++ )); do
    printf "  网卡对 %2d: %-10s ↔ %-10s\n" "$((i+1))" "${SERVER_HCAS[$i]}" "${CLIENT_HCAS[$i]}"
done
echo ""

# SSH 命令包装
ssh_cmd() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USER@$1" "$2" 2>/dev/null
}

# 测试 SSH 连接（并行检查）
echo -e "${BOLD}[检查]${NC} 并行测试 SSH 连接..."

# 创建临时目录存储检查结果
CHECK_TMP_DIR="/tmp/ibperf_check_$$"
mkdir -p "$CHECK_TMP_DIR"

# 并行检查所有主机
check_count=0
for (( i=0; i<PAIR_COUNT; i++ )); do
    server="${SERVERS[$i]}"
    client="${CLIENTS[$i]}"

    # 并行检查服务器
    (
        if ssh_cmd "$server" "command -v ib_write_lat" &>/dev/null; then
            echo "OK" > "$CHECK_TMP_DIR/server_${i}"
        else
            echo "FAIL" > "$CHECK_TMP_DIR/server_${i}"
        fi
    ) &

    # 并行检查客户端
    (
        if ssh_cmd "$client" "command -v ib_write_lat" &>/dev/null; then
            echo "OK" > "$CHECK_TMP_DIR/client_${i}"
        else
            echo "FAIL" > "$CHECK_TMP_DIR/client_${i}"
        fi
    ) &

    check_count=$((check_count + 2))

    # 分批等待，避免过多并发
    if [ $((check_count % 64)) -eq 0 ]; then
        wait
        echo -e "  ${CYAN}已检查 ${check_count}/$((PAIR_COUNT * 2)) 个主机...${NC}"
    fi
done

wait
echo -e "${GREEN}[完成]${NC} 所有主机检查完成"
echo ""

# 收集检查结果并显示
connection_failed=false
echo -e "${BOLD}[结果]${NC} SSH 连接状态:"

for (( i=0; i<PAIR_COUNT; i++ )); do
    server="${SERVERS[$i]}"
    client="${CLIENTS[$i]}"

    printf "  主机对 %3d: %-15s " "$((i+1))" "$server"

    server_status=$(cat "$CHECK_TMP_DIR/server_${i}" 2>/dev/null)
    if [ "$server_status" = "OK" ]; then
        echo -ne "${GREEN}✓${NC}"
    else
        echo -ne "${RED}✗${NC}"
        connection_failed=true
    fi

    printf " %-15s " "$client"

    client_status=$(cat "$CHECK_TMP_DIR/client_${i}" 2>/dev/null)
    if [ "$client_status" = "OK" ]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗${NC}"
        connection_failed=true
    fi
done

# 清理临时文件
rm -rf "$CHECK_TMP_DIR"

if [ "$connection_failed" = true ]; then
    echo ""
    echo -e "${RED}[失败]${NC} 部分主机 SSH 连接失败或缺少 ib_write_lat 工具"
    exit 1
fi

echo ""
echo -e "${GREEN}[成功]${NC} 所有主机连接正常"
echo ""

# 检测和启动 MST，获取网卡 NUMA 映射
if [ "$ENABLE_NUMA_BINDING" = true ]; then
    echo -e "${BOLD}[NUMA检测]${NC} 检测网卡 NUMA 节点映射..."

    # 声明关联数组存储每个主机的网卡到NUMA节点的映射
    declare -A NUMA_MAP

    # 获取所有唯一主机
    unique_hosts=()
    for server in "${SERVERS[@]}"; do
        if [[ ! " ${unique_hosts[@]} " =~ " ${server} " ]]; then
            unique_hosts+=("$server")
        fi
    done
    for client in "${CLIENTS[@]}"; do
        if [[ ! " ${unique_hosts[@]} " =~ " ${client} " ]]; then
            unique_hosts+=("$client")
        fi
    done

    # 创建临时目录存储NUMA检测结果
    NUMA_TMP_DIR="/tmp/ibperf_numa_$$"
    mkdir -p "$NUMA_TMP_DIR"

    # 并行检测所有主机的NUMA映射
    numa_check_count=0
    for host in "${unique_hosts[@]}"; do
        (
            # 检查并启动 MST
            mst_status=$(ssh_cmd "$host" "mst status 2>/dev/null | grep -c 'MST PCI'" 2>/dev/null)
            if [ "$mst_status" = "0" ] || [ -z "$mst_status" ]; then
                ssh_cmd "$host" "mst start &>/dev/null" 2>/dev/null
                sleep 1
            fi

            # 获取网卡到 NUMA 节点的映射
            mst_output=$(ssh_cmd "$host" "mst status -v 2>/dev/null")

            # 将结果保存到临时文件
            echo "$mst_output" > "$NUMA_TMP_DIR/${host}.numa"
        ) &

        numa_check_count=$((numa_check_count + 1))

        # 批量等待，每64个主机等待一次
        if [ $((numa_check_count % 64)) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已检查 ${numa_check_count}/${#unique_hosts[@]} 个主机...${NC}"
        fi
    done

    # 等待所有后台任务完成
    wait

    # 从临时文件读取并解析NUMA映射
    for host in "${unique_hosts[@]}"; do
        if [ -f "$NUMA_TMP_DIR/${host}.numa" ]; then
            while IFS= read -r line; do
                if echo "$line" | grep -q "mlx5_"; then
                    rdma_dev=$(echo "$line" | awk '{print $4}')
                    numa_node=$(echo "$line" | awk '{print $NF}')

                    # 存储映射关系: host_device -> numa_node
                    NUMA_MAP["${host}_${rdma_dev}"]="$numa_node"
                fi
            done < "$NUMA_TMP_DIR/${host}.numa"
        fi
    done

    # 清理临时目录
    rm -rf "$NUMA_TMP_DIR"

    echo -e "${GREEN}[完成]${NC} NUMA 节点映射检测完成"

    # 显示 NUMA 映射（调试信息）
    if [ ${#NUMA_MAP[@]} -gt 0 ]; then
        echo -e "${CYAN}[信息]${NC} 已检测到 ${#NUMA_MAP[@]} 个网卡的 NUMA 映射"
    fi
    echo ""
fi

# 设置 CPU 性能模式
echo -e "${BOLD}[配置]${NC} 设置 CPU 性能模式..."
for (( i=0; i<PAIR_COUNT; i++ )); do
    ssh_cmd "${SERVERS[$i]}" "command -v cpupower &>/dev/null && cpupower frequency-set -g performance &>/dev/null || for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$cpu 2>/dev/null; done" &
    ssh_cmd "${CLIENTS[$i]}" "command -v cpupower &>/dev/null && cpupower frequency-set -g performance &>/dev/null || for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$cpu 2>/dev/null; done" &
done
wait
echo -e "${GREEN}[完成]${NC} CPU 性能模式设置完成"
echo ""

# 创建远程日志目录
echo -e "${BOLD}[准备]${NC} 创建远程日志目录..."
for (( i=0; i<PAIR_COUNT; i++ )); do
    ssh_cmd "${SERVERS[$i]}" "mkdir -p $REMOTE_LOG_DIR" &
    ssh_cmd "${CLIENTS[$i]}" "mkdir -p $REMOTE_LOG_DIR" &
done
wait
echo -e "${GREEN}[完成]${NC} 远程目录创建完成"
echo ""

# 根据测试模式确定命令
if [ "$TEST_MODE" = "latency" ]; then
    TEST_CMD="ib_write_lat"
else
    TEST_CMD="ib_write_bw"
fi

# 构建测试参数
TEST_PARAMS="-i ${IB_PORT} -s ${SIZE} -F"

# 通用参数
if [ -n "$ITERATIONS" ]; then
    TEST_PARAMS="$TEST_PARAMS -n ${ITERATIONS}"
else
    TEST_PARAMS="$TEST_PARAMS -D ${DURATION}"
fi
[ "$PERFORM_WARMUP" = true ] && TEST_PARAMS="$TEST_PARAMS --perform_warm_up"

# 延时测试专用参数
if [ "$TEST_MODE" = "latency" ]; then
    [ "$REPORT_HISTOGRAM" = true ] && TEST_PARAMS="$TEST_PARAMS -H"
    [ "$REPORT_UNSORTED" = true ] && TEST_PARAMS="$TEST_PARAMS -U"
fi

# 带宽测试专用参数
if [ "$TEST_MODE" = "bandwidth" ]; then
    [ "$BIDIRECTIONAL" = true ] && TEST_PARAMS="$TEST_PARAMS -b"
    [ "$ALL_SIZES" = true ] && TEST_PARAMS="$TEST_PARAMS -a"
    [ "$REPORT_GBITS" = true ] && TEST_PARAMS="$TEST_PARAMS --report_gbits"
    [ "$NO_PEAK" = true ] && TEST_PARAMS="$TEST_PARAMS -N"
    [ "$RUN_INFINITELY" = true ] && TEST_PARAMS="$TEST_PARAMS --run_infinitely"
    [ "$REVERSED" = true ] && TEST_PARAMS="$TEST_PARAMS --reversed"
    [ -n "$MTU" ] && TEST_PARAMS="$TEST_PARAMS -m ${MTU}"
    TEST_PARAMS="$TEST_PARAMS -t ${TX_DEPTH} -q ${QP_NUM}"
fi

# 分批启动所有服务器端
echo -e "${BOLD}[启动]${NC} 分批启动所有服务器端..."
server_count=0

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"

    for hca_idx in "${!SERVER_HCAS[@]}"; do
        server_hca="${SERVER_HCAS[$hca_idx]}"
        tcp_port=$((BASE_TCP_PORT + pair_idx * 100 + hca_idx))
        log_file="${REMOTE_LOG_DIR}/server_pair${pair_idx}_${server_hca}.log"

        # 构建启动命令，根据是否启用 NUMA 绑定
        if [ "$ENABLE_NUMA_BINDING" = true ]; then
            numa_node="${NUMA_MAP["${server}_${server_hca}"]}"
            if [ -n "$numa_node" ]; then
                start_cmd="numactl --cpunodebind=${numa_node} --membind=${numa_node} ${TEST_CMD} -d ${server_hca} ${TEST_PARAMS} -p ${tcp_port}"
            else
                start_cmd="${TEST_CMD} -d ${server_hca} ${TEST_PARAMS} -p ${tcp_port}"
            fi
        else
            start_cmd="${TEST_CMD} -d ${server_hca} ${TEST_PARAMS} -p ${tcp_port}"
        fi

        # 启动服务器端
        ssh_cmd "$server" "nohup ${start_cmd} > ${log_file} 2>&1 &" &

        server_count=$((server_count + 1))

        # 分批控制
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

# 分批启动所有客户端
echo -e "${BOLD}[启动]${NC} 分批启动所有客户端..."
client_count=0

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"
    client="${CLIENTS[$pair_idx]}"

    for hca_idx in "${!CLIENT_HCAS[@]}"; do
        client_hca="${CLIENT_HCAS[$hca_idx]}"
        tcp_port=$((BASE_TCP_PORT + pair_idx * 100 + hca_idx))
        log_file="${REMOTE_LOG_DIR}/client_pair${pair_idx}_${client_hca}.log"

        # 构建启动命令，根据是否启用 NUMA 绑定
        if [ "$ENABLE_NUMA_BINDING" = true ]; then
            numa_node="${NUMA_MAP["${client}_${client_hca}"]}"
            if [ -n "$numa_node" ]; then
                start_cmd="numactl --cpunodebind=${numa_node} --membind=${numa_node} ${TEST_CMD} -d ${client_hca} ${TEST_PARAMS} -p ${tcp_port} ${server}"
            else
                start_cmd="${TEST_CMD} -d ${client_hca} ${TEST_PARAMS} -p ${tcp_port} ${server}"
            fi
        else
            start_cmd="${TEST_CMD} -d ${client_hca} ${TEST_PARAMS} -p ${tcp_port} ${server}"
        fi

        # 启动客户端
        ssh_cmd "$client" "nohup ${start_cmd} > ${log_file} 2>&1 &" &

        client_count=$((client_count + 1))

        # 分批控制
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
    echo -e "  测试时长: $DURATION 秒 ($(echo "scale=1; $DURATION/60" | bc) 分钟)"
    echo -e "  预计完成: $(date -d "+${DURATION} seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -v+${DURATION}S "+%Y-%m-%d %H:%M:%S" 2>/dev/null)"
fi
echo ""
echo -e "${YELLOW}[提示]${NC} 测试进行中，请勿中断..."
echo ""

# 等待测试完成
if [ -n "$DURATION" ]; then
    # 流畅的进度条显示
    start_time=$(date +%s)
    end_time=$((start_time + DURATION))
    bar_width=50

    while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        # 检查是否完成
        if [ $elapsed -ge $DURATION ]; then
            elapsed=$DURATION
        fi

        # 计算百分比
        pct=$((elapsed * 100 / DURATION))

        # 计算进度条填充
        filled=$((elapsed * bar_width / DURATION))
        empty=$((bar_width - filled))

        # 绘制进度条
        bar="["
        for ((j=0; j<filled; j++)); do bar+="█"; done
        for ((j=0; j<empty; j++)); do bar+="░"; done
        bar+="]"

        # 计算剩余时间
        remaining=$((DURATION - elapsed))
        remaining_min=$((remaining / 60))
        remaining_sec=$((remaining % 60))

        # 计算已用时间
        elapsed_min=$((elapsed / 60))
        elapsed_sec=$((elapsed % 60))

        # 显示进度
        printf "\r  ${CYAN}进度:${NC} %s ${GREEN}%3d%%${NC} | 已用: %02d:%02d | 剩余: %02d:%02d " \
            "$bar" "$pct" "$elapsed_min" "$elapsed_sec" "$remaining_min" "$remaining_sec"

        # 完成后退出
        if [ $elapsed -ge $DURATION ]; then
            echo ""
            break
        fi

        # 每秒更新一次
        sleep 1
    done
else
    echo -e "${YELLOW}[等待]${NC} 等待迭代测试完成（基于迭代次数，无法预估时间）..."
    # 简单的动画等待
    spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    elapsed=0
    while [ $elapsed -lt 60 ]; do
        for i in "${spinner[@]}"; do
            printf "\r  ${YELLOW}${i}${NC} 测试进行中... (已等待 ${elapsed} 秒)"
            sleep 1
            elapsed=$((elapsed + 1))
            if [ $elapsed -ge 60 ]; then
                break
            fi
        done
    done
    echo ""
fi

# 额外等待确保所有进程完成
echo -e "${YELLOW}[等待]${NC} 等待所有进程完全结束 (10秒)..."
sleep 10
echo ""

# 收集所有日志
echo -e "${BOLD}[收集]${NC} 收集测试日志..."
collected=0
total=$((PAIR_COUNT * HCA_COUNT * 2))

# 创建临时目录存储scp结果
SCP_TMP_DIR="/tmp/ibperf_scp_$$"
mkdir -p "$SCP_TMP_DIR"

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"
    client="${CLIENTS[$pair_idx]}"

    for hca_idx in "${!SERVER_HCAS[@]}"; do
        server_hca="${SERVER_HCAS[$hca_idx]}"
        client_hca="${CLIENT_HCAS[$hca_idx]}"

        # 收集服务器端日志（带错误检查）
        (
            scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10 \
                "$USER@$server:${REMOTE_LOG_DIR}/server_pair${pair_idx}_${server_hca}.log" \
                "$LOG_DIR/${server}_${server_hca}_server.log" &>/dev/null
            echo $? > "$SCP_TMP_DIR/server_${pair_idx}_${hca_idx}.status"
        ) &

        # 收集客户端日志（带错误检查）
        (
            scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10 \
                "$USER@$client:${REMOTE_LOG_DIR}/client_pair${pair_idx}_${client_hca}.log" \
                "$LOG_DIR/${client}_${client_hca}_client.log" &>/dev/null
            echo $? > "$SCP_TMP_DIR/client_${pair_idx}_${hca_idx}.status"
        ) &

        collected=$((collected + 2))

        # 分批等待
        if [ $((collected % (MAX_CONCURRENT_BATCH * 2))) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已收集 ${collected}/${total} 个日志文件...${NC}"
        fi
    done
done

wait

# 检查收集结果
failed_count=0
for status_file in "$SCP_TMP_DIR"/*.status; do
    if [ -f "$status_file" ]; then
        status=$(cat "$status_file")
        if [ "$status" != "0" ]; then
            failed_count=$((failed_count + 1))
        fi
    fi
done

# 清理临时目录
rm -rf "$SCP_TMP_DIR"

if [ $failed_count -gt 0 ]; then
    echo -e "${YELLOW}[警告]${NC} 日志收集完成，但有 ${failed_count} 个文件收集失败"
    echo -e "  ${YELLOW}提示: 可能是远程进程启动失败或网络问题${NC}"
else
    echo -e "${GREEN}[完成]${NC} 日志收集完成 (共 ${total} 个文件)"
fi
echo ""

# 清理远程日志
echo -e "${BOLD}[清理]${NC} 清理远程临时文件..."
for (( i=0; i<PAIR_COUNT; i++ )); do
    ssh_cmd "${SERVERS[$i]}" "rm -rf $REMOTE_LOG_DIR" &
    ssh_cmd "${CLIENTS[$i]}" "rm -rf $REMOTE_LOG_DIR" &
done
wait
echo -e "${GREEN}[完成]${NC} 清理完成"
echo ""

# 生成测试报告
echo -e "${BOLD}[分析]${NC} 生成测试报告..."

{
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    if [ "$TEST_MODE" = "latency" ]; then
        echo "║           IB 多主机对并发延时测试结果摘要                            ║"
    else
        echo "║           IB 多主机对并发带宽测试结果摘要                            ║"
    fi
    echo "║                  $(date +"%Y-%m-%d %H:%M:%S")                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "测试配置:"
    echo "  测试类型: $TEST_MODE"
    echo "  主机对数量: $PAIR_COUNT"
    echo "  每对测试网卡数: $HCA_COUNT"
    echo "  网卡列表: $HCA_LIST"
    if [ -n "$ITERATIONS" ]; then
        echo "  测试模式: 迭代次数 ($ITERATIONS 次)"
    else
        echo "  测试模式: 持续时间 ($DURATION 秒 = $(echo "scale=1; $DURATION/60" | bc) 分钟)"
    fi
    echo "  消息大小: $SIZE 字节"
    echo "  预热测试: $([ "$PERFORM_WARMUP" = true ] && echo "启用" || echo "禁用")"
    echo ""

    if [ "$TEST_MODE" = "latency" ]; then
        echo "说明: TPS = Transactions Per Second (每秒事务数/吞吐量)"
    else
        echo "说明: BW = Bandwidth (带宽), MsgRate = Message Rate (消息速率)"
    fi
    echo ""

    # 统一的表格头（根据测试模式不同）
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "测试结果详情"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$TEST_MODE" = "latency" ]; then
        echo "┌──────────────────────────────────────────────────────────────────────────────────────┐"
        echo "│ 服务端IP        客户端IP        HCA配对             迭代次数      平均延时(us)   TPS   │"
        echo "├──────────────────────────────────────────────────────────────────────────────────────┤"
    else
        echo "┌────────────────────────────────────────────────────────────────────────────────────────────┐"
        echo "│ 服务端IP        客户端IP        HCA配对             迭代次数      平均带宽(Gb/s)  消息速率  │"
        echo "├────────────────────────────────────────────────────────────────────────────────────────────┤"
    fi

    # 全局统计
    global_valid_count=0
    global_total_value=0
    global_min_value=999999
    global_max_value=0
    missing_logs=()  # 记录缺失的日志

    # 遍历所有主机对，生成统一表格
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
                    # 延时测试结果解析
                    result_line=$(grep -A1 "#bytes.*#iterations.*t_avg" "$client_log" | tail -1)

                    if [ -n "$result_line" ]; then
                        iterations=$(echo "$result_line" | awk '{print $2}')
                        avg_lat=$(echo "$result_line" | awk '{print $3}')
                        tps=$(echo "$result_line" | awk '{print $4}')

                        # 格式化 TPS 为整数
                        tps_int=$(printf "%.0f" "$tps")

                        printf "│ %-15s %-15s %-19s %-13s %-15s %-6s │\n" \
                            "$server" "$client" "$hca_pair" "$iterations" "$avg_lat" "$tps_int"

                        global_valid_count=$((global_valid_count + 1))
                        global_total_value=$(echo "$global_total_value + $tps" | bc)

                        if (( $(echo "$avg_lat < $global_min_value" | bc -l) )); then
                            global_min_value=$avg_lat
                        fi
                        if (( $(echo "$avg_lat > $global_max_value" | bc -l) )); then
                            global_max_value=$avg_lat
                        fi
                    else
                        printf "│ %-15s %-15s %-19s %-40s │\n" "$server" "$client" "$hca_pair" "解析失败"
                    fi
                else
                    # 带宽测试结果解析
                    # 格式: #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
                    result_line=$(grep -E "^\s*[0-9]+\s+[0-9]+\s+" "$client_log" | tail -1)

                    if [ -n "$result_line" ]; then
                        iterations=$(echo "$result_line" | awk '{print $2}')
                        bw_avg=$(echo "$result_line" | awk '{print $4}')
                        msg_rate=$(echo "$result_line" | awk '{print $5}')

                        # 格式化带宽和消息速率
                        bw_formatted=$(printf "%.2f" "$bw_avg")
                        msg_rate_formatted=$(printf "%.3f" "$msg_rate")

                        printf "│ %-15s %-15s %-19s %-13s %-15s %-9s │\n" \
                            "$server" "$client" "$hca_pair" "$iterations" "$bw_formatted" "$msg_rate_formatted"

                        global_valid_count=$((global_valid_count + 1))
                        global_total_value=$(echo "$global_total_value + $bw_avg" | bc)

                        if (( $(echo "$bw_avg < $global_min_value" | bc -l) )); then
                            global_min_value=$bw_avg
                        fi
                        if (( $(echo "$bw_avg > $global_max_value" | bc -l) )); then
                            global_max_value=$bw_avg
                        fi
                    else
                        printf "│ %-15s %-15s %-19s %-46s │\n" "$server" "$client" "$hca_pair" "解析失败"
                    fi
                fi
            else
                # 记录缺失的日志
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

    # 全局统计信息
    echo "全局统计:"
    expected_total=$((PAIR_COUNT * HCA_COUNT))
    echo "  预期测试数: ${expected_total}"
    echo "  成功测试数: ${global_valid_count}"

    if [ ${global_valid_count} -lt ${expected_total} ]; then
        missing_count=$((expected_total - global_valid_count))
        echo "  缺失测试数: ${missing_count} ⚠"
    fi

    if [ $global_valid_count -gt 0 ]; then
        if [ "$TEST_MODE" = "latency" ]; then
            echo "  最低延时: ${global_min_value} us"
            echo "  最高延时: ${global_max_value} us"
            echo "  总 TPS: $(printf "%.0f" $global_total_value)"
            echo "  平均 TPS: $(echo "scale=0; $global_total_value / $global_valid_count" | bc)"
        else
            echo "  最低带宽: ${global_min_value} Gb/s"
            echo "  最高带宽: ${global_max_value} Gb/s"
            echo "  总带宽: $(printf "%.2f" $global_total_value) Gb/s"
            echo "  平均带宽: $(echo "scale=2; $global_total_value / $global_valid_count" | bc) Gb/s"
        fi
    else
        echo "  ⚠ 警告: 所有测试失败"
    fi
    echo ""

    # 显示缺失的日志详情
    if [ ${#missing_logs[@]} -gt 0 ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠ 缺失或失败的测试链路 (共 ${#missing_logs[@]} 条):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        for log_entry in "${missing_logs[@]}"; do
            echo "  - ${log_entry}"
        done
        echo ""
        echo "建议:"
        echo "  1. 检查上述主机的网卡是否正常"
        echo "  2. 检查远程进程日志: ${REMOTE_LOG_DIR}/"
        echo "  3. 手动执行测试验证连接性"
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
