#!/bin/bash
#
# ck-bench.sh - ClusterKit GPU RDMA Network Benchmark Tool
#
# Author: Vincentwu@zhengytech.com
#
# Usage: ./ck-bench.sh [options]
#
# Features:
#   - Auto-detect GPU-associated compute network HCAs
#   - Run RDMA latency and bandwidth tests
#   - Support GPUDirect RDMA and stress testing
#   - Rail-by-rail testing for per-HCA diagnostics
#   - CSV output for data analysis
#   - Topology check for troubleshooting
#
# Supported environments:
#   - Mac (via CPU server jump to GPU server)
#   - CPU server (direct SSH to GPU server)
#   - GPU server (local execution)
#

set -e

# ==================== Configuration ====================
# Local script directory
LOCAL_DIR="$(cd "$(dirname "$0")" && pwd)"

# CPU server configuration (for Mac mode only)
# Can be overridden by environment variables:
#   export CK_CPU_SERVER="192.168.1.100"
#   export CK_CPU_USER="admin"
#   export CK_REMOTE_DIR="/opt/clusterkit"
CPU_SERVER="${CK_CPU_SERVER:-10.0.1.2}"
CPU_SERVER_USER="${CK_CPU_USER:-root}"

# Remote script directory on CPU server (for Mac mode only)
REMOTE_DIR="${CK_REMOTE_DIR:-/mnt/sdb/x/clusterkit}"

# HPCX path (on GPU server) - can be overridden by -r option or HPCX_HOME env var
DEFAULT_HPCX_HOME="/tmp/hpcx-v2.21.3-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64"
HPCX_HOME="${HPCX_HOME:-$DEFAULT_HPCX_HOME}"

# ==================== Default Values ====================
HOSTFILE="hostfile.txt"
HCA_LIST=""
AUTO_HCA=0
RAIL_BY_RAIL=0
CHECK_TOPOLOGY=0
GPUDIRECT=""
CONNECTX7=""
TRAFFIC_TIME=""
PPN=""                 # Processes per node (empty = use clusterkit default)
EXTRA_ARGS=""
OUTPUT_CSV=0
QUIET_MODE=0
TOPO_CA_DEV="mlx5_0"  # Default HCA device for sminfo/ibtracert in topology check
CHECK_HEALTH_ONLY=0    # Health check only mode: 1=skip benchmark, 0=run benchmark
LOOP_COUNT=1           # Loop test count (default: 1, no loop)
LOOP_TEST_MODE=0       # Test mode: 1=skip reboot verification, 0=verify reboot
VIEW_RESULTS=""        # View historical results (directory or file path)
HEALTH_CHECK_TIMEOUT=900  # 15 minutes timeout for health check
HEALTH_CHECK_PARALLEL=64  # Max parallel health checks (0=unlimited)
AUTO_START_TIMEOUT=30  # 30 seconds auto-start timeout after health check
REBOOT_WAIT_TIME=180   # 3 minutes wait before checking (allow reboot to complete)
MAX_UPTIME_MINUTES=10  # Max uptime to consider as "rebooted" (10 minutes)
AUTO_REBOOT=0          # Auto reboot nodes between loop rounds (0=disabled, 1=enabled)
REBOOT_INTERVAL=1      # Interval between rebooting each node (seconds, default: 1)
REBOOT_METHOD="reboot" # Reboot method: "reboot" (soft) or "ipmi" (power cycle)
AUTO_REMOVE_BAD_NODES=0  # Auto remove bad nodes during loop testing (0=disabled, 1=enabled)
MIN_NODES=2             # Minimum nodes required to continue testing (default: 2)
RESET_OPTICS=0          # Reset optical modules instead of rebooting (0=disabled, 1=enabled)
OPTICS_RESET_INTERVAL=2 # Wait time between resetting each HCA's optics (seconds, default: 2)
AUTO_NUMA=0             # Auto NUMA binding based on HCA's NUMA node (0=disabled, 1=enabled)
NUMA_POLICY=""          # NUMA policy: auto, none, node0, node1 (empty = use auto if --auto-numa)

# Health check logging
HEALTH_LOG_FILE=""     # Will be set when starting each round
HEALTH_CSV_FILE=""     # Will be set in main loop

# ==================== Environment Detection ====================
# Detect runtime environment: mac, cpu_server, gpu_server
detect_environment() {
    # Check for nvidia-smi (GPU server)
    if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
        echo "gpu_server"
        return
    fi

    # Check for macOS
    if [[ "$(uname)" == "Darwin" ]]; then
        echo "mac"
        return
    fi

    # Linux without GPU = CPU server
    if [[ "$(uname)" == "Linux" ]]; then
        echo "cpu_server"
        return
    fi

    echo "unknown"
}

RUN_ENV=$(detect_environment)

# Can be overridden by environment variable (useful when running on GPU node as control node)
# Example: CK_FORCE_MODE=cpu_server ./ck-bench.sh ...
if [ -n "${CK_FORCE_MODE}" ]; then
    RUN_ENV="${CK_FORCE_MODE}"
fi

# ==================== Output Functions ====================
# Print message (respects quiet mode)
log() {
    if [ ${QUIET_MODE} -eq 0 ]; then
        echo "$@"
    fi
}

# Print message (always, even in quiet mode)
log_always() {
    echo "$@"
}

# Log to health check file (if enabled)
log_health() {
    if [ -n "${HEALTH_LOG_FILE}" ]; then
        echo "$@" >> "${HEALTH_LOG_FILE}"
    fi
}

# Log to both console and health check file
log_health_always() {
    log_always "$@"
    log_health "$@"
}

# Append to health check CSV
append_health_csv() {
    local timestamp="$1"
    local round="$2"
    local host="$3"
    local ssh="$4"
    local ib_active="$5"
    local gpu="$6"
    local uptime="$7"
    local pcie_speed="$8"
    local pcie_width="$9"
    local rx_err="${10}"
    local tx_err="${11}"
    local status="${12}"

    if [ -n "${HEALTH_CSV_FILE}" ]; then
        echo "${timestamp},${round},${host},${ssh},${ib_active},${gpu},${uptime},${pcie_speed},${pcie_width},${rx_err},${tx_err},${status}" >> "${HEALTH_CSV_FILE}"
    fi
}

# ==================== Function Definitions ====================
usage() {
    cat <<EOF
ck-bench.sh - ClusterKit GPU RDMA Network Benchmark Tool
Author: Vincentwu@zhengytech.com

Usage: $0 [options]

Options (compatible with clusterkit.sh):
  -f, --hostfile <file>       Specify hostfile (default: hostfile.txt)
  -r, --hpcx_dir <path>       Specify HPCX installation path (default: ${DEFAULT_HPCX_HOME})
  -d, --hca_list <list>       Specify HCA list (e.g., "mlx5_0:1" or "mlx5_0:1,mlx5_1:1")
  -p, --ppn <number>          Number of processes per node (default: 1)
  --auto-hca                  Auto-detect GPU-associated compute network HCAs
  --rail-by-rail, --rbr       Test each HCA separately and generate summary report
  -G, --gpudirect             Enable GPUDirect RDMA
  -cx7, --connectx-7          Enable ConnectX-7 mode (4 QPs)
  -z, --traffic <minutes>     Run stress test for specified minutes
  -h, --help                  Show this help message

Additional options:
  --check-topology            Show GPU-NIC-Switch topology mapping and exit
  --check-health-only         Only run health checks (SSH+IB+GPU+PCIe), skip benchmark
  --Ca <device>               Specify HCA device for topology query (default: mlx5_0)
  --output-csv                Output results in CSV format (rail-by-rail mode)
  -q, --quiet                 Quiet mode, only show final summary
  --loop <count>              Loop stress test N times with node reboot between rounds
  --loop-test <count>         Loop test mode (skip reboot verification, for testing)
  --auto-reboot               Auto reboot nodes between loop rounds (randomized order)
  --reboot-interval <sec>     Interval between rebooting each node (default: 1 second)
  --reboot-method <method>    Reboot method: "reboot" (soft, default) or "ipmi" (power cycle)
  --reset-optics              Reset optical modules instead of rebooting (use with --loop-test)
                              Requires either --auto-hca (auto-detect all HCAs) or --hca_list (specify HCAs)
  --optics-interval <sec>     Wait time between resetting each HCA's optics (default: 2 seconds)
  --auto-remove-bad-nodes     Auto remove bad nodes during loop testing (log to bad_nodes.log)
  --min-nodes <count>         Minimum nodes required to continue testing (default: 2)
  --auto-numa                 Auto NUMA binding based on HCA's NUMA node (recommended for rail-by-rail)
  --numa-policy <policy>      NUMA policy: auto (detect from HCA), none, node0, node1 (default: auto)
  --view <path>               View historical results with colorized matrix
                              <path> can be: directory (auto-find results) or file (bandwidth.txt/latency.txt)

HPCX path can also be set via HPCX_HOME environment variable.
Other clusterkit.sh options are passed through directly.

Runtime environment: auto-detected (current: ${RUN_ENV})
  - mac:        Via CPU server jump to GPU server
  - cpu_server: Direct SSH to GPU server
  - gpu_server: Local execution

Environment variables:
  CK_FORCE_MODE=cpu_server    Force CPU server mode (useful when running on GPU node as control node)
  CK_CPU_SERVER=10.0.1.2      CPU server IP for Mac mode (default: 10.0.1.2)
  CK_CPU_USER=root            CPU server user for Mac mode (default: root)
  CK_REMOTE_DIR=/path         Remote directory for Mac mode (default: /mnt/sdb/x/clusterkit)

Examples:
  # Basic testing
  $0 --auto-hca -G -cx7                           # Auto-detect HCAs, test all together
  $0 --auto-hca -G -cx7 -p 2                      # 2 processes per node
  $0 --auto-hca --rail-by-rail -G -cx7            # Test each rail separately
  $0 --rbr -G -cx7 --output-csv                   # Rail-by-rail with CSV output
  $0 --rbr -G -cx7 -q                             # Rail-by-rail quiet mode

  # NUMA binding (reduce latency for NUMA-aware testing)
  $0 --rbr -G -cx7 --auto-numa                    # Rail-by-rail with auto NUMA binding
  $0 -d mlx5_0:1 -G -cx7 --auto-numa              # Single HCA with NUMA binding
  $0 -d mlx5_4:1,mlx5_5:1 -G -cx7 --auto-numa --numa-policy node1  # Force NUMA node 1

  # Topology and health checks
  $0 --check-topology                             # Show topology mapping (default: mlx5_0)
  $0 --check-topology --Ca mlx5_1                 # Topology with specific HCA device
  $0 --check-health-only                          # Only run health checks (SSH+IB+GPU+PCIe)
  $0 --check-health-only --auto-hca               # Health check with auto-detected HCAs

  # Loop testing with manual reboot
  $0 --auto-hca -G -cx7 -z 60 --loop 10           # Loop 10 times (60 min each, manual reboot)
  $0 --auto-hca -G -cx7 -z 3 --loop-test 5        # Test mode: 5 rounds without reboot

  # Loop testing with auto-reboot (randomized order to avoid power surge)
  $0 --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot                      # Soft reboot, 1s interval
  $0 --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot --reboot-interval 2 # Soft reboot, 2s interval
  $0 --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot --reboot-method ipmi  # IPMI power cycle
  $0 --auto-hca -G -cx7 -z 30 --loop 5 --auto-reboot --reboot-method ipmi --reboot-interval 2  # IPMI, 2s interval

  # Loop testing with optical module reset (no server reboot)
  $0 --auto-hca -G -cx7 -z 30 --loop-test 5 --reset-optics                # Auto-detect all HCAs, reset optics
  $0 -d mlx5_0:1,mlx5_5:1 -G -cx7 -z 30 --loop-test 5 --reset-optics     # Reset only specified HCAs
  $0 --auto-hca -G -cx7 -z 30 --loop-test 5 --reset-optics --optics-interval 5  # Custom reset interval

  # Loop testing with auto-remove bad nodes
  $0 --auto-hca -G -cx7 -z 30 --loop 10 --auto-reboot --auto-remove-bad-nodes  # Auto remove bad nodes
  $0 --auto-hca -G -cx7 -z 30 --loop 10 --auto-reboot --auto-remove-bad-nodes --min-nodes 4  # Min 4 nodes

  # Combined features
  $0 --auto-hca -G -cx7 -z 30 --loop-test 10 --reset-optics --auto-remove-bad-nodes  # Reset optics + auto remove

  # View historical results
  $0 --view results/rbr_20251207_120000_GPU-1-GPU-9/                # View all rails in directory
  $0 --view results/rbr_20251207_120000_GPU-1-GPU-9/mlx5_0/         # View specific rail
  $0 --view results/20251207_120000/bandwidth.txt                    # View specific file

  # Run on GPU node as control node (force CPU server mode)
  CK_FORCE_MODE=cpu_server $0 --auto-hca -G -cx7                          # Force cpu_server mode

EOF
    exit 0
}

# Parse nvidia-smi topo -m output to get GPU-associated HCA list
parse_gpu_hca_list() {
    awk '
BEGIN {
    in_nic_legend = 0
}

/^NIC Legend:/ {
    in_nic_legend = 1
    next
}

in_nic_legend == 1 {
    if (length($0) == 0 || $0 ~ /^[ \t]*$/) {
        next
    }

    if ($0 ~ /^ *NIC[0-9]+:/) {
        gsub(/:/, "", $1)
        nic_num = substr($1, 4)
        nic_dev[nic_num] = $2
        next
    }

    in_nic_legend = 0
}

/^NIC[0-9]/ && in_nic_legend == 0 {
    nic_name = $1
    nic_num = substr(nic_name, 4)

    for (i=2; i<=9; i++) {
        if ($i == "PIX") {
            gpu_num = i - 2
            gpu_nic_map[gpu_num] = nic_num
        }
    }
}

END {
    count = 0
    for (gpu = 0; gpu <= 15; gpu++) {
        if (gpu in gpu_nic_map) {
            nic_num = gpu_nic_map[gpu]
            if (nic_num in nic_dev) {
                devices[++count] = nic_dev[nic_num]
            }
        }
    }

    for (i = 1; i <= count; i++) {
        printf "%s:1", devices[i]
        if (i < count) printf ","
    }
    print ""
}
'
}

# Get GPU HCA list based on environment
get_gpu_hca_list() {
    local target_host=$1

    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${target_host} 'nvidia-smi topo -m'" | parse_gpu_hca_list
            ;;
        cpu_server)
            ssh ${target_host} "nvidia-smi topo -m" | parse_gpu_hca_list
            ;;
        gpu_server)
            nvidia-smi topo -m | parse_gpu_hca_list
            ;;
    esac
}

# Execute remote command based on environment
run_remote_cmd() {
    local gpu_host=$1
    local cmd=$2

    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${gpu_host} '${cmd}'"
            ;;
        cpu_server)
            ssh ${gpu_host} "${cmd}"
            ;;
        gpu_server)
            eval "${cmd}"
            ;;
    esac
}

# Health check for a single node (SSH + IB + GPU)
# Returns: 0=healthy, 1=ssh_fail, 2=ib_fail, 3=gpu_fail
check_node_health() {
    local host=$1
    local check_type=${2:-all}  # all, ssh, ib, gpu

    # For "all" check, use single SSH call to check all 3 items (much faster!)
    if [[ "${check_type}" == "all" ]]; then
        local result=$(timeout 10 ssh -o ConnectTimeout=5 -o BatchMode=yes ${host} bash -s <<'HEALTHCHECK'
# Check all 3 items in one SSH session
# Output format: ssh_ok|ib_count|gpu_ok

# IB check
ib_count=$(ibstat 2>/dev/null | grep -E 'State:.*Active' | wc -l)

# GPU check
if nvidia-smi &>/dev/null; then
    gpu_ok=1
else
    gpu_ok=0
fi

echo "OK|${ib_count}|${gpu_ok}"
HEALTHCHECK
        )

        # Parse result
        if [ -z "$result" ]; then
            return 1  # SSH failed
        fi

        local ssh_ok=$(echo "$result" | cut -d'|' -f1)
        local ib_count=$(echo "$result" | cut -d'|' -f2)
        local gpu_ok=$(echo "$result" | cut -d'|' -f3)

        if [ "$ssh_ok" != "OK" ]; then
            return 1  # SSH failed
        fi

        if [ "$ib_count" -eq 0 ]; then
            return 2  # IB check failed
        fi

        if [ "$gpu_ok" -ne 1 ]; then
            return 3  # GPU check failed
        fi

        return 0
    fi

    # Individual checks (kept for compatibility, but slower)
    # SSH check
    if [[ "${check_type}" == "ssh" ]]; then
        if ! timeout 5 ssh -o ConnectTimeout=5 -o BatchMode=yes ${host} "echo ok" &>/dev/null; then
            return 1
        fi
    fi

    # IB check (at least one HCA Active)
    if [[ "${check_type}" == "ib" ]]; then
        local ib_status=$(timeout 5 ssh -o ConnectTimeout=5 ${host} "ibstat 2>/dev/null | grep -E 'State:.*Active' | wc -l" 2>/dev/null || echo "0")
        if [[ "${ib_status}" -eq 0 ]]; then
            return 2
        fi
    fi

    # GPU check
    if [[ "${check_type}" == "gpu" ]]; then
        if ! timeout 5 ssh -o ConnectTimeout=5 ${host} "nvidia-smi &>/dev/null" 2>/dev/null; then
            return 3
        fi
    fi

    return 0
}

# Check PCIe status on a single node
# Returns: "PASS|WARN|FAIL|interface_count|details"
check_node_pcie_status() {
    local host=$1
    local hca_filter="$2"  # Optional: comma-separated list of HCA names (e.g., "mlx5_0,mlx5_1")

    # SSH to node and run PCIe check
    local result=$(timeout 30 ssh -o ConnectTimeout=10 ${host} bash -s "$hca_filter" <<'EOFSCRIPT'
#!/bin/bash

HCA_FILTER="$1"

# Get GPU-NIC mapping to determine which NICs to check
get_compute_nics() {
    # Use nvidia-smi topo -m to get accurate GPU-NIC mapping
    nvidia-smi topo -m 2>/dev/null | awk '
    BEGIN { in_nic_legend = 0 }
    /^NIC Legend:/ { in_nic_legend = 1; next }
    in_nic_legend == 1 {
        if (length($0) == 0 || $0 ~ /^[ \t]*$/) { next }
        if ($0 ~ /^ *NIC[0-9]+:/) {
            gsub(/:/, "", $1)
            nic_num = substr($1, 4)
            nic_dev[nic_num] = $2
            next
        }
        in_nic_legend = 0
    }
    /^NIC[0-9]/ && in_nic_legend == 0 {
        nic_name = $1
        nic_num = substr(nic_name, 4)
        for (i=2; i<=9; i++) {
            if ($i == "PIX") {
                gpu_num = i - 2
                gpu_nic_map[gpu_num] = nic_num
            }
        }
    }
    END {
        for (gpu = 0; gpu <= 15; gpu++) {
            if (gpu in gpu_nic_map) {
                nic_num = gpu_nic_map[gpu]
                if (nic_num in nic_dev) {
                    print nic_dev[nic_num]
                }
            }
        }
    }
    '
}

# Build list of NICs to check
if [ -n "$HCA_FILTER" ]; then
    # Use specified HCA list
    CHECK_NICS="$HCA_FILTER"
else
    # Use GPU-mapped compute NICs only
    CHECK_NICS=$(get_compute_nics | tr '\n' ',')
fi

# Check each IB interface
interface_count=0
fail_count=0
warn_count=0
details=""

# Use process substitution to avoid subshell issue with while loop
while read -r line; do
    # Extract HCA device name (e.g., mlx5_0)
    hca_dev=$(echo "$line" | awk '{print $1}')

    # Check if this device is in the list
    if [ -n "$CHECK_NICS" ]; then
        if ! echo "$CHECK_NICS" | tr ',' '\n' | grep -qx "$hca_dev"; then
            continue  # Skip this interface
        fi
    fi

    netdev=$(echo "$line" | awk -F "==> " '{print $2}' | awk '{print $1}')
    if [ -z "$netdev" ]; then continue; fi

    pci_addr=$(ethtool -i "$netdev" 2>/dev/null | grep "bus-info" | awk '{print $2}')
    if [ -z "$pci_addr" ]; then continue; fi

    # Get PCIe status
    lnk_sta=$(lspci -s "$pci_addr" -vvv 2>/dev/null | grep "LnkSta:" | head -n 1)
    current_speed=$(echo "$lnk_sta" | grep -o "[0-9]*GT/s")
    current_width=$(echo "$lnk_sta" | grep -o "x[0-9]*")

    # Get signal integrity errors
    ethtool_stats=$(ethtool -S "$netdev" 2>/dev/null)
    rx_err=$(echo "$ethtool_stats" | grep "rx_pci_signal_integrity" | awk '{print $2}')
    tx_err=$(echo "$ethtool_stats" | grep "tx_pci_signal_integrity" | awk '{print $2}')

    [ -z "$rx_err" ] && rx_err=0
    [ -z "$tx_err" ] && tx_err=0

    interface_count=$((interface_count + 1))

    # Check conditions
    status="PASS"
    if [ "$current_speed" != "32GT/s" ] || [ "$current_width" != "x16" ]; then
        status="FAIL"
        fail_count=$((fail_count + 1))
    elif [ "$rx_err" -ge 10 ] || [ "$tx_err" -ge 10 ]; then
        status="FAIL"
        fail_count=$((fail_count + 1))
    elif [ "$rx_err" -gt 0 ] || [ "$tx_err" -gt 0 ]; then
        status="WARN"
        warn_count=$((warn_count + 1))
    fi

    # Build details string
    if [ -n "$details" ]; then
        details="${details};"
    fi
    details="${details}${netdev}:${current_speed:-N/A}/${current_width:-N/A}/RX:${rx_err}/TX:${tx_err}/${status}"
done < <(ibdev2netdev 2>/dev/null)

# Output final status
if [ $fail_count -gt 0 ]; then
    echo "FAIL|${interface_count}|${details}"
elif [ $warn_count -gt 0 ]; then
    echo "WARN|${interface_count}|${details}"
else
    echo "PASS|${interface_count}|${details}"
fi
EOFSCRIPT
    )

    echo "$result"
}

# Check PCIe status for all nodes
# Returns: 0=all pass, 1=has failures
check_all_nodes_pcie() {
    local hostfile_path=$1
    local round_num=${2:-1}  # Optional round number for logging

    # Build HCA filter from HCA_LIST if specified
    local hca_filter=""
    if [ -n "${HCA_LIST}" ]; then
        # Extract HCA names from HCA_LIST (format: "mlx5_0:1,mlx5_1:1" -> "mlx5_0,mlx5_1")
        hca_filter=$(echo "${HCA_LIST}" | sed 's/:[0-9]*//g')
    fi

    log_health_always ""
    log_health_always "=========================================="
    log_health_always "Checking PCIe Status..."
    if [ -n "$hca_filter" ]; then
        log_health_always "HCA Filter: ${hca_filter}"
    else
        log_health_always "Auto-detecting compute NICs (GPU-mapped only)"
    fi
    log_health_always "=========================================="
    log_health_always ""

    # Read all hosts
    local hosts=()
    while IFS= read -r host; do
        [[ -z "$host" || "$host" =~ ^# ]] && continue
        hosts+=("$host")
    done < "${hostfile_path}"

    local has_failure=0
    local has_warning=0

    # Display header
    log_health_always "---------------------------------------------------------------"
    log_health_always "Host            Interfaces    Status    Details"
    log_health_always "---------------------------------------------------------------"

    # Check each host in parallel
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local tmpdir="/tmp/pcie_check_$$"
    mkdir -p "$tmpdir"

    # Launch parallel checks
    for host in "${hosts[@]}"; do
        (
            result=$(check_node_pcie_status "${host}" "${hca_filter}")
            echo "$result" > "$tmpdir/${host}.result"
        ) &
    done

    # Wait for all checks to complete
    wait

    # Process results
    for host in "${hosts[@]}"; do
        local result=""
        if [ -f "$tmpdir/${host}.result" ]; then
            result=$(cat "$tmpdir/${host}.result")
        fi

        if [ -z "$result" ]; then
            log_health_always "${host}       N/A           ERROR     Unable to check"
            has_failure=1
            # Save to CSV: mark as error
            append_health_csv "${timestamp}" "${round_num}" "${host}" "✓" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "N/A" "ERROR"
            continue
        fi

        local status=$(echo "$result" | cut -d'|' -f1)
        local intf_count=$(echo "$result" | cut -d'|' -f2)
        local details=$(echo "$result" | cut -d'|' -f3)

        # Format details for display
        # If PASS: show first interface as summary
        # If WARN/FAIL: show problem interfaces
        local display_details=""
        local first_intf=""

        if [ "$status" = "PASS" ]; then
            # Show first interface
            first_intf=$(echo "$details" | cut -d';' -f1)
            display_details=$(echo "$first_intf" | cut -d':' -f2-)
        else
            # Show problem interfaces (WARN or FAIL status)
            local problem_list=""
            IFS=';' read -ra INTFS <<< "$details"
            for intf in "${INTFS[@]}"; do
                local intf_status=$(echo "$intf" | rev | cut -d'/' -f1 | rev)
                if [ "$intf_status" != "PASS" ]; then
                    local intf_name=$(echo "$intf" | cut -d':' -f1)
                    local intf_detail=$(echo "$intf" | cut -d':' -f2-)
                    if [ -z "$problem_list" ]; then
                        problem_list="${intf_name}:${intf_detail}"
                    else
                        problem_list="${problem_list}, ${intf_name}:${intf_detail}"
                    fi
                fi
            done
            display_details="$problem_list"
            # Use first interface for CSV data
            first_intf=$(echo "$details" | cut -d';' -f1)
        fi

        # Parse first interface details for CSV
        # Format: ibs11:32GT/s/x16/RX:0/TX:0/PASS
        # Extract speed and width from the second field
        local speed_width=$(echo "$first_intf" | cut -d':' -f2)
        # Speed: 32GT/s (first and second field combined)
        local pcie_speed=$(echo "$speed_width" | cut -d'/' -f1,2)
        # Width: x16 (third field)
        local pcie_width=$(echo "$speed_width" | cut -d'/' -f3)
        local rx_err=$(echo "$first_intf" | grep -o "RX:[0-9]*" | cut -d':' -f2)
        local tx_err=$(echo "$first_intf" | grep -o "TX:[0-9]*" | cut -d':' -f2)

        # Color and status
        case $status in
            PASS)
                log_health_always "$(printf '%-15s %-13s %-9s %s' "${host}" "${intf_count}" "✓ PASS" "${display_details}")"
                ;;
            WARN)
                log_health_always "$(printf '%-15s %-13s %-9s %s' "${host}" "${intf_count}" "⚠ WARN" "${display_details}")"
                has_warning=1
                ;;
            FAIL)
                log_health_always "$(printf '%-15s %-13s %-9s %s' "${host}" "${intf_count}" "✗ FAIL" "${display_details}")"
                has_failure=1
                ;;
        esac

        # Try to load basic health data from temp file (if exists, for health-only mode)
        local basic_health_file="/tmp/health_basic_${host}_$$"
        local ssh_val="✓"
        local ib_val="N/A"
        local gpu_val="N/A"
        local health_status="${status}"

        if [ -f "${basic_health_file}" ]; then
            # Merge with basic health data
            local basic_data=$(cat "${basic_health_file}")
            ssh_val=$(echo "${basic_data}" | cut -d'|' -f2)
            ib_val=$(echo "${basic_data}" | cut -d'|' -f3)
            gpu_val=$(echo "${basic_data}" | cut -d'|' -f4)
            # Overall status: FAIL if either health or PCIe failed
            local basic_status=$(echo "${basic_data}" | cut -d'|' -f5)
            if [[ "${basic_status}" == "FAIL" || "${status}" == "FAIL" ]]; then
                health_status="FAIL"
            fi
        fi

        # Save to CSV: merge basic health + PCIe data
        append_health_csv "${timestamp}" "${round_num}" "${host}" "${ssh_val}" "${ib_val}" "${gpu_val}" "N/A" \
            "${pcie_speed:-N/A}" "${pcie_width:-N/A}" "${rx_err:-N/A}" "${tx_err:-N/A}" "${health_status}"
    done

    # Cleanup temp directory
    rm -rf "$tmpdir"

    # Cleanup basic health temp files
    rm -f /tmp/health_basic_*_$$

    log_health_always "---------------------------------------------------------------"

    if [ ${has_failure} -eq 1 ]; then
        log_health_always ""
        log_health_always "❌ PCIe检查失败！发现以下问题："
        log_health_always "   - PCIe降速 (非Gen5 x16)"
        log_health_always "   - 信号完整性错误 >= 10"
        log_health_always ""
        log_health_always "测试终止！"
        return 1
    elif [ ${has_warning} -eq 1 ]; then
        log_health_always ""
        log_health_always "⚠️  警告：发现少量信号完整性错误 (< 10)，测试继续"
    else
        log_health_always ""
        log_health_always "✓ 所有节点 PCIe 状态正常"
    fi

    log_health_always ""
    return 0
}

# Get node uptime in minutes
get_node_uptime_minutes() {
    local host=$1
    # Get uptime in seconds, then convert to minutes
    local uptime_sec=$(timeout 5 ssh -o ConnectTimeout=5 ${host} "cat /proc/uptime 2>/dev/null | awk '{print int(\$1)}'" 2>/dev/null || echo "999999")
    echo $((uptime_sec / 60))
}

# Check if node was recently rebooted
check_node_rebooted() {
    local host=$1
    local max_uptime=${MAX_UPTIME_MINUTES}

    local uptime_min=$(get_node_uptime_minutes "${host}")

    if [[ ${uptime_min} -le ${max_uptime} ]]; then
        return 0  # Recently rebooted
    else
        return 1  # Not rebooted or uptime too long
    fi
}

# Check single node with detailed status
check_node_with_details() {
    local host=$1
    local check_reboot=${2:-0}  # 1=check reboot, 0=skip reboot check
    local ssh_ok="✓"
    local ib_ok="✓"
    local gpu_ok="✓"
    local reboot_ok="✓"
    local ib_count=0
    local uptime_min=0

    # OPTIMIZED: Single SSH call for all checks
    local hca_filter=""
    if [ -n "${HCA_LIST}" ]; then
        hca_filter=$(echo "${HCA_LIST}" | sed 's/:[0-9]*//g')
    fi

    local result=$(timeout 15 ssh -o ConnectTimeout=5 -o BatchMode=yes ${host} bash -s <<DETAILCHECK
HCA_FILTER="$hca_filter"
CHECK_REBOOT=$check_reboot
MAX_UPTIME_MIN=${MAX_UPTIME_MINUTES}

# Get uptime if needed
uptime_min=0
reboot_ok=1
if [ \$CHECK_REBOOT -eq 1 ]; then
    uptime_sec=\$(cat /proc/uptime 2>/dev/null | awk '{print int(\$1)}')
    uptime_min=\$((uptime_sec / 60))
    if [ \$uptime_min -gt \$MAX_UPTIME_MIN ]; then
        reboot_ok=0
    fi
fi

# IB check - count active NICs
if [ -n "\$HCA_FILTER" ]; then
    ib_count=0
    for hca in \$(echo "\$HCA_FILTER" | tr ',' ' '); do
        state=\$(ibstat "\$hca" 2>/dev/null | grep -E 'State:.*Active')
        if [ -n "\$state" ]; then
            ib_count=\$((ib_count + 1))
        fi
    done
else
    # Auto-detect GPU-mapped NICs
    get_compute_nics() {
        nvidia-smi topo -m 2>/dev/null | awk '
        BEGIN { in_nic_legend = 0 }
        /^NIC Legend:/ { in_nic_legend = 1; next }
        in_nic_legend == 1 {
            if (length(\$0) == 0 || \$0 ~ /^[ \t]*\$/) { next }
            if (\$0 ~ /^ *NIC[0-9]+:/) {
                gsub(/:/, "", \$1)
                nic_num = substr(\$1, 4)
                nic_dev[nic_num] = \$2
                next
            }
            in_nic_legend = 0
        }
        /^NIC[0-9]/ && in_nic_legend == 0 {
            nic_name = \$1
            nic_num = substr(nic_name, 4)
            for (i=2; i<=9; i++) {
                if (\$i == "PIX") {
                    gpu_num = i - 2
                    gpu_nic_map[gpu_num] = nic_num
                }
            }
        }
        END {
            for (gpu = 0; gpu <= 15; gpu++) {
                if (gpu in gpu_nic_map) {
                    nic_num = gpu_nic_map[gpu]
                    if (nic_num in nic_dev) {
                        print nic_dev[nic_num]
                    }
                }
            }
        }
        '
    }

    ib_count=0
    for hca in \$(get_compute_nics); do
        state=\$(ibstat "\$hca" 2>/dev/null | grep -E 'State:.*Active')
        if [ -n "\$state" ]; then
            ib_count=\$((ib_count + 1))
        fi
    done
fi

# GPU check
if nvidia-smi &>/dev/null; then
    gpu_ok=1
else
    gpu_ok=0
fi

# Output: ib_count|gpu_ok|uptime_min|reboot_ok
echo "\${ib_count}|\${gpu_ok}|\${uptime_min}|\${reboot_ok}"
DETAILCHECK
    )

    # Parse result
    if [ -z "$result" ]; then
        ssh_ok="✗"
        if [[ ${check_reboot} -eq 1 ]]; then
            echo "${host}|${ssh_ok}|N/A|N/A|N/A"
        else
            echo "${host}|${ssh_ok}|N/A|N/A"
        fi
        return 1
    fi

    ib_count=$(echo "$result" | cut -d'|' -f1)
    local gpu_result=$(echo "$result" | cut -d'|' -f2)
    uptime_min=$(echo "$result" | cut -d'|' -f3)
    local reboot_result=$(echo "$result" | cut -d'|' -f4)

    # Format status symbols
    if [[ "${ib_count}" -eq 0 ]]; then
        ib_ok="✗"
    fi

    if [[ "${gpu_result}" -ne 1 ]]; then
        gpu_ok="✗"
    fi

    if [[ "${reboot_result}" -ne 1 ]]; then
        reboot_ok="✗"
    fi

    if [[ ${check_reboot} -eq 1 ]]; then
        echo "${host}|${ssh_ok}|${ib_ok} (${ib_count})|${gpu_ok}|${reboot_ok} (${uptime_min}m)"
        if [[ "${ssh_ok}" == "✓" && "${ib_ok}" == "✓" && "${gpu_ok}" == "✓" && "${reboot_ok}" == "✓" ]]; then
            return 0
        else
            return 1
        fi
    else
        echo "${host}|${ssh_ok}|${ib_ok} (${ib_count})|${gpu_ok}"
        if [[ "${ssh_ok}" == "✓" && "${ib_ok}" == "✓" && "${gpu_ok}" == "✓" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

# Wait for all nodes to become healthy after reboot
wait_for_nodes_ready() {
    local hostfile_path=$1
    local check_reboot=${2:-1}  # 1=verify reboot, 0=skip reboot check
    local round_num=${3:-1}      # Optional round number for CSV logging
    local skip_csv=${4:-0}       # 1=skip CSV write (for health-only mode), 0=write CSV
    local timeout=${HEALTH_CHECK_TIMEOUT}
    local start_time=$(date +%s)

    if [[ ${check_reboot} -eq 1 ]]; then
        log_always ""
        log_always "=========================================="
        log_always "Waiting for Node Reboot..."
        log_always "=========================================="
        log_always "Waiting ${REBOOT_WAIT_TIME}s (3 minutes) for nodes to reboot..."
        log_always ""

        local wait_start=$(date +%s)
        while true; do
            local wait_elapsed=$(($(date +%s) - wait_start))
            if [[ ${wait_elapsed} -ge ${REBOOT_WAIT_TIME} ]]; then
                break
            fi
            local remaining=$((REBOOT_WAIT_TIME - wait_elapsed))
            printf "\r[$(date '+%H:%M:%S')] Waiting... ${remaining}s remaining   "
            sleep 5
        done
        printf "\n\n"
    fi

    log_always ""
    log_always "=========================================="
    log_always "Health Check - Verifying node status..."
    log_always "=========================================="
    log_always "Timeout: ${timeout}s (15 minutes)"
    log_always "Check interval: 5s"
    if [[ ${check_reboot} -eq 1 ]]; then
        log_always "Reboot verification: Uptime must be < ${MAX_UPTIME_MINUTES} minutes"
    fi
    log_always ""

    # Read all hosts
    local hosts=()
    while IFS= read -r host; do
        [[ -z "$host" || "$host" =~ ^# ]] && continue
        hosts+=("$host")
    done < "${hostfile_path}"

    local total_hosts=${#hosts[@]}
    local ready_count=0
    local check_round=0
    local last_status_change=0

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ ${elapsed} -ge ${timeout} ]]; then
            log_always ""
            log_always "Error: Health check timeout after ${elapsed}s"
            log_always ""
            log_always "Failed nodes status:"

            # Collect failed nodes for export
            local timeout_failed_nodes=()

            if [[ ${check_reboot} -eq 1 ]]; then
                log_always "---------------------------------------------------------------"
                log_always "Host            SSH    IB         GPU    Reboot"
                log_always "---------------------------------------------------------------"
                for host in "${hosts[@]}"; do
                    local status=$(check_node_with_details "${host}" 1)
                    local node_status=$(echo "${status}" | awk -F'|' '{printf "%-15s %-6s %-10s %-6s %-12s\n", $1, $2, $3, $4, $5}')
                    log_always "${node_status}"

                    # Check if node is healthy
                    if ! (check_node_health "${host}" "all" && check_node_rebooted "${host}"); then
                        timeout_failed_nodes+=("${host}")
                    fi
                done
                log_always "---------------------------------------------------------------"
            else
                log_always "----------------------------------------"
                log_always "Host            SSH    IB         GPU"
                log_always "----------------------------------------"
                for host in "${hosts[@]}"; do
                    local status=$(check_node_with_details "${host}" 0)
                    local node_status=$(echo "${status}" | awk -F'|' '{printf "%-15s %-6s %-10s %-6s\n", $1, $2, $3, $4}')
                    log_always "${node_status}"

                    # Check if node is healthy
                    if ! check_node_health "${host}" "all"; then
                        timeout_failed_nodes+=("${host}")
                    fi
                done
                log_always "----------------------------------------"
            fi

            # Export failed nodes to temp file
            printf "%s\n" "${timeout_failed_nodes[@]}" > "/tmp/failed_nodes_$$"
            return 1
        fi

        ready_count=0
        local failed_hosts=()
        ((check_round++))

        # Check each host in parallel (using background jobs with concurrency limit)
        local tmpdir="/tmp/health_check_$$_${check_round}"
        mkdir -p "$tmpdir"

        local parallel_limit=${HEALTH_CHECK_PARALLEL}
        if [ "$parallel_limit" -eq 0 ]; then
            parallel_limit=999999  # Unlimited
        fi

        local job_count=0
        for host in "${hosts[@]}"; do
            (
                if [[ ${check_reboot} -eq 1 ]]; then
                    # Check health AND reboot status
                    if check_node_health "${host}" "all" && check_node_rebooted "${host}"; then
                        echo "READY" > "$tmpdir/${host}.status"
                    else
                        echo "FAILED" > "$tmpdir/${host}.status"
                    fi
                else
                    # Only check health
                    if check_node_health "${host}" "all"; then
                        echo "READY" > "$tmpdir/${host}.status"
                    else
                        echo "FAILED" > "$tmpdir/${host}.status"
                    fi
                fi
            ) &

            ((job_count++))
            # Wait when reaching parallel limit
            if [ $((job_count % parallel_limit)) -eq 0 ]; then
                wait
            fi
        done

        # Wait for remaining background checks to complete
        wait

        # Count results
        for host in "${hosts[@]}"; do
            if [ -f "$tmpdir/${host}.status" ]; then
                local status=$(cat "$tmpdir/${host}.status")
                if [ "$status" = "READY" ]; then
                    ((ready_count++))
                else
                    failed_hosts+=("${host}")
                fi
            else
                failed_hosts+=("${host}")
            fi
        done

        # Cleanup
        rm -rf "$tmpdir"

        # Display progress header every 10 checks or status change
        if [[ $((check_round % 10)) -eq 1 || ${ready_count} -ne ${last_status_change} ]]; then
            log_always ""
            log_always "[$(date '+%H:%M:%S')] Check #${check_round} | Ready: ${ready_count}/${total_hosts} nodes | Elapsed: ${elapsed}s"

            if [[ ${ready_count} -lt ${total_hosts} ]]; then
                if [[ ${check_reboot} -eq 1 ]]; then
                    log_always "---------------------------------------------------------------"
                    log_always "Host            SSH    IB         GPU    Reboot"
                    log_always "---------------------------------------------------------------"
                    for host in "${hosts[@]}"; do
                        local status=$(check_node_with_details "${host}" 1)
                        local node_status=$(echo "${status}" | awk -F'|' '{printf "%-15s %-6s %-10s %-6s %-12s\n", $1, $2, $3, $4, $5}')
                        log_always "${node_status}"
                    done
                    log_always "---------------------------------------------------------------"
                else
                    log_always "----------------------------------------"
                    log_always "Host            SSH    IB         GPU"
                    log_always "----------------------------------------"
                    for host in "${hosts[@]}"; do
                        local status=$(check_node_with_details "${host}" 0)
                        local node_status=$(echo "${status}" | awk -F'|' '{printf "%-15s %-6s %-10s %-6s\n", $1, $2, $3, $4}')
                        log_always "${node_status}"
                    done
                    log_always "----------------------------------------"
                fi
            fi

            last_status_change=${ready_count}
        fi

        if [[ ${ready_count} -eq ${total_hosts} ]]; then
            log_health_always ""
            log_health_always "=========================================="
            log_health_always "All nodes are healthy!"
            log_health_always "=========================================="
            log_health_always "Final status:"

            local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

            if [[ ${check_reboot} -eq 1 ]]; then
                log_health_always "---------------------------------------------------------------"
                log_health_always "Host            SSH    IB         GPU    Reboot"
                log_health_always "---------------------------------------------------------------"
                for host in "${hosts[@]}"; do
                    local status=$(check_node_with_details "${host}" 1)
                    local node_status=$(echo "${status}" | awk -F'|' '{printf "%-15s %-6s %-10s %-6s %-12s\n", $1, $2, $3, $4, $5}')
                    log_health_always "${node_status}"

                    # Parse status for CSV: format is "host|ssh|ib|gpu|reboot"
                    local host_name=$(echo "${status}" | cut -d'|' -f1)
                    local ssh_status=$(echo "${status}" | cut -d'|' -f2)
                    local ib_status=$(echo "${status}" | cut -d'|' -f3 | awk '{print $1}')
                    local ib_count=$(echo "${status}" | cut -d'|' -f3 | grep -o '[0-9]*' | head -1)
                    local gpu_status=$(echo "${status}" | cut -d'|' -f4)
                    local reboot_info=$(echo "${status}" | cut -d'|' -f5)
                    local uptime_min=$(echo "${reboot_info}" | grep -o '[0-9]*' | head -1)

                    # Determine overall status
                    local overall_status="PASS"
                    if [[ "${ssh_status}" != "✓" || "${ib_status}" != "✓" || "${gpu_status}" != "✓" || "${reboot_info}" =~ "✗" ]]; then
                        overall_status="FAIL"
                    fi

                    # Save to CSV: PCIe fields will be N/A for health check only (unless skip_csv=1)
                    if [ ${skip_csv} -eq 0 ]; then
                        append_health_csv "${timestamp}" "${round_num}" "${host_name}" "${ssh_status}" "${ib_count:-N/A}" "${gpu_status}" "${uptime_min:-N/A}m" "N/A" "N/A" "N/A" "N/A" "${overall_status}"
                    fi
                done
                log_health_always "---------------------------------------------------------------"
            else
                log_health_always "----------------------------------------"
                log_health_always "Host            SSH    IB         GPU"
                log_health_always "----------------------------------------"

                # Parallel execution: collect results to temp files
                local detail_tmpdir="/tmp/health_detail_$$"
                mkdir -p "$detail_tmpdir"

                local parallel_limit=${HEALTH_CHECK_PARALLEL}
                if [ "$parallel_limit" -eq 0 ]; then
                    parallel_limit=999999
                fi

                local job_count=0
                for host in "${hosts[@]}"; do
                    (
                        status=$(check_node_with_details "${host}" 0)
                        echo "$status" > "$detail_tmpdir/${host}.status"
                    ) &

                    ((job_count++))
                    if [ $((job_count % parallel_limit)) -eq 0 ]; then
                        wait
                    fi
                done
                wait

                # Display results in order
                for host in "${hosts[@]}"; do
                    if [ -f "$detail_tmpdir/${host}.status" ]; then
                        local status=$(cat "$detail_tmpdir/${host}.status")
                        local node_status=$(echo "${status}" | awk -F'|' '{printf "%-15s %-6s %-10s %-6s\n", $1, $2, $3, $4}')
                        log_health_always "${node_status}"

                        # Parse status for CSV: format is "host|ssh|ib|gpu"
                        local host_name=$(echo "${status}" | cut -d'|' -f1)
                        local ssh_status=$(echo "${status}" | cut -d'|' -f2)
                        local ib_status=$(echo "${status}" | cut -d'|' -f3 | awk '{print $1}')
                        local ib_count=$(echo "${status}" | cut -d'|' -f3 | grep -o '[0-9]*' | head -1)
                        local gpu_status=$(echo "${status}" | cut -d'|' -f4)

                        # Determine overall status
                        local overall_status="PASS"
                        if [[ "${ssh_status}" != "✓" || "${ib_status}" != "✓" || "${gpu_status}" != "✓" ]]; then
                            overall_status="FAIL"
                        fi

                        # Save to CSV: No reboot check, PCIe fields N/A (unless skip_csv=1)
                        if [ ${skip_csv} -eq 0 ]; then
                            append_health_csv "${timestamp}" "${round_num}" "${host_name}" "${ssh_status}" "${ib_count:-N/A}" "${gpu_status}" "N/A" "N/A" "N/A" "N/A" "N/A" "${overall_status}"
                        fi

                        # Save basic health data to temp file for later merging with PCIe data
                        if [ ${skip_csv} -eq 1 ]; then
                            echo "${host_name}|${ssh_status}|${ib_count:-N/A}|${gpu_status}|${overall_status}" > "/tmp/health_basic_${host_name}_$$"
                        fi
                    fi
                done

                rm -rf "$detail_tmpdir"
                log_health_always "----------------------------------------"
            fi

            # Calculate total time based on check_reboot mode
            if [[ ${check_reboot} -eq 1 ]]; then
                log_health_always "Total time: $((elapsed + REBOOT_WAIT_TIME))s (Wait: ${REBOOT_WAIT_TIME}s + Check: ${elapsed}s)"
            else
                log_health_always "Total time: ${elapsed}s"
            fi
            log_health_always ""

            # Export empty failed nodes list (all nodes passed)
            echo "" > "/tmp/failed_nodes_$$"
            return 0
        fi

        # Wait 5 seconds before next check
        sleep 5
    done
}

# Reboot nodes in randomized order to avoid power surge
# Args: $1 = hostfile path
reboot_nodes_randomly() {
    local hostfile_path=$1

    # Read hosts from hostfile
    local hosts=()
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Extract hostname (first field)
        local host=$(echo "$line" | awk '{print $1}')
        [[ -n "$host" ]] && hosts+=("$host")
    done < "$hostfile_path"

    local total_nodes=${#hosts[@]}

    if [ $total_nodes -eq 0 ]; then
        log_always "Error: No hosts found in hostfile"
        return 1
    fi

    # Randomize host order (shuffle array)
    # Use Fisher-Yates shuffle algorithm
    for ((i=total_nodes-1; i>0; i--)); do
        j=$((RANDOM % (i+1)))
        # Swap hosts[i] and hosts[j]
        tmp="${hosts[i]}"
        hosts[i]="${hosts[j]}"
        hosts[j]="$tmp"
    done

    # Calculate total reboot time
    local total_time=$((total_nodes * REBOOT_INTERVAL))

    # Determine reboot method display name
    local method_display
    if [[ "${REBOOT_METHOD}" == "ipmi" ]]; then
        method_display="IPMI Power Cycle"
    else
        method_display="Soft Reboot"
    fi

    log_always ""
    log_always "=========================================="
    log_always "Auto Reboot Nodes (Randomized Order)"
    log_always "=========================================="
    log_always "Total nodes:      $total_nodes"
    log_always "Reboot method:    ${method_display}"
    log_always "Reboot interval:  ${REBOOT_INTERVAL}s per node"
    log_always "Estimated time:   ${total_time}s (~$((total_time / 60))m $((total_time % 60))s)"
    log_always "=========================================="
    log_always ""

    # Reboot each node with interval
    local count=0
    for host in "${hosts[@]}"; do
        ((count++))

        # Select reboot command based on method
        local reboot_cmd
        if [[ "${REBOOT_METHOD}" == "ipmi" ]]; then
            log_always "[${count}/${total_nodes}] Power cycling ${host} (IPMI)..."
            reboot_cmd="ipmitool chassis power cycle"
        else
            log_always "[${count}/${total_nodes}] Rebooting ${host} (soft)..."
            reboot_cmd="reboot"
        fi

        # Send reboot command (don't wait for response, as connection will drop)
        case ${RUN_ENV} in
            mac)
                ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh -o ConnectTimeout=5 ${host} 'nohup ${reboot_cmd} >/dev/null 2>&1 &'" 2>/dev/null &
                ;;
            cpu_server)
                ssh -o ConnectTimeout=5 ${host} "nohup ${reboot_cmd} >/dev/null 2>&1 &" 2>/dev/null &
                ;;
            gpu_server)
                # In GPU server mode, reboot via CPU server
                ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh -o ConnectTimeout=5 ${host} 'nohup ${reboot_cmd} >/dev/null 2>&1 &'" 2>/dev/null &
                ;;
        esac

        # Wait for interval (except for last node)
        if [ $count -lt $total_nodes ]; then
            sleep ${REBOOT_INTERVAL}
        fi
    done

    log_always ""
    log_always "All reboot commands sent. Waiting ${REBOOT_WAIT_TIME}s for nodes to come back online..."
    log_always ""

    # Wait for nodes to finish rebooting
    sleep ${REBOOT_WAIT_TIME}

    return 0
}

# Log bad nodes to bad_nodes.log with detailed failure reasons
# Args: $1 = bad_nodes_log_path, $2 = round_num, $3+ = failed hosts
log_bad_nodes() {
    local log_path=$1
    local round_num=$2
    shift 2
    local failed_hosts=("$@")

    if [ ${#failed_hosts[@]} -eq 0 ]; then
        return 0
    fi

    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Create or append to log file
    if [ ! -f "${log_path}" ]; then
        echo "# Bad Nodes Log - Auto-generated by ck-bench.sh" > "${log_path}"
        echo "# Format: Timestamp | Round | Node | SSH | IB | GPU | PCIe | Reason" >> "${log_path}"
        echo "# ======================================================================" >> "${log_path}"
    fi

    echo "" >> "${log_path}"
    echo "[${timestamp}] Round ${round_num}: ${#failed_hosts[@]} node(s) failed" >> "${log_path}"
    echo "----------------------------------------------------------------------" >> "${log_path}"

    # Check each failed node and get detailed status
    for host in "${failed_hosts[@]}"; do
        local status=$(check_node_with_details "${host}" 0)

        # Parse status: format is "host|ssh|ib|gpu"
        local ssh_status=$(echo "${status}" | cut -d'|' -f2)
        local ib_status=$(echo "${status}" | cut -d'|' -f3)
        local gpu_status=$(echo "${status}" | cut -d'|' -f4)

        # Determine failure reasons
        local reasons=()
        [[ "${ssh_status}" != "✓" ]] && reasons+=("SSH_FAIL")
        [[ ! "${ib_status}" =~ "✓" ]] && reasons+=("IB_FAIL")
        [[ "${gpu_status}" != "✓" ]] && reasons+=("GPU_FAIL")

        local reason_str=$(IFS=,; echo "${reasons[*]}")
        [ -z "${reason_str}" ] && reason_str="UNKNOWN"

        echo "${timestamp} | ${round_num} | ${host} | ${ssh_status} | ${ib_status} | ${gpu_status} | N/A | ${reason_str}" >> "${log_path}"
    done

    echo "----------------------------------------------------------------------" >> "${log_path}"
}

# Remove bad nodes from hostfile and create updated hostfile
# Args: $1 = original_hostfile, $2 = output_hostfile, $3+ = nodes_to_remove
# Returns: 0 on success, 1 if remaining nodes <= MIN_NODES
remove_bad_nodes_from_hostfile() {
    local original_hostfile=$1
    local output_hostfile=$2
    shift 2
    local nodes_to_remove=("$@")

    if [ ${#nodes_to_remove[@]} -eq 0 ]; then
        cp "${original_hostfile}" "${output_hostfile}"
        return 0
    fi

    # Create associative array for fast lookup
    declare -A remove_map
    for node in "${nodes_to_remove[@]}"; do
        remove_map["${node}"]=1
    done

    # Create new hostfile excluding bad nodes
    local remaining_count=0
    > "${output_hostfile}"  # Clear file

    while IFS= read -r line || [ -n "$line" ]; do
        # Keep comments and empty lines
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            echo "$line" >> "${output_hostfile}"
            continue
        fi

        # Extract hostname (first field)
        local host=$(echo "$line" | awk '{print $1}')

        # Skip if in removal list
        if [[ -n "${remove_map[$host]}" ]]; then
            echo "# REMOVED: $line" >> "${output_hostfile}"
            continue
        fi

        # Keep this node
        echo "$line" >> "${output_hostfile}"
        ((remaining_count++))
    done < "${original_hostfile}"

    # Check if remaining nodes meet minimum requirement
    if [ ${remaining_count} -lt ${MIN_NODES} ]; then
        return 1
    fi

    return 0
}

# Get NUMA node for a specific HCA
# Args: $1 = hca_name (e.g., "mlx5_0" or "mlx5_0:1")
# Returns: NUMA node number (0, 1, etc.) or -1 if not found
get_hca_numa_node() {
    local hca=$1
    local host=${2:-""}  # Optional: specific host to query

    # Remove :N suffix if present (e.g., mlx5_0:1 -> mlx5_0)
    local hca_name="${hca%%:*}"

    local numa_node=-1

    if [ -z "${host}" ]; then
        # Query local node
        if [ -f "/sys/class/infiniband/${hca_name}/device/numa_node" ]; then
            numa_node=$(cat /sys/class/infiniband/${hca_name}/device/numa_node 2>/dev/null || echo "-1")
        fi
    else
        # Query remote node
        case ${RUN_ENV} in
            mac)
                numa_node=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'cat /sys/class/infiniband/${hca_name}/device/numa_node 2>/dev/null || echo -1'" 2>/dev/null)
                ;;
            cpu_server)
                numa_node=$(ssh ${host} "cat /sys/class/infiniband/${hca_name}/device/numa_node 2>/dev/null || echo -1" 2>/dev/null)
                ;;
            gpu_server)
                numa_node=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'cat /sys/class/infiniband/${hca_name}/device/numa_node 2>/dev/null || echo -1'" 2>/dev/null)
                ;;
        esac
    fi

    # Validate and return
    if [[ "${numa_node}" =~ ^[0-9]+$ ]]; then
        echo "${numa_node}"
    else
        echo "-1"
    fi
}

# Build MPI NUMA binding arguments based on NUMA policy
# Args: $1 = numa_node (0, 1, etc.), $2 = numa_policy (auto/none/node0/node1)
# Returns: MPI binding arguments string
build_numa_mpi_args() {
    local numa_node=$1
    local policy=${2:-"auto"}
    local mpi_args=""

    # If policy is "none", return empty
    if [ "${policy}" = "none" ]; then
        echo ""
        return 0
    fi

    # Determine target NUMA node
    local target_numa=-1
    case "${policy}" in
        node0)
            target_numa=0
            ;;
        node1)
            target_numa=1
            ;;
        auto)
            target_numa=${numa_node}
            ;;
        *)
            target_numa=${numa_node}
            ;;
    esac

    # If invalid NUMA node, return empty
    if [ ${target_numa} -lt 0 ]; then
        echo ""
        return 0
    fi

    # Build MPI binding arguments
    # Use OpenMPI's binding options
    mpi_args="--bind-to numa --map-by numa:PE=24"

    # Add NUMA node specific CPU list if needed
    # NUMA0: CPUs 0-47,96-143
    # NUMA1: CPUs 48-95,144-191
    if [ ${target_numa} -eq 0 ]; then
        mpi_args="${mpi_args} --cpu-set 0-47,96-143"
    elif [ ${target_numa} -eq 1 ]; then
        mpi_args="${mpi_args} --cpu-set 48-95,144-191"
    fi

    echo "${mpi_args}"
}

# Reset optical modules on all nodes for specified HCAs
# Args: $1 = hostfile_path, $2 = hca_list (comma-separated, e.g., "mlx5_0,mlx5_1"), $3 = auto_detect (0/1)
wait_for_ib_links_up() {
    local hostfile_path=$1
    local hca_list=$2
    local auto_detect=${3:-0}
    local timeout=${4:-120}  # Default 120s timeout (2 minutes)

    log_always ""
    log_always "=========================================="
    log_always "Waiting for IB links to come up..."
    log_always "=========================================="
    log_always "Timeout: ${timeout}s"
    log_always ""

    local start_time=$(date +%s)
    local check_interval=5

    # Read hosts from hostfile
    local hosts=()
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local host=$(echo "$line" | awk '{print $1}')
        [[ -n "$host" ]] && hosts+=("$host")
    done < "$hostfile_path"

    local total_nodes=${#hosts[@]}

    # Prepare HCA array
    local hca_array=()
    if [ ${auto_detect} -eq 1 ]; then
        hca_array=()
    else
        IFS=',' read -ra hca_array <<< "$hca_list"
    fi

    # Debug: show what we're checking
    log_always "Checking ${#hca_array[@]} HCA(s) on ${total_nodes} node(s)"
    if [ ${#hca_array[@]} -eq 0 ]; then
        log_always "Warning: No HCAs to check, skipping link verification"
        return 0
    fi

    # Disable exit on error for this function
    set +e

    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [ ${elapsed} -ge ${timeout} ]; then
            log_always ""
            log_always "Warning: Timeout waiting for IB links (${timeout}s)"
            log_always "Continuing anyway..."
            set -e  # Re-enable before return
            return 1
        fi

        local all_links_up=1
        local links_down_count=0

        # Create temp directory for parallel checks
        local check_tmpdir="/tmp/link_check_$$_${elapsed}"
        mkdir -p "$check_tmpdir"

        # Parallel link checking with concurrency limit
        local parallel_limit=64
        local job_count=0

        for host in "${hosts[@]}"; do
            (
                # Get HCA list for this host
                local current_hca_array=("${hca_array[@]}")
                if [ ${auto_detect} -eq 1 ]; then
                    case ${RUN_ENV} in
                        mac)
                            mapfile -t current_hca_array < <(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'ibstat -l 2>/dev/null'")
                            ;;
                        cpu_server)
                            mapfile -t current_hca_array < <(ssh ${host} "ibstat -l 2>/dev/null")
                            ;;
                        gpu_server)
                            mapfile -t current_hca_array < <(ssh ${host} "ibstat -l 2>/dev/null")
                            ;;
                    esac
                fi

                # Check each HCA on this host
                local host_links_down=0
                for hca in "${current_hca_array[@]}"; do
                    hca=$(echo "$hca" | xargs)
                    local hca_name="${hca%%:*}"

                    # Check IB link state
                    local link_state=""
                    case ${RUN_ENV} in
                        mac)
                            link_state=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'ibstat ${hca_name} 2>/dev/null | grep \"State:\" | awk \"{print \\\$2}\"'")
                            ;;
                        cpu_server)
                            link_state=$(ssh ${host} "ibstat ${hca_name} 2>/dev/null | grep 'State:' | awk '{print \$2}'")
                            ;;
                        gpu_server)
                            link_state=$(ssh ${host} "ibstat ${hca_name} 2>/dev/null | grep 'State:' | awk '{print \$2}'")
                            ;;
                    esac

                    if [ "${link_state}" != "Active" ]; then
                        ((host_links_down++)) || true
                    fi
                done

                # Save result for this host
                echo "${host_links_down}" > "$check_tmpdir/${host}.count"
            ) &

            ((job_count++))
            # Wait when reaching parallel limit
            if [ $((job_count % parallel_limit)) -eq 0 ]; then
                wait
            fi
        done

        # Wait for remaining parallel checks
        wait

        # Collect results
        for host in "${hosts[@]}"; do
            if [ -f "$check_tmpdir/${host}.count" ]; then
                local host_down=$(cat "$check_tmpdir/${host}.count")
                links_down_count=$((links_down_count + host_down))
                if [ ${host_down} -gt 0 ]; then
                    all_links_up=0
                fi
            else
                # If check failed, assume links are down
                all_links_up=0
                links_down_count=$((links_down_count + ${#hca_array[@]}))
            fi
        done

        # Cleanup
        rm -rf "$check_tmpdir"

        if [ ${all_links_up} -eq 1 ]; then
            log_always ""
            log_always "✓ All IB links are up!"
            log_always "Time taken: ${elapsed}s"
            log_always ""
            set -e  # Re-enable before return
            return 0
        fi

        local remaining=$((timeout - elapsed))
        printf "\r[$(date '+%H:%M:%S')] Checking... ${links_down_count} links down, ${remaining}s remaining   "
        sleep ${check_interval}
    done
}

reset_optical_modules() {
    local hostfile_path=$1
    local hca_list=$2
    local auto_detect=${3:-0}

    # Read hosts from hostfile
    local hosts=()
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Extract hostname (first field)
        local host=$(echo "$line" | awk '{print $1}')
        [[ -n "$host" ]] && hosts+=("$host")
    done < "$hostfile_path"

    local total_nodes=${#hosts[@]}

    if [ $total_nodes -eq 0 ]; then
        log_always "Error: No hosts found in hostfile"
        return 1
    fi

    log_always ""
    log_always "=========================================="
    log_always "Resetting Optical Modules"
    log_always "=========================================="
    if [ ${auto_detect} -eq 1 ]; then
        log_always "Mode: Auto-detect all HCAs"
    else
        log_always "HCA List: ${hca_list}"
    fi
    log_always "Total nodes: ${total_nodes}"
    log_always "Reset interval: ${OPTICS_RESET_INTERVAL}s per node"
    log_always ""

    # Prepare HCA array
    local hca_array=()
    if [ ${auto_detect} -eq 1 ]; then
        # Will auto-detect on each node
        hca_array=()
    else
        # Convert comma-separated HCA list to array
        IFS=',' read -ra hca_array <<< "$hca_list"
    fi

    # Create temp directory for parallel execution
    local tmpdir="/tmp/reset_optics_$$"
    mkdir -p "$tmpdir"

    log_always "Resetting optical modules in parallel on all nodes..."
    log_always ""

    local node_count=0
    # Launch parallel jobs for all nodes
    for host in "${hosts[@]}"; do
        ((node_count++))

        (
            # If auto-detect mode, get HCA list from the node
            local current_hca_array=("${hca_array[@]}")
            if [ ${auto_detect} -eq 1 ]; then
            # Get HCA list from remote node
            # Extract RDMA device names from mst status -v (column 4)
            # Support both mlx5_0 and mlx5_gdr_1 formats
            case ${RUN_ENV} in
                mac)
                    mapfile -t current_hca_array < <(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'mst status -v 2>/dev/null | grep -E \"mlx5_(gdr_)?[0-9]+\" | awk \"{print \\\$4}\"'")
                    ;;
                cpu_server)
                    mapfile -t current_hca_array < <(ssh ${host} "mst status -v 2>/dev/null | grep -E 'mlx5_(gdr_)?[0-9]+' | awk '{print \$4}'")
                    ;;
                gpu_server)
                    mapfile -t current_hca_array < <(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'mst status -v 2>/dev/null | grep -E \"mlx5_(gdr_)?[0-9]+\" | awk \"{print \\\$4}\"'")
                    ;;
            esac

            if [ ${#current_hca_array[@]} -eq 0 ]; then
                log_always "  Warning: No HCAs detected on ${host}, skipping..."
                continue
            fi
            log_always "  Detected ${#current_hca_array[@]} HCAs: ${current_hca_array[*]}"
        fi

        # For each HCA in the list
        for hca in "${current_hca_array[@]}"; do
            # Trim whitespace
            hca=$(echo "$hca" | xargs)

            # Remove :N suffix if present (e.g., mlx5_0:1 -> mlx5_0)
            # This is needed because clusterkit uses mlx5_0:1 format but mst uses mlx5_0
            hca_name="${hca%%:*}"

            # Run reset command on remote host (simplified output)
            case ${RUN_ENV} in
                mac)
                    ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} '
                        mst start 2>/dev/null || true
                        pci_addr=\$(mst status -v 2>/dev/null | grep \"${hca_name}\" | grep -oE \"[0-9a-f]{2,3}:[0-9a-f]{2}\\.[0-9]\" | head -1)
                        if [ -n \"\$pci_addr\" ]; then
                            echo \"${hca_name} (PCI: \$pci_addr) - Resetting...\"
                            if mlxlink -d \$pci_addr --module_state TG >/dev/null 2>&1; then
                                echo \"${hca_name} - OK\"
                            else
                                echo \"${hca_name} - FAILED\"
                            fi
                        else
                            echo \"${hca_name} - ERROR: Could not find PCI address\"
                        fi
                    '" 2>&1
                    ;;
                cpu_server)
                    ssh ${host} "
                        # Start MST if not already started
                        mst start 2>/dev/null || true

                        # Get PCI address for this HCA
                        pci_addr=\$(mst status -v 2>/dev/null | grep \"${hca_name}\" | grep -oE '[0-9a-f]{2,3}:[0-9a-f]{2}\.[0-9]' | head -1)

                        if [ -n \"\$pci_addr\" ]; then
                            echo \"${hca_name} (PCI: \$pci_addr) - Resetting...\"
                            if mlxlink -d \$pci_addr --module_state TG >/dev/null 2>&1; then
                                echo \"${hca_name} - OK\"
                            else
                                echo \"${hca_name} - FAILED\"
                            fi
                        else
                            echo \"${hca_name} - ERROR: Could not find PCI address\"
                        fi
                    " 2>&1
                    ;;
                gpu_server)
                    # In GPU server mode, run via CPU server
                    ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} '
                        mst start 2>/dev/null || true
                        pci_addr=\$(mst status -v 2>/dev/null | grep \"${hca_name}\" | grep -oE \"[0-9a-f]{2,3}:[0-9a-f]{2}\\.[0-9]\" | head -1)
                        if [ -n \"\$pci_addr\" ]; then
                            echo \"${hca_name} (PCI: \$pci_addr) - Resetting...\"
                            if mlxlink -d \$pci_addr --module_state TG >/dev/null 2>&1; then
                                echo \"${hca_name} - OK\"
                            else
                                echo \"${hca_name} - FAILED\"
                            fi
                        else
                            echo \"${hca_name} - ERROR: Could not find PCI address\"
                        fi
                    '" 2>&1
                    ;;
            esac
            done

            # Save completion status
            echo "done" > "$tmpdir/${host}.status"
        ) > "$tmpdir/${host}.log" 2>&1 &
    done

    # Wait for all parallel jobs to complete
    wait

    log_always ""
    log_always "All parallel reset operations completed"
    log_always ""

    # Display results from all nodes
    for host in "${hosts[@]}"; do
        if [ -f "$tmpdir/${host}.log" ]; then
            log_always "--- Results from ${host} ---"
            cat "$tmpdir/${host}.log" | while IFS= read -r line; do
                log_always "  $line"
            done
        fi
    done

    # Cleanup
    rm -rf "$tmpdir"

    log_always ""
    log_always "Optical module reset completed for all nodes"
    log_always ""

    return 0
}

# Upload hostfile based on environment
upload_hostfile() {
    local hostfile_path=$1
    local gpu_host=$2

    case ${RUN_ENV} in
        mac)
            scp -q "${hostfile_path}" ${CPU_SERVER_USER}@${CPU_SERVER}:/tmp/hostfile_tmp.txt
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "scp -q /tmp/hostfile_tmp.txt ${gpu_host}:${HPCX_HOME}/hostfile.txt"
            ;;
        cpu_server)
            scp -q "${hostfile_path}" ${gpu_host}:${HPCX_HOME}/hostfile.txt
            ;;
        gpu_server)
            cp "${hostfile_path}" ${HPCX_HOME}/hostfile.txt
            ;;
    esac
}

# Download results based on environment
download_results() {
    local gpu_host=$1
    local output_dir=$2
    local results_dir=$3

    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "mkdir -p ${results_dir} && scp -q -r ${gpu_host}:${HPCX_HOME}/${output_dir} ${results_dir}/"
            ;;
        cpu_server)
            mkdir -p ${results_dir}
            if ! scp -q -r ${gpu_host}:${HPCX_HOME}/${output_dir} ${results_dir}/; then
                log_always "Warning: Failed to download results from ${gpu_host}:${HPCX_HOME}/${output_dir}"
                return 1
            fi
            ;;
        gpu_server)
            mkdir -p ${results_dir}
            # Try HPCX_HOME first, then current directory
            local source_path="${HPCX_HOME}/${output_dir}"
            if [ ! -d "${source_path}" ]; then
                # If not in HPCX_HOME, try current directory
                source_path="./${output_dir}"
                if [ ! -d "${source_path}" ]; then
                    log_always "Warning: Cannot find results directory:"
                    log_always "  Tried: ${HPCX_HOME}/${output_dir}"
                    log_always "  Tried: ./${output_dir}"
                    return 1
                fi
            fi
            if ! cp -r "${source_path}" ${results_dir}/; then
                log_always "Warning: Failed to copy results from ${source_path}"
                return 1
            fi
            ;;
    esac
    return 0
}

# Show result files based on environment
show_results() {
    local results_dir=$1
    local output_dir=$2

    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ls -la ${results_dir}/${output_dir}/"
            ;;
        cpu_server|gpu_server)
            ls -la ${results_dir}/${output_dir}/
            ;;
    esac
}

# Get ANSI color code based on value ratio (green->yellow->red)
# Args: $1 = ratio (0.0 to 1.0)
get_color_for_ratio() {
    local ratio=$1

    # Convert ratio to integer percentage (0-100)
    local pct=$(awk -v r="$ratio" 'BEGIN {printf "%.0f", r * 100}')

    # Color thresholds:
    # >= 98%: Green (background)
    # >= 95%: Yellow (background)
    # <  95%: Red (background)
    if [ "$pct" -ge 98 ]; then
        printf '\033[42m\033[30m'  # Green background, black text
    elif [ "$pct" -ge 95 ]; then
        printf '\033[43m\033[30m'  # Yellow background, black text
    else
        printf '\033[41m\033[37m'  # Red background, white text
    fi
}

# Reset ANSI color
reset_color() {
    printf '\033[0m'
}

# Display colorized matrix from bandwidth.txt or latency.txt
# Args: $1 = results_dir, $2 = output_dir, $3 = file_type (bandwidth|latency)
display_colorized_matrix() {
    local results_dir=$1
    local output_dir=$2
    local file_type=$3
    local file_path="${results_dir}/${output_dir}/${file_type}.txt"

    # Check file existence based on environment
    local file_exists=0
    case ${RUN_ENV} in
        mac)
            if ssh ${CPU_SERVER_USER}@${CPU_SERVER} "[ -f ${file_path} ]" 2>/dev/null; then
                file_exists=1
            fi
            ;;
        cpu_server|gpu_server)
            if [ -f "${file_path}" ]; then
                file_exists=1
            fi
            ;;
    esac

    if [ $file_exists -eq 0 ]; then
        return 1
    fi

    # Read file content based on environment
    local content=""
    case ${RUN_ENV} in
        mac)
            content=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "cat ${file_path}" 2>/dev/null)
            ;;
        cpu_server|gpu_server)
            content=$(cat "${file_path}" 2>/dev/null)
            ;;
    esac

    if [ -z "$content" ]; then
        return 1
    fi

    # Parse the matrix data
    local in_matrix=0
    local matrix_lines=()
    local max_value=0

    # First pass: extract matrix and find max value (for bandwidth only)
    while IFS= read -r line; do
        if [[ "$line" =~ ^Rank: ]]; then
            in_matrix=1
            matrix_lines+=("$line")
            continue
        fi

        if [ $in_matrix -eq 1 ]; then
            if [[ "$line" =~ ^[[:space:]]*[0-9]+ ]]; then
                matrix_lines+=("$line")

                # Extract numeric values (skip diagonal 0.0 values)
                if [ "$file_type" == "bandwidth" ]; then
                    # Fix concatenated numbers like "0.0332928.0" -> "0.0 332928.0"
                    local fixed_line=$(echo "$line" | sed -E 's/([0-9])([0-9]{6,})/\1 \2/g')
                    local values=$(echo "$fixed_line" | awk '{for(i=3;i<=NF;i++) print $i}')
                    while IFS= read -r val; do
                        # Skip 0.0 values (diagonal)
                        if [ -n "$val" ] && [ "$val" != "0.0" ] && [ "$val" != "0" ] && awk -v v="$val" 'BEGIN {exit !(v > 0)}'; then
                            # Compare using awk for float comparison
                            local is_greater=$(awk -v v="$val" -v m="$max_value" 'BEGIN {print (v > m) ? 1 : 0}')
                            if [ "$is_greater" -eq 1 ]; then
                                max_value=$val
                            fi
                        fi
                    done <<< "$values"
                fi
            elif [[ "$line" =~ ^Minimum|^Maximum|^Average ]]; then
                continue
            elif [ -z "$line" ] || [[ ! "$line" =~ ^[[:space:]]*[0-9]+ ]]; then
                break
            fi
        fi
    done <<< "$content"

    # Build output buffer for fast display
    local output_buffer=""

    # Display title
    if [ "$file_type" == "bandwidth" ]; then
        output_buffer+="\n"
        output_buffer+="==========================================\n"
        output_buffer+="Bandwidth Matrix (Colorized)\n"
        output_buffer+="==========================================\n"
        output_buffer+="\n"
        output_buffer+="Color Legend: "
        output_buffer+='\033[42m\033[30m >= 0.98 \033[0m  '
        output_buffer+='\033[46m\033[30m >= 0.96 \033[0m  '
        output_buffer+='\033[43m\033[30m >= 0.94 \033[0m  '
        output_buffer+='\033[45m\033[30m >= 0.92 \033[0m  '
        output_buffer+='\033[41m\033[37m < 0.92 \033[0m'
        output_buffer+="\n\n"
    else
        output_buffer+="\n"
        output_buffer+="==========================================\n"
        output_buffer+="Latency Matrix (Colorized)\n"
        output_buffer+="==========================================\n"
        output_buffer+="\n"
        output_buffer+="Color Legend: "
        output_buffer+='\033[42m\033[30m <= 2.0us \033[0m  '
        output_buffer+='\033[46m\033[30m <= 2.5us \033[0m  '
        output_buffer+='\033[43m\033[30m <= 3.0us \033[0m  '
        output_buffer+='\033[45m\033[30m <= 4.5us \033[0m  '
        output_buffer+='\033[41m\033[37m > 4.5us \033[0m'
        output_buffer+="\n\n"
    fi

    # Second pass: build matrix display with colors
    for line in "${matrix_lines[@]}"; do
        if [[ "$line" =~ ^Rank: ]]; then
            # Build aligned header
            output_buffer+="    Rank:               "
            # Extract column headers with different spacing for bandwidth vs latency
            if [ "$file_type" == "bandwidth" ]; then
                output_buffer+=$(echo "$line" | awk '{for(i=2;i<=NF;i++) printf "%2s    ", $i; print ""}')
            else
                output_buffer+=$(echo "$line" | awk '{for(i=2;i<=NF;i++) printf "%2s     ", $i; print ""}')
            fi
            output_buffer+="\n"
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*[0-9]+ ]]; then
            # Fix concatenated numbers in the line first
            local fixed_line=$(echo "$line" | sed -E 's/([0-9])([0-9]{6,})/\1 \2/g')

            # Extract rank and host - format: "0 (GPU-17):"
            local rank=$(echo "$fixed_line" | awk '{print $1}')
            local host=$(echo "$fixed_line" | awk '{print $2}' | tr -d ':')

            # Build the row with rank and host
            local row_buffer=$(printf "%8s %-12s" "$rank" "$host")

            # Process each numeric value (starting from field 3)
            local values=$(echo "$fixed_line" | awk '{for(i=3;i<=NF;i++) print $i}')
            while IFS= read -r val; do
                if [ -z "$val" ]; then
                    continue
                fi

                if [ "$file_type" == "bandwidth" ]; then
                    # Calculate ratio for bandwidth
                    local ratio=$(awk -v v="$val" -v m="$max_value" 'BEGIN {
                        if (m == 0) print "0.0"
                        else if (v == 0) print "0.0"
                        else printf "%.4f", v / m
                    }')

                    # Format as percentage of max (0.98 format)
                    local display_val=$(awk -v r="$ratio" 'BEGIN {printf "%4.2f", r}')

                    # Get color based on ratio (skip color for 0.00 values)
                    if awk -v r="$ratio" 'BEGIN {exit !(r > 0.01)}'; then
                        if awk -v r="$ratio" 'BEGIN {exit !(r >= 0.98)}'; then
                            row_buffer+=$(printf "  \033[42m\033[30m%s\033[0m" "$display_val")  # Green
                        elif awk -v r="$ratio" 'BEGIN {exit !(r >= 0.96)}'; then
                            row_buffer+=$(printf "  \033[46m\033[30m%s\033[0m" "$display_val")  # Cyan
                        elif awk -v r="$ratio" 'BEGIN {exit !(r >= 0.94)}'; then
                            row_buffer+=$(printf "  \033[43m\033[30m%s\033[0m" "$display_val")  # Yellow
                        elif awk -v r="$ratio" 'BEGIN {exit !(r >= 0.92)}'; then
                            row_buffer+=$(printf "  \033[45m\033[30m%s\033[0m" "$display_val")  # Magenta
                        else
                            row_buffer+=$(printf "  \033[41m\033[37m%s\033[0m" "$display_val")  # Red
                        fi
                    else
                        row_buffer+=$(printf "  %4s" "$display_val")
                    fi
                else
                    # For latency, display with color based on value
                    if awk -v v="$val" 'BEGIN {exit !(v > 0.01)}'; then
                        local lat_val=$(awk -v v="$val" 'BEGIN {printf "%.2f", v}')
                        if awk -v v="$val" 'BEGIN {exit !(v <= 2.0)}'; then
                            row_buffer+=$(printf "  \033[42m\033[30m%5s\033[0m" "$lat_val")  # Green
                        elif awk -v v="$val" 'BEGIN {exit !(v <= 2.5)}'; then
                            row_buffer+=$(printf "  \033[46m\033[30m%5s\033[0m" "$lat_val")  # Cyan
                        elif awk -v v="$val" 'BEGIN {exit !(v <= 3.0)}'; then
                            row_buffer+=$(printf "  \033[43m\033[30m%5s\033[0m" "$lat_val")  # Yellow
                        elif awk -v v="$val" 'BEGIN {exit !(v <= 4.5)}'; then
                            row_buffer+=$(printf "  \033[45m\033[30m%5s\033[0m" "$lat_val")  # Magenta
                        else
                            row_buffer+=$(printf "  \033[41m\033[37m%5s\033[0m" "$lat_val")  # Red
                        fi
                    else
                        row_buffer+=$(printf "  %5s" "$val")
                    fi
                fi
            done <<< "$values"

            output_buffer+="${row_buffer}\n"
        fi
    done

    # Add summary statistics to buffer
    output_buffer+="\n"
    if [ "$file_type" == "bandwidth" ]; then
        local min_line=$(echo "$content" | grep "^Minimum bandwidth:")
        local max_line=$(echo "$content" | grep "^Maximum bandwidth:")
        local avg_line=$(echo "$content" | grep "^Average bandwidth:")

        [ -n "$min_line" ] && output_buffer+="${min_line}\n"
        [ -n "$max_line" ] && output_buffer+="${max_line} (Reference: 1.00)\n"
        [ -n "$avg_line" ] && output_buffer+="${avg_line}\n"
    else
        local min_line=$(echo "$content" | grep "^Minimum latency:")
        local max_line=$(echo "$content" | grep "^Maximum latency:")
        local avg_line=$(echo "$content" | grep "^Average latency:")

        [ -n "$min_line" ] && output_buffer+="${min_line}\n"
        [ -n "$max_line" ] && output_buffer+="${max_line}\n"
        [ -n "$avg_line" ] && output_buffer+="${avg_line}\n"
    fi

    output_buffer+="==========================================\n\n"

    # Output everything at once for smooth display
    printf "%b" "$output_buffer"

    return 0
}

# Setup NUMA binding on remote nodes
# This verifies numactl is available and detects NUMA topology on each node
# Args: $1 = hostfile_path, $2 = hca (e.g., "mlx5_9:1")
setup_remote_numa_binding() {
    local hostfile_path=$1
    local hca=$2

    log "  Verifying NUMA binding setup on remote nodes..."

    # Read hosts from hostfile
    local hosts=()
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        local host=$(echo "$line" | awk '{print $1}')
        [[ -n "$host" ]] && hosts+=("$host")
    done < "$hostfile_path"

    # Create temp directory for parallel checks
    local check_tmpdir="/tmp/numa_check_$$"
    mkdir -p "$check_tmpdir"

    # Parallel verification with 64 concurrency limit
    local parallel_limit=64
    local job_count=0

    # Verify numactl and detect NUMA node for each host in parallel
    for host in "${hosts[@]}"; do
        (
            # Detect NUMA node for this HCA on this specific host
            local host_numa_node=$(get_hca_numa_node "${hca}" "${host}")

            if [ ${host_numa_node} -ge 0 ]; then
                echo "${host}: HCA ${hca%%:*} on NUMA node ${host_numa_node}" > "$check_tmpdir/${host}.info"

                # Verify numactl is installed
                case ${RUN_ENV} in
                    mac)
                        ssh ${CPU_SERVER_USER}@${CPU_SERVER} "ssh ${host} 'which numactl > /dev/null 2>&1'" || echo "Warning: numactl not found" > "$check_tmpdir/${host}.warning"
                        ;;
                    cpu_server|gpu_server)
                        ssh ${host} "which numactl > /dev/null 2>&1" || echo "Warning: numactl not found" > "$check_tmpdir/${host}.warning"
                        ;;
                esac
            else
                echo "${host}: Warning - could not detect NUMA node for ${hca}" > "$check_tmpdir/${host}.warning"
            fi
        ) &

        ((job_count++))
        # Wait when reaching parallel limit
        if [ $((job_count % parallel_limit)) -eq 0 ]; then
            wait
        fi
    done

    # Wait for remaining parallel checks
    wait

    # Collect and display results
    for host in "${hosts[@]}"; do
        if [ -f "$check_tmpdir/${host}.info" ]; then
            log "    $(cat "$check_tmpdir/${host}.info")"
        fi
        if [ -f "$check_tmpdir/${host}.warning" ]; then
            log "      $(cat "$check_tmpdir/${host}.warning")"
        fi
    done

    # Cleanup
    rm -rf "$check_tmpdir"
}

# Extract latency from test output (take last occurrence for stress test mode)
extract_latency() {
    local output="$1"
    echo "${output}" | grep "Average latency:" | tail -1 | awk '{print $3}'
}

# Extract bandwidth from test output (take last occurrence for stress test mode)
extract_bandwidth() {
    local output="$1"
    echo "${output}" | grep "Average bandwidth:" | tail -1 | awk '{print $3}'
}

# Run single rail benchmark
run_single_rail_benchmark() {
    local hca=$1
    local gpu_host=$2
    local hostfile_path="${3:-${CURRENT_HOSTFILE}}"  # Use parameter or global variable

    # NUMA binding: detect HCA's NUMA node if --auto-numa is enabled
    local numa_node=-1
    local numa_mpi_opts=""

    if [ ${AUTO_NUMA} -eq 1 ]; then
        # Get NUMA node for this HCA (query from gpu_host)
        numa_node=$(get_hca_numa_node "${hca}" "${gpu_host}")

        if [ ${numa_node} -ge 0 ]; then
            log "  NUMA binding: HCA ${hca} on NUMA node ${numa_node}"

            # Verify NUMA binding setup on remote nodes
            setup_remote_numa_binding "${hostfile_path}" "${hca}"

            # Set GOMP_CPU_AFFINITY to bind processes to NUMA node CPUs
            # NUMA 0: CPUs 0-47,96-143
            # NUMA 1: CPUs 48-95,144-191
            if [ ${numa_node} -eq 0 ]; then
                numa_mpi_opts="-x GOMP_CPU_AFFINITY='0-47,96-143'"
                log "  MPI NUMA binding: node 0 (CPUs 0-47,96-143)"
            elif [ ${numa_node} -eq 1 ]; then
                numa_mpi_opts="-x GOMP_CPU_AFFINITY='48-95,144-191'"
                log "  MPI NUMA binding: node 1 (CPUs 48-95,144-191)"
            fi
        else
            log "  Warning: Could not detect NUMA node for ${hca}, skipping NUMA binding"
        fi
    fi

    # Build clusterkit.sh arguments for single rail
    local ck_args="--hostfile hostfile.txt --hca_list \"${hca}\""
    [ -n "${PPN}" ] && ck_args="${ck_args} --ppn ${PPN}"
    [ -n "${GPUDIRECT}" ] && ck_args="${ck_args} ${GPUDIRECT}"
    [ -n "${CONNECTX7}" ] && ck_args="${ck_args} ${CONNECTX7}"
    [ -n "${TRAFFIC_TIME}" ] && ck_args="${ck_args} --traffic ${TRAFFIC_TIME}"

    # Add NUMA MPI options if enabled
    if [ -n "${numa_mpi_opts}" ]; then
        ck_args="${ck_args} --mpi_opt \"${numa_mpi_opts}\""
    fi

    [ -n "${EXTRA_ARGS}" ] && ck_args="${ck_args} ${EXTRA_ARGS}"

    # Build remote execution command
    local remote_cmd="cd ${HPCX_HOME} && \
export HPCX_HOME=${HPCX_HOME} && \
source \${HPCX_HOME}/hpcx-init.sh && \
hpcx_load && \
./clusterkit/bin/clusterkit.sh ${ck_args}"

    # Execute test and capture output
    run_remote_cmd "${gpu_host}" "${remote_cmd}" 2>&1
}

# Check topology for all hosts in hostfile
# Returns: prints to stdout (table format) and saves to file if save_path provided
check_topology() {
    local hostfile_path=$1
    local save_path=$2  # Optional: path to save topology file
    local ca_dev=$3     # HCA device for sminfo/ibtracert (default: mlx5_0)
    ca_dev="${ca_dev:-mlx5_0}"

    # Batch size for parallel execution (avoid overloading IB SM)
    local BATCH_SIZE=10

    # Create a temporary script file for topology collection
    # Pass ca_dev as first argument to the script
    local topo_script_file="/tmp/topo_collect_$$.sh"
    cat > "${topo_script_file}" << 'TOPO_SCRIPT'
#!/bin/bash
CA_DEV="${1:-mlx5_0}"
# Collect GPU-NIC mapping first
tmpdir="/tmp/topo_$$"
mkdir -p "$tmpdir"

nvidia-smi topo -m 2>/dev/null | awk '
BEGIN { in_nic_legend = 0 }
/^NIC Legend:/ { in_nic_legend = 1; next }
in_nic_legend == 1 {
    if (length($0) == 0 || $0 ~ /^[ \t]*$/) { next }
    if ($0 ~ /^ *NIC[0-9]+:/) {
        gsub(/:/, "", $1)
        nic_num = substr($1, 4)
        nic_dev[nic_num] = $2
        next
    }
    in_nic_legend = 0
}
/^NIC[0-9]/ && in_nic_legend == 0 {
    nic_name = $1
    nic_num = substr(nic_name, 4)
    for (i=2; i<=9; i++) {
        if ($i == "PIX") {
            gpu_num = i - 2
            gpu_nic_map[gpu_num] = nic_num
        }
    }
}
END {
    for (gpu = 0; gpu <= 15; gpu++) {
        if (gpu in gpu_nic_map) {
            nic_num = gpu_nic_map[gpu]
            if (nic_num in nic_dev) {
                print "GPU" gpu "," nic_dev[nic_num]
            }
        }
    }
}
' > "$tmpdir/gpu_nic_list.txt"

# Get SM LID once using specified CA device
sm_lid=$(timeout 2 sminfo --Ca "$CA_DEV" 2>/dev/null | grep -oP "sm lid \K\d+")

# Query each HCA in parallel
# Note: sminfo uses specified CA_DEV, ibtracert uses each HCA's own device
while IFS="," read -r gpu mlx_dev; do
    (
        lid=$(ibstat "$mlx_dev" 2>/dev/null | grep -i "base lid" | awk '{print $3}')
        if [ -n "$lid" ] && [ -n "$sm_lid" ]; then
            switch_info=$(timeout 2 ibtracert --Ca "$mlx_dev" "$lid" "$sm_lid" 2>/dev/null | head -2 | tail -1)
            if [ -n "$switch_info" ] && [[ "$switch_info" == *"switch"* || "$switch_info" == *"["* ]]; then
                port=$(echo "$switch_info" | grep -oP "\[(\d+)\]" | tail -1 | tr -d "[]")
                switch=$(echo "$switch_info" | grep -oP '"[^"]+"' | tr -d '"')
                if [ -n "$port" ] && [ -n "$switch" ]; then
                    echo "$(hostname),$gpu,$mlx_dev,Port $port,$switch"
                else
                    echo "$(hostname),$gpu,$mlx_dev,PARSE_ERR,Failed to parse switch info"
                fi
            else
                echo "$(hostname),$gpu,$mlx_dev,ROUTE_ERR,ibtracert failed (SM lid: $sm_lid)"
            fi
        else
            echo "$(hostname),$gpu,$mlx_dev,NO_LID,ibstat/sminfo failed"
        fi
    ) > "$tmpdir/${gpu}.txt" &
done < "$tmpdir/gpu_nic_list.txt"
wait

# Output results in GPU order
for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -f "$tmpdir/GPU${i}.txt" ] && cat "$tmpdir/GPU${i}.txt"
done

rm -rf "$tmpdir"
TOPO_SCRIPT
    chmod +x "${topo_script_file}"

    # Collect all topology data using temp file (batched parallel execution)
    local topo_tmp_dir="/tmp/topo_data_$$"
    mkdir -p "${topo_tmp_dir}"

    # Build host list
    local hosts=()
    while IFS= read -r host || [ -n "$host" ]; do
        [ -z "$host" ] && continue
        hosts+=("$host")
    done < "${hostfile_path}"

    local total_hosts=${#hosts[@]}

    # Batched parallel topology collection
    case ${RUN_ENV} in
        mac)
            # Copy script to CPU server first
            scp -q "${topo_script_file}" ${CPU_SERVER_USER}@${CPU_SERVER}:/tmp/topo_collect.sh
            # Run batched collection on CPU server
            ssh -n ${CPU_SERVER_USER}@${CPU_SERVER} "
                hosts=(${hosts[*]})
                batch_size=${BATCH_SIZE}
                ca_dev=${ca_dev}
                total=\${#hosts[@]}
                for ((i=0; i<total; i+=batch_size)); do
                    # Process batch
                    for ((j=i; j<i+batch_size && j<total; j++)); do
                        host=\${hosts[\$j]}
                        (scp -q /tmp/topo_collect.sh \${host}:/tmp/topo_collect.sh 2>/dev/null && \
                         ssh -n -o ConnectTimeout=10 \${host} \"bash /tmp/topo_collect.sh \${ca_dev}\" 2>/dev/null) &
                    done
                    wait
                done
            " > "${topo_tmp_dir}/all.txt" 2>/dev/null
            ;;
        cpu_server|gpu_server)
            # Copy script to all hosts first (can be fully parallel, it's just scp)
            for host in "${hosts[@]}"; do
                scp -q "${topo_script_file}" ${host}:/tmp/topo_collect.sh 2>/dev/null &
            done
            wait

            # Execute in batches to avoid overloading IB SM
            for ((i=0; i<total_hosts; i+=BATCH_SIZE)); do
                # Process this batch
                for ((j=i; j<i+BATCH_SIZE && j<total_hosts; j++)); do
                    host="${hosts[$j]}"
                    ssh -n -o ConnectTimeout=10 ${host} "bash /tmp/topo_collect.sh ${ca_dev}" > "${topo_tmp_dir}/${host}.txt" 2>/dev/null &
                done
                wait
            done

            # Merge results
            cat "${topo_tmp_dir}"/*.txt > "${topo_tmp_dir}/all.txt" 2>/dev/null
            ;;
    esac

    rm -f "${topo_script_file}"

    # Merge results in hostfile order
    local all_topo_data=""
    case ${RUN_ENV} in
        cpu_server|gpu_server)
            # Results are in separate files per host, merge in order
            for host in "${hosts[@]}"; do
                if [ -f "${topo_tmp_dir}/${host}.txt" ]; then
                    all_topo_data+=$(cat "${topo_tmp_dir}/${host}.txt")$'\n'
                fi
            done
            ;;
        mac)
            # For mac mode, results are in all.txt, need to sort by hostname
            # Build a mapping of hostname to IP by querying each host
            # For simplicity, just use the data as-is (parallel order)
            all_topo_data=$(cat "${topo_tmp_dir}/all.txt" 2>/dev/null)
            ;;
    esac
    rm -rf "${topo_tmp_dir}"

    # Print header
    log_always "=========================================="
    log_always "GPU-NIC-Switch Topology Mapping"
    log_always "=========================================="
    log_always ""
    printf "%-15s %-6s %-10s %-10s %s\n" "Host" "GPU" "NIC" "Port" "Switch"
    log_always "----------------------------------------------------------------------"

    # Print data
    echo "${all_topo_data}" | while IFS=',' read -r hostname gpu nic port switch; do
        [ -z "$hostname" ] && continue
        printf "%-15s %-6s %-10s %-10s %s\n" "$hostname" "$gpu" "$nic" "$port" "$switch"
    done

    log_always "=========================================="

    # Save to file if path provided
    if [ -n "${save_path}" ]; then
        mkdir -p "$(dirname "${save_path}")"
        {
            echo "# GPU-NIC-Switch Topology Mapping"
            echo "# Generated: $(date)"
            echo "# Hostfile: ${hostfile_path}"
            echo ""
            printf "%-15s %-6s %-10s %-10s %s\n" "Host" "GPU" "NIC" "Port" "Switch"
            echo "----------------------------------------------------------------------"
            echo "${all_topo_data}" | while IFS=',' read -r hostname gpu nic port switch; do
                [ -z "$hostname" ] && continue
                printf "%-15s %-6s %-10s %-10s %s\n" "$hostname" "$gpu" "$nic" "$port" "$switch"
            done
        } > "${save_path}"
        log_always ""
        log_always "Topology saved to: ${save_path}"
    fi
}

# ==================== Argument Parsing ====================
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -f|--hostfile)
            HOSTFILE="$2"
            shift 2
            ;;
        -r|--hpcx_dir)
            HPCX_HOME="$2"
            shift 2
            ;;
        -d|--hca_list)
            HCA_LIST="$2"
            shift 2
            ;;
        -p|--ppn)
            PPN="$2"
            shift 2
            ;;
        --auto-hca)
            AUTO_HCA=1
            shift
            ;;
        --rail-by-rail|--rbr)
            RAIL_BY_RAIL=1
            AUTO_HCA=1  # rail-by-rail requires auto-hca
            shift
            ;;
        --check-topology)
            CHECK_TOPOLOGY=1
            shift
            ;;
        --check-health-only)
            CHECK_HEALTH_ONLY=1
            shift
            ;;
        --Ca)
            TOPO_CA_DEV="$2"
            shift 2
            ;;
        --output-csv)
            OUTPUT_CSV=1
            shift
            ;;
        -q|--quiet)
            QUIET_MODE=1
            shift
            ;;
        -G|--gpudirect)
            GPUDIRECT="--gpudirect"
            shift
            ;;
        -cx7|--connectx-7)
            CONNECTX7="--connectx-7"
            shift
            ;;
        -z|--traffic)
            TRAFFIC_TIME="$2"
            shift 2
            ;;
        --loop)
            LOOP_COUNT="$2"
            shift 2
            ;;
        --loop-test)
            LOOP_COUNT="$2"
            LOOP_TEST_MODE=1
            shift 2
            ;;
        --view)
            VIEW_RESULTS="$2"
            shift 2
            ;;
        --auto-reboot)
            AUTO_REBOOT=1
            shift
            ;;
        --reboot-interval)
            REBOOT_INTERVAL="$2"
            shift 2
            ;;
        --reboot-method)
            REBOOT_METHOD="$2"
            shift 2
            ;;
        --auto-remove-bad-nodes)
            AUTO_REMOVE_BAD_NODES=1
            shift
            ;;
        --min-nodes)
            MIN_NODES="$2"
            shift 2
            ;;
        --reset-optics)
            RESET_OPTICS=1
            shift
            ;;
        --optics-interval)
            OPTICS_RESET_INTERVAL="$2"
            shift 2
            ;;
        --auto-numa)
            AUTO_NUMA=1
            shift
            ;;
        --numa-policy)
            NUMA_POLICY="$2"
            shift 2
            ;;
        *)
            EXTRA_ARGS="${EXTRA_ARGS} $1"
            shift
            ;;
    esac
done

# ==================== Main Logic ====================

# Validate reboot method
if [[ "${REBOOT_METHOD}" != "reboot" && "${REBOOT_METHOD}" != "ipmi" ]]; then
    log_always "Error: Invalid reboot method '${REBOOT_METHOD}'"
    log_always "Valid options: 'reboot' (soft) or 'ipmi' (power cycle)"
    exit 1
fi

# Check if hostfile exists
HOSTFILE_PATH="${LOCAL_DIR}/${HOSTFILE}"
if [ ! -f "${HOSTFILE_PATH}" ]; then
    log_always "Error: hostfile not found: ${HOSTFILE_PATH}"
    exit 1
fi

# Get first GPU node from hostfile
GPU_HOST=$(head -1 "${HOSTFILE_PATH}")
if [ -z "${GPU_HOST}" ]; then
    log_always "Error: hostfile is empty"
    exit 1
fi

# ==================== Parameter Validation ====================
# Block -z (stress test) with --rbr (rail-by-rail) combination
if [ ${RAIL_BY_RAIL} -eq 1 ] && [ -n "${TRAFFIC_TIME}" ]; then
    log_always "Error: -z/--traffic (stress test) cannot be used with --rbr/--rail-by-rail"
    log_always "  Stress test is designed for sustained load testing on all HCAs together."
    log_always "  Rail-by-rail mode is for quick diagnostics per HCA."
    log_always ""
    log_always "Usage alternatives:"
    log_always "  Stress test:     ./ck-bench.sh --auto-hca -G -cx7 -z ${TRAFFIC_TIME}"
    log_always "  Rail-by-rail:    ./ck-bench.sh --rbr -G -cx7"
    exit 1
fi

# --rbr with --loop-test is now supported (每个循环都会执行完整的 rail-by-rail 测试)

# ==================== View Historical Results Mode ====================
if [ -n "${VIEW_RESULTS}" ]; then
    log_always "Viewing historical results: ${VIEW_RESULTS}"
    log_always ""

    # Check if path exists
    if [ ! -e "${VIEW_RESULTS}" ]; then
        log_always "Error: Path not found: ${VIEW_RESULTS}"
        exit 1
    fi

    # Determine if it's a file or directory
    if [ -f "${VIEW_RESULTS}" ]; then
        # It's a file - check if it's bandwidth.txt or latency.txt
        filename=$(basename "${VIEW_RESULTS}")
        dirpath=$(dirname "${VIEW_RESULTS}")
        parent_dir=$(dirname "${dirpath}")

        if [ "${filename}" == "bandwidth.txt" ] || [ "${filename}" == "latency.txt" ]; then
            file_type="${filename%.txt}"
            display_colorized_matrix "${parent_dir}" "$(basename ${dirpath})" "${file_type}" || true
        else
            log_always "Error: File must be bandwidth.txt or latency.txt"
            log_always "Got: ${filename}"
            exit 1
        fi
    elif [ -d "${VIEW_RESULTS}" ]; then
        # It's a directory - search for result files
        # Try to find all subdirectories with bandwidth.txt/latency.txt
        found_results=0

        # Check if this directory directly contains bandwidth.txt/latency.txt
        if [ -f "${VIEW_RESULTS}/bandwidth.txt" ] || [ -f "${VIEW_RESULTS}/latency.txt" ]; then
            parent_dir=$(dirname "${VIEW_RESULTS}")
            subdir=$(basename "${VIEW_RESULTS}")
            log_always "=========================================="
            log_always "Results in: ${VIEW_RESULTS}"
            log_always "=========================================="
            [ -f "${VIEW_RESULTS}/bandwidth.txt" ] && display_colorized_matrix "${parent_dir}" "${subdir}" "bandwidth" || true
            [ -f "${VIEW_RESULTS}/latency.txt" ] && display_colorized_matrix "${parent_dir}" "${subdir}" "latency" || true
            found_results=1
        else
            # Search for result directories (one level deep)
            for rail_dir in "${VIEW_RESULTS}"/*/; do
                [ -d "${rail_dir}" ] || continue

                # Check for nested timestamp directory (rail-by-rail structure)
                result_dir=""
                if [ -d "${rail_dir}" ]; then
                    # Find the first subdirectory (timestamp directory)
                    for subdir in "${rail_dir}"/*/; do
                        if [ -d "${subdir}" ] && ([ -f "${subdir}/bandwidth.txt" ] || [ -f "${subdir}/latency.txt" ]); then
                            result_dir=$(basename "${subdir}")
                            rail_name=$(basename "${rail_dir}")

                            log_always ""
                            log_always "=========================================="
                            log_always "Results for ${rail_name}:"
                            log_always "=========================================="

                            [ -f "${rail_dir}/${result_dir}/bandwidth.txt" ] && \
                                display_colorized_matrix "${rail_dir}" "${result_dir}" "bandwidth" || true
                            [ -f "${rail_dir}/${result_dir}/latency.txt" ] && \
                                display_colorized_matrix "${rail_dir}" "${result_dir}" "latency" || true

                            found_results=1
                            break
                        fi
                    done
                fi
            done
        fi

        if [ ${found_results} -eq 0 ]; then
            log_always "No bandwidth.txt or latency.txt files found in: ${VIEW_RESULTS}"
            log_always ""
            log_always "Expected structure:"
            log_always "  Directory with bandwidth.txt/latency.txt directly, or"
            log_always "  Rail-by-rail structure: <session_dir>/<rail_name>/<timestamp>/{bandwidth.txt,latency.txt}"
            exit 1
        fi
    else
        log_always "Error: Path is neither a file nor a directory: ${VIEW_RESULTS}"
        exit 1
    fi

    log_always ""
    exit 0
fi

# ==================== Check Topology Only Mode ====================
# If only --check-topology without --rbr, just show topology and exit
if [ ${CHECK_TOPOLOGY} -eq 1 ] && [ ${RAIL_BY_RAIL} -eq 0 ]; then
    TOPO_TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
    TOPO_SAVE_PATH="${LOCAL_DIR}/results/topology_${TOPO_TIMESTAMP}.txt"
    log "Using HCA device for topology query: ${TOPO_CA_DEV}"
    check_topology "${HOSTFILE_PATH}" "${TOPO_SAVE_PATH}" "${TOPO_CA_DEV}"
    exit 0
fi

# Set results directory based on environment
case ${RUN_ENV} in
    mac)
        RESULTS_DIR="${REMOTE_DIR}/results"
        RESULTS_DISPLAY="${CPU_SERVER_USER}@${CPU_SERVER}:${RESULTS_DIR}"
        ;;
    cpu_server)
        # Use script directory for results (not hardcoded REMOTE_DIR)
        RESULTS_DIR="${LOCAL_DIR}/results"
        RESULTS_DISPLAY="${RESULTS_DIR}"
        ;;
    gpu_server)
        RESULTS_DIR="${LOCAL_DIR}/results"
        RESULTS_DISPLAY="${RESULTS_DIR}"
        ;;
esac

# Auto-detect HCAs if enabled
if [ ${AUTO_HCA} -eq 1 ]; then
    log "Auto-detecting GPU-associated HCAs from ${GPU_HOST}..."
    HCA_LIST=$(get_gpu_hca_list "${GPU_HOST}")
    if [ -z "${HCA_LIST}" ]; then
        log_always "Error: failed to auto-detect HCA list"
        exit 1
    fi
    log "Detected HCA list: ${HCA_LIST}"
    log ""
fi

# ==================== Rail-by-Rail Mode ====================
if [ ${RAIL_BY_RAIL} -eq 1 ]; then
    # Create timestamp for this test session
    SESSION_TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

    # Get first and last host from hostfile for directory naming
    FIRST_HOST=$(head -1 "${HOSTFILE_PATH}")
    LAST_HOST=$(tail -1 "${HOSTFILE_PATH}")
    HOST_RANGE="${FIRST_HOST}-${LAST_HOST}"

    # Build session directory name with host range
    SESSION_DIR="rbr_${SESSION_TIMESTAMP}_${HOST_RANGE}"

    # Create results directory
    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "mkdir -p ${RESULTS_DIR}/${SESSION_DIR}"
            ;;
        cpu_server|gpu_server)
            mkdir -p ${RESULTS_DIR}/${SESSION_DIR}
            ;;
    esac

    log "=========================================="
    log "ClusterKit Rail-by-Rail Benchmark"
    log "=========================================="
    log "Environment: ${RUN_ENV}"
    log "Script dir:  ${LOCAL_DIR}"
    log "GPU server:  ${GPU_HOST}"
    log "HPCX path:   ${HPCX_HOME}"
    log "Hostfile:    ${HOSTFILE}"
    log "HCA list:    ${HCA_LIST}"
    [ -n "${GPUDIRECT}" ] && log "GPUDirect:   enabled"
    [ -n "${CONNECTX7}" ] && log "ConnectX-7:  enabled"
    [ -n "${TRAFFIC_TIME}" ] && log "Stress test: ${TRAFFIC_TIME} minutes"
    log "Results dir: ${RESULTS_DISPLAY}/${SESSION_DIR}"
    log "=========================================="
    log ""

    # Check topology if requested
    if [ ${CHECK_TOPOLOGY} -eq 1 ]; then
        log "[0/4] Checking topology (using ${TOPO_CA_DEV})..."
        TOPO_SAVE_PATH="${RESULTS_DIR}/${SESSION_DIR}/topology.txt"
        case ${RUN_ENV} in
            mac)
                # For mac, save to local temp first then upload
                LOCAL_TOPO_TMP="/tmp/topology_${SESSION_TIMESTAMP}.txt"
                check_topology "${HOSTFILE_PATH}" "${LOCAL_TOPO_TMP}" "${TOPO_CA_DEV}"
                scp -q "${LOCAL_TOPO_TMP}" ${CPU_SERVER_USER}@${CPU_SERVER}:${TOPO_SAVE_PATH}
                rm -f "${LOCAL_TOPO_TMP}"
                ;;
            cpu_server|gpu_server)
                check_topology "${HOSTFILE_PATH}" "${TOPO_SAVE_PATH}" "${TOPO_CA_DEV}"
                ;;
        esac
        log ""
    fi

    # Upload hostfile
    log "[1/4] Uploading hostfile to GPU server..."
    upload_hostfile "${HOSTFILE_PATH}" "${GPU_HOST}"
    log "Hostfile ready"
    log ""

    # Convert HCA list to array
    IFS=',' read -ra HCA_ARRAY <<< "${HCA_LIST}"
    TOTAL_RAILS=${#HCA_ARRAY[@]}

    # Arrays to store results
    declare -a RAIL_NAMES
    declare -a RAIL_LATENCIES
    declare -a RAIL_BANDWIDTHS

    log "[2/4] Running rail-by-rail benchmark..."
    log ""

    # Test each rail
    for i in "${!HCA_ARRAY[@]}"; do
        hca="${HCA_ARRAY[$i]}"
        rail_num=$((i + 1))
        rail_name="${hca%:*}"  # Remove :1 suffix for display

        log "----------------------------------------"
        log "Testing rail ${rail_num}/${TOTAL_RAILS}: ${rail_name}"
        log "----------------------------------------"

        # Run benchmark for this rail with real-time output
        OUTPUT_TMP="/tmp/ck_bench_rail_$$.txt"
        if [ ${QUIET_MODE} -eq 0 ]; then
            run_single_rail_benchmark "${hca}" "${GPU_HOST}" "${HOSTFILE_PATH}" 2>&1 | tee "${OUTPUT_TMP}" || true
        else
            run_single_rail_benchmark "${hca}" "${GPU_HOST}" "${HOSTFILE_PATH}" > "${OUTPUT_TMP}" 2>&1 || true
        fi
        OUTPUT=$(cat "${OUTPUT_TMP}")
        rm -f "${OUTPUT_TMP}"

        # Extract metrics
        latency=$(extract_latency "${OUTPUT}")
        bandwidth=$(extract_bandwidth "${OUTPUT}")

        # Store results
        RAIL_NAMES+=("${rail_name}")
        RAIL_LATENCIES+=("${latency:-N/A}")
        RAIL_BANDWIDTHS+=("${bandwidth:-N/A}")

        # Extract and download results (only the timestamp directory, not full path)
        OUTPUT_DIR=$(echo "${OUTPUT}" | grep "Output directory:" | tail -1 | awk '{print $NF}' | sed 's:/$::' | xargs basename)
        if [ -n "${OUTPUT_DIR}" ]; then
            download_results "${GPU_HOST}" "${OUTPUT_DIR}" "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}"
        fi

        log "  Latency:   ${latency:-N/A} usec"
        log "  Bandwidth: ${bandwidth:-N/A} MB/s"
        log ""

        # Display colorized matrix immediately after each rail test (if not in quiet/csv mode)
        if [ ${OUTPUT_CSV} -eq 0 ] && [ ${QUIET_MODE} -eq 0 ]; then
            # Find the actual result directory (nested)
            rail_result_dir=""
            case ${RUN_ENV} in
                mac)
                    rail_result_dir=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "find ${RESULTS_DIR}/${SESSION_DIR}/${rail_name} -mindepth 1 -maxdepth 1 -type d | head -1 | xargs basename" 2>/dev/null)
                    ;;
                cpu_server|gpu_server)
                    rail_result_dir=$(find ${RESULTS_DIR}/${SESSION_DIR}/${rail_name} -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 | xargs basename)
                    ;;
            esac

            if [ -n "$rail_result_dir" ]; then
                log_always ""
                log_always "=========================================="
                log_always "Results for ${rail_name}:"
                log_always "=========================================="
                display_colorized_matrix "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}" "${rail_result_dir}" "bandwidth" || true
                display_colorized_matrix "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}" "${rail_result_dir}" "latency" || true
            fi
        fi
    done

    log "[3/4] Saving results..."

    # Prepare CSV content
    CSV_CONTENT="Rail,Latency(usec),Bandwidth(MB/s)"
    for i in "${!RAIL_NAMES[@]}"; do
        CSV_CONTENT="${CSV_CONTENT}"$'\n'"${RAIL_NAMES[$i]},${RAIL_LATENCIES[$i]},${RAIL_BANDWIDTHS[$i]}"
    done

    # Save CSV file
    CSV_FILE="${RESULTS_DIR}/${SESSION_DIR}/summary.csv"
    case ${RUN_ENV} in
        mac)
            echo "${CSV_CONTENT}" | ssh ${CPU_SERVER_USER}@${CPU_SERVER} "cat > ${CSV_FILE}"
            ;;
        cpu_server|gpu_server)
            echo "${CSV_CONTENT}" > "${CSV_FILE}"
            ;;
    esac

    log "[4/4] Done"
    log ""

    # Print summary report
    if [ ${OUTPUT_CSV} -eq 1 ]; then
        # CSV output to stdout
        log_always "${CSV_CONTENT}"
    else
        # Table output
        log_always "=========================================="
        log_always "Rail-by-Rail Test Summary"
        log_always "=========================================="
        printf "%-12s %15s %18s\n" "Rail" "Latency(usec)" "Bandwidth(MB/s)"
        log_always "------------------------------------------"
        for i in "${!RAIL_NAMES[@]}"; do
            printf "%-12s %15s %18s\n" "${RAIL_NAMES[$i]}" "${RAIL_LATENCIES[$i]}" "${RAIL_BANDWIDTHS[$i]}"
        done
        log_always "=========================================="
    fi

    log_always ""
    log_always "Results saved to: ${RESULTS_DISPLAY}/${SESSION_DIR}/"
    log_always "  - summary.csv (benchmark results)"
    [ ${CHECK_TOPOLOGY} -eq 1 ] && log_always "  - topology.txt (GPU-NIC-Switch mapping)"

    # Display colorized matrix for each rail
    if [ ${OUTPUT_CSV} -eq 0 ]; then
        for i in "${!RAIL_NAMES[@]}"; do
            rail_name="${RAIL_NAMES[$i]}"
            log_always ""
            log_always "=========================================="
            log_always "Results for ${rail_name}:"
            log_always "=========================================="

            # Find the actual result directory (it's nested: SESSION_DIR/rail_name/timestamp/)
            # Get the first (and should be only) subdirectory
            rail_result_dir=""
            case ${RUN_ENV} in
                mac)
                    rail_result_dir=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "find ${RESULTS_DIR}/${SESSION_DIR}/${rail_name} -mindepth 1 -maxdepth 1 -type d | head -1 | xargs basename" 2>/dev/null)
                    ;;
                cpu_server|gpu_server)
                    rail_result_dir=$(find ${RESULTS_DIR}/${SESSION_DIR}/${rail_name} -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 | xargs basename)
                    ;;
            esac

            if [ -n "$rail_result_dir" ]; then
                display_colorized_matrix "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}" "${rail_result_dir}" "bandwidth" || true
                display_colorized_matrix "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}" "${rail_result_dir}" "latency" || true
            fi
        done
    fi
fi

# Run rail-by-rail benchmark round (called from main loop)
run_railbyrail_round() {
    local round_num=$1
    local total_rounds=$2

    # Create timestamp for this test session
    SESSION_TIMESTAMP=$(date "+%Y%m%d_%H%M%S")

    # Get first and last host from hostfile for directory naming
    FIRST_HOST=$(head -1 "${HOSTFILE_PATH}")
    LAST_HOST=$(tail -1 "${HOSTFILE_PATH}")
    HOST_RANGE="${FIRST_HOST}-${LAST_HOST}"

    # Build session directory name with host range and round number
    if [ ${total_rounds} -gt 1 ]; then
        SESSION_DIR="rbr_${SESSION_TIMESTAMP}_round${round_num}_${HOST_RANGE}"
    else
        SESSION_DIR="rbr_${SESSION_TIMESTAMP}_${HOST_RANGE}"
    fi

    # Create results directory
    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "mkdir -p ${RESULTS_DIR}/${SESSION_DIR}"
            ;;
        cpu_server|gpu_server)
            mkdir -p ${RESULTS_DIR}/${SESSION_DIR}
            ;;
    esac

    log "=========================================="
    log "ClusterKit Rail-by-Rail Benchmark"
    log "=========================================="
    log "Environment: ${RUN_ENV}"
    log "Script dir:  ${LOCAL_DIR}"
    log "GPU server:  ${GPU_HOST}"
    log "HPCX path:   ${HPCX_HOME}"
    log "Hostfile:    ${HOSTFILE}"
    log "HCA list:    ${HCA_LIST}"
    [ -n "${GPUDIRECT}" ] && log "GPUDirect:   enabled"
    [ -n "${CONNECTX7}" ] && log "ConnectX-7:  enabled"
    [ -n "${TRAFFIC_TIME}" ] && log "Stress test: ${TRAFFIC_TIME} minutes"
    log "Results dir: ${RESULTS_DISPLAY}/${SESSION_DIR}"
    log "=========================================="
    log ""

    # Check topology if requested
    if [ ${CHECK_TOPOLOGY} -eq 1 ]; then
        log "[0/4] Checking topology (using ${TOPO_CA_DEV})..."
        TOPO_SAVE_PATH="${RESULTS_DIR}/${SESSION_DIR}/topology.txt"
        case ${RUN_ENV} in
            mac)
                # For mac, save to local temp first then upload
                LOCAL_TOPO_TMP="/tmp/topology_${SESSION_TIMESTAMP}.txt"
                check_topology "${HOSTFILE_PATH}" "${LOCAL_TOPO_TMP}" "${TOPO_CA_DEV}"
                scp -q "${LOCAL_TOPO_TMP}" ${CPU_SERVER_USER}@${CPU_SERVER}:${TOPO_SAVE_PATH}
                rm -f "${LOCAL_TOPO_TMP}"
                ;;
            cpu_server|gpu_server)
                check_topology "${HOSTFILE_PATH}" "${TOPO_SAVE_PATH}" "${TOPO_CA_DEV}"
                ;;
        esac
        log ""
    fi

    # Upload hostfile
    log "[1/4] Uploading hostfile to GPU server..."
    upload_hostfile "${HOSTFILE_PATH}" "${GPU_HOST}"
    log "Hostfile ready"
    log ""

    # Convert HCA list to array
    IFS=',' read -ra HCA_ARRAY <<< "${HCA_LIST}"
    TOTAL_RAILS=${#HCA_ARRAY[@]}

    # Arrays to store results
    declare -a RAIL_NAMES
    declare -a RAIL_LATENCIES
    declare -a RAIL_BANDWIDTHS

    log "[2/4] Running rail-by-rail benchmark..."
    log ""

    # Test each rail
    for i in "${!HCA_ARRAY[@]}"; do
        hca="${HCA_ARRAY[$i]}"
        rail_num=$((i + 1))
        rail_name="${hca%:*}"  # Remove :1 suffix for display

        log "----------------------------------------"
        log "Testing rail ${rail_num}/${TOTAL_RAILS}: ${rail_name}"
        log "----------------------------------------"

        # Run benchmark for this rail with real-time output
        OUTPUT_TMP="/tmp/ck_bench_rail_$$.txt"
        if [ ${QUIET_MODE} -eq 0 ]; then
            run_single_rail_benchmark "${hca}" "${GPU_HOST}" "${HOSTFILE_PATH}" 2>&1 | tee "${OUTPUT_TMP}" || true
        else
            run_single_rail_benchmark "${hca}" "${GPU_HOST}" "${HOSTFILE_PATH}" > "${OUTPUT_TMP}" 2>&1 || true
        fi
        OUTPUT=$(cat "${OUTPUT_TMP}")
        rm -f "${OUTPUT_TMP}"

        # Extract metrics
        latency=$(extract_latency "${OUTPUT}")
        bandwidth=$(extract_bandwidth "${OUTPUT}")

        # Store results
        RAIL_NAMES+=("${rail_name}")
        RAIL_LATENCIES+=("${latency:-N/A}")
        RAIL_BANDWIDTHS+=("${bandwidth:-N/A}")

        # Extract and download results (only the timestamp directory, not full path)
        OUTPUT_DIR=$(echo "${OUTPUT}" | grep "Output directory:" | tail -1 | awk '{print $NF}' | sed 's:/$::' | xargs basename)
        if [ -n "${OUTPUT_DIR}" ]; then
            download_results "${GPU_HOST}" "${OUTPUT_DIR}" "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}"
        fi

        log "  Latency:   ${latency:-N/A} usec"
        log "  Bandwidth: ${bandwidth:-N/A} MB/s"
        log ""

        # Display colorized matrix immediately after each rail test (if not in quiet/csv mode)
        if [ ${OUTPUT_CSV} -eq 0 ] && [ ${QUIET_MODE} -eq 0 ]; then
            # Find the actual result directory (nested)
            rail_result_dir=""
            case ${RUN_ENV} in
                mac)
                    rail_result_dir=$(ssh ${CPU_SERVER_USER}@${CPU_SERVER} "find ${RESULTS_DIR}/${SESSION_DIR}/${rail_name} -mindepth 1 -maxdepth 1 -type d | head -1 | xargs basename" 2>/dev/null)
                    ;;
                cpu_server|gpu_server)
                    rail_result_dir=$(find ${RESULTS_DIR}/${SESSION_DIR}/${rail_name} -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 | xargs basename)
                    ;;
            esac

            if [ -n "$rail_result_dir" ]; then
                log_always ""
                log_always "=========================================="
                log_always "Results for ${rail_name}:"
                log_always "=========================================="
                display_colorized_matrix "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}" "${rail_result_dir}" "bandwidth" || true
                display_colorized_matrix "${RESULTS_DIR}/${SESSION_DIR}/${rail_name}" "${rail_result_dir}" "latency" || true
            fi
        fi
    done

    log "[3/4] Saving results..."

    # Prepare CSV content
    CSV_CONTENT="Rail,Latency(usec),Bandwidth(MB/s)"
    for i in "${!RAIL_NAMES[@]}"; do
        CSV_CONTENT="${CSV_CONTENT}"$'\n'"${RAIL_NAMES[$i]},${RAIL_LATENCIES[$i]},${RAIL_BANDWIDTHS[$i]}"
    done

    # Save CSV file
    CSV_FILE="${RESULTS_DIR}/${SESSION_DIR}/summary.csv"
    case ${RUN_ENV} in
        mac)
            echo "${CSV_CONTENT}" | ssh ${CPU_SERVER_USER}@${CPU_SERVER} "cat > ${CSV_FILE}"
            ;;
        cpu_server|gpu_server)
            echo "${CSV_CONTENT}" > "${CSV_FILE}"
            ;;
    esac

    log "[4/4] Done"
    log ""

    # Print summary report
    if [ ${OUTPUT_CSV} -eq 1 ]; then
        # CSV output to stdout
        log_always "${CSV_CONTENT}"
    else
        # Table output
        log_always "=========================================="
        log_always "Rail-by-Rail Test Summary"
        log_always "=========================================="
        printf "%-12s %15s %18s\n" "Rail" "Latency(usec)" "Bandwidth(MB/s)"
        log_always "------------------------------------------"
        for i in "${!RAIL_NAMES[@]}"; do
            printf "%-12s %15s %18s\n" "${RAIL_NAMES[$i]}" "${RAIL_LATENCIES[$i]}" "${RAIL_BANDWIDTHS[$i]}"
        done
        log_always "=========================================="
    fi

    log_always ""
    log_always "Results saved to: ${RESULTS_DISPLAY}/${SESSION_DIR}/"
    log_always "  - summary.csv (benchmark results)"
    [ ${CHECK_TOPOLOGY} -eq 1 ] && log_always "  - topology.txt (GPU-NIC-Switch mapping)"
}

# Run single benchmark round
run_benchmark_round() {
    local round_num=$1
    local total_rounds=$2

    if [ ${total_rounds} -gt 1 ]; then
        log_always ""
        log_always "=========================================="
        log_always "Round ${round_num}/${total_rounds}"
        log_always "=========================================="
    fi

    log "=========================================="
    log "ClusterKit Benchmark"
    log "=========================================="
    log "Environment: ${RUN_ENV}"
    log "Script dir:  ${LOCAL_DIR}"
    log "GPU server:  ${GPU_HOST}"
    log "HPCX path:   ${HPCX_HOME}"
    log "Hostfile:    ${HOSTFILE}"
    [ -n "${HCA_LIST}" ] && log "HCA list:    ${HCA_LIST}"
    [ -n "${GPUDIRECT}" ] && log "GPUDirect:   enabled"
    [ -n "${CONNECTX7}" ] && log "ConnectX-7:  enabled"
    [ -n "${TRAFFIC_TIME}" ] && log "Stress test: ${TRAFFIC_TIME} minutes"
    [ -n "${EXTRA_ARGS}" ] && log "Extra args:  ${EXTRA_ARGS}"
    log "Results dir: ${RESULTS_DISPLAY}"
    log "=========================================="
    log ""

    # NUMA binding for normal mode (non-rail-by-rail)
    local numa_mpi_opts=""
    local numa_node=""

    if [ ${AUTO_NUMA} -eq 1 ]; then
        local policy="${NUMA_POLICY:-auto}"

        # In normal mode, try to detect NUMA from first HCA or use policy
        if [ -n "${HCA_LIST}" ]; then
            # Get first HCA from list
            local first_hca=$(echo "${HCA_LIST}" | cut -d',' -f1 | xargs)
            numa_node=$(get_hca_numa_node "${first_hca}" "${GPU_HOST}")

            if [ ${numa_node} -ge 0 ]; then
                log "NUMA binding: Using NUMA node ${numa_node} (from HCA ${first_hca})"
            fi
        elif [ "${policy}" = "node0" ]; then
            numa_node=0
            log "NUMA binding: Forcing NUMA node 0"
        elif [ "${policy}" = "node1" ]; then
            numa_node=1
            log "NUMA binding: Forcing NUMA node 1"
        fi

        # Build MPI NUMA binding options if valid node detected
        if [ "${numa_node}" != "" ] && [ ${numa_node} -ge 0 ]; then
            # Verify NUMA binding setup on remote nodes (parallel)
            if [ -n "${HCA_LIST}" ]; then
                local first_hca=$(echo "${HCA_LIST}" | cut -d',' -f1 | xargs)
                setup_remote_numa_binding "${HOSTFILE_PATH}" "${first_hca}"
            fi

            # Use GOMP_CPU_AFFINITY to bind OpenMP threads to NUMA node CPUs
            # This will be passed as MPI environment variable
            # NUMA 0: CPUs 0-47,96-143
            # NUMA 1: CPUs 48-95,144-191
            if [ ${numa_node} -eq 0 ]; then
                numa_mpi_opts="-x GOMP_CPU_AFFINITY='0-47,96-143'"
                log "MPI NUMA binding: node 0 (CPUs 0-47,96-143)"
            elif [ ${numa_node} -eq 1 ]; then
                numa_mpi_opts="-x GOMP_CPU_AFFINITY='48-95,144-191'"
                log "MPI NUMA binding: node 1 (CPUs 48-95,144-191)"
            fi
        fi
    fi

    # Build clusterkit.sh arguments
    CK_ARGS="--hostfile hostfile.txt"
    [ -n "${HCA_LIST}" ] && CK_ARGS="${CK_ARGS} --hca_list \"${HCA_LIST}\""
    [ -n "${PPN}" ] && CK_ARGS="${CK_ARGS} --ppn ${PPN}"
    [ -n "${GPUDIRECT}" ] && CK_ARGS="${CK_ARGS} ${GPUDIRECT}"
    [ -n "${CONNECTX7}" ] && CK_ARGS="${CK_ARGS} ${CONNECTX7}"
    [ -n "${TRAFFIC_TIME}" ] && CK_ARGS="${CK_ARGS} --traffic ${TRAFFIC_TIME}"

    # Add MPI NUMA binding options if enabled
    if [ -n "${numa_mpi_opts}" ]; then
        CK_ARGS="${CK_ARGS} --mpi_opt \"${numa_mpi_opts}\""
        log "MPI options: ${numa_mpi_opts}"
    fi

    [ -n "${EXTRA_ARGS}" ] && CK_ARGS="${CK_ARGS} ${EXTRA_ARGS}"

    log "[2/4] Running benchmark..."
    log "Command: ./clusterkit/bin/clusterkit.sh ${CK_ARGS}"
    log ""

    # Build remote execution command
    REMOTE_CMD="cd ${HPCX_HOME} && \
    export HPCX_HOME=${HPCX_HOME} && \
    source \${HPCX_HOME}/hpcx-init.sh && \
    hpcx_load && \
    ./clusterkit/bin/clusterkit.sh ${CK_ARGS}"
    
    # Execute test with real-time output (use tee to both display and capture)
    OUTPUT_TMP="/tmp/ck_bench_output_$$.txt"
    run_remote_cmd "${GPU_HOST}" "${REMOTE_CMD}" 2>&1 | tee "${OUTPUT_TMP}" || true
    log ""
    
    # Read captured output for parsing
    OUTPUT=$(cat "${OUTPUT_TMP}")
    rm -f "${OUTPUT_TMP}"
    
    # Extract output directory name from output (only the timestamp directory, not full path)
    # Example: "Output directory: /tmp/hpcx.../20251124_071936/" -> "20251124_071936"
    OUTPUT_DIR_ORIG=$(echo "${OUTPUT}" | grep "Output directory:" | tail -1 | awk '{print $NF}' | sed 's:/$::')
    if [ -n "${OUTPUT_DIR_ORIG}" ]; then
        OUTPUT_DIR_ORIG=$(basename "${OUTPUT_DIR_ORIG}")
    fi
    
    if [ -z "${OUTPUT_DIR_ORIG}" ]; then
        log_always "Warning: could not get output directory name"
        log_always "=========================================="
        log_always "Benchmark completed (results not downloaded)"
        log_always "=========================================="
        return 1
    fi
    
    # Build descriptive output directory name
    # Get first and last host from hostfile
    FIRST_HOST=$(head -1 "${HOSTFILE_PATH}")
    LAST_HOST=$(tail -1 "${HOSTFILE_PATH}")
    HOST_RANGE="${FIRST_HOST}-${LAST_HOST}"
    
    # Count number of HCAs (comma-separated)
    if [ -n "${HCA_LIST}" ]; then
        HCA_COUNT=$(echo "${HCA_LIST}" | tr ',' '\n' | wc -l | tr -d ' ')
        FIRST_HCA=$(echo "${HCA_LIST}" | cut -d',' -f1 | cut -d':' -f1)
    else
        HCA_COUNT=0
        FIRST_HCA=""
    fi
    
    # Build output directory name:
    # Single HCA: 20251124_083417_10.0.10.1-10.0.10.9_mlx5_0
    # Multiple HCAs: 20251124_083417_10.0.10.1-10.0.10.9
    # Loop mode: 20251124_083417_10.0.10.1-10.0.10.9_loop1
    if [ ${total_rounds} -gt 1 ]; then
        # Loop mode: add loop number
        if [ "${HCA_COUNT}" -eq 1 ]; then
            OUTPUT_DIR="${OUTPUT_DIR_ORIG}_${HOST_RANGE}_${FIRST_HCA}_loop${round_num}"
        else
            OUTPUT_DIR="${OUTPUT_DIR_ORIG}_${HOST_RANGE}_loop${round_num}"
        fi
    else
        # Normal mode: no loop number
        if [ "${HCA_COUNT}" -eq 1 ]; then
            OUTPUT_DIR="${OUTPUT_DIR_ORIG}_${HOST_RANGE}_${FIRST_HCA}"
        else
            OUTPUT_DIR="${OUTPUT_DIR_ORIG}_${HOST_RANGE}"
        fi
    fi
    
    log "[3/4] Downloading results..."
    log "Output directory: ${OUTPUT_DIR}"
    download_results "${GPU_HOST}" "${OUTPUT_DIR_ORIG}" "${RESULTS_DIR}"
    
    # Rename to descriptive name
    case ${RUN_ENV} in
        mac)
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "cd ${RESULTS_DIR} && mv ${OUTPUT_DIR_ORIG} ${OUTPUT_DIR}" 2>/dev/null || true
            ;;
        cpu_server|gpu_server)
            mv "${RESULTS_DIR}/${OUTPUT_DIR_ORIG}" "${RESULTS_DIR}/${OUTPUT_DIR}" 2>/dev/null || true
            ;;
    esac

    # Set health log file path for this round
    HEALTH_LOG_FILE="${RESULTS_DIR}/${OUTPUT_DIR}/health_check.log"

    log ""
    log "[4/4] Done"
    
    # Extract and display summary
    latency=$(extract_latency "${OUTPUT}")
    bandwidth=$(extract_bandwidth "${OUTPUT}")
    
    # For stress test mode, extract all bandwidth samples
    if [ -n "${TRAFFIC_TIME}" ]; then
        # Extract all bandwidth values (one per minute)
        BANDWIDTH_SAMPLES=$(echo "${OUTPUT}" | grep "Average bandwidth:" | awk '{print $3}')
        SAMPLE_COUNT=$(echo "${BANDWIDTH_SAMPLES}" | wc -l | tr -d ' ')
    
        # Save bandwidth samples to CSV
        SUMMARY_FILE="${RESULTS_DIR}/${OUTPUT_DIR}/summary.csv"
        case ${RUN_ENV} in
            mac)
                {
                    echo "Sample,Bandwidth(MB/s)"
                    i=1
                    echo "${BANDWIDTH_SAMPLES}" | while read bw; do
                        echo "${i},${bw}"
                        i=$((i + 1))
                    done
                } | ssh ${CPU_SERVER_USER}@${CPU_SERVER} "cat > ${SUMMARY_FILE}"
                ;;
            cpu_server|gpu_server)
                {
                    echo "Sample,Bandwidth(MB/s)"
                    i=1
                    echo "${BANDWIDTH_SAMPLES}" | while read bw; do
                        echo "${i},${bw}"
                        i=$((i + 1))
                    done
                } > "${SUMMARY_FILE}"
                ;;
        esac
    fi
    
    if [ ${OUTPUT_CSV} -eq 1 ]; then
        if [ -n "${TRAFFIC_TIME}" ]; then
            # Stress test CSV output (all samples)
            log_always "Sample,Bandwidth(MB/s)"
            i=1
            echo "${BANDWIDTH_SAMPLES}" | while read bw; do
                log_always "${i},${bw}"
                i=$((i + 1))
            done
        else
            log_always "HCA,Latency(usec),Bandwidth(MB/s)"
            log_always "${HCA_LIST:-all},${latency:-N/A},${bandwidth:-N/A}"
        fi
    else
        log_always "=========================================="
        log_always "Benchmark Summary"
        log_always "=========================================="
        # Only show latency if available (not in stress test mode)
        if [ -n "${latency}" ]; then
            log_always "Latency:   ${latency} usec"
        fi
        log_always "Bandwidth: ${bandwidth:-N/A} MB/s"
        # Show sample count for stress test
        if [ -n "${TRAFFIC_TIME}" ]; then
            log_always "Samples:   ${SAMPLE_COUNT} (saved to summary.csv)"
        fi
        log_always "=========================================="
        log_always ""
        log_always "Results saved to: ${RESULTS_DISPLAY}/${OUTPUT_DIR}"
    
        # Show result files
        log ""
        log "Result files:"
        show_results "${RESULTS_DIR}" "${OUTPUT_DIR}"

        # Display colorized matrix results
        log ""
        display_colorized_matrix "${RESULTS_DIR}" "${OUTPUT_DIR}" "bandwidth" || true
        display_colorized_matrix "${RESULTS_DIR}" "${OUTPUT_DIR}" "latency" || true
    fi
    }
    
    # ==================== Main Loop Logic ====================

# Check if only health check is requested
if [ ${CHECK_HEALTH_ONLY} -eq 1 ]; then
    log_always ""
    log_always "=========================================="
    log_always "Health Check Only Mode"
    log_always "=========================================="
    log_always ""

    # Initialize health check CSV file
    mkdir -p "${RESULTS_DIR}"
    HEALTH_CSV_FILE="${RESULTS_DIR}/health_check.csv"
    if [ ! -f "${HEALTH_CSV_FILE}" ]; then
        echo "Timestamp,Round,Host,SSH,IB_Active,GPU,Uptime,PCIe_Speed,PCIe_Width,RX_Err,TX_Err,Status" > "${HEALTH_CSV_FILE}"
    fi

    # Create temporary log file
    HEALTH_LOG_FILE="${RESULTS_DIR}/health_check_$(date +%Y%m%d_%H%M%S).log"

    # Run health check
    log_always "Running health check on all nodes..."
    log_always ""

    # Skip CSV write (skip_csv=1) - will merge with PCIe data later
    if ! wait_for_nodes_ready "${HOSTFILE_PATH}" 0 1 1; then
        log_always ""
        log_always "❌ Health check failed!"
        exit 1
    fi

    # Run PCIe check (will merge with basic health data and write complete CSV)
    if ! check_all_nodes_pcie "${HOSTFILE_PATH}" 1; then
        log_always ""
        log_always "❌ PCIe check failed!"
        exit 1
    fi

    log_always ""
    log_always "=========================================="
    log_always "Health check completed successfully!"
    log_always "=========================================="
    log_always "Logs saved to:"
    log_always "  - ${HEALTH_LOG_FILE}"
    log_always "  - ${HEALTH_CSV_FILE}"
    log_always ""

    exit 0
fi

    # Upload hostfile once before loop
log "[1/4] Uploading hostfile to GPU server..."
upload_hostfile "${HOSTFILE_PATH}" "${GPU_HOST}"
log "Hostfile ready"
log ""

# Initialize health check CSV file (once, before first round)
# Ensure results directory exists
mkdir -p "${RESULTS_DIR}"

HEALTH_CSV_FILE="${RESULTS_DIR}/health_check.csv"
if [ ! -f "${HEALTH_CSV_FILE}" ]; then
    echo "Timestamp,Round,Host,SSH,IB_Active,GPU,Uptime,PCIe_Speed,PCIe_Width,RX_Err,TX_Err,Status" > "${HEALTH_CSV_FILE}"
fi

# Safety check for auto-reboot mode
if [ ${AUTO_REBOOT} -eq 1 ] && [ ${LOOP_COUNT} -gt 1 ]; then
    # Count total nodes
    total_nodes=$(grep -v '^#' "${HOSTFILE_PATH}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    total_reboot_time=$((total_nodes * REBOOT_INTERVAL))

    log_always ""
    log_always "=========================================="
    log_always "WARNING: Auto-Reboot Mode Enabled"
    log_always "=========================================="
    log_always "This will automatically reboot ALL nodes between test rounds."
    log_always ""
    log_always "Configuration:"
    log_always "  - Total nodes:        ${total_nodes}"
    log_always "  - Loop rounds:        ${LOOP_COUNT}"
    log_always "  - Reboot interval:    ${REBOOT_INTERVAL}s per node"
    log_always "  - Time per reboot:    ${total_reboot_time}s (~$((total_reboot_time / 60))m)"
    log_always "  - Total reboots:      $((LOOP_COUNT - 1)) times"
    log_always ""
    log_always "Press Ctrl+C to cancel, or Enter to continue..."
    log_always "=========================================="

    read -p ""

    log_always ""
    log_always "Auto-reboot confirmed. Starting benchmark..."
    log_always ""
fi

# Initialize bad nodes tracking (for auto-remove mode)
if [ ${AUTO_REMOVE_BAD_NODES} -eq 1 ]; then
    BAD_NODES_LOG="${RESULTS_DIR}/bad_nodes.log"
    TOTAL_BAD_NODES=0
    # Track all removed nodes across all rounds
    declare -a ALL_BAD_NODES=()
fi

# Track current hostfile (may be updated if bad nodes are removed)
CURRENT_HOSTFILE="${HOSTFILE_PATH}"

# Main loop
for ((round=1; round<=LOOP_COUNT; round++)); do
    # Display current node count
    current_node_count=$(grep -v '^#' "${CURRENT_HOSTFILE}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    log_always ""
    log_always "=========================================="
    log_always "Round ${round}/${LOOP_COUNT}"
    log_always "Current active nodes: ${current_node_count}"
    if [ ${AUTO_REMOVE_BAD_NODES} -eq 1 ] && [ ${TOTAL_BAD_NODES} -gt 0 ]; then
        log_always "Total bad nodes removed: ${TOTAL_BAD_NODES}"
    fi
    log_always "=========================================="
    log_always ""

    # Run benchmark for this round
    if [ ${RAIL_BY_RAIL} -eq 1 ]; then
        run_railbyrail_round ${round} ${LOOP_COUNT}
    else
        run_benchmark_round ${round} ${LOOP_COUNT}
    fi

    # If not the last round, wait for node reboot
    if [ ${round} -lt ${LOOP_COUNT} ]; then
        log_always ""
        log_always "=========================================="
        log_always "Round ${round}/${LOOP_COUNT} completed"
        log_always "=========================================="
        log_always ""

        if [ ${LOOP_TEST_MODE} -eq 1 ]; then
            # Test mode: reset optical modules and wait for links to come up
            if [ ${RESET_OPTICS} -eq 1 ]; then
                log_always "[TEST MODE] Resetting optical modules before next round..."
                log_always ""

                # Reset optical modules
                # Both --auto-hca and --hca_list modes use HCA_LIST
                # (HCA_LIST is populated by get_gpu_hca_list when --auto-hca is used)
                if [ -n "${HCA_LIST}" ]; then
                    if ! reset_optical_modules "${CURRENT_HOSTFILE}" "${HCA_LIST}" 0; then
                        log_always "Warning: Optical module reset encountered errors"
                    fi

                    # Wait for IB links to come up (120s timeout = 2 minutes)
                    wait_for_ib_links_up "${CURRENT_HOSTFILE}" "${HCA_LIST}" 0 120
                else
                    log_always "Warning: --reset-optics requires either --auto-hca or --hca_list"
                fi
            else
                # No optical reset requested, just a brief pause
                log_always "[TEST MODE] No optical reset requested, continuing to next round..."
                log_always ""
            fi
        else
            # Production mode: verify reboot
            if [ ${AUTO_REBOOT} -eq 1 ]; then
                # Auto reboot mode
                if ! reboot_nodes_randomly "${CURRENT_HOSTFILE}"; then
                    log_always "Error: Failed to reboot nodes"
                    exit 1
                fi
            else
                # Manual reboot mode
                log_always "Please reboot all GPU nodes now."
                log_always "Waiting for nodes to be ready..."
                log_always ""
            fi

            # Wait for nodes to be ready (with reboot verification)
            wait_for_nodes_ready "${CURRENT_HOSTFILE}" 1 "${round}"
            health_check_result=$?

            # Check PCIe status after reboot (production mode only)
            if ! check_all_nodes_pcie "${CURRENT_HOSTFILE}" "${round}"; then
                log_always ""
                log_always "PCIe check detected failures"
            fi

            # Process failed nodes if auto-remove is enabled
            if [ ${AUTO_REMOVE_BAD_NODES} -eq 1 ] && [ ${health_check_result} -ne 0 ]; then
                # Read failed nodes from temp file
                mapfile -t round_failed_nodes < "/tmp/failed_nodes_$$"

                if [ ${#round_failed_nodes[@]} -gt 0 ]; then
                    log_always ""
                    log_always "=========================================="
                    log_always "Processing ${#round_failed_nodes[@]} failed node(s)"
                    log_always "=========================================="

                    # Log bad nodes
                    log_bad_nodes "${BAD_NODES_LOG}" "${round}" "${round_failed_nodes[@]}"

                    # Add to total bad nodes list
                    ALL_BAD_NODES+=("${round_failed_nodes[@]}")
                    TOTAL_BAD_NODES=$((TOTAL_BAD_NODES + ${#round_failed_nodes[@]}))

                    # Create updated hostfile
                    TEMP_HOSTFILE="/tmp/hostfile_round_${round}_$$"
                    if ! remove_bad_nodes_from_hostfile "${CURRENT_HOSTFILE}" "${TEMP_HOSTFILE}" "${round_failed_nodes[@]}"; then
                        remaining=$(grep -v '^#' "${TEMP_HOSTFILE}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
                        log_always ""
                        log_always "=========================================="
                        log_always "CRITICAL: Too few nodes remaining"
                        log_always "=========================================="
                        log_always "Remaining nodes: ${remaining}"
                        log_always "Minimum required: ${MIN_NODES}"
                        log_always "Test aborted."
                        log_always ""
                        log_always "Bad nodes log: ${BAD_NODES_LOG}"
                        log_always "=========================================="
                        exit 1
                    fi

                    # Update current hostfile
                    CURRENT_HOSTFILE="${TEMP_HOSTFILE}"

                    remaining=$(grep -v '^#' "${CURRENT_HOSTFILE}" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
                    log_always "Updated hostfile: ${remaining} active nodes"
                    log_always "Bad nodes logged to: ${BAD_NODES_LOG}"
                    log_always ""

                    # Upload updated hostfile
                    upload_hostfile "${CURRENT_HOSTFILE}" "${GPU_HOST}"
                fi
            elif [ ${health_check_result} -ne 0 ]; then
                # Auto-remove disabled, abort on failure
                log_always "Error: Nodes not ready after timeout"
                exit 1
            fi
        fi

        # Ask user if ready to start next round (with 30s auto-start)
        log_always ""
        log_always "Press Enter to start next round, or wait ${AUTO_START_TIMEOUT}s for auto-start..."

        # Use read with timeout for auto-start
        if read -t ${AUTO_START_TIMEOUT} -p ""; then
            log_always "Starting round $((round+1))..."
        else
            log_always ""
            log_always "Auto-starting round $((round+1))..."
        fi
    fi
done

log_always ""
log_always "=========================================="
log_always "All ${LOOP_COUNT} rounds completed!"
log_always "=========================================="

# Display bad nodes summary if auto-remove was enabled
if [ ${AUTO_REMOVE_BAD_NODES} -eq 1 ] && [ ${TOTAL_BAD_NODES} -gt 0 ]; then
    log_always ""
    log_always "=========================================="
    log_always "Bad Nodes Summary"
    log_always "=========================================="
    log_always "Total bad nodes removed: ${TOTAL_BAD_NODES}"
    log_always ""
    log_always "Bad nodes list:"
    log_always "----------------------------------------"

    # Remove duplicates and sort
    unique_bad_nodes=($(printf "%s\n" "${ALL_BAD_NODES[@]}" | sort -u))

    for node in "${unique_bad_nodes[@]}"; do
        log_always "  - ${node}"
    done

    log_always "----------------------------------------"
    log_always ""
    log_always "Detailed failure log: ${BAD_NODES_LOG}"
    log_always "=========================================="
fi
