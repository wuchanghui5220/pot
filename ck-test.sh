#!/bin/bash
# Enhanced Clusterkit Network Performance Testing Script
# This script performs RDMA network performance testing for ConnectX-7 HCAs
# with unidirectional tests and specified parameters

# Configuration
HPCX_HOME="/root/workspace/clusterkit/hpcx-v2.23-gcc-doca_ofed-ubuntu22.04-cuda12-x86_64/"
HPCX_DIR="$HPCX_HOME"
HOSTFILE="$HPCX_HOME/hostfile.txt"
CK_DIR="$HPCX_HOME/clusterkit"
TEST_DURATION=1  # Traffic test duration in minutes
PROCESSES_PER_NODE=8 # Number of processes per node
OUTPUT_DIR="$(pwd)/clusterkit_results"

# Create results directory with timestamp
DATE=$(date "+%Y%m%d_%H%M%S")
RESULTS_DIR="${OUTPUT_DIR}/${DATE}"
mkdir -p "$RESULTS_DIR"

# Log file
LOG_FILE="${RESULTS_DIR}/test_log.txt"

# Log function
log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Define HCAs - ConnectX-7 only
declare -A hca_name
hca_name["0"]="mlx5_0"
hca_name["1"]="mlx5_1"
hca_name["2"]="mlx5_2"
hca_name["3"]="mlx5_3"
hca_name["4"]="mlx5_8"
hca_name["5"]="mlx5_9"
hca_name["6"]="mlx5_10"
hca_name["7"]="mlx5_11"

# Get list of HCAs to test (default: all)
if [ -z "$1" ]; then
    ncas=(0 1 2 3 4 5 6 7)
else
    # User provided list of HCA indices
    IFS=',' read -ra ncas <<< "$1"
fi

# Basic MPI options
mpi_opt="-x CK_OUTPUT_SUBDIR -x CLUSTERKIT_HCA -x UCX_NET_DEVICES"

# Main testing loop
log "Starting ConnectX-7 network performance tests (unidirectional)"
log "Testing on HCAs: ${ncas[*]}"

# Create summary file
SUMMARY_FILE="${RESULTS_DIR}/summary.txt"
echo "CLUSTERKIT PERFORMANCE TEST SUMMARY" > "$SUMMARY_FILE"
echo "Date: $DATE" >> "$SUMMARY_FILE"
echo "=============================================" >> "$SUMMARY_FILE"

# Run tests for each HCA
for i in "${ncas[@]}"; do
    device=${hca_name[$i]}
    log "Testing HCA: $device"

    # Create HCA-specific output directory
    HCA_RESULTS_DIR="${RESULTS_DIR}/${device}"
    mkdir -p "$HCA_RESULTS_DIR"

    # Export environment variables
    export CK_OUTPUT_SUBDIR="${HCA_RESULTS_DIR}"
    export HCA_TAG="${device}"
    export CLUSTERKIT_HCA=1
    export UCX_NET_DEVICES="${device}:1"

    # Run the test with the specified parameters
    log "Running bandwidth and latency tests on $device (unidirectional)"

    # Construct the command exactly as specified
    cmd="$CK_DIR/bin/clusterkit.sh --traffic -N"
    cmd+=" --mpi_opt \"$mpi_opt\" -r $HPCX_DIR -f $HOSTFILE"
    cmd+=" --mapper $CK_DIR/bin/core_to_hca_hgx100.sh"  # Using your custom mapping script
    cmd+=" --exe_opt \"-d bw -d lat --unidirectional\""

    # Execute the command
    log "Executing: $cmd"
    eval "$cmd" >> "$LOG_FILE" 2>&1

    # Add a small delay between tests
    sleep 5

    # Record results to summary
    echo "Results for HCA: $device" >> "$SUMMARY_FILE"
    echo "Output directory: ${HCA_RESULTS_DIR}" >> "$SUMMARY_FILE"

    # Extract and log bandwidth results if available
    if [ -f "${HCA_RESULTS_DIR}/bandwidth.json" ]; then
        BW=$(grep -o '"Links": \[\[0,[0-9.]*\]\]' "${HCA_RESULTS_DIR}/bandwidth.json" | grep -o '[0-9.]*' | tail -1)
        if [ -n "$BW" ]; then
            echo "Bandwidth: $BW MB/s" >> "$SUMMARY_FILE"
            log "HCA $device bandwidth: $BW MB/s"
        fi
    fi

    # Extract and log latency results if available
    if [ -f "${HCA_RESULTS_DIR}/latency.json" ]; then
        LAT=$(grep -o '"Links": \[\[0,[0-9.]*\]\]' "${HCA_RESULTS_DIR}/latency.json" | grep -o '[0-9.]*' | tail -1)
        if [ -n "$LAT" ]; then
            echo "Latency: $LAT μs" >> "$SUMMARY_FILE"
            log "HCA $device latency: $LAT μs"
        fi
    fi

    echo "----------------------------------------" >> "$SUMMARY_FILE"
done

# Generate comprehensive report
log "Generating final report and visualization"
report_cmd="$CK_DIR/bin/clusterkit.sh  -v -r $HPCX_DIR -f $HOSTFILE"
report_cmd+=" --output --normalize --report"
eval "$report_cmd" >> "$LOG_FILE" 2>&1

log "Testing complete! Results available in: $RESULTS_DIR"
echo "Testing complete! Results available in: $RESULTS_DIR" >> "$SUMMARY_FILE"

# Create a tarball of all results
tar -czf "${RESULTS_DIR}.tar.gz" "$RESULTS_DIR"
log "Results archive created: ${RESULTS_DIR}.tar.gz"
