# ParaPerf - 并行网络性能测试工具

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Shell](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04%2B-blue.svg)](https://ubuntu.com/)

基于iperf3的专业集群网络性能测试工具，专为高速网络环境（如25G/100G网络）设计，支持多种测试模式、双向测试和离线部署。

## ✨ 核心特性

- 🚀 **自动化部署**: 自动安装iperf3及所有依赖工具
- 🔐 **SSH管理**: 无需手动配置，自动处理SSH连接和认证
- 🔍 **智能检测**: 自动发现离线主机并提供详细提示
- ⚡ **并发测试**: 支持可配置的并行测试，大幅提升测试效率
- 🔄 **双向测试**: 支持同时测试上行和下行带宽 **[NEW]**
- 🎯 **多种模式**: 5种测试配对模式适应不同测试场景
- 📊 **多格式输出**: 表格、JSON、CSV三种格式，支持数据分析
- 🌐 **网卡识别**: 自动显示测试IP对应的网卡接口信息
- 📦 **离线支持**: 完整的离线安装包，支持无网络环境部署
- 📝 **详细日志**: 完整的操作记录和错误诊断信息
- 🛡️ **错误恢复**: 强大的错误处理和自动重试机制

## 🏗️ 系统要求

- **操作系统**: Ubuntu 22.04.5 或更新版本
- **权限**: 具有sudo权限的用户账户
- **网络**: 测试主机间需要相互访问，端口5201及以上可用
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
# 复制示例文件并编辑
vim hosts.txt

# 格式：每行一个IP地址或主机名
# 192.168.200.11
# 192.168.200.12
# 192.168.200.13
# 192.168.200.14
# 192.168.200.15
# 192.168.200.16
```

### 3. 基本测试

```bash
# 基本网络性能测试
./paraperf.sh -u username -p password -f hosts.txt

# 双向测试（推荐）
./paraperf.sh -u username -p password -f hosts.txt -b
```

## 📋 测试模式详解

| 模式 | 说明 | 测试连接数 | 适用场景 |
|------|------|------------|----------|
| **full** | 全连接测试 | N×(N-1) | 全面性能评估，发现瓶颈 |
| **star** | 星形测试 | N-1 | 中心节点性能评估 |
| **ring** | 环形测试 | N | 基础连通性验证 |
| **pair** | 对等测试 | N/2 | 快速性能抽样 |
| **opposite** | 对称测试 | N/2 | 对称性能验证 |

### 测试模式图解

```
Full模式 (N=4):        Star模式 (N=4):        Ring模式 (N=4):
A ←→ B,C,D            A ←→ B,C,D             A → B → C → D → A
B ←→ C,D              B,C,D → A              
C ←→ D                                       

Pair模式 (N=4):        Opposite模式 (N=4):
A ←→ B                A ←→ D
C ←→ D                B ←→ C
```

## 💡 双向测试功能

ParaPerf支持iperf3的双向测试功能，可以同时测试上行和下行带宽：

### 基本用法

```bash
# 启用双向测试
./paraperf.sh -u admin -p password -f hosts.txt -b

# 双向全连接测试
./paraperf.sh -u admin -p password -f hosts.txt -m full -b

# 双向测试结果CSV输出
./paraperf.sh -u admin -p password -f hosts.txt -b -o csv
```

### 双向测试输出示例

```
ID   服务器  网卡 客户端  网卡 服务器IP     客户端IP     上行带宽     下行带宽     延迟
1    server01 eth0 server02 eth0 192.168.1.10 192.168.1.11 945.67 Mbps  923.45 Mbps  0.234 ms
2    server01 eth0 server03 eth0 192.168.1.10 192.168.1.12 934.21 Mbps  912.78 Mbps  0.287 ms
```

## 🎛️ 高级配置

### 性能调优

```bash
# 25G网络推荐配置
./paraperf.sh -u admin -p password -f hosts.txt -j 4 -d 30 -b

# 100G网络高性能测试
./paraperf.sh -u admin -p password -f hosts.txt -j 8 -d 60 -c 3

# UDP协议测试
./paraperf.sh -u admin -p password -f hosts.txt -t udp -b
```

### 线程数配置指南

| 网络带宽 | 推荐线程数 | 说明 |
|----------|------------|------|
| 1G | 1 | 单线程足够 |
| 10G | 2-4 | 充分利用带宽 |
| 25G | 4-8 | 推荐配置 |
| 40G+ | 8-16 | 高性能网络 |

### 参数完整列表

```bash
./paraperf.sh [选项]

必需参数:
  -u, --username USERNAME     SSH连接用户名
  -p, --password PASSWORD     SSH连接密码
  -f, --hostfile FILE         主机列表文件

可选参数:
  -m, --mode MODE             配对模式 [full|ring|star|pair|opposite] (默认: full)
  -c, --concurrent NUM        并发测试数量 (默认: 5)
  -d, --duration SECONDS      每次测试持续时间 (默认: 10)
  -j, --threads NUM           iperf3并行线程数 (默认: 1, 范围: 1-128)
  -P, --port PORT             iperf3端口 (默认: 5201)
  -t, --protocol PROTO        协议类型 [tcp|udp] (默认: tcp)
  -o, --output FORMAT         输出格式 [table|json|csv] (默认: table)
  -b, --bidirectional         启用双向测试模式
  -v, --verbose               详细输出
  -n, --dry-run               试运行模式 (不执行实际测试)
  -F, --force-install         强制重新安装iperf3
  -h, --help                  显示帮助信息
```

## 📦 离线部署

### 准备离线安装包

```bash
# 在有网络的机器上执行
./prepare-iperf3-offline.sh

# 指定架构和版本
./prepare-iperf3-offline.sh -a amd64 -v 22.04

# 强制重新下载
./prepare-iperf3-offline.sh -f
```

### 离线安装

```bash
# 1. 将paraperf-offline目录复制到目标主机
scp -r paraperf-offline/ user@target-host:/tmp/

# 2. 在目标主机上安装
cd /tmp/paraperf-offline
./install.sh

# 3. 验证安装
iperf3 --version
```

## 📊 输出格式

### 表格格式（默认）
```
ID   服务器    网卡   客户端    网卡   服务器IP      客户端IP      带宽          延迟
1    server01  eth0   server02  eth0   192.168.1.10  192.168.1.11  945.67 Mbps   0.234 ms
```

### JSON格式
```json
{
  "test_info": {
    "timestamp": "2024-01-15T10:30:00Z",
    "pairing_mode": "full",
    "protocol": "tcp",
    "duration": 10,
    "bidirectional": true
  },
  "results": [
    {
      "test_id": 1,
      "server": "192.168.1.10",
      "client": "192.168.1.11",
      "bandwidth_forward": 945.67,
      "bandwidth_reverse": 923.45,
      "unit": "Mbps",
      "rtt": 0.234,
      "status": "SUCCESS"
    }
  ]
}
```

### CSV格式
```csv
test_id,server_ip,client_ip,bandwidth_forward,bandwidth_reverse,rtt,status
1,192.168.1.10,192.168.1.11,945.67,923.45,0.234,SUCCESS
```

## 🔧 故障排除

### 常见问题

#### 1. SSH连接失败
```bash
# 检查SSH连通性
ssh -o ConnectTimeout=10 user@host

# 常见解决方案：
- 验证用户名和密码
- 检查目标主机SSH服务状态
- 确认网络连通性
- 检查防火墙设置
```

#### 2. iperf3安装失败
```bash
# 手动安装iperf3
sudo apt-get update
sudo apt-get install -y iperf3 jq sshpass bc

# 或使用离线包
cd paraperf-offline
./install.sh
```

#### 3. 权限不足
```bash
# 检查sudo权限
sudo -l

# 确保用户在sudoers文件中
sudo usermod -aG sudo username
```

#### 4. 端口占用
```bash
# 检查端口使用情况
netstat -tlnp | grep 5201

# 停止占用进程
sudo pkill -f iperf3

# 或使用其他端口
./paraperf.sh -u user -p pass -f hosts.txt -P 5202
```

#### 5. 测试结果异常

**带宽过低**：
- 检查网络配置和网卡驱动
- 增加并行线程数 (`-j 4`)
- 检查网络拥塞情况

**延迟过高**：
- 检查网络路由
- 验证交换机配置
- 排查网络设备负载

**测试失败**：
- 使用 `-v` 参数查看详细日志
- 检查 `.paraperf/logs/paraperf.log`
- 验证主机间连通性

### 日志查看

```bash
# 查看主日志
cat .paraperf/logs/paraperf.log

# 查看详细输出
./paraperf.sh -u user -p pass -f hosts.txt -v

# 试运行模式调试
./paraperf.sh -u user -p pass -f hosts.txt -n
```

## 📈 最佳实践

### 1. 测试策略
- **初次测试**: 使用ring模式快速验证连通性
- **性能基线**: 使用pair模式建立性能基线
- **全面评估**: 使用full模式进行完整性能测试
- **瓶颈分析**: 使用star模式检测中心节点性能

### 2. 参数调优
- **高速网络**: 使用多线程 (`-j 4-8`) 充分利用带宽
- **生产环境**: 适当延长测试时间 (`-d 30-60`) 获得稳定结果
- **大规模集群**: 限制并发数 (`-c 2-3`) 避免过载

### 3. 数据分析
- 使用CSV格式导出数据进行深度分析
- 关注双向测试的带宽不对称性
- 监控延迟抖动和重传率

## 🤝 贡献指南

我们欢迎各种形式的贡献！

### 报告问题
- 使用GitHub Issues报告bugs
- 提供详细的环境信息和日志
- 包含重现步骤

### 功能请求
- 提交功能请求前请先搜索已有issues
- 详细描述需求和使用场景
- 欢迎提供设计思路

### 代码贡献
1. Fork本项目
2. 创建特性分支 (`git checkout -b feature/AmazingFeature`)
3. 提交更改 (`git commit -m 'Add some AmazingFeature'`)
4. 推送到分支 (`git push origin feature/AmazingFeature`)
5. 打开Pull Request

## 📄 许可证

本项目基于MIT许可证开源 - 查看 [LICENSE](LICENSE) 文件了解详情。

## 🏆 致谢

- 感谢 [iperf3](https://github.com/esnet/iperf) 项目提供强大的网络测试核心
- 感谢所有贡献者和用户的反馈

## 📞 支持

- 📧 问题反馈: [GitHub Issues](https://github.com/your-repo/paraperf/issues)
- 💬 讨论交流: [GitHub Discussions](https://github.com/your-repo/paraperf/discussions)
- 📖 文档更新: 欢迎提交文档改进

---

**ParaPerf** - 让网络性能测试更简单、更强大！ 🚀
