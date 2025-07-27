# ParaPerf 简易安装使用指南

ParaPerf 是一个基于 iperf3 的并行网络性能测试工具，专为集群带宽测试设计。

## 快速安装

### 方法一：在线安装（推荐）
```bash
# 下载 ParaPerf
git clone https://github.com/wuchanghui5220/pot.git
cd pot/paraperf

# 直接运行测试（会自动安装依赖）
./paraperf.sh -u username -p password -f hosts.txt
```

### 方法二：离线安装
```bash
# 1. 在有网络的机器上准备离线包
./prepare-iperf3-offline.sh

# 2. 将 paraperf-offline 目录复制到目标主机

# 3. 在目标主机上安装依赖
cd paraperf-offline
./install.sh
```

## 基本配置

### 1. 准备主机列表文件
创建 `hosts.txt` 文件，每行一个IP地址：
```
192.168.1.10
192.168.1.11
192.168.1.12
192.168.1.13
```

### 2. 确保SSH连通性
```bash
# 测试SSH连接
ssh username@192.168.1.10

# 确保用户具有sudo权限
sudo -l
```

## 基本使用

### 1. 全连接测试（默认）
```bash
./paraperf.sh -u admin -p mypassword -f hosts.txt
```

### 2. 环形测试
```bash
./paraperf.sh -u admin -p mypassword -f hosts.txt -m ring
```

### 3. 星形测试（所有节点连接第一个节点）
```bash
./paraperf.sh -u admin -p mypassword -f hosts.txt -m star
```

### 4. 对等测试（相邻节点配对）
```bash
./paraperf.sh -u admin -p mypassword -f hosts.txt -m pair
```

## 高级选项

### 测试参数调整
```bash
# 设置测试时长为30秒
./paraperf.sh -u admin -p password -f hosts.txt -d 30

# 设置并发连接数为5
./paraperf.sh -u admin -p password -f hosts.txt -c 5

# UDP协议测试
./paraperf.sh -u admin -p password -f hosts.txt -t udp
```

### 输出格式
```bash
# JSON格式输出
./paraperf.sh -u admin -p password -f hosts.txt -o json

# CSV格式输出
./paraperf.sh -u admin -p password -f hosts.txt -o csv

# 表格格式输出（默认）
./paraperf.sh -u admin -p password -f hosts.txt -o table
```

### 调试和验证
```bash
# 试运行模式（不执行实际测试）
./paraperf.sh -u admin -p password -f hosts.txt -n

# 详细输出模式
./paraperf.sh -u admin -p password -f hosts.txt -v

# 强制重新安装iperf3
./paraperf.sh -u admin -p password -f hosts.txt -F
```

## 测试模式说明

| 模式 | 说明 | 适用场景 |
|------|------|----------|
| full | 全连接测试，每个节点都与其他所有节点测试 | 全面性能评估 |
| ring | 环形测试，节点按顺序连接成环 | 基础连通性测试 |
| star | 星形测试，所有节点连接到第一个节点 | 中心节点性能测试 |
| pair | 对等测试，相邻节点两两配对 | 快速性能抽样 |
| opposite | 对称测试，首尾配对测试 | 整体网络性能压测 |
## 常见问题

### 1. SSH连接失败
- 检查用户名密码是否正确
- 确保目标主机SSH服务正常
- 验证网络连通性

### 2. 权限不足
- 确保用户具有sudo权限
- 检查目标主机的sudo配置

### 3. iperf3安装失败
```bash
# 手动安装iperf3
sudo apt-get update
sudo apt-get install -y iperf3

# 或使用离线包
cd paraperf-offline
./install.sh
```

### 4. 端口占用
- 默认使用端口5201
- 确保防火墙允许该端口通信
- 检查端口是否被占用：`netstat -tlnp | grep 5201`

## 结果解读

### 输出指标说明
- **Bandwidth**: 带宽速度（Mbits/sec 或 Gbits/sec）
- **Transfer**: 传输数据量
- **Retransmits**: 重传次数（TCP）
- **Cwnd**: 拥塞窗口大小（TCP）

### 性能分析
- 带宽越高越好
- 重传次数越少越好
- 延迟和抖动越小越好

## 日志和故障排除

### 查看详细日志
```bash
# 查看主日志
cat .paraperf/logs/paraperf.log

# 查看临时文件
ls .paraperf/temp/
```

### 手动测试连通性
```bash
# 测试单个连接
iperf3 -c 192.168.1.10 -t 10

# 测试UDP
iperf3 -c 192.168.1.10 -u -t 10
```

## 示例完整命令

```bash
# 基础测试
./paraperf.sh -u admin -p mypass123 -f hosts.txt

# 生产环境测试
./paraperf.sh -u admin -p mypass123 -f hosts.txt -m full -d 60 -c 3 -o json -v

# 快速验证
./paraperf.sh -u admin -p mypass123 -f hosts.txt -m ring -d 10 -n
```

---

**系统要求**：Ubuntu 22.04.5+，具有sudo权限的用户账户
**网络要求**：测试主机间可互相访问，端口5201开放
