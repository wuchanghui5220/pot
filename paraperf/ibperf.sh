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

# Latin Square 模式参数
LATIN_SQUARE_MODE=false   # 是否启用 Latin Square 拉丁方阵模式
SU_FILES=""               # SU 文件列表，逗号分隔，例如: SU1.txt,SU2.txt,SU3.txt,SU4.txt
NODE_SHIFT_START=0        # Node 层循环起始值
NODE_SHIFT_END=31         # Node 层循环结束值
PORT_SHIFT_START=0        # Port 层循环起始值
PORT_SHIFT_END=7          # Port 层循环结束值

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
    echo -e "${BOLD}Latin Square 拉丁方阵模式:${NC}"
    echo "  --latin_square            启用 Latin Square 模式（适用于多 SU 集群全互联测试）"
    echo "  --su_files FILE1,FILE2,... SU 文件列表，逗号分隔 (例如: SU1.txt,SU2.txt,SU3.txt,SU4.txt)"
    echo "  --node_shift_range START-END Node 层循环范围 (默认: 0-31，全量测试)"
    echo "                            快速验证: 0-0 或 0-1"
    echo "  --port_shift_range START-END Port 层循环范围 (默认: 0-7，全量测试)"
    echo "                            快速验证: 0-0 或 0-1"
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
    echo ""
    echo "  # Latin Square 全量测试（4个SU，全互联）"
    echo "  $0 --latin_square --su_files SU1.txt,SU2.txt,SU3.txt,SU4.txt --duration 600"
    echo ""
    echo "  # Latin Square 快速验证模式"
    echo "  $0 --latin_square --su_files SU1.txt,SU2.txt,SU3.txt,SU4.txt --node_shift_range 0-1 --port_shift_range 0-1 --duration 60"
    exit 0
}

# ============================================================================
# 通用辅助函数
# ============================================================================

# SSH 命令封装函数
ssh_cmd() {
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$USER@$1" "$2" 2>/dev/null
}

# ============================================================================
# Latin Square 拉丁方阵测试模式实现
# ============================================================================

# 全局关联数组（必须在函数外声明）
declare -A CLUSTER

# 解析 SU 文件，构建三维数据结构
# 结构: CLUSTER[SU_ID,NODE_ID,PORT_ID] = "IP,HCA_NAME"
parse_su_files() {
    local su_idx=0
    SU_NAMES=()  # 普通数组
    NODES_PER_SU=()  # 普通数组

    echo -e "${BOLD}[解析]${NC} 读取 SU 文件并构建三维数据结构..."

    for su_file in "${SU_FILE_ARRAY[@]}"; do
        local su_name=$(basename "$su_file" .txt)
        SU_NAMES+=("$su_name")

        local node_idx=0

        while IFS= read -r line; do
            # 跳过注释和空行
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # 只有IP，自动推断8个HCA
            if [[ "$line" =~ ^[0-9.]+$ ]]; then
                local current_ip="$line"
                for p in 0 1 2 3 6 7 8 9; do
                    CLUSTER["$su_idx,$node_idx,$p"]="$current_ip,mlx5_$p"
                done
                node_idx=$((node_idx + 1))
            fi
        done < "$su_file"

        NODES_PER_SU+=("$node_idx")
        echo -e "  ${GREEN}✓${NC} $su_name: $node_idx 个节点 × 8 端口"
        su_idx=$((su_idx + 1))
    done

    echo -e "${GREEN}[完成]${NC} 数据结构构建完成"
    echo ""

    # 显示数据结构示例（调试用）
    if [ "${NODES_PER_SU[0]}" -le 4 ]; then
        echo -e "${CYAN}[调试]${NC} 数据结构示例 (前2个节点，前4个端口):"
        for su in 0 1; do
            if [ $su -lt ${#SU_NAMES[@]} ]; then
                echo "  SU${su} (${SU_NAMES[$su]}):"
                for node in 0 1; do
                    if [ $node -lt ${NODES_PER_SU[$su]} ]; then
                        echo "    Node${node}:"
                        for port in 0 1 2 3; do
                            local key="$su,$node,$port"
                            local value="${CLUSTER[$key]}"
                            echo "      Port${port}: $value"
                        done
                    fi
                done
            fi
        done
        echo ""
    fi
}

# Latin Square 结果汇总函数
generate_latin_square_summary() {
    echo -e "${BOLD}[分析]${NC} 生成测试报告和 CSV 文件..."

    local SUMMARY_FILE="$LOG_DIR/results_summary.txt"
    local CSV_FILE="$LOG_DIR/results.csv"

    # 生成文本报告
    {
        echo "╔═══════════════════════════════════════════════════════════════════════╗"
        if [ "$TEST_MODE" = "latency" ]; then
            echo "║         Latin Square 拉丁方阵延时测试结果汇总                        ║"
        else
            echo "║         Latin Square 拉丁方阵带宽测试结果汇总                        ║"
        fi
        echo "║                  $(date +"%Y-%m-%d %H:%M:%S")                              ║"
        echo "╚═══════════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "测试配置:"
        echo "  SU 数量: ${#SU_FILE_ARRAY[@]}"
        echo "  每个 SU 节点数: ${NODES_PER_SU[0]}"
        echo "  每个节点端口数: 8 (mlx5_0,1,2,3,6,7,8,9)"
        echo "  Node Shift 范围: $NODE_SHIFT_START - $NODE_SHIFT_END"
        echo "  Port Shift 范围: $PORT_SHIFT_START - $PORT_SHIFT_END"
        echo "  测试类型: $TEST_MODE"
        if [ -n "$ITERATIONS" ]; then
            echo "  测试模式: 迭代次数 ($ITERATIONS 次)"
        else
            echo "  测试模式: 持续时间 ($DURATION 秒)"
        fi
        echo "  消息大小: $SIZE 字节"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "测试结果详情"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        if [ "$TEST_MODE" = "latency" ]; then
            printf "%-6s %-15s %-8s %-15s %-8s %-10s %-12s %-8s\n" \
                "轮次" "源IP" "源HCA" "目标IP" "目标HCA" "迭代次数" "延时(μs)" "TPS"
            echo "────────────────────────────────────────────────────────────────────────────────────────────"
        else
            printf "%-6s %-15s %-8s %-15s %-8s %-10s %-12s %-10s\n" \
                "轮次" "源IP" "源HCA" "目标IP" "目标HCA" "迭代次数" "带宽(Gb/s)" "消息速率"
            echo "────────────────────────────────────────────────────────────────────────────────────────────────"
        fi

    } > "$SUMMARY_FILE"

    # 生成 CSV 文件
    if [ "$TEST_MODE" = "latency" ]; then
        echo "Round,Source_IP,Source_HCA,Target_IP,Target_HCA,Iterations,Latency_us,TPS" > "$CSV_FILE"
    else
        echo "Round,Source_IP,Source_HCA,Target_IP,Target_HCA,Iterations,Bandwidth_Gbps,MsgRate_Mpps" > "$CSV_FILE"
    fi

    # 统计变量
    local total_tests=0
    local valid_tests=0
    local failed_tests=0
    local sum_value=0
    local min_value=999999
    local max_value=0

    # 遍历所有日志文件
    for log_file in "$LOG_DIR"/*_client_*.log; do
        if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
            continue
        fi

        total_tests=$((total_tests + 1))

        # 从文件名解析信息
        local filename=$(basename "$log_file")
        # 格式: {IP}_{HCA}_client_round{N}_task{N}.log
        # 例如: 10.0.10.12_mlx5_0_client_round1_task8.log
        local src_ip=$(echo "$filename" | sed 's/_mlx5_.*//')
        local src_hca=$(echo "$filename" | sed 's/.*_\(mlx5_[0-9]\)_client.*/\1/')
        local round_num=$(echo "$filename" | sed 's/.*_round\([0-9]*\)_.*/\1/')

        # 从日志内容获取目标信息（从 remote address 行）
        local dst_ip=""
        local dst_hca=""

        # 解析测试结果
        if [ "$TEST_MODE" = "latency" ]; then
            local result_line=$(grep -A1 "#bytes.*#iterations.*t_avg" "$log_file" | tail -1)
            if [ -n "$result_line" ]; then
                local iterations=$(echo "$result_line" | awk '{print $2}')
                local avg_lat=$(echo "$result_line" | awk '{print $3}')
                local tps=$(echo "$result_line" | awk '{print $4}')

                # 从文件名获取目标IP（通过task编号查找对应的server日志）
                local task_num=$(echo "$filename" | sed 's/.*_task\([0-9]*\)\.log/\1/')
                local server_log=$(ls "$LOG_DIR"/*_server_round${round_num}_task${task_num}.log 2>/dev/null | head -1)
                if [ -n "$server_log" ]; then
                    local server_filename=$(basename "$server_log")
                    dst_ip=$(echo "$server_filename" | sed 's/_mlx5_.*//')
                    dst_hca=$(echo "$server_filename" | sed 's/.*_\(mlx5_[0-9]\)_server.*/\1/')
                fi

                # 写入文本报告
                printf "%-6s %-15s %-8s %-15s %-8s %-10s %-12s %-8.0f\n" \
                    "$round_num" "$src_ip" "$src_hca" "$dst_ip" "$dst_hca" "$iterations" "$avg_lat" "$tps" >> "$SUMMARY_FILE"

                # 写入 CSV
                echo "$round_num,$src_ip,$src_hca,$dst_ip,$dst_hca,$iterations,$avg_lat,$tps" >> "$CSV_FILE"

                valid_tests=$((valid_tests + 1))
                sum_value=$(echo "$sum_value + $avg_lat" | bc)
                if (( $(echo "$avg_lat < $min_value" | bc -l) )); then
                    min_value=$avg_lat
                fi
                if (( $(echo "$avg_lat > $max_value" | bc -l) )); then
                    max_value=$avg_lat
                fi
            else
                failed_tests=$((failed_tests + 1))
            fi
        else
            # 带宽测试
            local result_line=$(grep -E "^\s*[0-9]+\s+[0-9]+\s+" "$log_file" | tail -1)
            if [ -n "$result_line" ]; then
                local iterations=$(echo "$result_line" | awk '{print $2}')
                local bw_avg=$(echo "$result_line" | awk '{print $4}')
                local msg_rate=$(echo "$result_line" | awk '{print $5}')

                local task_num=$(echo "$filename" | sed 's/.*_task\([0-9]*\)\.log/\1/')
                local server_log=$(ls "$LOG_DIR"/*_server_round${round_num}_task${task_num}.log 2>/dev/null | head -1)
                if [ -n "$server_log" ]; then
                    local server_filename=$(basename "$server_log")
                    dst_ip=$(echo "$server_filename" | sed 's/_mlx5_.*//')
                    dst_hca=$(echo "$server_filename" | sed 's/.*_\(mlx5_[0-9]\)_server.*/\1/')
                fi

                printf "%-6s %-15s %-8s %-15s %-8s %-10s %-12.2f %-10s\n" \
                    "$round_num" "$src_ip" "$src_hca" "$dst_ip" "$dst_hca" "$iterations" "$bw_avg" "$msg_rate" >> "$SUMMARY_FILE"

                echo "$round_num,$src_ip,$src_hca,$dst_ip,$dst_hca,$iterations,$bw_avg,$msg_rate" >> "$CSV_FILE"

                valid_tests=$((valid_tests + 1))
                sum_value=$(echo "$sum_value + $bw_avg" | bc)
                if (( $(echo "$bw_avg < $min_value" | bc -l) )); then
                    min_value=$bw_avg
                fi
                if (( $(echo "$bw_avg > $max_value" | bc -l) )); then
                    max_value=$bw_avg
                fi
            else
                failed_tests=$((failed_tests + 1))
            fi
        fi
    done

    # 生成统计摘要
    {
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "统计摘要"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "测试总数: $total_tests"
        echo "成功: $valid_tests"
        echo "失败: $failed_tests"
        echo ""

        if [ $valid_tests -gt 0 ]; then
            local avg_value=$(echo "scale=2; $sum_value / $valid_tests" | bc)
            if [ "$TEST_MODE" = "latency" ]; then
                echo "延时统计:"
                echo "  最小延时: $min_value μs"
                echo "  最大延时: $max_value μs"
                echo "  平均延时: $avg_value μs"
            else
                echo "带宽统计:"
                echo "  最小带宽: $min_value Gb/s"
                echo "  最大带宽: $max_value Gb/s"
                echo "  平均带宽: $avg_value Gb/s"
            fi
        fi
        echo ""
        echo "报告文件:"
        echo "  文本报告: $SUMMARY_FILE"
        echo "  CSV 文件: $CSV_FILE"
        echo ""
    } >> "$SUMMARY_FILE"

    # 显示报告
    cat "$SUMMARY_FILE"

    echo -e "${GREEN}[完成]${NC} 测试报告已生成"
    echo "  文本报告: $SUMMARY_FILE"
    echo "  CSV 文件: $CSV_FILE"
    echo ""
}

# Latin Square 主测试函数
run_latin_square_test() {
    # 初始化日志目录和临时变量
    local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    local DIR_NAME="latin_square_${TIMESTAMP}"
    local RESULTS_BASE_DIR="./results"
    LOG_DIR="${RESULTS_BASE_DIR}/${DIR_NAME}"
    REMOTE_LOG_DIR="/tmp/ib_test_${TIMESTAMP}"
    SCP_TMP_DIR="/tmp/ibperf_scp_$$"

    mkdir -p "$LOG_DIR"

    # 定义 Phase 配对 (Perfect Matching)
    local -a PHASES=(
        "0,1:2,3"
        "0,2:1,3"
        "0,3:1,2"
    )

    # 解析 SU 文件
    parse_su_files

    local num_sus=${#SU_FILE_ARRAY[@]}

    # 显示测试配置
    echo -e "${BOLD}[配置]${NC} Latin Square 测试参数:"
    echo "  SU 数量: $num_sus"
    echo "  Node Shift 范围: $NODE_SHIFT_START - $NODE_SHIFT_END"
    echo "  Port Shift 范围: $PORT_SHIFT_START - $PORT_SHIFT_END"
    echo "  测试模式: $TEST_MODE"
    if [ -n "$DURATION" ]; then
        echo "  持续时间: $DURATION 秒"
    else
        echo "  迭代次数: $ITERATIONS"
    fi

    # 根据SU数量调整Phase配对（All-to-All 模式）
    local -a phase_configs
    local -a phase_descs
    local total_phases=0

    if [ $num_sus -eq 2 ]; then
        # 2个SU模式：只有1对配对
        phase_configs=("0,1")
        phase_descs=("SU0↔SU1")
        total_phases=1
        echo -e "${CYAN}[模式]${NC} 2-SU All-to-All 模式（1对配对）"
    elif [ $num_sus -eq 4 ]; then
        # 4个SU模式：All-to-All，共6对配对
        # SU0↔SU1, SU0↔SU2, SU0↔SU3, SU1↔SU2, SU1↔SU3, SU2↔SU3
        phase_configs=("0,1" "0,2" "0,3" "1,2" "1,3" "2,3")
        phase_descs=("SU0↔SU1" "SU0↔SU2" "SU0↔SU3" "SU1↔SU2" "SU1↔SU3" "SU2↔SU3")
        total_phases=6
        echo -e "${CYAN}[模式]${NC} 4-SU All-to-All 模式（6对配对）"
    else
        echo -e "${RED}[错误]${NC} 当前仅支持 2 或 4 个 SU，您提供了 $num_sus 个"
        exit 1
    fi

    local total_node_shifts=$((NODE_SHIFT_END - NODE_SHIFT_START + 1))
    local total_port_shifts=$((PORT_SHIFT_END - PORT_SHIFT_START + 1))
    local total_rounds=$((total_phases * total_node_shifts * total_port_shifts))

    echo "  总测试轮次: $total_rounds ($total_phases 对配对 × $total_node_shifts NodeShift × $total_port_shifts PortShift)"
    echo ""

    # 开始完整三层循环测试
    echo -e "${BOLD}${GREEN}[开始]${NC}${BOLD} 执行完整三层循环测试${NC}"
    echo ""

    local current_round=0
    local start_time=$(date +%s)

    # 第一层循环：配对（All-to-All）
    for (( phase_idx=0; phase_idx<${#phase_configs[@]}; phase_idx++ )); do
        local phase_config="${phase_configs[$phase_idx]}"
        local phase_desc="${phase_descs[$phase_idx]}"

        echo -e "${BOLD}${CYAN}========================================${NC}"
        echo -e "${BOLD}${CYAN}  配对 $((phase_idx + 1))/${#phase_configs[@]}: ${phase_desc}${NC}"
        echo -e "${BOLD}${CYAN}========================================${NC}"
        echo ""

        # 第二层循环：NodeShift
        for (( node_shift=NODE_SHIFT_START; node_shift<=NODE_SHIFT_END; node_shift++ )); do

            # 第三层循环：PortShift
            for (( port_shift=PORT_SHIFT_START; port_shift<=PORT_SHIFT_END; port_shift++ )); do
                current_round=$((current_round + 1))

                echo -e "${BOLD}[轮次 $current_round/$total_rounds]${NC} 配对=$((phase_idx+1)), NodeShift=$node_shift, PortShift=$port_shift"
                echo ""

                # 执行单轮测试
                run_single_round_test "$phase_config" "$node_shift" "$port_shift" "$current_round"

                # 显示进度
                local elapsed=$(($(date +%s) - start_time))
                local avg_time_per_round=$((elapsed / current_round))
                local remaining_rounds=$((total_rounds - current_round))
                local estimated_remaining=$((avg_time_per_round * remaining_rounds))

                echo -e "${CYAN}[进度]${NC} 已完成: $current_round/$total_rounds 轮 ($(( current_round * 100 / total_rounds ))%)"
                echo -e "  已用时间: $((elapsed / 60)) 分 $((elapsed % 60)) 秒"
                echo -e "  预计剩余: $((estimated_remaining / 60)) 分 $((estimated_remaining % 60)) 秒"
                echo ""
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
            done
        done
    done

    # 完成提示
    local total_elapsed=$(($(date +%s) - start_time))
    echo -e "${BOLD}${GREEN}========================================${NC}"
    echo -e "${BOLD}${GREEN}  完整测试全部完成！${NC}"
    echo -e "${BOLD}${GREEN}========================================${NC}"
    echo ""
    echo -e "${GREEN}[统计]${NC} 测试完成统计:"
    echo "  总轮次: $total_rounds"
    echo "  总耗时: $((total_elapsed / 60)) 分 $((total_elapsed % 60)) 秒"
    echo "  平均每轮: $((total_elapsed / total_rounds)) 秒"
    echo "  日志目录: $LOG_DIR"
    echo ""

    # 生成结果汇总和 CSV
    generate_latin_square_summary
}

# 执行单轮 Latin Square 测试
run_single_round_test() {
    local phase_config="$1"      # 例如: "0,1:2,3"
    local node_shift="$2"         # 例如: 0
    local port_shift="$3"         # 例如: 0
    local round_num="${4:-1}"     # 轮次编号，默认为1

    echo -e "${BOLD}[执行]${NC} 开始单轮测试..."

    # 解析Phase配对（All-to-All 模式，每次只测试一对 SU）
    local su_src=$(echo "$phase_config" | cut -d',' -f1)     # 0
    local su_dst=$(echo "$phase_config" | cut -d',' -f2)     # 1

    echo "  配对: SU${su_src}(${SU_NAMES[$su_src]}) ↔ SU${su_dst}(${SU_NAMES[$su_dst]})"
    echo ""

    # 生成测试任务（All-to-All：按源节点分批执行）
    local src_nodes=${NODES_PER_SU[$su_src]}
    local dst_nodes=${NODES_PER_SU[$su_dst]}
    local total_tasks=$((src_nodes * 8 * dst_nodes))

    echo -e "${CYAN}[策略]${NC} 按源节点分批执行 All-to-All 测试"
    echo "  源节点数: $src_nodes"
    echo "  目标节点数: $dst_nodes"
    echo "  总任务数: $total_tasks (每批 $((8 * dst_nodes)) 个任务)"
    echo "  总批次数: $src_nodes"
    echo ""

    local batch_start_time=$(date +%s)
    local completed_tasks=0

    # 按源节点分批执行
    for (( src_node=0; src_node<src_nodes; src_node++ )); do
        echo -e "${CYAN}[批次 $((src_node+1))/$src_nodes]${NC} 源节点 $src_node"

        local task_count=0
        declare -a TEST_TASKS=()

        # 生成当前批次的任务（单个源节点的所有端口 × 所有目标节点）
        for src_port in 0 1 2 3 6 7 8 9; do
            local src_port_idx=0
            case $src_port in
                0) src_port_idx=0 ;;
                1) src_port_idx=1 ;;
                2) src_port_idx=2 ;;
                3) src_port_idx=3 ;;
                6) src_port_idx=4 ;;
                7) src_port_idx=5 ;;
                8) src_port_idx=6 ;;
                9) src_port_idx=7 ;;
            esac

            # 循环移位计算目标端口
            local dst_port_shifted=$(( (src_port_idx + port_shift) % 8 ))
            local dst_port_map=(0 1 2 3 6 7 8 9)
            local dst_port=${dst_port_map[$dst_port_shifted]}

            # 遍历目标 SU 的所有节点（All-to-All）
            for (( dst_node=0; dst_node<dst_nodes; dst_node++ )); do
                # 应用 NodeShift
                local dst_node_shifted=$(( (dst_node + node_shift) % dst_nodes ))

                # 获取IP和HCA
                local src_key="${su_src},${src_node},${src_port}"
                local dst_key="${su_dst},${dst_node_shifted},${dst_port}"
                local src_info="${CLUSTER[$src_key]}"
                local dst_info="${CLUSTER[$dst_key]}"

                if [ -n "$src_info" ] && [ -n "$dst_info" ]; then
                    local src_ip=$(echo "$src_info" | cut -d',' -f1)
                    local src_hca=$(echo "$src_info" | cut -d',' -f2)
                    local dst_ip=$(echo "$dst_info" | cut -d',' -f1)
                    local dst_hca=$(echo "$dst_info" | cut -d',' -f2)

                    # 计算TCP端口（使用 src_node 和 dst_node 确保唯一性）
                    local tcp_port=$(( BASE_TCP_PORT + src_node * 1000 + dst_node * 100 + src_port_idx ))

                    # 记录任务
                    TEST_TASKS+=("${src_ip},${src_hca},${dst_ip},${dst_hca},${tcp_port}")
                    task_count=$((task_count + 1))
                fi
            done
        done

        echo "  生成了 $task_count 个测试任务"

        # 显示第一批次的前3个任务作为验证
        if [ $src_node -eq 0 ]; then
            echo -e "${CYAN}[示例]${NC} 前3个测试任务:"
            for (( i=0; i<3 && i<${#TEST_TASKS[@]}; i++ )); do
                local task="${TEST_TASKS[$i]}"
                local task_src_ip=$(echo "$task" | cut -d',' -f1)
                local task_src_hca=$(echo "$task" | cut -d',' -f2)
                local task_dst_ip=$(echo "$task" | cut -d',' -f3)
                local task_dst_hca=$(echo "$task" | cut -d',' -f4)
                local task_tcp_port=$(echo "$task" | cut -d',' -f5)
                echo "    $task_src_ip:$task_src_hca -> $task_dst_ip:$task_dst_hca (port $task_tcp_port)"
            done
        fi
        echo ""

        # ==================== 执行当前批次的测试 ====================

        # 根据测试模式确定命令
        local test_cmd=""
        if [ "$TEST_MODE" = "latency" ]; then
            test_cmd="ib_write_lat"
        else
            test_cmd="ib_write_bw"
        fi

        # 构建测试参数
        local test_params="-i ${IB_PORT} -s ${SIZE} -F"

        if [ -n "$ITERATIONS" ]; then
            test_params="$test_params -n ${ITERATIONS}"
        else
        test_params="$test_params -D ${DURATION}"
    fi
    [ "$PERFORM_WARMUP" = true ] && test_params="$test_params --perform_warm_up"

    # 延时测试专用参数
    if [ "$TEST_MODE" = "latency" ]; then
        [ "$REPORT_HISTOGRAM" = true ] && test_params="$test_params -H"
        [ "$REPORT_UNSORTED" = true ] && test_params="$test_params -U"
    fi

    # 带宽测试专用参数
    if [ "$TEST_MODE" = "bandwidth" ]; then
        [ "$BIDIRECTIONAL" = true ] && test_params="$test_params -b"
        [ "$ALL_SIZES" = true ] && test_params="$test_params -a"
        [ "$REPORT_GBITS" = true ] && test_params="$test_params --report_gbits"
        [ "$NO_PEAK" = true ] && test_params="$test_params -N"
        [ "$RUN_INFINITELY" = true ] && test_params="$test_params --run_infinitely"
        [ "$REVERSED" = true ] && test_params="$test_params --reversed"
        [ -n "$MTU" ] && test_params="$test_params -m ${MTU}"
        test_params="$test_params -t ${TX_DEPTH} -q ${QP_NUM}"
    fi

    # 创建远程日志目录
    echo -e "${BOLD}[准备]${NC} 创建远程日志目录..."
    declare -A unique_hosts
    for task in "${TEST_TASKS[@]}"; do
        local src_ip=$(echo "$task" | cut -d',' -f1)
        local dst_ip=$(echo "$task" | cut -d',' -f3)
        unique_hosts["$src_ip"]=1
        unique_hosts["$dst_ip"]=1
    done

    for host in "${!unique_hosts[@]}"; do
        ssh_cmd "$host" "mkdir -p $REMOTE_LOG_DIR" &
    done
    wait
    echo -e "${GREEN}[完成]${NC} 远程目录创建完成"
    echo ""

    # 启动所有服务器端
    echo -e "${BOLD}[启动]${NC} 启动所有服务器端 (共 ${#TEST_TASKS[@]} 个)..."
    local server_count=0

    for (( i=0; i<${#TEST_TASKS[@]}; i++ )); do
        local task="${TEST_TASKS[$i]}"
        local dst_ip=$(echo "$task" | cut -d',' -f3)
        local dst_hca=$(echo "$task" | cut -d',' -f4)
        local tcp_port=$(echo "$task" | cut -d',' -f5)
        local log_file="${REMOTE_LOG_DIR}/server_round${round_num}_task${i}_${dst_hca}.log"

        local start_cmd="${test_cmd} -d ${dst_hca} ${test_params} -p ${tcp_port}"
        ssh_cmd "$dst_ip" "nohup ${start_cmd} > ${log_file} 2>&1 &" &

        server_count=$((server_count + 1))

        if [ $((server_count % MAX_CONCURRENT_BATCH)) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已启动 ${server_count}/${#TEST_TASKS[@]} 个服务端进程...${NC}"
            sleep 1
        fi
    done

    wait
    echo -e "${GREEN}[完成]${NC} 所有服务器端已启动"
    echo -e "${YELLOW}[等待]${NC} 等待服务器端初始化 (5秒)..."
    sleep 5
    echo ""

    # 启动所有客户端
    echo -e "${BOLD}[启动]${NC} 启动所有客户端 (共 ${#TEST_TASKS[@]} 个)..."
    local client_count=0

    for (( i=0; i<${#TEST_TASKS[@]}; i++ )); do
        local task="${TEST_TASKS[$i]}"
        local src_ip=$(echo "$task" | cut -d',' -f1)
        local src_hca=$(echo "$task" | cut -d',' -f2)
        local dst_ip=$(echo "$task" | cut -d',' -f3)
        local tcp_port=$(echo "$task" | cut -d',' -f5)
        local log_file="${REMOTE_LOG_DIR}/client_round${round_num}_task${i}_${src_hca}.log"

        local start_cmd="${test_cmd} -d ${src_hca} ${test_params} -p ${tcp_port} ${dst_ip}"
        ssh_cmd "$src_ip" "nohup ${start_cmd} > ${log_file} 2>&1 &" &

        client_count=$((client_count + 1))

        if [ $((client_count % MAX_CONCURRENT_BATCH)) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已启动 ${client_count}/${#TEST_TASKS[@]} 个客户端进程...${NC}"
            sleep 1
        fi
    done

    wait
    echo -e "${GREEN}[完成]${NC} 所有客户端已启动"
    echo ""

    # 显示测试信息
    echo -e "${BOLD}${GREEN}[运行中]${NC}${BOLD} 测试正在执行！${NC}"
    echo -e "  测试任务数: ${#TEST_TASKS[@]}"
    if [ -n "$ITERATIONS" ]; then
        echo -e "  测试迭代: $ITERATIONS 次"
    else
        echo -e "  测试时长: $DURATION 秒"
    fi
    echo ""

    # 等待测试完成
    if [ -n "$DURATION" ]; then
        echo -e "${YELLOW}[等待]${NC} 等待测试完成..."
        sleep $DURATION
    else
        echo -e "${YELLOW}[等待]${NC} 等待迭代测试完成 (60秒)..."
        sleep 60
    fi

    echo -e "${YELLOW}[等待]${NC} 等待所有进程完全结束 (10秒)..."
    sleep 10
    echo ""

    # 收集日志
    echo -e "${BOLD}[收集]${NC} 收集测试日志..."
    local collected=0
    local total=$((${#TEST_TASKS[@]} * 2))

    mkdir -p "$SCP_TMP_DIR"

    for (( i=0; i<${#TEST_TASKS[@]}; i++ )); do
        local task="${TEST_TASKS[$i]}"
        local src_ip=$(echo "$task" | cut -d',' -f1)
        local src_hca=$(echo "$task" | cut -d',' -f2)
        local dst_ip=$(echo "$task" | cut -d',' -f3)
        local dst_hca=$(echo "$task" | cut -d',' -f4)

        # 收集服务器端日志
        (
            scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10 \
                "$USER@$dst_ip:${REMOTE_LOG_DIR}/server_round${round_num}_task${i}_${dst_hca}.log" \
                "$LOG_DIR/${dst_ip}_${dst_hca}_server_round${round_num}_task${i}.log" &>/dev/null
            echo $? > "$SCP_TMP_DIR/server_round${round_num}_${i}.status"
        ) &

        # 收集客户端日志
        (
            scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10 \
                "$USER@$src_ip:${REMOTE_LOG_DIR}/client_round${round_num}_task${i}_${src_hca}.log" \
                "$LOG_DIR/${src_ip}_${src_hca}_client_round${round_num}_task${i}.log" &>/dev/null
            echo $? > "$SCP_TMP_DIR/client_round${round_num}_${i}.status"
        ) &

        collected=$((collected + 2))

        if [ $((collected % (MAX_CONCURRENT_BATCH * 2))) -eq 0 ]; then
            wait
            echo -e "  ${CYAN}已收集 ${collected}/${total} 个日志文件...${NC}"
        fi
    done

    wait

    # 检查收集结果
    local failed_count=0
    for status_file in "$SCP_TMP_DIR"/*.status; do
        if [ -f "$status_file" ]; then
            local status=$(cat "$status_file")
            if [ "$status" != "0" ]; then
                failed_count=$((failed_count + 1))
            fi
        fi
    done

    rm -rf "$SCP_TMP_DIR"

    if [ $failed_count -gt 0 ]; then
        echo -e "${YELLOW}[警告]${NC} 日志收集完成，但有 ${failed_count} 个文件收集失败"
    else
        echo -e "${GREEN}[完成]${NC} 日志收集完成 (共 ${total} 个文件)"
    fi
    echo ""

    # 清理远程日志
    echo -e "${BOLD}[清理]${NC} 清理远程临时文件..."
    for host in "${!unique_hosts[@]}"; do
        ssh_cmd "$host" "rm -rf $REMOTE_LOG_DIR" &
    done
    wait
    echo -e "${GREEN}[完成]${NC} 远程清理完成"
    echo ""

        # 更新批次进度
        completed_tasks=$((completed_tasks + task_count))
        local batch_elapsed=$(($(date +%s) - batch_start_time))
        local avg_time_per_batch=$((batch_elapsed / (src_node + 1)))
        local remaining_batches=$((src_nodes - src_node - 1))
        local estimated_remaining=$((avg_time_per_batch * remaining_batches))

        echo -e "${CYAN}[进度]${NC} 已完成批次: $((src_node + 1))/$src_nodes"
        echo "  已完成任务: $completed_tasks/$total_tasks"
        if [ $remaining_batches -gt 0 ]; then
            local remaining_min=$((estimated_remaining / 60))
            local remaining_sec=$((estimated_remaining % 60))
            echo "  预计剩余: ${remaining_min} 分 ${remaining_sec} 秒"
        fi
        echo ""
    done  # 结束批次循环

    echo -e "${GREEN}[完成]${NC} 单轮测试执行完成"
    echo -e "  日志目录: $LOG_DIR"
    echo ""
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
        # Latin Square 模式参数
        --latin_square) LATIN_SQUARE_MODE=true; shift ;;
        --su_files) SU_FILES="$2"; shift 2 ;;
        --node_shift_range)
            NODE_SHIFT_START=$(echo "$2" | cut -d'-' -f1)
            NODE_SHIFT_END=$(echo "$2" | cut -d'-' -f2)
            shift 2 ;;
        --port_shift_range)
            PORT_SHIFT_START=$(echo "$2" | cut -d'-' -f1)
            PORT_SHIFT_END=$(echo "$2" | cut -d'-' -f2)
            shift 2 ;;
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
if [ "$LATIN_SQUARE_MODE" = true ]; then
    # Latin Square 模式的参数验证
    if [ -z "$SU_FILES" ]; then
        echo -e "${RED}错误:${NC} Latin Square 模式必须指定 --su_files 参数"
        show_help
    fi

    # 验证所有 SU 文件存在
    IFS=',' read -ra SU_FILE_ARRAY <<< "$SU_FILES"
    for file in "${SU_FILE_ARRAY[@]}"; do
        if [ ! -f "$file" ]; then
            echo -e "${RED}错误:${NC} SU 文件 $file 不存在"
            exit 1
        fi
    done

    # Latin Square 模式不需要 SERVER_FILE 和 CLIENT_FILE
else
    # 普通模式的参数验证
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
fi

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

# ==================== Latin Square 模式入口 ====================
if [ "$LATIN_SQUARE_MODE" = true ]; then
    echo -e "${BOLD}${GREEN}========================================${NC}"
    echo -e "${BOLD}${GREEN}  Latin Square 拉丁方阵测试模式${NC}"
    echo -e "${BOLD}${GREEN}========================================${NC}"
    echo ""

    # 调用 Latin Square 主函数
    run_latin_square_test
    exit 0
fi

# ==================== 普通模式逻辑 ====================
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
# SSH 命令封装
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
