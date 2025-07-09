# IB LinkInfo Parser

**作者**: VincentWu@zhengytech.com

InfiniBand链路信息解析工具，用于分析IB网络拓扑、检测Down状态的端口并生成统计报告。

## 功能特性

- 🔍 **自动检测Down端口**：快速识别网络中断开的连接
- 📊 **分组统计分析**：按设备组进行精细化统计
- 📁 **多种数据源**：支持实时查询和文件导入
- 📋 **CSV报告导出**：生成详细的Excel兼容报告
- ⚙️ **灵活配置**：支持自定义设备分组和端口范围

## 快速开始

### 编译

```bash
# 本地编译
go build -o ibpdc ibportdowncheck.go

# 交叉编译到Linux
GOOS=linux GOARCH=amd64 go build -o ibpdc ibportdowncheck.go
```

### 基本用法

```bash
# 使用默认CA (mlx5_0)
./ibpdc -c devices.conf -g leaf1-10

# 指定特定CA
./ibpdc -C mlx5_4 -c devices.conf -g spine1-3

# 从文件读取数据
./ibpdc -f iblinkinfo_output.txt -c devices.conf -g pod

# 查看帮助
./ibpdc --help
```

## 命令行参数

| 参数 | 长格式 | 说明 | 示例 |
|------|--------|------|------|
| `-C` | | CA名称 | `-C mlx5_4` |
| `-c` | `--config` | 配置文件路径 | `-c devices.conf` |
| `-g` | `--groups` | 指定查询组名 | `-g "leaf1-10 spine1-3"` |
| `-f` | `--file` | 从文件读取数据 | `-f output.txt` |
| `-o` | `--output` | 输出文件前缀 | `-o my_report` |
| `-h` | `--help` | 显示帮助信息 | |
| | `--no-down-report` | 不生成Down状态报告 | |
| | `--show-excluded` | 显示被排除的连接 | |

## 配置文件格式

配置文件采用类似Ansible hosts的格式，支持设备分组和端口范围定义：

```ini
# 叶子交换机组 (端口1-24)
[leaf1-10:1-24]
0xa088c20300579618
0xa088c20300579620
0xa088c20300579628

# 脊柱交换机组 (端口1-36) 
[spine1-3:1-36]
0xa088c20300579630
0xa088c20300579638
0xa088c20300579640

# 特殊设备 (端口1-15)
[spine4:1-15]
0xa088c20300579648

# 父组定义
[pod:children]
leaf1-10
spine1-3
spine4
```

### 配置语法说明

- `[组名:端口范围]`：定义设备组及其端口范围
- `[组名:children]`：定义父组，包含多个子组
- `0x...`：设备GUID（小写）
- `#`：注释行

## 输出文件

运行后会生成以下文件：

### 主要输出
- `ib_linkinfo_[CA/文件名]_[时间戳]_[组名].csv` - 主要数据文件
- `ib_linkinfo_[CA/文件名]_[时间戳]_[组名]_down.csv` - Down状态统计

### 可选输出
- `*_excluded.csv` - 被排除的连接（使用`--show-excluded`）

## 使用场景

### 1. 日常巡检
```bash
# 检查特定组的连接状态
./ibpdc -C mlx5_4 -c network.conf -g leaf1-10
```

### 2. 故障排查
```bash
# 分析历史数据
./ibpdc -f troubleshoot_data.txt -c network.conf -g pod --show-excluded
```

### 3. 批量检查
```bash
# 检查所有组的状态
./ibpdc -C mlx5_4 -c network.conf
```

## 统计信息示例

```
=== 总体统计信息 ===
  总连接数：240
  正常连接：239
  Down连接：1
  Down连接占比：0.4%

=== 按组统计信息 ===
  [leaf1-10] (端口范围: 1-24):
    总连接: 240, 正常: 239, Down: 1
      0xa088c20300579618 Storage-Leaf06: 端口 23
```

## CSV报告格式

生成的CSV文件包含以下字段：
- Source_GUID, Source_Name, Source_LID, Source_Port
- Connection_Type, Speed, Status
- Target_GUID, Target_LID, Target_Port, Target_Name
- Comment, Group

## 注意事项

⚠️ **重要提醒**：
- `-C` 和 `-f` 参数不能同时使用
- 未指定CA时默认使用 `mlx5_0`
- 组名可以用空格分隔指定多个：`-g "group1 group2"`
- 确保有执行`iblinkinfo`命令的权限

## 故障排除

### 常见问题

1. **权限不足**
   ```bash
   sudo ./ibpdc -C mlx5_4 -c devices.conf -g leaf1-10
   ```

2. **CA不存在**
   ```bash
   # 查看可用的CA
   ibstat
   ```

3. **配置文件格式错误**
   - 检查GUID格式（必须以0x开头）
   - 确认端口范围格式正确
   - 验证组名不包含特殊字符

## 性能优化

- 使用配置文件过滤可以显著提升处理速度
- 大型网络建议按组分批检查
- 定期清理历史报告文件

---

**技术支持**: VincentWu@zhengytech.com
