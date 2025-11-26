# ck-bench.sh 使用手册

**作者**: Vincentwu@zhengytech.com
**版本**: 1.0
**更新日期**: 2025-11-26

---

## 目录

1. [简介](#简介)
2. [环境要求](#环境要求)
3. [快速开始](#快速开始)
4. [功能详解](#功能详解)
5. [参数说明](#参数说明)
6. [使用场景](#使用场景)
7. [输出说明](#输出说明)
8. [故障排查](#故障排查)
9. [性能优化建议](#性能优化建议)
10. [附录](#附录)

---

## 简介

`ck-bench.sh` 是一个基于 NVIDIA HPC-X ClusterKit 的 GPU RDMA 网络基准测试工具，专为 AI/HPC 集群设计。它提供了：

- **自动化测试流程**：从节点健康检查到网络性能测试的全流程自动化
- **多种测试模式**：支持全局测试、逐 Rail 测试、循环压力测试等
- **智能检测**：自动检测 GPU 绑定的计算网卡、网络拓扑验证
- **详细日志**：健康检查日志、PCIe 状态检查、拓扑映射报告
- **三种运行环境**：Mac、CPU 服务器、GPU 服务器均可运行

### 核心特性

| 特性 | 说明 |
|------|------|
| 自动 HCA 检测 | 通过 `nvidia-smi topo` 自动识别 GPU 绑定的网卡 |
| Rail-by-Rail 测试 | 逐个测试每条 Rail，生成对比报告 |
| 健康检查 | SSH、IB、GPU、PCIe 状态全面检查 |
| 拓扑验证 | 验证 GPU-NIC-Switch 连接的 Rail 对齐 |
| 循环压力测试 | 支持节点重启后的多轮压力测试 |
| CSV 报告 | 生成结构化 CSV 格式的测试报告 |

---

## 环境要求

### 硬件要求

- **GPU 服务器**:
  - NVIDIA GPU (支持 GPUDirect RDMA)
  - Mellanox/NVIDIA 网卡 (CX-5/CX-6/CX-7)
  - InfiniBand 或 RoCE 网络

- **网络拓扑**:
  - 推荐 Rail-Optimized Fat-Tree 拓扑
  - 每个 GPU 对应独立的 NIC 和 Leaf 交换机

### 软件要求

- **操作系统**: Linux (Ubuntu 20.04+, CentOS 7+, RHEL 8+)
- **NVIDIA Driver**: 推荐 525.x 或更新版本
- **CUDA Toolkit**: 11.8+ 或 12.x
- **HPC-X**: 2.18+ (包含 UCX, OpenMPI, ClusterKit)
- **OFED**: MLNX_OFED 5.8+ 或 DOCA OFED

### 权限要求

- **root 权限**: 需要 root 权限进行节点重启、IB 状态查询
- **SSH 免密登录**: 控制节点需要能免密 SSH 到所有 GPU 节点
- **GPU 访问权限**: 能够运行 `nvidia-smi` 命令

---

## 快速开始

### 1. 准备工作

**创建 hostfile**：
```bash
# hostfile.txt - 每行一个 GPU 节点 IP
10.0.10.1
10.0.10.2
10.0.10.3
10.0.10.4
```

**验证环境**：
```bash
# 检查 HPC-X 是否安装
ls /tmp/hpcx*/clusterkit/bin/clusterkit.sh

# 检查网卡
ibdev2netdev

# 检查 GPU
nvidia-smi
```

### 2. 最简单的测试

```bash
# 自动检测网卡，运行基准测试
./ck-bench.sh --auto-hca -G -cx7
```

### 3. 查看网络拓扑

```bash
# 检查 GPU-NIC-Switch 连接关系
./ck-bench.sh --check-topology
```

### 4. 只做健康检查

```bash
# 跳过基准测试，只检查节点健康状态
./ck-bench.sh --check-health-only
```

---

## 功能详解

### 4.1 基本网络测试

#### 全局测试模式（推荐用于快速验证）

测试所有网卡的聚合带宽：

```bash
# 使用 4 张网卡
./ck-bench.sh -f hostfile.txt \
  -d "mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1" \
  -G -cx7

# 或者自动检测
./ck-bench.sh --auto-hca -G -cx7
```

**预期结果**（4 节点，4 张 CX-7 网卡）：
```
Average bandwidth: 335000 MB/s (约 335 GB/s)
```

#### Rail-by-Rail 测试模式（推荐用于问题诊断）

逐个测试每条 Rail，识别问题网卡：

```bash
./ck-bench.sh --auto-hca --rail-by-rail -G -cx7 --output-csv
```

**输出示例**：
```
Rail mlx5_0: 98113.1 MB/s  [  OK  ]
Rail mlx5_1: 98044.3 MB/s  [  OK  ]
Rail mlx5_2: 45230.5 MB/s  [ FAIL ] ← 问题网卡
Rail mlx5_3: 97895.2 MB/s  [  OK  ]
```

**生成文件**：
- `results/rail_summary_YYYYMMDD_HHMMSS.txt` - 汇总报告
- `results/rail_summary_YYYYMMDD_HHMMSS.csv` - CSV 格式（可选）

### 4.2 健康检查

#### 完整健康检查

检查 SSH 连接、IB 状态、GPU 可用性、PCIe 链路：

```bash
./ck-bench.sh --check-health-only
```

**检查内容**：
1. **SSH 连接** (ConnectTimeout: 5s)
2. **IB 活跃网卡数量** (检查 GPU 映射的网卡)
3. **GPU 可用性** (nvidia-smi)
4. **PCIe 状态** (Gen5 x16, Signal Integrity)

**输出示例**：
```
Host            SSH    IB         GPU
----------------------------------------
10.0.10.1       ✓      ✓ (8)      ✓
10.0.10.2       ✓      ✓ (8)      ✓
10.0.10.3       ✓      ✗ (0)      ✓  ← IB 问题
10.0.10.4       ✓      ✓ (8)      ✗  ← GPU 问题
----------------------------------------

PCIe Status:
Host            Interfaces    Status    Details
---------------------------------------------------------------
10.0.10.1       8             ✓ PASS    32GT/s/x16/RX:0/TX:0/PASS
10.0.10.2       8             ✓ PASS    32GT/s/x16/RX:0/TX:0/PASS
10.0.10.3       8             ⚠ WARN    ibs14:32GT/s/x16/RX:5/TX:2/WARN
10.0.10.4       8             ✗ FAIL    ibs16:16GT/s/x8/RX:0/TX:0/FAIL
---------------------------------------------------------------
```

**日志文件**：
- `results/health_check.csv` - 所有轮次的汇总 CSV
- `results/YYYYMMDD_HHMMSS_loop1/health_check.log` - 每轮详细日志

#### 并发健康检查

脚本自动并行检查多个节点（默认并发数：64）：

```bash
# 60 个节点，预计 10-15 秒完成
./ck-bench.sh --check-health-only
```

**性能参数**（`ck-bench.sh` 第 57 行）：
```bash
HEALTH_CHECK_PARALLEL=64  # 可调整并发数
```

### 4.3 拓扑验证

#### 检查 GPU-NIC-Switch 映射

验证 Rail 对齐是否正确：

```bash
./ck-bench.sh --check-topology
```

**输出示例**：
```
Host            GPU    NIC        Port       Switch
----------------------------------------------------------------------
GPU-7           GPU0   mlx5_0     Port 39    Compute-SU1-Leaf01-A03-40U
GPU-7           GPU1   mlx5_1     Port 39    Compute-SU1-Leaf02-A03-38U
GPU-7           GPU2   mlx5_2     Port 39    Compute-SU1-Leaf03-A03-36U
GPU-7           GPU3   mlx5_3     Port 39    Compute-SU1-Leaf04-A03-34U
GPU-7           GPU4   mlx5_6     Port 39    Compute-SU1-Leaf05-A10-40U
GPU-7           GPU5   mlx5_7     Port 39    Compute-SU1-Leaf06-A10-38U
GPU-7           GPU6   mlx5_8     Port 39    Compute-SU1-Leaf07-A10-36U
GPU-7           GPU7   mlx5_9     Port 39    Compute-SU1-Leaf08-A10-34U
```

**验证 Rail 对齐**：
```bash
# 下载拓扑文件
scp root@10.0.1.2:/mnt/sdb/x/clusterkit/results/topology_*.txt .

# 使用 Python 脚本验证
python3 analyze_topology.py topology_20251126_104530.txt --export result.csv --report report.txt
```

**分析报告示例**：
```
======================================================================
Rail Topology Analysis Report
======================================================================

Summary Statistics:
  Total GPU-NIC records : 32
  Rail aligned (OK)     : 32
  Rail errors           : 0
  Success Rate: 100.0%

OVERALL STATUS: PASS - All connections are rail-aligned
```

### 4.4 循环压力测试

#### 生产环境压力测试（带重启）

模拟生产环境，测试节点重启后的网络稳定性：

```bash
# 10 轮测试，每轮 60 分钟，节点重启间隔
./ck-bench.sh --auto-hca -G -cx7 -z 60 --loop 10
```

**工作流程**：
```
Round 1:
  1. 重启所有节点 (pdsh reboot)
  2. 等待 3 分钟 (REBOOT_WAIT_TIME)
  3. 健康检查 (SSH + IB + GPU + 验证 uptime < 10 分钟)
  4. PCIe 状态检查
  5. 运行 60 分钟压力测试

Round 2:
  重复上述步骤...
```

**超时保护**：
- 健康检查超时：15 分钟（`HEALTH_CHECK_TIMEOUT`）
- 节点必须在 10 分钟内完成重启（`MAX_UPTIME_MINUTES`）

#### 测试模式（不重启）

用于快速验证脚本逻辑，不实际重启节点：

```bash
# 5 轮测试，每轮 1 分钟，跳过重启和 uptime 验证
./ck-bench.sh --auto-hca -G -cx7 -z 1 --loop-test 5
```

**区别**：
| 参数 | `--loop` | `--loop-test` |
|------|----------|---------------|
| 节点重启 | ✅ 是 | ❌ 否 |
| Uptime 验证 | ✅ 是 | ❌ 否 |
| 适用场景 | 生产验证 | 功能测试 |

---

## 参数说明

### 5.1 基本参数

| 参数 | 简写 | 说明 | 默认值 |
|------|------|------|--------|
| `--hostfile <file>` | `-f` | 节点列表文件 | `hostfile.txt` |
| `--hpcx_dir <path>` | `-r` | HPC-X 安装路径 | 自动检测 |
| `--hca_list <list>` | `-d` | 手动指定网卡列表 | - |
| `--auto-hca` | - | 自动检测 GPU 绑定网卡 | - |
| `--gpudirect` | `-G` | 启用 GPUDirect RDMA | 关闭 |
| `--connectx-7` | `-cx7` | 启用 CX-7 模式（4 QPs） | 关闭 |
| `--traffic <min>` | `-z` | 压力测试时长（分钟） | 不运行 |

### 5.2 测试模式

| 参数 | 说明 | 典型用途 |
|------|------|----------|
| `--rail-by-rail` / `--rbr` | 逐 Rail 测试 | 诊断问题网卡 |
| `--output-csv` | 生成 CSV 报告 | 数据分析 |
| `--quiet` / `-q` | 安静模式 | 批处理脚本 |
| `--loop <N>` | 循环压力测试（带重启） | 生产验证 |
| `--loop-test <N>` | 循环测试（不重启） | 功能测试 |

### 5.3 检查功能

| 参数 | 说明 | 输出 |
|------|------|------|
| `--check-health-only` | 只做健康检查 | 控制台 + CSV |
| `--check-topology` | 显示拓扑映射 | 控制台 + TXT |
| `--Ca <device>` | 指定拓扑查询网卡 | 默认 mlx5_0 |

### 5.4 HCA 列表格式

**格式**：`mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1`

- `mlx5_X`: HCA 设备名称
- `:1`: 端口号（CX-7 单端口网卡通常是 1）

**示例**：

```bash
# 单网卡
-d "mlx5_0:1"

# 4 张网卡（GPU0-3）
-d "mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1"

# 8 张网卡（GPU0-7）
-d "mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_6:1,mlx5_7:1,mlx5_8:1,mlx5_9:1"

# 自动检测（推荐）
--auto-hca
```

---

## 使用场景

### 6.1 场景 1：新集群验收测试

**目标**：全面验证集群网络性能

```bash
# Step 1: 拓扑验证
./ck-bench.sh --check-topology
python3 analyze_topology.py topology_*.txt --export topo.csv --report topo_report.txt

# Step 2: 健康检查
./ck-bench.sh --check-health-only --auto-hca

# Step 3: Rail-by-Rail 测试
./ck-bench.sh --auto-hca --rail-by-rail -G -cx7 --output-csv

# Step 4: 全局性能测试
./ck-bench.sh --auto-hca -G -cx7

# Step 5: 压力测试 (可选)
./ck-bench.sh --auto-hca -G -cx7 -z 60 --loop 3
```

### 6.2 场景 2：故障诊断

**问题**：训练任务网络性能异常

```bash
# Step 1: 快速健康检查
./ck-bench.sh --check-health-only

# Step 2: 逐 Rail 测试，找出问题网卡
./ck-bench.sh --auto-hca --rbr -G -cx7 -q

# Step 3: 检查 PCIe 状态
# (已包含在 health check 中，查看日志)
cat results/health_check.csv | grep FAIL

# Step 4: 验证拓扑
./ck-bench.sh --check-topology
```

### 6.3 场景 3：性能基线建立

**目标**：建立不同网卡配置的性能基线

```bash
# 测试 1 张网卡
./ck-bench.sh -d "mlx5_0:1" -G -cx7

# 测试 2 张网卡
./ck-bench.sh -d "mlx5_0:1,mlx5_1:1" -G -cx7

# 测试 4 张网卡
./ck-bench.sh -d "mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1" -G -cx7

# 测试 8 张网卡
./ck-bench.sh --auto-hca -G -cx7
```

**结果对比**（参考值，4 节点 CX-7）：

| 网卡数 | 平均带宽 | 扩展效率 |
|--------|---------|---------|
| 1 张   | ~98 GB/s | 100% |
| 2 张   | ~196 GB/s | 100% |
| 4 张   | ~335 GB/s | 85% |
| 8 张   | ~335 GB/s | 42% (受限于算法模型) |

### 6.4 场景 4：日常巡检

**目标**：定期检查集群健康状态

**Crontab 配置**：
```bash
# 每天凌晨 2 点运行健康检查
0 2 * * * /mnt/sdb/x/clusterkit/ck-bench.sh --check-health-only 2>&1 | tee /var/log/cluster_health_$(date +\%Y\%m\%d).log
```

**脚本示例**：
```bash
#!/bin/bash
# daily_check.sh - 每日健康检查

LOG_DIR="/var/log/cluster_health"
mkdir -p $LOG_DIR

DATE=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/health_$DATE.log"

# 运行健康检查
/mnt/sdb/x/clusterkit/ck-bench.sh --check-health-only 2>&1 | tee $LOG_FILE

# 检查是否有失败
if grep -q "FAIL\|✗" $LOG_FILE; then
    # 发送告警邮件
    mail -s "Cluster Health Check FAILED - $DATE" admin@example.com < $LOG_FILE
fi
```

### 6.5 场景 5：网卡数量影响评估

**问题**：应该使用多少张网卡？

```bash
# 依次测试 1/2/4/8 张网卡
for hca_count in 1 2 4 8; do
    echo "Testing with $hca_count HCAs..."

    case $hca_count in
        1) HCA_LIST="mlx5_0:1" ;;
        2) HCA_LIST="mlx5_0:1,mlx5_1:1" ;;
        4) HCA_LIST="mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1" ;;
        8) HCA_LIST="--auto-hca" ;;
    esac

    ./ck-bench.sh -d "$HCA_LIST" -G -cx7 -z 3

    sleep 10
done
```

**分析结果**：
- 1-2 张网卡：线性扩展，效率 100%
- 4 张网卡：达到 ~335 GB/s，为点对点峰值
- 8 张网卡：与 4 张相同（受限于算法模型）

**推荐配置**：
- **小规模训练（<16 节点）**：4 张网卡
- **大规模训练（32+ 节点）**：8 张网卡（集合通信受益）

---

## 输出说明

### 7.1 控制台输出

#### 基准测试输出

```
==========================================
ClusterKit Benchmark
==========================================
Environment: cpu_server
GPU server:  10.0.10.7
Hostfile:    hostfile.txt
HCA list:    mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1
==========================================

[2/4] Running benchmark...

MPI_HOME=/tmp/hpcx-v2.21.3-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64/ompi
mpi_opt= -x UCX_NET_DEVICES=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1 ...

Testing bandwidth
NUM_BATCHES = 4
Completed 4 out of 4 batch sizes: 100%

Message size: 8388608 B     Iterations: 10000

Minimum bandwidth: 332028.6 MB/s between GPU-11 and GPU-15
Maximum bandwidth: 341659.1 MB/s between GPU-7 and GPU-13
Average bandwidth: 335047.1 MB/s  ← 关键指标

Test bandwidth ended
```

#### Rail-by-Rail 输出

```
==========================================
Rail-by-Rail Test Summary
==========================================

Rail   Bandwidth (MB/s)   Status    Variance
--------------------------------------------------
mlx5_0    98113.1         [  OK  ]    0.0%
mlx5_1    98044.3         [  OK  ]   -0.1%
mlx5_2    97895.2         [  OK  ]   -0.2%
mlx5_3    98201.5         [  OK  ]   +0.1%
mlx5_6    45230.5         [ FAIL ]  -53.9%  ← 问题网卡
mlx5_7    97980.3         [  OK  ]   -0.1%
mlx5_8    98075.4         [  OK  ]    0.0%
mlx5_9    98150.2         [  OK  ]   +0.0%
--------------------------------------------------

Average (excluding failures): 98057.5 MB/s
Failed Rails: 1 (mlx5_6)
```

### 7.2 文件输出

#### 目录结构

```
results/
├── health_check.csv                          # 健康检查汇总 CSV
├── topology_20251126_104530.txt              # 拓扑映射文件
├── rail_summary_20251126_110203.txt          # Rail-by-Rail 汇总
├── rail_summary_20251126_110203.csv          # Rail-by-Rail CSV
└── 20251126_152030_10.0.10.1-10.0.10.4/      # 单次测试结果目录
    ├── bandwidth.json                         # 带宽测试原始数据
    ├── health_check.log                       # 健康检查详细日志
    └── stress_test_*.log                      # 压力测试日志 (如果运行)
```

#### health_check.csv 格式

```csv
Timestamp,Round,Host,SSH,IB_Active,GPU,Uptime,PCIe_Speed,PCIe_Width,RX_Err,TX_Err,Status
2025-11-26 15:10:17,1,10.0.10.1,✓,8,✓,5m,32GT/s,x16,0,0,PASS
2025-11-26 15:10:17,1,10.0.10.2,✓,8,✓,4m,32GT/s,x16,0,0,PASS
2025-11-26 15:10:17,1,10.0.10.3,✓,0,✓,3m,N/A,N/A,N/A,N/A,FAIL
```

**字段说明**：
- `SSH`: SSH 连接状态 (✓/✗)
- `IB_Active`: 活跃的 IB 网卡数量
- `GPU`: GPU 可用性 (✓/✗)
- `Uptime`: 节点运行时间（分钟）
- `PCIe_Speed`: PCIe 链路速度 (32GT/s = Gen5)
- `PCIe_Width`: PCIe 链路宽度 (x16)
- `RX_Err/TX_Err`: PCIe 信号完整性错误计数
- `Status`: 综合状态 (PASS/WARN/FAIL)

#### topology 文件格式

```
Host            GPU    NIC        Port       Switch
----------------------------------------------------------------------
GPU-7           GPU0   mlx5_0     Port 39    Compute-SU1-Leaf01-A03-40U
GPU-7           GPU1   mlx5_1     Port 39    Compute-SU1-Leaf02-A03-38U
...
```

### 7.3 性能指标解读

#### 带宽单位换算

```
1 MB/s = 8 Mbps (兆比特每秒)
1000 MB/s = 1 GB/s
1 GB/s ≈ 8 Gbps

示例：
335047 MB/s = 335 GB/s = 2.68 Tbps
```

#### CX-7 理论带宽

- **单卡理论**：400 Gbps = 50 GB/s (单向) = 100 GB/s (全双工)
- **实际测得**：~98 GB/s (单卡，考虑协议开销)

#### 性能评估标准

| 配置 | 预期带宽 | 评估 |
|------|---------|------|
| 1 × CX-7 | 95-100 GB/s | ✓ 正常 |
| 2 × CX-7 | 190-200 GB/s | ✓ 正常 |
| 4 × CX-7 | 320-350 GB/s | ✓ 正常 |
| 8 × CX-7 | 320-350 GB/s | ✓ 正常 (受限于算法模型) |

**异常判断**：
- **单卡 < 90 GB/s**: 检查 PCIe 状态、网络拓扑
- **多卡无扩展**: 检查 HCA 列表配置、UCX 参数
- **Rail 间差异 > 10%**: 检查问题 Rail 的链路质量

---

## 故障排查

### 8.1 常见错误

#### 错误 1: 找不到 clusterkit.sh

```
Error: clusterkit.sh not found at /tmp/hpcx-*/clusterkit/bin/
```

**原因**：HPC-X 未安装或路径不正确

**解决**：
```bash
# 方法 1: 指定 HPC-X 路径
./ck-bench.sh -r /path/to/hpcx --auto-hca -G -cx7

# 方法 2: 设置环境变量
export HPCX_HOME=/path/to/hpcx
./ck-bench.sh --auto-hca -G -cx7

# 方法 3: 安装 HPC-X
wget https://content.mellanox.com/hpc/hpc-x/v2.21.3/hpcx-v2.21.3-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64.tbz
tar xf hpcx-*.tbz -C /tmp/
```

#### 错误 2: SSH 连接失败

```
Host            SSH    IB         GPU
----------------------------------------
10.0.10.1       ✗      N/A        N/A
```

**原因**：SSH 免密登录未配置

**解决**：
```bash
# 生成 SSH 密钥
ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa

# 复制公钥到所有节点
for host in 10.0.10.{1..60}; do
    ssh-copy-id root@$host
done

# 验证
ssh root@10.0.10.1 hostname
```

#### 错误 3: IB 网卡不活跃

```
Host            SSH    IB         GPU
----------------------------------------
10.0.10.1       ✓      ✗ (0)      ✓
```

**原因**：IB 驱动未加载或端口 Down

**诊断**：
```bash
# 检查 IB 状态
ssh 10.0.10.1 ibstat

# 检查网卡状态
ssh 10.0.10.1 ibdev2netdev

# 检查端口状态
ssh 10.0.10.1 "ibstatus | grep State"
```

**解决**：
```bash
# 重启 IB 驱动
ssh 10.0.10.1 "/etc/init.d/openibd restart"

# 启动端口
ssh 10.0.10.1 "ibportstate 1 1 enable"
```

#### 错误 4: PCIe 降速

```
Host            Interfaces    Status    Details
---------------------------------------------------------------
10.0.10.1       8             ✗ FAIL    ibs14:16GT/s/x8/RX:0/TX:0/FAIL
```

**原因**：PCIe 链路训练失败，未达到 Gen5 x16

**诊断**：
```bash
# 检查 PCIe 链路状态
ssh 10.0.10.1 "lspci -s $(ethtool -i ibs14 | grep bus-info | awk '{print $2}') -vvv | grep LnkSta"
```

**解决**：
1. 检查 PCIe 插槽是否插好
2. 检查 BIOS 设置 (PCIe Gen5, ASPM Disabled)
3. 更新网卡固件
4. 尝试重新插拔网卡

#### 错误 5: Signal Integrity 错误

```
Host            Interfaces    Status    Details
---------------------------------------------------------------
10.0.10.1       8             ⚠ WARN    ibs14:32GT/s/x16/RX:15/TX:0/WARN
```

**原因**：PCIe 信号质量问题

**诊断**：
```bash
# 查看错误计数
ssh 10.0.10.1 "ethtool -S ibs14 | grep signal_integrity"

# 清零计数器
ssh 10.0.10.1 "ethtool -S ibs14 --reset"

# 重新测试
./ck-bench.sh --check-health-only
```

**解决**：
1. **RX/TX < 10**: 可接受，继续观察
2. **RX/TX >= 10**: 检查 PCIe 线缆、插槽质量
3. **持续增长**: 更换 PCIe 插槽或网卡

### 8.2 性能问题

#### 问题 1: 带宽低于预期

**现象**：单卡只有 50 GB/s (预期 98 GB/s)

**排查步骤**：
```bash
# 1. 检查 GPUDirect 是否启用
./ck-bench.sh -d "mlx5_0:1" -G -cx7  # 确保有 -G

# 2. 检查网卡模式
ssh 10.0.10.1 "ibstat mlx5_0 | grep Rate"
# 应该看到: Rate: 400 Gb/sec

# 3. 检查 PCIe
./ck-bench.sh --check-health-only
# 应该看到: 32GT/s/x16

# 4. 检查拓扑
./ck-bench.sh --check-topology
# 确认 GPU-NIC 是 PIX (同一 PCIe 交换机)
```

#### 问题 2: 多卡无扩展

**现象**：4 张网卡和 1 张网卡带宽相同

**原因**：HCA 列表配置错误

**检查**：
```bash
# 错误示例 (只会用第一张网卡)
./ck-bench.sh -d "mlx5_0:1" -G -cx7  # ❌

# 正确示例
./ck-bench.sh -d "mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1" -G -cx7  # ✓

# 或者使用自动检测
./ck-bench.sh --auto-hca -G -cx7  # ✓
```

#### 问题 3: Rail-by-Rail 某个 Rail 很慢

**现象**：mlx5_6 只有 45 GB/s，其他都是 98 GB/s

**诊断**：
```bash
# 1. 检查该 Rail 的 PCIe 状态
ssh 10.0.10.1 "ethtool -i ibs16 | grep bus-info"
ssh 10.0.10.1 "lspci -s <bus-info> -vvv | grep LnkSta"

# 2. 检查该 Rail 的拓扑
./ck-bench.sh --check-topology --Ca mlx5_6

# 3. 检查交换机端口状态
ssh <switch> "show interface status | grep <port>"

# 4. 检查光模块
ssh 10.0.10.1 "mst start && mlxlink -d /dev/mst/mt4125_pciconf0 --port_type PCIE"
```

### 8.3 Debug 技巧

#### 启用详细日志

```bash
# 在脚本中添加 set -x
bash -x ./ck-bench.sh --auto-hca -G -cx7

# 或者修改脚本第 2 行
#!/bin/bash
set -x  # 添加这一行
```

#### 手动运行单步

```bash
# 1. 只做健康检查
./ck-bench.sh --check-health-only

# 2. 只做拓扑检查
./ck-bench.sh --check-topology

# 3. 手动运行 clusterkit
ssh 10.0.10.7
cd /tmp/hpcx-v2.21.3-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64
source hpcx-init.sh
hpcx_load
./clusterkit/bin/clusterkit.sh --hostfile /tmp/hostfile_tmp.txt \
  --hca_list "mlx5_0:1" --gpudirect --connectx-7
```

#### 查看并发健康检查日志

```bash
# 查看临时文件
ls -la /tmp/health_check_*/

# 查看某个节点的状态
cat /tmp/health_check_12345/10.0.10.1.status
```

---

## 性能优化建议

### 9.1 网络配置优化

#### BIOS 设置

```
推荐配置：
- PCIe: Gen5 enabled
- ASPM: Disabled (Active State Power Management)
- SR-IOV: Enabled
- NUMA: Enabled
- CPU C-States: Disabled (降低延迟)
```

#### 网卡固件

```bash
# 检查固件版本
mst start
mlxfwmanager

# 更新固件 (如果需要)
mlxfwmanager --update -y
```

#### 系统参数

```bash
# /etc/sysctl.conf
net.core.rmem_max = 268435456
net.core.wmem_max = 268435456
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
```

### 9.2 GPU 配置优化

#### GPU Persistence Mode

```bash
# 启用 GPU 持久化模式 (减少初始化时间)
nvidia-smi -pm 1
```

#### GPU Clocks

```bash
# 锁定 GPU 频率到最大值
nvidia-smi -lgc 1980,1980  # H100: 1980 MHz
```

### 9.3 测试参数优化

#### 节点数量建议

| 网卡数量 | 推荐节点数 | 原因 |
|---------|----------|------|
| 1-2 张  | 2-4 节点 | 验证单 Rail |
| 4 张    | 4-8 节点 | 点对点峰值 |
| 8 张    | 16+ 节点 | 集合通信受益 |

#### 压力测试时长

```bash
# 快速验证: 1-3 分钟
./ck-bench.sh --auto-hca -G -cx7 -z 1

# 日常测试: 10-30 分钟
./ck-bench.sh --auto-hca -G -cx7 -z 10

# 压力测试: 60+ 分钟
./ck-bench.sh --auto-hca -G -cx7 -z 60 --loop 10
```

---

## 附录

### 10.1 环境变量

| 变量 | 说明 | 示例 |
|------|------|------|
| `HPCX_HOME` | HPC-X 安装路径 | `/tmp/hpcx-v2.21.3-...` |
| `HEALTH_CHECK_PARALLEL` | 健康检查并发数 | `64` |
| `HEALTH_CHECK_TIMEOUT` | 健康检查超时（秒） | `900` |
| `MAX_UPTIME_MINUTES` | 重启后最大 uptime（分钟） | `10` |
| `REBOOT_WAIT_TIME` | 重启后等待时间（秒） | `180` |

### 10.2 配置文件修改

#### 调整并发数

```bash
# 编辑 ck-bench.sh 第 57 行
vim ck-bench.sh

# 找到这一行:
HEALTH_CHECK_PARALLEL=64  # Max parallel health checks (0=unlimited)

# 修改为:
HEALTH_CHECK_PARALLEL=128  # 更高的并发数 (适用于更多节点)
```

#### 调整超时时间

```bash
# 编辑 ck-bench.sh 第 56 行
HEALTH_CHECK_TIMEOUT=900  # 15 minutes timeout

# 修改为:
HEALTH_CHECK_TIMEOUT=1800  # 30 minutes (适用于大规模集群)
```

### 10.3 相关工具

#### analyze_topology.py

拓扑分析脚本，验证 Rail 对齐：

```bash
# 基本用法
python3 analyze_topology.py topology.txt

# 生成 CSV 和报告
python3 analyze_topology.py topology.txt --export result.csv --report report.txt
```

#### 输出示例

```
======================================================================
Rail Topology Analysis Report
======================================================================

Summary Statistics:
  Total GPU-NIC records : 32
  Rail aligned (OK)     : 31
  Rail errors           : 1
  Success Rate: 96.9%

RAIL MISALIGNMENT DETAILS
----------------------------------------------------------------------
  GPU-13:
    GPU3 (mlx5_3): Expected Leaf04, got Leaf03

RECOMMENDATIONS
----------------------------------------------------------------------
  4. [LOW] Swap cables to correct leaf switches for rail alignment
```

### 10.4 术语表

| 术语 | 全称 | 说明 |
|------|------|------|
| HCA | Host Channel Adapter | InfiniBand 网卡 |
| CX-7 | ConnectX-7 | Mellanox/NVIDIA 第 7 代网卡 |
| GPUDirect | NVIDIA GPUDirect RDMA | GPU 直接访问网卡，绕过 CPU |
| Rail | - | GPU-NIC-Switch 的专用通道 |
| UCX | Unified Communication X | HPC-X 通信库 |
| RDMA | Remote Direct Memory Access | 远程直接内存访问 |
| QP | Queue Pair | InfiniBand 连接队列对 |
| PCIe | PCI Express | 高速串行总线 |
| Gen5 | PCIe Generation 5 | 32 GT/s，128 GB/s (x16) |
| NUMA | Non-Uniform Memory Access | 非一致性内存访问 |

### 10.5 参考文档

- [NVIDIA HPC-X Documentation](https://docs.nvidia.com/networking/display/hpcx)
- [NVIDIA GPUDirect RDMA](https://docs.nvidia.com/cuda/gpudirect-rdma/)
- [Mellanox OFED Documentation](https://docs.nvidia.com/networking/display/mlnxofedv531000)
- [ClusterKit User Guide](https://docs.nvidia.com/networking/display/hpcx/clusterkit)

### 10.6 常见问题 FAQ

**Q: 为什么 8 张网卡的带宽和 4 张网卡一样？**
A: 这是正常现象。点对点测试受限于单个 GPU 的 PCIe 带宽（~128 GB/s）。8 张网卡在大规模集合通信（All-reduce）中才会体现优势。

**Q: 如何判断网卡是否有问题？**
A: 使用 `--rail-by-rail` 模式逐个测试。如果某个 Rail 的带宽比其他 Rail 低 10% 以上，可能存在问题。

**Q: PCIe 信号完整性错误多少算正常？**
A: RX/TX 错误 < 10 可接受，10-100 需要观察，> 100 需要检查硬件。

**Q: 健康检查为什么这么慢？**
A: 脚本已经并行化（默认 64 并发）。如果仍然慢，检查网络延迟和节点响应时间。

**Q: 可以在 Mac 上运行吗？**
A: 可以。脚本会自动检测运行环境，通过 CPU 服务器中转到 GPU 服务器。

---

## 更新日志

### Version 1.0 (2025-11-26)
- ✅ 初始版本发布
- ✅ 支持自动 HCA 检测
- ✅ 支持 Rail-by-Rail 测试
- ✅ 支持健康检查（SSH+IB+GPU+PCIe）
- ✅ 支持拓扑验证
- ✅ 支持循环压力测试
- ✅ 支持并行健康检查（64 并发）
- ✅ 生成 CSV 格式报告

---

## 联系方式

如有问题或建议，请联系：

**作者**: Vincentwu
**Email**: Vincentwu@zhengytech.com
**项目**: ClusterKit GPU RDMA Benchmark Tool

---

**文档结束**
