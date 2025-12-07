# ck-bench

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/shell-bash-green.svg)](https://www.gnu.org/software/bash/)

**ck-bench** is a GPU RDMA network benchmark automation tool that wraps NVIDIA HPC-X ClusterKit functionality, designed for high-performance computing clusters with GPU servers.

## Features

### Core Capabilities
- 🚀 **Auto-detect GPU-associated HCAs** - Parse `nvidia-smi topo -m` to identify GPUDirect RDMA network adapters
- 📊 **Rail-by-rail testing** - Test each HCA separately for per-rail diagnostics
- 🎨 **Colorized matrix display** - Real-time bandwidth/latency visualization with 5-level color coding
- 🔄 **Loop testing** - Stress test with automatic node reboot or optical module reset
- 🗺️ **GPU-NIC-Switch topology** - Map GPU-to-NIC-to-Switch connections for network diagnostics
- 📈 **CSV export** - Export results for data analysis
- 🔍 **Historical results viewer** - Review past test results with colorized matrix

### Multi-Environment Support
- **macOS** - Control from Mac via CPU server jump host
- **CPU Server** - Direct SSH to GPU servers
- **GPU Server** - Local execution on GPU nodes

### Advanced Features
- GPUDirect RDMA latency and bandwidth testing
- ConnectX-7 optimization (4 QPs)
- NUMA binding for latency-sensitive workloads
- Auto-remove bad nodes during loop testing
- Health checks (SSH + IB + GPU + PCIe)
- Quiet mode for script integration

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Usage](#usage)
  - [Basic Testing](#basic-testing)
  - [Rail-by-Rail Testing](#rail-by-rail-testing)
  - [Loop Testing](#loop-testing)
  - [Topology Mapping](#topology-mapping)
  - [Viewing Historical Results](#viewing-historical-results)
- [Directory Structure](#directory-structure)
- [Network Architecture](#network-architecture)
- [Colorized Matrix Display](#colorized-matrix-display)
- [Parameters Reference](#parameters-reference)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Installation

### Prerequisites

- **NVIDIA HPC-X** installed on GPU servers (default: `/tmp/hpcx-v2.21.3-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64`)
- **NVIDIA GPU** with GPUDirect RDMA support
- **Mellanox/NVIDIA InfiniBand HCAs** (e.g., ConnectX-7)
- **SSH access** to GPU servers (passwordless SSH recommended)
- **Bash 4.0+** on the control node

### Setup

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/ck-bench.git
   cd ck-bench
   ```

2. Create a hostfile with your GPU server hostnames/IPs:
   ```bash
   cat > hostfile.txt <<EOF
   GPU-1
   GPU-2
   GPU-3
   EOF
   ```

3. Make the script executable:
   ```bash
   chmod +x ck-bench.sh
   ```

4. Verify HPC-X path (optional):
   ```bash
   # If HPC-X is in a different location, set it:
   export HPCX_HOME=/path/to/hpcx
   # Or use -r flag when running
   ```

---

## Quick Start

### Run a basic GPUDirect RDMA test:
```bash
./ck-bench.sh --auto-hca -G -cx7
```

### Test each HCA separately (rail-by-rail):
```bash
./ck-bench.sh --auto-hca --rbr -G -cx7
```

### View historical results:
```bash
./ck-bench.sh --view results/rbr_20251207_120000_GPU-1-GPU-9/
```

---

## Usage

### Basic Testing

Test all auto-detected HCAs together:
```bash
./ck-bench.sh --auto-hca -G -cx7
```

Specify HCAs manually:
```bash
./ck-bench.sh -d "mlx5_0:1,mlx5_1:1" -G -cx7
```

Run a 3-minute stress test:
```bash
./ck-bench.sh --auto-hca -G -cx7 -z 3
```

### Rail-by-Rail Testing

Test each HCA separately with summary report:
```bash
./ck-bench.sh --auto-hca --rbr -G -cx7
```

**Features:**
- Tests each HCA individually (e.g., mlx5_0, mlx5_1, ...)
- Displays colorized matrix immediately after each rail completes
- Generates `summary.csv` with latency/bandwidth for each rail
- Saves results to separate subdirectories

**Output structure:**
```
results/rbr_20251207_120000_GPU-1-GPU-9/
├── summary.csv
├── topology.txt (if --check-topology used)
├── mlx5_0/
│   └── 20251207_120015/
│       ├── bandwidth.txt
│       ├── latency.txt
│       └── ...
├── mlx5_1/
│   └── 20251207_120145/
│       ├── bandwidth.txt
│       └── latency.txt
...
```

With CSV output:
```bash
./ck-bench.sh --auto-hca --rbr -G -cx7 --output-csv
```

Quiet mode (only show summary):
```bash
./ck-bench.sh --auto-hca --rbr -G -cx7 -q
```

### Loop Testing

Run 5 rounds of rail-by-rail tests:
```bash
./ck-bench.sh --auto-hca --rbr -G -cx7 --loop-test 5
```

Loop with automatic node reboot between rounds:
```bash
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot
```

Loop with optical module reset (no server reboot):
```bash
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop-test 5 --reset-optics
```

Auto-remove bad nodes during loop testing:
```bash
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 10 --auto-reboot --auto-remove-bad-nodes
```

### Topology Mapping

Check GPU-NIC-Switch topology:
```bash
./ck-bench.sh --check-topology
```

**Example output:**
```
==========================================
GPU-NIC-Switch Topology Mapping
==========================================
Host            GPU    NIC        Port       Switch
----------------------------------------------------------------------
GPU-1           GPU0   mlx5_0     Port 33    Compute-SU1-Leaf01-A03-40U
GPU-1           GPU1   mlx5_1     Port 33    Compute-SU1-Leaf02-A03-38U
GPU-1           GPU2   mlx5_2     Port 33    Compute-SU1-Leaf03-A03-40U
...
==========================================
```

Combine topology check with rail-by-rail test:
```bash
./ck-bench.sh --auto-hca --rbr -G -cx7 --check-topology
```

### Viewing Historical Results

View all rails in a session:
```bash
./ck-bench.sh --view results/rbr_20251207_120000_GPU-1-GPU-9/
```

View a specific rail:
```bash
./ck-bench.sh --view results/rbr_20251207_120000_GPU-1-GPU-9/mlx5_0/
```

View a specific result file:
```bash
./ck-bench.sh --view results/rbr_20251207_120000_GPU-1-GPU-9/mlx5_0/20251207_120015/bandwidth.txt
```

**Features:**
- Displays colorized matrix with 5-level color coding
- Works with any historical result directory
- Supports both rail-by-rail and normal result structures
- Fast display with memory buffering (no line-by-line flickering)

---

## Directory Structure

```
clusterkit/
├── ck-bench.sh          # Main benchmark script
├── hostfile.txt         # Test node list
├── README.md            # This file
├── CLAUDE.md            # Development documentation
├── results/             # Test results directory
│   ├── rbr_<timestamp>_<host-range>/  # Rail-by-rail results
│   │   ├── summary.csv                # Benchmark summary
│   │   ├── topology.txt               # GPU-NIC-Switch mapping (optional)
│   │   ├── mlx5_0/                    # Per-rail results
│   │   │   └── <timestamp>/
│   │   │       ├── bandwidth.txt
│   │   │       ├── latency.txt
│   │   │       ├── bandwidth.json
│   │   │       └── latency.json
│   │   ├── mlx5_1/
│   │   └── ...
│   └── topology_<timestamp>.txt       # Standalone topology check
├── bin/                 # ClusterKit binaries (copied from HPCX)
├── lib/                 # ClusterKit libraries
└── share/               # ClusterKit shared files
```

---

## Network Architecture

### Typical Setup

- **CPU Server**: `10.0.1.2` (jump host / management node)
  - Script location: `/mnt/sdb/x/clusterkit/`
- **GPU Servers**: `10.0.10.x` (compute nodes, specified in `hostfile.txt`)
  - Script location: `/tmp/clusterkit/`
- **Default HPC-X path**: `/tmp/hpcx-v2.21.3-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64`

### Runtime Environment Detection

The script auto-detects the runtime environment:
1. Has `nvidia-smi` and can execute → **gpu_server** (local execution)
2. macOS system → **mac** (via CPU server jump)
3. Linux system → **cpu_server** (direct SSH to GPU server)

### GPU-HCA Auto-Detection

Parses `nvidia-smi topo -m` output to find NICs with PCIe direct connection (PIX topology) to GPUs:
- GPU0-GPU3 typically map to mlx5_0 - mlx5_3
- GPU4-GPU7 typically map to mlx5_6 - mlx5_9

---

## Colorized Matrix Display

### Bandwidth Matrix
- **Color Coding**: Displays bandwidth as a percentage of maximum value
- **5-level color scheme**:
  - 🟢 **Green** (≥ 0.98) - Excellent performance
  - 🔵 **Cyan** (≥ 0.96) - Good performance
  - 🟡 **Yellow** (≥ 0.94) - Acceptable performance
  - 🟣 **Magenta** (≥ 0.92) - Degraded performance
  - 🔴 **Red** (< 0.92) - Poor performance

**Example:**
```
Color Legend:  >= 0.98   >= 0.96   >= 0.94   >= 0.92   < 0.92

    Rank:                0     1     2     3     4     5     6     7
       0 (GPU-1):       0.00  0.98  0.97  0.98  0.97  0.98  0.97  0.98
       1 (GPU-2):       0.98  0.00  0.98  0.97  0.98  0.97  0.98  0.97
       2 (GPU-3):       0.97  0.98  0.00  0.98  0.97  0.98  0.97  0.98
```

### Latency Matrix
- **Color Coding**: Based on absolute latency values
- **5-level color scheme**:
  - 🟢 **Green** (≤ 2.0 μs) - Excellent latency
  - 🔵 **Cyan** (≤ 2.5 μs) - Good latency
  - 🟡 **Yellow** (≤ 3.0 μs) - Acceptable latency
  - 🟣 **Magenta** (≤ 4.5 μs) - Elevated latency
  - 🔴 **Red** (> 4.5 μs) - High latency

**Example:**
```
Color Legend:  <= 2.0us   <= 2.5us   <= 3.0us   <= 4.5us   > 4.5us

    Rank:                 0      1      2      3      4      5      6      7
       0 (GPU-1):       0.00   1.79   1.80   1.79   1.80   1.79   1.80   1.79
       1 (GPU-2):       1.79   0.00   1.80   1.79   1.80   1.79   1.80   1.79
```

### Display Features
- **Real-time display**: Shows matrix immediately after each rail test completes
- **Memory buffering**: All output is cached and displayed at once for smooth viewing
- **No flickering**: Optimized for large matrices with instant display

---

## Parameters Reference

### Compatible with clusterkit.sh
| Parameter | Description |
|-----------|-------------|
| `-f, --hostfile <file>` | Specify hostfile (default: `hostfile.txt`) |
| `-r, --hpcx_dir <path>` | Specify HPC-X installation path |
| `-d, --hca_list <list>` | Specify HCA list (e.g., `"mlx5_0:1,mlx5_1:1"`) |
| `-p, --ppn <number>` | Number of processes per node (default: 1) |
| `--auto-hca` | Auto-detect GPU-associated compute network HCAs |
| `-G, --gpudirect` | Enable GPUDirect RDMA |
| `-cx7, --connectx-7` | Enable ConnectX-7 mode (4 QPs) |
| `-z, --traffic <minutes>` | Run stress test for specified minutes |

### Additional ck-bench Options
| Parameter | Description |
|-----------|-------------|
| `--rail-by-rail, --rbr` | Test each HCA separately and generate summary report |
| `--check-topology` | Show GPU-NIC-Switch topology mapping |
| `--Ca <device>` | Specify HCA device for topology query (default: `mlx5_0`) |
| `--output-csv` | Output results in CSV format (rail-by-rail mode) |
| `-q, --quiet` | Quiet mode, only show final summary |
| `--loop <count>` | Loop stress test N times with node reboot between rounds |
| `--loop-test <count>` | Loop test mode (skip reboot verification, for testing) |
| `--auto-reboot` | Auto reboot nodes between loop rounds (randomized order) |
| `--reboot-interval <sec>` | Interval between rebooting each node (default: 1 second) |
| `--reboot-method <method>` | Reboot method: `"reboot"` (soft, default) or `"ipmi"` (power cycle) |
| `--reset-optics` | Reset optical modules instead of rebooting |
| `--optics-interval <sec>` | Wait time between resetting each HCA's optics (default: 2 seconds) |
| `--auto-remove-bad-nodes` | Auto remove bad nodes during loop testing |
| `--min-nodes <count>` | Minimum nodes required to continue testing (default: 2) |
| `--auto-numa` | Auto NUMA binding based on HCA's NUMA node |
| `--numa-policy <policy>` | NUMA policy: `auto`, `none`, `node0`, `node1` (default: `auto`) |
| `--view <path>` | View historical results with colorized matrix |
| `--check-health-only` | Only run health checks, skip benchmark |
| `-h, --help` | Show help message |

### Environment Variables
| Variable | Description |
|----------|-------------|
| `HPCX_HOME` | HPC-X installation path |
| `CK_FORCE_MODE` | Force runtime mode: `cpu_server`, `gpu_server`, or `mac` |
| `CK_CPU_SERVER` | CPU server IP for Mac mode (default: `10.0.1.2`) |
| `CK_CPU_USER` | CPU server user for Mac mode (default: `root`) |
| `CK_REMOTE_DIR` | Remote directory for Mac mode (default: `/mnt/sdb/x/clusterkit`) |

---

## Examples

### Basic Testing
```bash
# Auto-detect HCAs, test all together
./ck-bench.sh --auto-hca -G -cx7

# 2 processes per node
./ck-bench.sh --auto-hca -G -cx7 -p 2

# Manual HCA specification
./ck-bench.sh -d "mlx5_0:1,mlx5_1:1" -G -cx7

# 3-minute stress test
./ck-bench.sh --auto-hca -G -cx7 -z 3
```

### Rail-by-Rail Testing
```bash
# Basic rail-by-rail
./ck-bench.sh --auto-hca --rbr -G -cx7

# With CSV output
./ck-bench.sh --rbr -G -cx7 --output-csv

# Quiet mode
./ck-bench.sh --rbr -G -cx7 -q

# With topology check
./ck-bench.sh --rbr -G -cx7 --check-topology
```

### NUMA Binding
```bash
# Rail-by-rail with auto NUMA binding (reduces latency)
./ck-bench.sh --rbr -G -cx7 --auto-numa

# Single HCA with NUMA binding
./ck-bench.sh -d mlx5_0:1 -G -cx7 --auto-numa
```

### Loop Testing
```bash
# Test mode: 5 rounds without reboot
./ck-bench.sh --auto-hca -G -cx7 -z 3 --loop-test 5

# Production: 5 rounds with soft reboot (1s interval)
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot

# With custom reboot interval (2 seconds)
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot --reboot-interval 2

# IPMI power cycle
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot --reboot-method ipmi

# Reset optical modules (no server reboot)
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop-test 5 --reset-optics

# Custom optics reset interval
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop-test 5 --reset-optics --optics-interval 5

# Auto-remove bad nodes
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 10 --auto-reboot --auto-remove-bad-nodes

# Minimum 4 nodes required
./ck-bench.sh --auto-hca -G -cx7 -z 30 --loop 10 --auto-reboot --auto-remove-bad-nodes --min-nodes 4

# Rail-by-rail with loop testing (each round does full RBR)
./ck-bench.sh --auto-hca --rbr -G -cx7 --loop-test 3
```

### Topology Mapping
```bash
# Check topology only
./ck-bench.sh --check-topology

# Use specific HCA for SM query
./ck-bench.sh --check-topology --Ca mlx5_1

# Check topology with rail-by-rail test
./ck-bench.sh --rbr -G -cx7 --check-topology
```

### Viewing Historical Results
```bash
# View all rails in a session directory
./ck-bench.sh --view results/rbr_20251207_120000_GPU-1-GPU-9/

# View specific rail
./ck-bench.sh --view results/rbr_20251207_120000_GPU-1-GPU-9/mlx5_0/

# View specific bandwidth file
./ck-bench.sh --view results/20251207_120000/bandwidth.txt

# View specific latency file
./ck-bench.sh --view results/20251207_120000/latency.txt
```

### Environment Control
```bash
# Force CPU server mode (useful when running on GPU node as control node)
CK_FORCE_MODE=cpu_server ./ck-bench.sh --auto-hca -G -cx7

# Custom CPU server
CK_CPU_SERVER=192.168.1.100 ./ck-bench.sh --auto-hca -G -cx7

# Custom HPCX path
./ck-bench.sh -r /opt/hpcx --auto-hca -G -cx7
# or
HPCX_HOME=/opt/hpcx ./ck-bench.sh --auto-hca -G -cx7
```

---

## Troubleshooting

### HCA auto-detection fails
```bash
# Check if nvidia-smi is available
nvidia-smi topo -m

# Manually specify HCAs instead
./ck-bench.sh -d "mlx5_0:1,mlx5_1:1" -G -cx7
```

### SSH connection issues
```bash
# Test SSH connectivity
ssh GPU-1 hostname

# Setup passwordless SSH
ssh-copy-id GPU-1
```

### HPC-X not found
```bash
# Check HPC-X location
ls -la /tmp/hpcx*

# Specify custom path
./ck-bench.sh -r /path/to/hpcx --auto-hca -G -cx7
```

### Results not displaying colors
```bash
# Ensure terminal supports ANSI colors
echo -e "\033[42m\033[30m Green \033[0m"

# Try a different terminal emulator
```

### Topology check failures
```bash
# Error: "ROUTE_ERR" or "NO_LID"
# - Network routing issue or SM (Subnet Manager) not responding
# - Check InfiniBand fabric health
ibstat
ibstatus

# Try different HCA device for SM query
./ck-bench.sh --check-topology --Ca mlx5_1
```

### Permission denied errors
```bash
# Make script executable
chmod +x ck-bench.sh

# Check hostfile permissions
chmod 644 hostfile.txt
```

---

## Parameter Restrictions

| Combination | Allowed | Reason |
|-------------|---------|--------|
| `--rbr` + `-z` | ❌ No | Stress test needs all HCAs together; rail-by-rail is for quick diagnostics |
| `--rbr` + `--loop-test` | ✅ Yes | Each loop round executes full rail-by-rail test |
| `--rbr` + `--check-topology` | ✅ Yes | Topology saved with benchmark results |
| `--rbr` + `--output-csv` | ✅ Yes | CSV output to stdout and saved to file |
| `--rbr` + `-q` | ✅ Yes | Quiet mode shows only final summary |

---

## Development Notes

1. awk scripts must be compatible with macOS (avoid gawk-specific functions like `asorti`)
2. SSH jump path: Mac → CPU server → GPU server
3. hostfile needs to be uploaded from local to GPU server's HPCX_HOME directory
4. Test results are downloaded from GPU server to CPU server for storage
5. The script is portable - only needs `ck-bench.sh` and `hostfile.txt` to run on any node
6. Use `ssh -n` in while loops to prevent stdin consumption
7. Use `timeout` command for network operations to prevent hanging
8. `sminfo` and `ibtracert` must use `--Ca` to specify HCA device in multi-subnet environments
9. Topology collection uses batched parallel execution (BATCH_SIZE=10) to avoid overloading IB SM

---

## Contributing

Contributions are welcome! Please follow these guidelines:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature`)
3. Test your changes on a real GPU cluster
4. Commit your changes (`git commit -am 'Add new feature'`)
5. Push to the branch (`git push origin feature/your-feature`)
6. Create a Pull Request

### Code Style
- Follow existing bash scripting conventions
- Add comments for complex logic
- Update README.md for new features
- Ensure macOS compatibility (avoid GNU-specific extensions)

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

## Author

**Vincent Wu**
Email: [Vincentwu@zhengytech.com](mailto:Vincentwu@zhengytech.com)

---

## Acknowledgments

- Built on top of NVIDIA HPC-X ClusterKit
- Inspired by real-world GPU cluster management challenges
- Thanks to the HPC and GPU computing community

---

## See Also

- [NVIDIA HPC-X Documentation](https://developer.nvidia.com/networking/hpc-x)
- [NVIDIA GPUDirect RDMA](https://docs.nvidia.com/cuda/gpudirect-rdma/)
- [InfiniBand Architecture](https://www.infinibandta.org/)

---

**Star ⭐ this repository if you find it useful!**

