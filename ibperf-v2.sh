#!/bin/bash
# IB 性能测试集成脚本 (IBPerf)
# 支持延时测试 (ib_write_lat) 和带宽测试 (ib_write_bw)
# 支持大规模集群（如 128 台服务器）的并发测试

# 默认参数
SERVER_FILE=""
CLIENT_FILE=""
HOSTFILE=""              # 单文件主机列表（自动配对模式）
HCA_LIST="auto"          # auto = 从第一台主机自动探测所有 ACTIVE 的 mlx5 设备
                         # 也可显式写死: mlx5_bond1,mlx5_bond2,...
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
PAIRING_MODE=""   # 主机配对模式（稍后根据模式设置默认值）
# 双文件模式 (--server_file + --client_file): forward, reverse, random
# 单文件模式 (--hostfile): consecutive, split_half, odd_even, random
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

# ==================== CUDA / GPUDirect RDMA ====================
USE_CUDA=false         # 启用 GPUDirect RDMA (perftest --use_cuda=<gpu>)
CUDA_MAP=""            # 手工指定 HCA:GPU 映射, 例: mlx5_bond1:3,mlx5_bond2:1
                       # 留空则按 PCIe 拓扑自动推导（等价 nvidia-smi topo -m 的 PXB/PIX）

# ==================== NUMA 绑定 ====================
# numactl --cpunodebind=N --membind=N
# 开 CUDA 时 N 取该网卡对应 GPU 的 NUMA，否则取网卡自己的 numa_node
ENABLE_NUMA_BINDING=true

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
    echo "                            latency  - 延时测试 (使用 ib_write_lat)"
    echo "                            bandwidth - 带宽测试 (使用 ib_write_bw)"
    echo ""
    echo -e "${BOLD}通用参数:${NC}"
    echo "  --hca_list HCA1,HCA2,...  指定要测试的HCA设备列表"
    echo "                            默认 auto: 从第一台主机自动探测"
    echo "                            所有端口 ACTIVE 的 mlx5 设备（含 bond）"
    echo "  --user USER               SSH用户名 (默认: root)"
    echo "  --duration SECONDS        测试持续时间（秒），与 --iterations 二选一"
    echo "  --iterations N            测试迭代次数，与 --duration 二选一 (默认: duration 600)"
    echo "  --size BYTES              消息大小（字节）(默认: latency=2, bandwidth=65536)"
    echo "  --ib_port PORT            IB 端口号 (默认: 1)"
    echo "  --base_port PORT          基础 TCP 端口 (默认: 18515)"
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
    echo ""
    echo -e "${BOLD}CUDA / GPUDirect RDMA 参数:${NC}"
    echo "  --use_cuda                启用 GPUDirect RDMA (--use_cuda=<gpu>)"
    echo "                            GPU 按 PCIe 拓扑自动匹配最近的网卡"
    echo "  --cuda_map MAP            手工指定映射: mlx5_bond1:3,mlx5_bond2:1,..."
    echo "                            (指定后不再自动推导，隐含 --use_cuda)"
    echo ""
    echo -e "${BOLD}NUMA 绑定:${NC}"
    echo "  --no_numa                 禁用 NUMA 绑定 (默认: 启用)"
    echo "                            默认: numactl --cpunodebind=N --membind=N"
    echo "                            开 CUDA 时 N 取 GPU 的 NUMA，否则取网卡的"
    echo ""
    echo -e "${BOLD}延时测试专用参数:${NC}"
    echo "  --histogram               启用延时直方图输出 (-H 参数)"
    echo "  --unsorted                启用未排序结果输出 (-U 参数)"
    echo ""
    echo -e "${BOLD}带宽测试专用参数:${NC}"
    echo "  --bidirectional           双向带宽测试 (默认: 单向)"
    echo "  --all_sizes               测试从 2 到 2^23 的所有大小"
    echo "  --report_gbits            以 Gbit/s 报告结果 (默认: MiB/s)"
    echo "  --tx_depth N              发送队列深度 -t (默认: 128)"
    echo "  --qp N                    QP 数量 -q (默认: 2)"
    echo "  --mtu SIZE                MTU 大小: 256-4096"
    echo "  --no_peak                 取消峰值带宽计算"
    echo "  --run_infinitely          无限运行测试"
    echo "  --reversed                反向流量（服务器发送到客户端）"
    echo ""
    echo "  --help                    显示此帮助信息"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo ""
    echo -e "  ${BOLD}【单文件模式】${NC}"
    echo "  # 顺序两两配对（1->2, 3->4, 5->6...）"
    echo "  $0 --hostfile hosts.txt --pairing consecutive --duration 600"
    echo ""
    echo "  # 前后分半配对（前半->后半）"
    echo "  $0 --hostfile hosts.txt --pairing split_half --duration 600"
    echo ""
    echo "  # 奇偶配对（1,3,5...->2,4,6...）"
    echo "  $0 --hostfile hosts.txt --pairing odd_even --duration 600"
    echo ""
    echo "  # 带宽测试"
    echo "  $0 --hostfile hosts.txt --pairing random --mode bandwidth --duration 600"
    echo ""
    echo -e "  ${BOLD}【GPUDirect RDMA】${NC}"
    echo "  # 显存直通带宽测试，GPU 自动按拓扑匹配网卡，按 GPU 的 NUMA 绑定"
    echo "  $0 --hostfile hosts.txt --mode bandwidth --use_cuda --qp 4 \\"
    echo "     --hca_list mlx5_bond1,mlx5_bond2,mlx5_bond3,mlx5_bond4,mlx5_bond5,mlx5_bond6,mlx5_bond7,mlx5_bond8 \\"
    echo "     --duration 600"
    echo ""
    echo "  # 手工指定映射（本机拓扑: bond1↔GPU3 bond2↔GPU1 bond3↔GPU2 bond4↔GPU0"
    echo "  #                        bond5↔GPU4 bond6↔GPU6 bond7↔GPU5 bond8↔GPU7）"
    echo "  $0 --hostfile hosts.txt --mode bandwidth \\"
    echo "     --cuda_map mlx5_bond1:3,mlx5_bond2:1,mlx5_bond3:2,mlx5_bond4:0,mlx5_bond5:4,mlx5_bond6:6,mlx5_bond7:5,mlx5_bond8:7"
    echo ""
    echo -e "  ${BOLD}【双文件模式】${NC}"
    echo "  # 基本用法"
    echo "  $0 --server_file SU1.txt --client_file SU2.txt --duration 600"
    exit 0
}

# ============================================================================
# 通用辅助函数
# ============================================================================

# SSH 命令封装函数
ssh_cmd() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USER@$1" "$2" 2>/dev/null
}


# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        --server_file) SERVER_FILE="$2"; shift 2 ;;
        --client_file) CLIENT_FILE="$2"; shift 2 ;;
        --hostfile) HOSTFILE="$2"; shift 2 ;;
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
        # CUDA / GPUDirect RDMA
        --use_cuda) USE_CUDA=true; shift ;;
        --cuda_map) CUDA_MAP="$2"; USE_CUDA=true; shift 2 ;;
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
# 检查是否同时指定了单文件和双文件模式
if [ -n "$HOSTFILE" ] && { [ -n "$SERVER_FILE" ] || [ -n "$CLIENT_FILE" ]; }; then
    echo -e "${RED}错误:${NC} 不能同时使用 --hostfile 和 --server_file/--client_file"
    echo "请选择其中一种模式："
    echo "  模式1 (双文件): --server_file + --client_file"
    echo "  模式2 (单文件): --hostfile"
    show_help
fi

# 检查至少指定了一种模式
if [ -z "$HOSTFILE" ] && { [ -z "$SERVER_FILE" ] || [ -z "$CLIENT_FILE" ]; }; then
    echo -e "${RED}错误:${NC} 必须指定以下模式之一："
    echo "  模式1 (双文件): --server_file + --client_file"
    echo "  模式2 (单文件): --hostfile"
    show_help
fi

# 验证文件存在
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

# 设置配对模式的默认值（如果用户未指定）
if [ -z "$PAIRING_MODE" ]; then
    if [ -n "$HOSTFILE" ]; then
        PAIRING_MODE="consecutive"  # 单文件模式默认：顺序两两配对
    else
        PAIRING_MODE="forward"      # 双文件模式默认：正序配对
    fi
fi

# 验证主机配对模式
if [ -n "$HOSTFILE" ]; then
    # 单文件模式的配对验证
    if [[ "$PAIRING_MODE" != "consecutive" && "$PAIRING_MODE" != "split_half" && "$PAIRING_MODE" != "odd_even" && "$PAIRING_MODE" != "random" ]]; then
        echo -e "${RED}错误:${NC} 单文件模式下 --pairing 参数必须是以下之一："
        echo "  consecutive - 顺序两两配对 (1->2, 3->4, ...)"
        echo "  split_half  - 前后分半配对 (1->n/2+1, 2->n/2+2, ...)"
        echo "  odd_even    - 奇偶配对 (1,3,5...->2,4,6...)"
        echo "  random      - 随机分组配对"
        echo "当前值: $PAIRING_MODE"
        exit 1
    fi
else
    # 双文件模式的配对验证
    if [[ "$PAIRING_MODE" != "forward" && "$PAIRING_MODE" != "reverse" && "$PAIRING_MODE" != "random" ]]; then
        echo -e "${RED}错误:${NC} 双文件模式下 --pairing 参数必须是以下之一："
        echo "  forward - 正序配对 (server[1]↔client[1], ...)"
        echo "  reverse - 倒序配对 (server[1]↔client[n], ...)"
        echo "  random  - 随机配对 (客户端随机打乱)"
        echo "当前值: $PAIRING_MODE"
        exit 1
    fi
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

# 根据测试模式确定命令（提前到这里：后面的 SSH 可用性检查、
# 残留进程清理、CUDA 能力检查都要用到 TEST_CMD。原脚本在配置打印
# 时就引用了 $TEST_CMD，但赋值在几百行之后，那一行永远打印为空。）
if [ "$TEST_MODE" = "latency" ]; then
    TEST_CMD="ib_write_lat"
else
    TEST_CMD="ib_write_bw"
fi

# 验证带宽测试的数值参数
if [ "$TEST_MODE" = "bandwidth" ]; then
    if ! [[ "$QP_NUM" =~ ^[0-9]+$ ]] || [ "$QP_NUM" -lt 1 ]; then
        echo -e "${RED}错误:${NC} --qp 必须是正整数，当前值: $QP_NUM"
        exit 1
    fi
    if ! [[ "$TX_DEPTH" =~ ^[0-9]+$ ]] || [ "$TX_DEPTH" -lt 1 ]; then
        echo -e "${RED}错误:${NC} --tx_depth 必须是正整数，当前值: $TX_DEPTH"
        exit 1
    fi
    if [ -n "$MTU" ] && ! [[ "$MTU" =~ ^(256|512|1024|2048|4096)$ ]]; then
        echo -e "${RED}错误:${NC} --mtu 必须是 256/512/1024/2048/4096 之一，当前值: $MTU"
        exit 1
    fi
elif [ "$QP_NUM" != "2" ] || [ "$TX_DEPTH" != "128" ] || [ -n "$MTU" ]; then
    # ib_write_lat 不接受 -q / -t，传了会直接报错退出，
    # 表现为所有链路"日志为空"，很难定位。这里提前说清楚。
    echo -e "${YELLOW}[提示]${NC} 延时模式不支持 --qp / --tx_depth / --mtu，这些参数将被忽略"
fi

# NUMA 节点取值来源：开 CUDA 时按 GPU 的 NUMA（和手写脚本一致），否则按网卡的
if [ "$USE_CUDA" = true ]; then
    NUMA_SOURCE_EFF="gpu"
else
    NUMA_SOURCE_EFF="hca"
fi

# 解析手工 CUDA 映射
declare -A CUDA_MANUAL_MAP
if [ -n "$CUDA_MAP" ]; then
    IFS=',' read -ra _cm <<< "$CUDA_MAP"
    for kv in "${_cm[@]}"; do
        k="${kv%%:*}"; v="${kv##*:}"
        if [ -z "$k" ] || ! [[ "$v" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}错误:${NC} --cuda_map 格式应为 HCA:GPU索引,... 例: mlx5_bond1:3"
            echo "无法解析: $kv"
            exit 1
        fi
        CUDA_MANUAL_MAP["$k"]="$v"
    done
fi

# 根据测试模式设置默认SIZE（如果用户没有指定）
if [ "$SIZE" = "2" ]; then  # 默认值
    if [ "$TEST_MODE" = "bandwidth" ]; then
        SIZE=65536  # 带宽测试默认 64KB
    fi
    # latency 模式保持默认值 2
fi

# ==================== 普通模式逻辑 ====================
# 根据模式读取主机列表
if [ -n "$HOSTFILE" ]; then
    # ==================== 单文件模式 ====================
    # 读取所有主机
    HOSTS_ALL=()
    while IFS= read -r line; do
        [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]] && HOSTS_ALL+=("$line")
    done < "$HOSTFILE"

    # 检查主机数量
    if [ ${#HOSTS_ALL[@]} -eq 0 ]; then
        echo -e "${RED}错误:${NC} 主机列表为空"
        exit 1
    fi

    # 根据配对模式生成服务器和客户端列表
    SERVERS=()
    CLIENTS=()

    case "$PAIRING_MODE" in
        consecutive)
            # 顺序两两配对：1->2, 3->4, 5->6...
            if [ $((${#HOSTS_ALL[@]} % 2)) -ne 0 ]; then
                echo -e "${RED}错误:${NC} consecutive 模式需要偶数个主机"
                echo "当前主机数量: ${#HOSTS_ALL[@]}"
                exit 1
            fi
            for (( i=0; i<${#HOSTS_ALL[@]}; i+=2 )); do
                SERVERS+=("${HOSTS_ALL[$i]}")
                CLIENTS+=("${HOSTS_ALL[$i+1]}")
            done
            ;;
        split_half)
            # 前后分半配对：前半->后半
            if [ $((${#HOSTS_ALL[@]} % 2)) -ne 0 ]; then
                echo -e "${RED}错误:${NC} split_half 模式需要偶数个主机"
                echo "当前主机数量: ${#HOSTS_ALL[@]}"
                exit 1
            fi
            half=$((${#HOSTS_ALL[@]} / 2))
            for (( i=0; i<$half; i++ )); do
                SERVERS+=("${HOSTS_ALL[$i]}")
                CLIENTS+=("${HOSTS_ALL[$i+$half]}")
            done
            ;;
        odd_even)
            # 奇偶配对：1,3,5...->2,4,6...
            if [ $((${#HOSTS_ALL[@]} % 2)) -ne 0 ]; then
                echo -e "${RED}错误:${NC} odd_even 模式需要偶数个主机"
                echo "当前主机数量: ${#HOSTS_ALL[@]}"
                exit 1
            fi
            # 收集奇数位置（索引0,2,4...）
            for (( i=0; i<${#HOSTS_ALL[@]}; i+=2 )); do
                SERVERS+=("${HOSTS_ALL[$i]}")
            done
            # 收集偶数位置（索引1,3,5...）
            for (( i=1; i<${#HOSTS_ALL[@]}; i+=2 )); do
                CLIENTS+=("${HOSTS_ALL[$i]}")
            done
            ;;
        random)
            # 随机分组配对
            if [ $((${#HOSTS_ALL[@]} % 2)) -ne 0 ]; then
                echo -e "${RED}错误:${NC} random 模式需要偶数个主机"
                echo "当前主机数量: ${#HOSTS_ALL[@]}"
                exit 1
            fi

            # 创建索引数组并打乱
            indices=()
            for (( i=0; i<${#HOSTS_ALL[@]}; i++ )); do
                indices+=($i)
            done

            # Fisher-Yates 洗牌算法
            for (( i=${#indices[@]}-1; i>0; i-- )); do
                j=$((RANDOM % (i+1)))
                tmp=${indices[$i]}
                indices[$i]=${indices[$j]}
                indices[$j]=$tmp
            done

            # 前半作为服务器，后半作为客户端
            half=$((${#indices[@]} / 2))
            for (( i=0; i<$half; i++ )); do
                SERVERS+=("${HOSTS_ALL[${indices[$i]}]}")
                CLIENTS+=("${HOSTS_ALL[${indices[$i+$half]}]}")
            done
            ;;
    esac
else
    # ==================== 双文件模式 ====================
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
fi

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

# 双文件模式：检查是否所有原始主机都被配对
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

# ==================== 网卡列表自动探测 ====================
# 写死一份网卡名在不同机型上必然对不上（bond / 非 bond、编号顺序都不同），
# 所以默认从第一台主机的 sysfs 现场读，只取端口 ACTIVE 的 mlx5 设备。
if [ "$HCA_LIST" = "auto" ]; then
    echo -e "${BOLD}[网卡探测]${NC} 从 ${SERVERS[0]} 自动获取网卡列表..."
    HCA_LIST=$(ssh_cmd "${SERVERS[0]}" "
        for d in /sys/class/infiniband/*; do
            [ -e \"\$d\" ] || continue
            dev=\$(basename \$d)
            case \$dev in mlx5_*) ;; *) continue ;; esac
            for pd in \$d/ports/*; do
                [ -e \"\$pd/state\" ] || continue
                case \"\$(cat \$pd/state 2>/dev/null)\" in
                    *ACTIVE*) echo \$dev; break ;;
                esac
            done
        done | sort -V | paste -sd,")

    if [ -z "$HCA_LIST" ]; then
        echo -e "${RED}错误:${NC} 在 ${SERVERS[0]} 上没有探测到任何 ACTIVE 的 mlx5 设备"
        echo "  请检查: ibstatus / ibdev2netdev，或用 --hca_list 手工指定"
        exit 1
    fi
    echo -e "${GREEN}[完成]${NC} 探测到: ${HCA_LIST}"
    echo -e "${YELLOW}[注意]${NC} 自动探测会包含管理/存储网卡（如 mlx5_bond0）。"
    echo -e "        只想测计算网时请用 --hca_list 显式指定。"
    echo ""
fi

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
if [ -n "$HOSTFILE" ]; then
    HOSTFILE_BASE=$(basename "$HOSTFILE" | sed 's/\.[^.]*$//')
    SERVER_FILE_BASE="hostfile_${HOSTFILE_BASE}"
    CLIENT_FILE_BASE="${PAIRING_MODE}"
else
    SERVER_FILE_BASE=$(basename "$SERVER_FILE" | sed 's/\.[^.]*$//')
    CLIENT_FILE_BASE=$(basename "$CLIENT_FILE" | sed 's/\.[^.]*$//')
fi

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
if [ -n "$HOSTFILE" ]; then
    echo "  主机文件: $HOSTFILE (${#HOSTS_ALL[@]} 台，单文件模式)"
    echo "  配对后数量: ${#SERVERS[@]} 对"
else
    echo "  服务器列表: $SERVER_FILE (${#SERVERS[@]} 台)"
    echo "  客户端列表: $CLIENT_FILE (${#CLIENTS[@]} 台)"
fi
echo "  主机对数量: $PAIR_COUNT"

# 显示主机配对模式
if [ -n "$HOSTFILE" ]; then
    case "$PAIRING_MODE" in
        consecutive)
            echo "  主机配对模式: 顺序两两配对 (1->2, 3->4, 5->6...)"
            ;;
        split_half)
            echo "  主机配对模式: 前后分半配对 (前半->后半)"
            ;;
        odd_even)
            echo "  主机配对模式: 奇偶配对 (1,3,5...->2,4,6...)"
            ;;
        random)
            echo "  主机配对模式: 随机分组配对"
            ;;
    esac
else
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
fi

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
    echo "  测试模式: 持续时间 ($DURATION 秒 = $(awk "BEGIN {printf \"%.1f\", $DURATION/60}") 分钟)"
fi
echo "  消息大小: $SIZE 字节"
if [ "$TEST_MODE" = "bandwidth" ]; then
    echo "  QP 数量: $QP_NUM (-q)"
    echo "  发送队列深度: $TX_DEPTH (-t)"
    [ -n "$MTU" ] && echo "  MTU: $MTU (-m)"
    echo "  双向测试: $([ "$BIDIRECTIONAL" = true ] && echo "是 (-b)" || echo "否")"
fi
echo "  最大并发批次: $MAX_CONCURRENT_BATCH"
if [ "$USE_CUDA" = true ]; then
    echo -e "  ${GREEN}GPUDirect RDMA: 启用 (--use_cuda=<gpu>)${NC}"
    echo "  GPU 映射方式: $([ -n "$CUDA_MAP" ] && echo "手工 (--cuda_map)" || echo "PCIe 拓扑自动匹配")"
else
    echo "  GPUDirect RDMA: 禁用 (主存收发)"
fi
if [ "$ENABLE_NUMA_BINDING" = true ]; then
    echo "  NUMA 绑定: numactl --cpunodebind/--membind (节点取自 ${NUMA_SOURCE_EFF})"
else
    echo "  NUMA 绑定: 禁用"
fi
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

# SSH 命令封装（本机直接执行，不走 SSH）
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
    if is_local_host "$1"; then
        bash -c "$2" 2>/dev/null
    else
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USER@$1" "$2" 2>/dev/null
    fi
}

# ==================== 远程进程清理 ====================
# 测试进程（尤其 --run_infinitely 起的）不会自己退出，留下来会吃满 CPU
# 并把后续所有测量带偏。正常结束、Ctrl-C、被 kill 都必须清干净。
CLEANUP_DONE=0

# 幂等清理：trap 和正常收尾都会调用，只真正执行一次
# 用 pkill -x（精确匹配进程名）而不是 -f：ssh 过去执行的那条命令自己的
# 命令行里就含有测试程序名，-f 会让 pkill 杀掉自己的父 shell 先行退出。
cleanup_remote_processes() {
    [ "$CLEANUP_DONE" = "1" ] && return 0
    CLEANUP_DONE=1

    [ ${#unique_hosts[@]} -eq 0 ] && return 0

    for host in "${unique_hosts[@]}"; do
        ssh_cmd "$host" "pkill -x 'ib_write_lat'; pkill -x 'ib_write_bw'" 2>/dev/null &
    done
    wait
    return 0
}

# 中断时先把远程进程收干净再退出，否则上千个进程会一直跑下去
on_interrupt() {
    echo ""
    echo -e "${YELLOW}[中断]${NC} 收到中断信号，正在清理远程测试进程..."
    cleanup_remote_processes
    echo -e "${GREEN}[完成]${NC} 远程测试进程已清理"
    exit 130
}
trap on_interrupt INT TERM
# 兜底：任何路径退出（含中途 return/异常）都再清一次，幂等所以不会重复执行
trap cleanup_remote_processes EXIT

# 单机可用性检查：测试程序是否存在、（开 CUDA 时）是否编译进了 CUDA 支持
# 返回 OK / NOCMD / NOCUDA
check_host_ready() {
    local host="$1" out
    out=$(ssh_cmd "$host" "
        command -v ${TEST_CMD} >/dev/null 2>&1 || { echo NOCMD; exit 0; }
        if [ '${USE_CUDA}' = 'true' ]; then
            ${TEST_CMD} --help 2>&1 | grep -q -- '--use_cuda' || { echo NOCUDA; exit 0; }
            command -v nvidia-smi >/dev/null 2>&1 || { echo NOCUDA; exit 0; }
        fi
        echo OK" 2>/dev/null | tr -d '[:space:]')
    echo "${out:-NOCMD}"
}

# 测试 SSH 连接（并行检查）
echo -e "${BOLD}[检查]${NC} 并行测试 SSH 连接..."
if [ "$USE_CUDA" = true ]; then
    echo -e "  ${CYAN}同时检查 ${TEST_CMD} 是否带 CUDA 支持（--use_cuda）${NC}"
fi

# 创建临时目录存储检查结果
CHECK_TMP_DIR="/tmp/ibperf_check_$$"
mkdir -p "$CHECK_TMP_DIR"

# 并行检查所有主机
check_count=0
for (( i=0; i<PAIR_COUNT; i++ )); do
    server="${SERVERS[$i]}"
    client="${CLIENTS[$i]}"

    # 并行检查服务器
    ( check_host_ready "$server" > "$CHECK_TMP_DIR/server_${i}" ) &

    # 并行检查客户端
    ( check_host_ready "$client" > "$CHECK_TMP_DIR/client_${i}" ) &

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
    case "$server_status" in
        OK)      echo -ne "${GREEN}✓${NC}" ;;
        NOCUDA)  echo -ne "${RED}✗(无CUDA)${NC}"; connection_failed=true; cuda_missing=true ;;
        *)       echo -ne "${RED}✗${NC}"; connection_failed=true ;;
    esac

    printf " %-15s " "$client"

    client_status=$(cat "$CHECK_TMP_DIR/client_${i}" 2>/dev/null)
    case "$client_status" in
        OK)      echo -e "${GREEN}✓${NC}" ;;
        NOCUDA)  echo -e "${RED}✗(无CUDA)${NC}"; connection_failed=true; cuda_missing=true ;;
        *)       echo -e "${RED}✗${NC}"; connection_failed=true ;;
    esac
done

if [ "${cuda_missing:-false}" = true ]; then
    echo ""
    echo -e "${YELLOW}[提示]${NC} 部分主机的 ${TEST_CMD} 不支持 --use_cuda。"
    echo -e "        perftest 需要用 CUDA 重新编译，例如："
    echo -e "        ./autogen.sh && ./configure CUDA_H_PATH=/usr/local/cuda/include/cuda.h && make -j"
    echo -e "        （或去掉 --use_cuda 跑主存版本）"
fi

# 清理临时文件
rm -rf "$CHECK_TMP_DIR"

if [ "$connection_failed" = true ]; then
    echo ""
    echo -e "${RED}[失败]${NC} 部分主机 SSH 连接失败或缺少 ${TEST_CMD} 工具"
    exit 1
fi

echo ""
echo -e "${GREEN}[成功]${NC} 所有主机连接正常"
echo ""

# 获取所有唯一主机（NUMA 检测和收尾清理复核都要用，故放在 NUMA 开关之外）
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

# 开跑前先清理上一轮可能残留的测试进程：
# 残留进程占满 CPU，会让这一轮的延时/带宽整体偏差，且从结果上看不出原因。
echo -e "${BOLD}[检查]${NC} 检查并清理残留测试进程..."
stale_total=0
stale_hosts=""
for host in "${unique_hosts[@]}"; do
    (
        n=$(ssh_cmd "$host" "pgrep -c -x ib_write_lat 2>/dev/null || echo 0; pgrep -c -x ib_write_bw 2>/dev/null || echo 0" 2>/dev/null | awk '{s+=$1} END {print s+0}')
        if [ "${n:-0}" != "0" ]; then
            ssh_cmd "$host" "pkill -x ib_write_lat; pkill -x ib_write_bw" 2>/dev/null
            echo "${host}(${n})"
        fi
    ) &
done > /tmp/ibperf_stale_$$.txt
wait
if [ -s /tmp/ibperf_stale_$$.txt ]; then
    stale_hosts=$(tr '\n' ' ' < /tmp/ibperf_stale_$$.txt)
    stale_total=$(wc -l < /tmp/ibperf_stale_$$.txt)
    echo -e "${YELLOW}[清理]${NC} 发现 ${stale_total} 台主机有残留测试进程，已清理: ${stale_hosts}"
else
    echo -e "${GREEN}[完成]${NC} 无残留进程"
fi
rm -f /tmp/ibperf_stale_$$.txt
echo ""

# 网卡 NUMA / GPU 拓扑映射
# 关联数组统一在这里声明：开了 CUDA 但关了 NUMA 绑定时也要用 GPU_MAP
declare -A NUMA_MAP        # host_hca -> 网卡所在 NUMA
declare -A GPU_MAP         # host_hca -> PCIe 最近的 GPU 索引
declare -A GPU_NUMA_MAP    # host_hca -> 该 GPU 所在 NUMA
declare -A GPU_DEPTH       # host_hca -> 与该 GPU 的 PCIe 公共路径深度（越大越近）

if [ "$ENABLE_NUMA_BINDING" = true ] || [ "$USE_CUDA" = true ]; then
    if [ "$USE_CUDA" = true ]; then
        echo -e "${BOLD}[拓扑检测]${NC} 检测网卡 NUMA 节点 + GPU PCIe 亲和性..."
    else
        echo -e "${BOLD}[NUMA检测]${NC} 检测网卡 NUMA 节点映射..."
    fi

    # 创建临时目录存储NUMA检测结果
    NUMA_TMP_DIR="/tmp/ibperf_numa_$$"
    mkdir -p "$NUMA_TMP_DIR"

    # 并行检测所有主机的NUMA映射
    numa_check_count=0
    for host in "${unique_hosts[@]}"; do
        (
            # 直接从 sysfs 读取，不依赖 mst：
            #   - mst 需要内核模块和一次 mst start，每台多一轮 SSH 和 1 秒等待
            #   - mst status -v 的 NUMA 是倒数第二列（最后一列是 VFIO），用 $NF
            #     取值只是在 VFIO 为空时碰巧正确
            # sysfs 的 numa_node 是权威值，任何 NUMA 布局（2 域/4 域/SNC/NPS）都适用。
            # 同时取 numactl 是否存在，绑不了要说话而不是闷头跑。
            # 一次 SSH 同时取回：numactl 是否存在、每张网卡的 numa_node、
            # 以及 PCIe 拓扑上最近的 GPU 及其 numa_node。
            #
            # GPU 匹配不依赖 nvidia-smi topo -m 的文本格式（各版本列数会变），
            # 而是直接比较 sysfs 里两者的 PCIe 路径公共前缀长度 —— 这正是
            # nvidia-smi 判定 PIX/PXB/NODE/SYS 的依据：公共前缀越长越近。
            # 对 bond 设备同样成立（mlx5_bondX/device 指向其中一个 PF）。
            #
            # 输出格式（每行一张卡）:
            #   HCA  hca_numa  gpu_index  gpu_numa  common_pci_depth
            numa_output=$(ssh_cmd "$host" "
                command -v numactl >/dev/null 2>&1 && echo '#numactl ok' || echo '#numactl missing'
                gpulist=\$(nvidia-smi --query-gpu=index,pci.bus_id --format=csv,noheader 2>/dev/null | tr -d ' ' | tr 'A-Z' 'a-z')
                for d in /sys/class/infiniband/*; do
                    [ -e \"\$d\" ] || continue
                    dev=\$(basename \$d)
                    case \$dev in mlx5_*) ;; *) continue ;; esac
                    nn=\$(cat \$d/device/numa_node 2>/dev/null || echo -1)
                    ibp=\$(readlink -f \$d/device 2>/dev/null)
                    best=-1; bestlen=-1; bestnuma=-1
                    for g in \$gpulist; do
                        gi=\${g%%,*}; gb=\${g#*,}; gb=\${gb#0000}
                        gp=\$(readlink -f /sys/bus/pci/devices/\$gb 2>/dev/null)
                        [ -n \"\$gp\" ] || continue
                        l=\$(awk -v a=\"\$ibp\" -v b=\"\$gp\" 'BEGIN{n=split(a,A,\"/\");m=split(b,B,\"/\");c=0;for(i=1;i<=n&&i<=m;i++){if(A[i]==B[i])c++;else break}print c}')
                        if [ \"\$l\" -gt \"\$bestlen\" ] 2>/dev/null; then
                            bestlen=\$l; best=\$gi
                            bestnuma=\$(cat /sys/bus/pci/devices/\$gb/numa_node 2>/dev/null || echo -1)
                        fi
                    done
                    echo \"\$dev \$nn \$best \$bestnuma \$bestlen\"
                done" 2>/dev/null)

            # 将结果保存到临时文件
            echo "$numa_output" > "$NUMA_TMP_DIR/${host}.numa"
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
    NUMA_HOSTS_NO_NUMACTL=""
    for host in "${unique_hosts[@]}"; do
        if [ -f "$NUMA_TMP_DIR/${host}.numa" ]; then
            while IFS= read -r line; do
                case "$line" in
                    "#numactl missing")
                        NUMA_HOSTS_NO_NUMACTL="${NUMA_HOSTS_NO_NUMACTL} ${host}"
                        continue
                        ;;
                    "#numactl ok"|"") continue ;;
                esac

                read -r rdma_dev numa_node gpu_idx gpu_numa pci_depth <<< "$line"

                # 只接受非负整数。-1 表示设备没有 NUMA 亲和性，
                # 硬塞给 numactl --cpunodebind=-1 会直接让测试起不来。
                case "$rdma_dev" in
                    mlx5_*) ;;
                    *) continue ;;
                esac
                if [[ "$numa_node" =~ ^[0-9]+$ ]]; then
                    NUMA_MAP["${host}_${rdma_dev}"]="$numa_node"
                fi
                if [[ "$gpu_idx" =~ ^[0-9]+$ ]]; then
                    GPU_MAP["${host}_${rdma_dev}"]="$gpu_idx"
                    GPU_DEPTH["${host}_${rdma_dev}"]="${pci_depth:-0}"
                fi
                if [[ "$gpu_numa" =~ ^[0-9]+$ ]]; then
                    GPU_NUMA_MAP["${host}_${rdma_dev}"]="$gpu_numa"
                fi
            done < "$NUMA_TMP_DIR/${host}.numa"
        fi
    done

    if [ -n "$NUMA_HOSTS_NO_NUMACTL" ]; then
        echo -e "${YELLOW}[警告]${NC} 以下主机没有 numactl，将不绑定运行:${NUMA_HOSTS_NO_NUMACTL}"
    fi

    # 清理临时目录
    rm -rf "$NUMA_TMP_DIR"

    echo -e "${GREEN}[完成]${NC} NUMA 节点映射检测完成"

    # 显示 NUMA 映射（调试信息）
    if [ ${#NUMA_MAP[@]} -gt 0 ]; then
        echo -e "${CYAN}[信息]${NC} 已检测到 ${#NUMA_MAP[@]} 个网卡的 NUMA 映射"

        # 各主机的 NUMA 域数量：集群里如果有的机器 BIOS 没开 SNC，
        # 域数会不一致，绑定粒度随之不同，结果不能横向比较。
        numa_domain_sig=$(for k in "${!NUMA_MAP[@]}"; do
            echo "${k%%_mlx5_*} ${NUMA_MAP[$k]}"
        done | sort -u | awk '{c[$1]++} END {for (h in c) print c[h]}' | sort -un | tr '\n' ' ')
        echo -e "${CYAN}[信息]${NC} 各主机网卡覆盖的 NUMA 域数: ${numa_domain_sig}"
        if [ "$(echo ${numa_domain_sig} | wc -w)" -gt 1 ]; then
            echo -e "${YELLOW}[警告]${NC} 集群内 NUMA 域数不一致（部分机器 BIOS SNC 可能未开启）。"
            echo -e "        域数少的机器绑定粒度更粗（一个域覆盖更多核），"
            echo -e "        其延时/带宽与其他机器不宜直接横向比较。"
        fi
    elif [ "$ENABLE_NUMA_BINDING" = true ]; then
        echo -e "${YELLOW}[警告]${NC} 未检测到任何 NUMA 映射，全部测试将不绑定运行"
    fi
    echo ""
fi

# ==================== CUDA: GPU ↔ 网卡 映射确认 ====================
if [ "$USE_CUDA" = true ]; then
    echo -e "${BOLD}[CUDA]${NC} 确认 GPU ↔ 网卡 映射..."

    # 手工映射覆盖自动探测（对所有主机生效）
    if [ ${#CUDA_MANUAL_MAP[@]} -gt 0 ]; then
        for host in "${unique_hosts[@]}"; do
            for hca in "${!CUDA_MANUAL_MAP[@]}"; do
                GPU_MAP["${host}_${hca}"]="${CUDA_MANUAL_MAP[$hca]}"
                GPU_DEPTH["${host}_${hca}"]="manual"
            done
        done
        echo -e "  ${CYAN}使用 --cuda_map 手工映射（已覆盖自动探测结果）${NC}"
    fi

    # 校验：被测网卡是否都拿到了 GPU
    CUDA_UNMAPPED=""
    for host in "${unique_hosts[@]}"; do
        for hca in "${HCAS_RAW[@]}"; do
            [ -z "${GPU_MAP["${host}_${hca}"]}" ] && CUDA_UNMAPPED="${CUDA_UNMAPPED} ${host}:${hca}"
        done
    done
    if [ -n "$CUDA_UNMAPPED" ]; then
        echo -e "${RED}[错误]${NC} 以下网卡没有匹配到 GPU:${CUDA_UNMAPPED}"
        echo -e "        请用 --cuda_map 手工指定，或去掉 --use_cuda"
        exit 1
    fi

    # 打印首台主机的映射（集群同构时对所有机器一致）
    ref_host="${unique_hosts[0]}"
    echo -e "${CYAN}[信息]${NC} ${ref_host} 的映射（PCIe 深度越大越近，manual 为手工指定）:"
    printf "  %-14s %-6s %-10s %-10s %s\n" "HCA" "GPU" "网卡NUMA" "GPU NUMA" "PCIe深度"
    for hca in "${HCAS_RAW[@]}"; do
        printf "  %-14s %-6s %-10s %-10s %s\n" \
            "$hca" \
            "${GPU_MAP["${ref_host}_${hca}"]:--}" \
            "${NUMA_MAP["${ref_host}_${hca}"]:--}" \
            "${GPU_NUMA_MAP["${ref_host}_${hca}"]:--}" \
            "${GPU_DEPTH["${ref_host}_${hca}"]:--}"
    done

    # 同一台机上一个 GPU 被多张被测网卡共用 —— 通常是自动探测没分开，
    # 会让这几条链路互相抢同一块显存和同一条 PCIe 上行，结果偏低。
    dup=$(for hca in "${HCAS_RAW[@]}"; do echo "${GPU_MAP["${ref_host}_${hca}"]}"; done | sort | uniq -d | tr '\n' ' ')
    if [ -n "$(echo $dup)" ]; then
        echo -e "${YELLOW}[警告]${NC} GPU ${dup}被多张被测网卡共用，带宽会被摊薄。"
        echo -e "        建议用 --cuda_map 显式一一对应。"
    fi
    echo ""
fi

# 未能绑定的网卡列表（在启动阶段累加，测试开始前汇总提示）
UNBOUND_LIST=""

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

# TEST_CMD 已在参数校验阶段确定（见上方），此处不再重复赋值

# 构建测试参数（服务端和客户端分开）
# 服务端：基础参数，不需要 -D 和 --run_infinitely
# 客户端：使用 --run_infinitely 循环测试，由脚本到时间后主动 kill
BASE_PARAMS="-i ${IB_PORT} -s ${SIZE} -F"
[ "$PERFORM_WARMUP" = true ] && BASE_PARAMS="$BASE_PARAMS --perform_warm_up"

# 延时测试专用参数
if [ "$TEST_MODE" = "latency" ]; then
    [ "$REPORT_HISTOGRAM" = true ] && BASE_PARAMS="$BASE_PARAMS -H"
    [ "$REPORT_UNSORTED" = true ] && BASE_PARAMS="$BASE_PARAMS -U"
fi

# 带宽测试专用参数
if [ "$TEST_MODE" = "bandwidth" ]; then
    [ "$BIDIRECTIONAL" = true ] && BASE_PARAMS="$BASE_PARAMS -b"
    [ "$ALL_SIZES" = true ] && BASE_PARAMS="$BASE_PARAMS -a"
    [ "$REPORT_GBITS" = true ] && BASE_PARAMS="$BASE_PARAMS --report_gbits"
    [ "$NO_PEAK" = true ] && BASE_PARAMS="$BASE_PARAMS -N"
    [ "$REVERSED" = true ] && BASE_PARAMS="$BASE_PARAMS --reversed"
    [ -n "$MTU" ] && BASE_PARAMS="$BASE_PARAMS -m ${MTU}"
    BASE_PARAMS="$BASE_PARAMS -t ${TX_DEPTH} -q ${QP_NUM}"
fi

# 按时长运行时的参数选择：
#   ib_write_bw 支持 --run_infinitely（每轮输出一行，脚本到时间后 kill）
#   ib_write_lat 不支持，传给它只会打印
#       "run_infinitely exists only in BW tests for now."
#   然后不产生任何结果，表格里全变成"解析失败"。
#   两者都支持 -D <秒>（SYMMETRIC，服务端和客户端都要带），延时测试改用它。
if [ "$TEST_MODE" = "latency" ]; then
    DURATION_PARAM="-D ${DURATION}"
else
    DURATION_PARAM="--run_infinitely"
fi

# 服务端参数：基础参数 + 时长控制（run_infinitely 由脚本到时间后 kill）
SERVER_TEST_PARAMS="$BASE_PARAMS"
if [ -z "$ITERATIONS" ]; then
    SERVER_TEST_PARAMS="$SERVER_TEST_PARAMS ${DURATION_PARAM}"
fi

# 客户端参数：加上运行控制
CLIENT_TEST_PARAMS="$BASE_PARAMS"
if [ -n "$ITERATIONS" ]; then
    CLIENT_TEST_PARAMS="$CLIENT_TEST_PARAMS -n ${ITERATIONS}"
else
    CLIENT_TEST_PARAMS="$CLIENT_TEST_PARAMS ${DURATION_PARAM}"
fi

# ==================== 启动命令构建辅助函数 ====================

# 该 (host, hca) 应绑定到哪个 NUMA 节点
resolve_numa_node() {
    local host="$1" hca="$2" n=""
    if [ "$NUMA_SOURCE_EFF" = "gpu" ]; then
        n="${GPU_NUMA_MAP["${host}_${hca}"]}"
        [ -z "$n" ] && n="${NUMA_MAP["${host}_${hca}"]}"
    else
        n="${NUMA_MAP["${host}_${hca}"]}"
        [ -z "$n" ] && n="${GPU_NUMA_MAP["${host}_${hca}"]}"
    fi
    echo "$n"
}

# 构建 numactl 前缀 -> 全局 BIND_PREFIX
BIND_PREFIX=""
build_bind_prefix() {
    local node
    BIND_PREFIX=""
    [ "$ENABLE_NUMA_BINDING" != true ] && return
    node=$(resolve_numa_node "$1" "$2")
    [ -z "$node" ] && return
    BIND_PREFIX="numactl --cpunodebind=${node} --membind=${node}"
}

# 构建 CUDA 参数 -> 全局 CUDA_OPT
CUDA_OPT=""
build_cuda_opt() {
    CUDA_OPT=""
    [ "$USE_CUDA" != true ] && return
    local g="${GPU_MAP["${1}_${2}"]}"
    [ -n "$g" ] && CUDA_OPT="--use_cuda=${g}"
}

# 分批启动所有服务器端
echo -e "${BOLD}[启动]${NC} 分批启动所有服务器端..."
server_count=0

for (( pair_idx=0; pair_idx<PAIR_COUNT; pair_idx++ )); do
    server="${SERVERS[$pair_idx]}"

    for hca_idx in "${!SERVER_HCAS[@]}"; do
        server_hca="${SERVER_HCAS[$hca_idx]}"
        tcp_port=$((BASE_TCP_PORT + pair_idx * 100 + hca_idx))
        log_file="${REMOTE_LOG_DIR}/server_pair${pair_idx}_${server_hca}.log"

        # 构建启动命令（服务端使用 SERVER_TEST_PARAMS）
        # 绑定失败不能悄悄跑：未绑定的延时/带宽会明显偏差，
        # 混在结果里看起来像是这块卡有问题。
        build_bind_prefix "$server" "$server_hca"
        build_cuda_opt   "$server" "$server_hca"
        if [ "$ENABLE_NUMA_BINDING" = true ] && [ -z "$BIND_PREFIX" ]; then
            UNBOUND_LIST="${UNBOUND_LIST} ${server}:${server_hca}"
        fi
        start_cmd="${BIND_PREFIX} ${TEST_CMD} -d ${server_hca} ${SERVER_TEST_PARAMS} ${CUDA_OPT} -p ${tcp_port}"

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

        # 构建启动命令（客户端使用 CLIENT_TEST_PARAMS）
        build_bind_prefix "$client" "$client_hca"
        build_cuda_opt   "$client" "$client_hca"
        if [ "$ENABLE_NUMA_BINDING" = true ] && [ -z "$BIND_PREFIX" ]; then
            UNBOUND_LIST="${UNBOUND_LIST} ${client}:${client_hca}"
        fi
        start_cmd="${BIND_PREFIX} ${TEST_CMD} -d ${client_hca} ${CLIENT_TEST_PARAMS} ${CUDA_OPT} -p ${tcp_port} ${server}"

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
if [ "$ENABLE_NUMA_BINDING" = true ]; then
    if [ -n "$UNBOUND_LIST" ]; then
        unbound_n=$(echo ${UNBOUND_LIST} | wc -w)
        echo -e "  ${YELLOW}NUMA 绑定: $((PAIR_COUNT * HCA_COUNT * 2 - unbound_n))/$((PAIR_COUNT * HCA_COUNT * 2)) 个进程已绑定${NC}"
        echo -e "  ${YELLOW}未绑定:${UNBOUND_LIST}${NC}"
        echo -e "  ${YELLOW}（未绑定进程的延时/带宽会偏差，勿与已绑定的横向比较）${NC}"
    else
        echo -e "  NUMA 绑定: 全部已绑定"
    fi
else
    echo -e "  ${YELLOW}NUMA 绑定: 已禁用 (--no_numa)${NC}"
fi
if [ -n "$ITERATIONS" ]; then
    echo -e "  测试迭代: $ITERATIONS 次"
else
    echo -e "  测试时长: $DURATION 秒 ($(awk "BEGIN {printf \"%.1f\", $DURATION/60}") 分钟)"
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
    echo -e "${YELLOW}[等待]${NC} 等待迭代测试完成..."
    # 轮询实际进程是否结束，而不是固定等 60 秒：
    # 迭代次数大时 60 秒远远不够，到点就往下走会把还没写完结果的进程
    # 一并 kill 掉，表现为莫名其妙的"解析失败"。
    spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    elapsed=0
    spin_idx=0
    ITER_WAIT_MAX=${ITER_WAIT_MAX:-3600}   # 兜底上限，防止异常挂死
    while [ $elapsed -lt $ITER_WAIT_MAX ]; do
        running=0
        for host in "${unique_hosts[@]}"; do
            n=$(ssh_cmd "$host" "pgrep -c -x '${TEST_CMD}' 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
            running=$((running + ${n:-0}))
        done
        [ "$running" -eq 0 ] && break

        printf "\r  ${YELLOW}${spinner[$spin_idx]}${NC} 测试进行中... (已等待 ${elapsed} 秒, 仍在运行 ${running} 个进程)  "
        spin_idx=$(( (spin_idx + 1) % 10 ))
        sleep 5
        elapsed=$((elapsed + 5))
    done
    echo ""
    if [ $elapsed -ge $ITER_WAIT_MAX ]; then
        echo -e "${YELLOW}[警告]${NC} 等待超过 ${ITER_WAIT_MAX} 秒仍未结束，强制进入收尾"
    fi
fi

# -D 模式下进程到点自行退出并打印结果，紧接着 pkill 有可能在它写最后一行
# 结果时把它砍掉。先给一个宽限期，让它们自己收尾，pkill 只用来清理漏网的。
if [ -z "$ITERATIONS" ] && [ "$TEST_MODE" = "latency" ]; then
    echo -e "${YELLOW}[等待]${NC} 等待延时测试自行结束 (5秒)..."
    sleep 5
fi

# 停止所有远程测试进程（两种模式都做：迭代模式下服务端也可能有残留）
echo -e "${BOLD}[停止]${NC} 清理所有远程测试进程..."
cleanup_remote_processes

# 复核：确认真的清干净了，没清掉要说出来而不是假装完成
leftover_hosts=""
for host in "${unique_hosts[@]}"; do
    n=$(ssh_cmd "$host" "pgrep -c -x '${TEST_CMD}' 2>/dev/null || echo 0" 2>/dev/null | tr -d '[:space:]')
    [ "${n:-0}" != "0" ] && leftover_hosts="${leftover_hosts} ${host}(${n})"
done
if [ -n "$leftover_hosts" ]; then
    echo -e "${YELLOW}[警告]${NC} 以下主机仍有测试进程残留:${leftover_hosts}"
    echo -e "        残留进程会占满 CPU 并影响后续测试，请手动清理:"
    echo -e "        ansible all -i hosts -m shell -a \"pkill -x ${TEST_CMD}\""
else
    echo -e "${GREEN}[完成]${NC} 所有测试进程已停止"
fi

# 额外等待确保所有进程完全结束、日志写入完成
echo -e "${YELLOW}[等待]${NC} 等待日志写入完成 (5秒)..."
sleep 5
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
        echo "  测试模式: 持续时间 ($DURATION 秒 = $(awk "BEGIN {printf \"%.1f\", $DURATION/60}") 分钟)"
    fi
    echo "  消息大小: $SIZE 字节"
    if [ "$TEST_MODE" = "bandwidth" ]; then
        echo "  QP 数量: $QP_NUM"
        echo "  发送队列深度: $TX_DEPTH"
        [ -n "$MTU" ] && echo "  MTU: $MTU"
        echo "  双向测试: $([ "$BIDIRECTIONAL" = true ] && echo "是" || echo "否")"
    fi
    echo "  预热测试: $([ "$PERFORM_WARMUP" = true ] && echo "启用" || echo "禁用")"
    if [ "$USE_CUDA" = true ]; then
        echo "  GPUDirect RDMA: 启用 (--use_cuda=<gpu>)"
        echo "  GPU 映射: $([ -n "$CUDA_MAP" ] && echo "$CUDA_MAP" || echo "PCIe 拓扑自动匹配")"
        if [ ${#unique_hosts[@]} -gt 0 ]; then
            _rh="${unique_hosts[0]}"
            echo "  映射明细 (${_rh}):"
            for hca in "${HCAS_RAW[@]}"; do
                printf "    %-14s -> GPU %-3s (网卡NUMA %s / GPU NUMA %s)\n" \
                    "$hca" "${GPU_MAP["${_rh}_${hca}"]:--}" \
                    "${NUMA_MAP["${_rh}_${hca}"]:--}" "${GPU_NUMA_MAP["${_rh}_${hca}"]:--}"
            done
        fi
    else
        echo "  GPUDirect RDMA: 禁用"
    fi
    if [ "$ENABLE_NUMA_BINDING" = true ]; then
        echo "  NUMA 绑定: --cpunodebind/--membind (来源 ${NUMA_SOURCE_EFF})"
    else
        echo "  NUMA 绑定: 禁用"
    fi
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
        echo "│ 服务端IP        客户端IP        HCA配对             迭代/轮次     平均延时(us)   TPS   │"
        echo "├──────────────────────────────────────────────────────────────────────────────────────┤"
    else
        echo "┌────────────────────────────────────────────────────────────────────────────────────────────┐"
        echo "│ 服务端IP        客户端IP        HCA配对             迭代/轮次     平均带宽(Gb/s)  消息速率  │"
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
                    # 延时测试结果解析（--run_infinitely 模式下有多行结果）
                    # 格式: #bytes #iterations    t_avg[usec]    tps
                    result_lines=$(grep -A1 "#bytes.*#iterations.*t_avg" "$client_log" | grep -v "^#" | grep -v "^--$" | grep -E "^\s*[0-9]")
                    line_count=$(echo "$result_lines" | grep -c . 2>/dev/null || echo 0)

                    if [ -n "$result_lines" ] && [ "$line_count" -gt 0 ]; then
                        # 用 awk 一次性计算所有轮次的平均值（避免依赖 bc）
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
                        # 检查是否有连接错误或设备错误
                        if grep -qE "Failed to modify QP|Unable to Connect|Unable to find|not found|Couldn't|state is Down" "$client_log"; then
                            printf "│ %-15s %-15s %-19s %-40s │\n" "$server" "$client" "$hca_pair" "连接/设备失败"
                        else
                            printf "│ %-15s %-15s %-19s %-40s │\n" "$server" "$client" "$hca_pair" "解析失败"
                        fi
                    fi
                else
                    # 带宽测试结果解析（--run_infinitely 模式下有多行结果）
                    # 格式: #bytes     #iterations    BW peak[Gb/sec]    BW average[Gb/sec]   MsgRate[Mpps]
                    result_lines=$(grep -E "^\s*[0-9]+\s+[0-9]+\s+" "$client_log")
                    line_count=$(echo "$result_lines" | grep -c . 2>/dev/null || echo 0)

                    if [ -n "$result_lines" ] && [ "$line_count" -gt 0 ]; then
                        # 用 awk 一次性计算所有轮次的平均值（避免依赖 bc）
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
                        # 检查是否有连接错误或设备错误
                        if grep -qE "Failed to modify QP|Unable to Connect|Unable to find|not found|Couldn't|state is Down" "$client_log"; then
                            printf "│ %-15s %-15s %-19s %-46s │\n" "$server" "$client" "$hca_pair" "连接/设备失败"
                        else
                            printf "│ %-15s %-15s %-19s %-46s │\n" "$server" "$client" "$hca_pair" "解析失败"
                        fi
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
