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

# CPU server configuration
CPU_SERVER="10.0.1.2"
CPU_SERVER_USER="root"

# Remote script directory on CPU server
REMOTE_DIR="/mnt/sdb/x/clusterkit"

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
EXTRA_ARGS=""
OUTPUT_CSV=0
QUIET_MODE=0
TOPO_CA_DEV="mlx5_0"  # Default HCA device for sminfo/ibtracert in topology check

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
  --auto-hca                  Auto-detect GPU-associated compute network HCAs
  --rail-by-rail, --rbr       Test each HCA separately and generate summary report
  -G, --gpudirect             Enable GPUDirect RDMA
  -cx7, --connectx-7          Enable ConnectX-7 mode (4 QPs)
  -z, --traffic <minutes>     Run stress test for specified minutes
  -h, --help                  Show this help message

Additional options:
  --check-topology            Show GPU-NIC-Switch topology mapping and exit
  --Ca <device>               Specify HCA device for topology query (default: mlx5_0)
  --output-csv                Output results in CSV format (rail-by-rail mode)
  -q, --quiet                 Quiet mode, only show final summary

HPCX path can also be set via HPCX_HOME environment variable.
Other clusterkit.sh options are passed through directly.

Runtime environment: auto-detected (current: ${RUN_ENV})
  - mac:        Via CPU server jump to GPU server
  - cpu_server: Direct SSH to GPU server
  - gpu_server: Local execution

Examples:
  $0 --auto-hca -G -cx7                           # Auto-detect HCAs, test all together
  $0 --auto-hca --rail-by-rail -G -cx7            # Test each rail separately
  $0 --rbr -G -cx7 --output-csv                   # Rail-by-rail with CSV output
  $0 --rbr -G -cx7 -q                             # Rail-by-rail quiet mode
  $0 --check-topology                             # Show topology mapping (default: mlx5_0)
  $0 --check-topology --Ca mlx5_1                 # Topology with specific HCA device

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
            ssh ${CPU_SERVER_USER}@${CPU_SERVER} "mkdir -p ${results_dir} && scp -q -r ${gpu_host}:${HPCX_HOME}/${output_dir} ${results_dir}/" 2>/dev/null
            ;;
        cpu_server)
            mkdir -p ${results_dir}
            scp -q -r ${gpu_host}:${HPCX_HOME}/${output_dir} ${results_dir}/ 2>/dev/null
            ;;
        gpu_server)
            mkdir -p ${results_dir}
            cp -r ${HPCX_HOME}/${output_dir} ${results_dir}/
            ;;
    esac
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

    # Build clusterkit.sh arguments for single rail
    local ck_args="--hostfile hostfile.txt --hca_list \"${hca}\""
    [ -n "${GPUDIRECT}" ] && ck_args="${ck_args} ${GPUDIRECT}"
    [ -n "${CONNECTX7}" ] && ck_args="${ck_args} ${CONNECTX7}"
    [ -n "${TRAFFIC_TIME}" ] && ck_args="${ck_args} --traffic ${TRAFFIC_TIME}"
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
        *)
            EXTRA_ARGS="${EXTRA_ARGS} $1"
            shift
            ;;
    esac
done

# ==================== Main Logic ====================

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
        RESULTS_DIR="${REMOTE_DIR}/results"
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
    SESSION_DIR="rbr_${SESSION_TIMESTAMP}"

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
            run_single_rail_benchmark "${hca}" "${GPU_HOST}" 2>&1 | tee "${OUTPUT_TMP}" || true
        else
            run_single_rail_benchmark "${hca}" "${GPU_HOST}" > "${OUTPUT_TMP}" 2>&1 || true
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

    exit 0
fi

# ==================== Normal Mode ====================
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

log "[1/4] Uploading hostfile to GPU server..."
upload_hostfile "${HOSTFILE_PATH}" "${GPU_HOST}"
log "Hostfile ready"
log ""

# Build clusterkit.sh arguments
CK_ARGS="--hostfile hostfile.txt"
[ -n "${HCA_LIST}" ] && CK_ARGS="${CK_ARGS} --hca_list \"${HCA_LIST}\""
[ -n "${GPUDIRECT}" ] && CK_ARGS="${CK_ARGS} ${GPUDIRECT}"
[ -n "${CONNECTX7}" ] && CK_ARGS="${CK_ARGS} ${CONNECTX7}"
[ -n "${TRAFFIC_TIME}" ] && CK_ARGS="${CK_ARGS} --traffic ${TRAFFIC_TIME}"
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
OUTPUT_DIR=$(echo "${OUTPUT}" | grep "Output directory:" | tail -1 | awk '{print $NF}' | sed 's:/$::' | xargs basename)

if [ -z "${OUTPUT_DIR}" ]; then
    log_always "Warning: could not get output directory name"
    log_always "=========================================="
    log_always "Benchmark completed (results not downloaded)"
    log_always "=========================================="
    exit 0
fi

log "[3/4] Downloading results..."
log "Output directory: ${OUTPUT_DIR}"
download_results "${GPU_HOST}" "${OUTPUT_DIR}" "${RESULTS_DIR}"

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
fi
