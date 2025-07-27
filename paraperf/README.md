# ParaPerf - 并行网络性能测试工具

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04%2B-blue.svg)](https://ubuntu.com/)

基于iperf3的专业集群网络性能测试工具，专为高速网络环境（如25G网络）设计，支持多种测试模式和离线部署。

## ✨ 核心特性

- 🚀 **自动化部署**: 自动安装iperf3及所有依赖工具
- 🔐 **SSH管理**: 无需手动配置，自动处理SSH连接
- 🔍 **智能检测**: 自动发现离线主机并提供详细提示
- ⚡ **并发测试**: 支持可配置的并行测试，提升效率
- 📊 **多种输出**: 表格、JSON、CSV三种格式输出
- 🔄 **灵活配对**: 5种测试模式适应不同场景需求
- 🌐 **网卡识别**: 显示测试IP对应的网卡接口信息
- 📦 **离线支持**: 完整的离线安装包解决方案
- 📝 **详细日志**: 完整的操作记录和错误诊断

## 🏗️ 系统要求

- **操作系统**: Ubuntu 22.04.5 或更新版本
- **权限**: 具有sudo权限的用户账户
- **网络**: 测试主机间需要相互访问
- **依赖工具**: `iperf3`, `jq`, `sshpass`, `bc` (脚本可自动安装)

## 🚀 快速开始

### 1. 获取项目

```bash
git clone https://github.com/wuchanghui5220/pot.git
cd pot/paraperf
chmod +x *.sh
```

### 2. 准备主机列表

```bash
# 复制示例文件并编辑主机文件
vim hosts.txt

# 格式：每行一个IP地址或主机名
# 192.168.200.11
# 192.168.200.12
# 192.168.200.13
# 192.168.200.14
# 192.168.200.15
# 192.168.200.16
```

### 3. 基本使用

```bash
# 快速测试 - 全连接模式
./paraperf.sh -u ubuntu -p your_password -f hosts.txt

# 整体网络并发测试验证提升效率 - 对称模式
./paraperf.sh -u ubuntu -p password123 -f hosts.txt -m opposite -d 10 -c 5

```

## 📖 详细用法

### 命令行参数

#### 必需参数
| 参数 | 长参数 | 说明 | 示例 |
|------|--------|------|------|
| `-u` | `--username` | SSH连接用户名 | `-u ubuntu` |
| `-p` | `--password` | SSH连接密码 | `-p mypassword` |
| `-f` | `--hostfile` | 主机列表文件 | `-f hosts.txt` |

#### 可选参数
| 参数 | 长参数 | 默认值 | 说明 | 示例 |
|------|--------|--------|------|------|
| `-m` | `--pairing` | `full` | 配对模式 | `-m opposite` |
| `-c` | `--concurrent` | `5` | 并发测试数量 | `-c 3` |
| `-d` | `--duration` | `10` | 测试持续时间(秒) | `-d 30` |
|`-j`  | ` --threads` | `1` | 并行线程数 | `-j 2` |
| `-P` | `--port` | `5201` | iperf3端口 | `-P 5202` |
| `-t` | `--protocol` | `tcp` | 协议类型 | `-t udp` |
| `-o` | `--output` | `table` | 输出格式 | `-o json` |
| `-v` | `--verbose` | - | 详细输出 | `-v` |
| `-n` | `--dry-run` | - | 试运行模式 | `-n` |
| `-F` | `--force-install` | - | 强制重装iperf3 | `-F` |

### 🔄 测试模式详解

#### 1. 全连接模式 (full)
每个主机与其他所有主机测试，适合全面评估网络性能。
```
主机: A, B, C, D
测试对: A↔B, A↔C, A↔D, B↔C, B↔D, C↔D
```

#### 2. 对称模式 (opposite) 🔥 **推荐用于25G网络**
首尾配对，独立网络路径，适合高速网络并发验证。
```
主机: A, B, C, D, E, F
测试对: A↔F, B↔E, C↔D
特点: 每对使用独立路径，真实反映并发性能
```

#### 3. 环形模式 (ring)
按顺序环形测试，检查网络链路连续性。
```
主机: A, B, C, D
测试对: A→B, B→C, C→D, D→A
```

#### 4. 星形模式 (star)
第一台主机作为中心节点，检查核心性能。
```
主机: A, B, C, D (A为中心)
测试对: A↔B, A↔C, A↔D
```

#### 5. 对等模式 (pair)
相邻主机配对，快速基本连通性检查。
```
主机: A, B, C, D
测试对: A↔B, C↔D
```

### 🔧 并发参数详解

`-c` 参数控制同时运行的测试数量：

```bash
# 顺序测试 (c=1): 获得最大单链路带宽
./paraperf.sh -u admin -p pass -f hosts.txt -c 1
# 结果: 每个连接约20-23Gbps (25G网络)

# 并发测试 (c=3): 模拟真实负载
./paraperf.sh -u admin -p pass -f hosts.txt -c 3
# 结果: 每个连接约8Gbps，总计24Gbps
```

**选择建议**:
- `c=1`: 测量峰值性能
- `c=2-5`: 模拟正常业务负载
- `c>5`: 压力测试

## 📊 输出格式

### 表格格式 (默认)
```
==========================================
           网络性能测试报告
==========================================

ID   服务器  网卡 客户端  网卡 服务器IP     客户端IP     带宽       延迟
----------------------------------------------------------------------------------------------------------------------
1    server01   eth0   server06   eth0   192.168.200.11  192.168.200.16  23.2 Gbps   0.125 ms
2    server02   eth0   server05   eth0   192.168.200.12  192.168.200.15  22.8 Gbps   0.087 ms
3    server03   eth0   server04   eth0   192.168.200.13  192.168.200.14  23.5 Gbps   0.092 ms
----------------------------------------------------------------------------------------------------------------------
```

### JSON格式
```bash
./paraperf.sh -u admin -p pass -f hosts.txt -o json > results.json
```
<details>
<summary>查看JSON示例</summary>

```json
{
  "test_info": {
    "timestamp": "2024-07-25T15:30:00+08:00",
    "pairing_mode": "opposite",
    "protocol": "tcp",
    "duration": 10,
    "port": 5201
  },
  "results": [
    {
      "test_id": 1,
      "server": {
        "hostname": "server01",
        "ip": "192.168.200.11",
        "interface": "eth0"
      },
      "client": {
        "hostname": "server06",
        "ip": "192.168.200.16",
        "interface": "eth0"
      },
      "result": {
        "status": "SUCCESS",
        "bandwidth": "23200.5",
        "bandwidth_unit": "Mbps",
        "rtt": "0.125",
        "rtt_unit": "ms"
      }
    }
  ]
}
```
</details>

### CSV格式
```bash
./paraperf.sh -u admin -p pass -f hosts.txt -o csv > results.csv
```

## 🏭 生产环境部署

### 离线环境支持

#### 1. 准备离线安装包
```bash
# 在有网络的环境中运行
./prepare-iperf3-offline.sh -f

# 查看生成的包
ls -la paraperf-offline/
```

#### 2. 部署到离线环境
```bash
# 复制到目标服务器
scp -r paraperf-offline user@target-server:/opt/

# 在目标服务器安装
cd /opt/paraperf-offline
sudo ./install.sh
```

#### 3. 验证安装
```bash
./paraperf.sh -u admin -p pass -f hosts.txt -n  # 试运行
```

### 25G网络测试最佳实践

```bash
# 1. 基线性能测试 (顺序)
./paraperf.sh -u admin -p pass -f hosts.txt -m opposite -d 30 -c 1

# 2. 并发性能验证
./paraperf.sh -u admin -p pass -f hosts.txt -m opposite -d 30 -c 3

# 3. 长时间稳定性测试
./paraperf.sh -u admin -p pass -f hosts.txt -m full -d 300 -c 2

# 4. UDP延迟测试
./paraperf.sh -u admin -p pass -f hosts.txt -m ring -t udp -d 10
```

### 自动化脚本示例

```bash
#!/bin/bash
# 生产环境自动化测试脚本

CONFIGS=(
    "opposite tcp 60 1"   # 峰值性能
    "opposite tcp 60 3"   # 并发性能
    "full tcp 30 2"       # 全面测试
    "ring udp 10 1"       # 延迟测试
)

for config in "${CONFIGS[@]}"; do
    read -r mode protocol duration concurrent <<< "$config"
    echo "测试配置: $mode $protocol ${duration}s c=$concurrent"

    ./paraperf.sh -u admin -p password \
                  -f hosts.txt \
                  -m "$mode" \
                  -t "$protocol" \
                  -d "$duration" \
                  -c "$concurrent" \
                  -o json > "results_${mode}_${protocol}_c${concurrent}.json"
done
```

## 🔍 故障排除

### 常见问题

<details>
<summary>🔴 缺少依赖工具</summary>

**错误**: `缺少必需的工具: jq sshpass`

**解决方案**:
```bash
# 方法1: 自动安装
sudo apt-get update && sudo apt-get install -y jq sshpass bc

# 方法2: 使用离线包
cd paraperf-offline && sudo ./install.sh
```
</details>

<details>
<summary>🔴 SSH连接失败</summary>

**错误**: `SSH连接失败: 192.168.1.100`

**解决方案**:
```bash
# 检查连通性
ping 192.168.1.100

# 测试SSH连接
ssh -o ConnectTimeout=10 username@192.168.1.100

# 检查sshpass
sshpass -p 'password' ssh username@192.168.1.100 'echo "OK"'
```
</details>

<details>
<summary>🔴 主机离线</summary>

**提示**: `[WARN] 主机离线: 192.168.1.105`

**解决方案**:
1. 检查主机是否在线: `ping 192.168.1.105`
2. 确认IP地址正确
3. 检查网络配置
4. 从hosts.txt中移除离线主机
</details>

<details>
<summary>🔴 iperf3安装失败</summary>

**错误**: `iperf3安装失败: host`

**解决方案**:
```bash
# 强制重新安装
./paraperf.sh -u admin -p pass -f hosts.txt -F

# 手动安装
ssh admin@host 'sudo apt-get update && sudo apt-get install -y iperf3'
```
</details>

### 性能调优

#### 25G网络优化建议

1. **网络接口优化**
```bash
# 增加缓冲区大小
sudo sysctl -w net.core.rmem_max=268435456
sudo sysctl -w net.core.wmem_max=268435456

# 调整TCP窗口
sudo sysctl -w net.ipv4.tcp_rmem="4096 12582912 268435456"
sudo sysctl -w net.ipv4.tcp_wmem="4096 12582912 268435456"
```

2. **CPU优化**
```bash
# 检查CPU使用率
htop

# 如果CPU成为瓶颈，降低并发数
./paraperf.sh -u admin -p pass -f hosts.txt -c 2  # 降低并发
```

3. **存储优化**
```bash
# 使用RAM存储临时文件 (可选)
export TMPDIR=/dev/shm
./paraperf.sh -u admin -p pass -f hosts.txt
```

## 📁 项目结构

```
paraperf/
├── paraperf.sh                 # 主测试脚本
├── prepare-iperf3-offline.sh   # 离线包准备脚本
├── hosts.txt.example           # 主机列表示例
├── README.md                   # 项目文档
├── CLAUDE.md                   # 技术文档
├── paraperf-offline/           # 离线安装包目录
│   ├── install.sh              # 自动安装脚本
│   ├── package-info.txt        # 包信息
│   └── *.deb                   # DEB安装包
└── .paraperf/                  # 运行时目录
    ├── logs/                   # 日志文件
    └── temp/                   # 临时文件
```

## 🧪 测试示例

### 基本功能测试
```bash
# 试运行检查配置
./paraperf.sh -u ubuntu -p password -f hosts.txt -n

# 快速连通性测试
./paraperf.sh -u ubuntu -p password -f hosts.txt -m pair -d 5

# 详细日志模式
./paraperf.sh -u ubuntu -p password -f hosts.txt -v
```

### 25G网络验证完整流程
```bash
# 步骤1: 环境检查
./paraperf.sh -u admin -p pass -f hosts.txt -n

# 步骤2: 单链路峰值测试
./paraperf.sh -u admin -p pass -f hosts.txt -m opposite -d 30 -c 1 -o json > peak.json

# 步骤3: 并发性能测试
./paraperf.sh -u admin -p pass -f hosts.txt -m opposite -d 30 -c 3 -o json > concurrent.json

# 步骤4: 全网络拓扑测试
./paraperf.sh -u admin -p pass -f hosts.txt -m full -d 60 -c 2 -o csv > full_test.csv

# 步骤5: 分析结果
jq '.results[] | select(.result.bandwidth | tonumber > 20000)' peak.json
```

## 🤝 贡献指南

欢迎提交Issue和Pull Request！

1. Fork 项目
2. 创建功能分支: `git checkout -b feature/amazing-feature`
3. 提交更改: `git commit -am 'Add amazing feature'`
4. 推送到分支: `git push origin feature/amazing-feature`
5. 创建 Pull Request

## 📄 许可证

本项目采用 MIT 许可证 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 📞 支持

- 📧 **Issues**: [GitHub Issues](https://github.com/your-repo/paraperf/issues)
- 📚 **文档**: 详见本README和CLAUDE.md
- 🔧 **技术支持**: 通过GitHub Issues提交

## 🏆 致谢

- 基于 [iperf3](https://github.com/esnet/iperf) 网络测试工具
- 感谢所有贡献者和用户的反馈

---

**🚀 ParaPerf - 让网络性能测试更简单、更专业！**
