#!/usr/bin/env bash
#==============================================================================
# mlxlink_ext - Extended mlxlink wrapper with HCA device selection
#
# A wrapper script for mlxlink that adds support for querying devices
# across multiple InfiniBand subnets/network planes by specifying
# the local HCA device.
#
# Author  : Vincent
# License : GNU GPL v3
#
#==============================================================================

set -u  # stop on uninitialized variable

VERSION="1.0.0"

## -- functions ---------------------------------------------------------------

show_help() {
    cat << 'EOF'
mlxlink_ext - Extended mlxlink wrapper with HCA device selection

USAGE:
    mlxlink_ext -C <hca_dev> [mlxlink_options...]
    mlxlink_ext -C <hca_dev> -P <port> [mlxlink_options...]

EXTENDED OPTIONS:
    -C <hca_dev>    HCA device to use (e.g., mlx5_0, mlx5_4)
    -P <hca_port>   HCA port number (default: 1)
    --version       Show version
    --help-ext      Show this extended help

DESCRIPTION:
    This wrapper intercepts the -d option and appends HCA information
    for multi-subnet access. All other options are passed directly to mlxlink.

    When you specify -C mlx5_4 and -d lid-98, the wrapper converts
    the device to: lid-98,mlx5_4,1

EXAMPLES:
    # Query remote switch port via storage network (mlx5_4)
    mlxlink_ext -C mlx5_4 -d lid-98 -p 1

    # Query remote switch port via compute network (mlx5_0)
    mlxlink_ext -C mlx5_0 -d lid-266 -p 15

    # Specify HCA port explicitly
    mlxlink_ext -C mlx5_4 -P 2 -d lid-98 -p 1

    # Eye opening measurement via specific network plane
    mlxlink_ext -C mlx5_4 -d lid-98 -p 1 --eye_sel all -e

    # Show BER counters
    mlxlink_ext -C mlx5_4 -d lid-98 -p 1 -c

    # Full port info with extended counters
    mlxlink_ext -C mlx5_4 -d lid-98 -p 1 -m -c -e

NETWORK TOPOLOGY EXAMPLE:
    ┌─────────────────────────────────────────────────────────────┐
    │                        GPU Server                           │
    │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
    │  │ mlx5_0  │  │ mlx5_1  │  │ mlx5_4  │  │ mlx5_5  │        │
    │  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘        │
    └───────┼────────────┼────────────┼────────────┼──────────────┘
            │            │            │            │
            ▼            ▼            ▼            ▼
       Compute Network (NDR)      Storage Network (HDR)
       
    # Query compute network switch
    mlxlink_ext -C mlx5_0 -d lid-266 -p 1
    
    # Query storage network switch
    mlxlink_ext -C mlx5_4 -d lid-98 -p 1

SEE ALSO:
    mlxlink --help    (for all mlxlink native options)

EOF
}

show_version() {
    echo "mlxlink_ext version $VERSION"
    echo "mlxlink version: $(mlxlink --version 2>/dev/null | head -1 || echo 'unknown')"
}

err() {
    echo "mlxlink_ext: error: $*" >&2
    exit 1
}

## -- main --------------------------------------------------------------------

# Variables for extended options
hca_dev=""
hca_port="1"
mlxlink_args=()
device_arg=""
device_idx=-1

# Parse arguments - extract our extended options, collect mlxlink args
i=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -C)
            [[ $# -lt 2 ]] && err "-C requires HCA device argument"
            hca_dev="$2"
            shift 2
            ;;
        -P)
            [[ $# -lt 2 ]] && err "-P requires port number argument"
            hca_port="$2"
            shift 2
            ;;
        --help-ext)
            show_help
            exit 0
            ;;
        --version)
            show_version
            exit 0
            ;;
        -d)
            [[ $# -lt 2 ]] && err "-d requires device argument"
            device_arg="$2"
            device_idx=${#mlxlink_args[@]}
            mlxlink_args+=("-d" "$2")
            shift 2
            ;;
        *)
            mlxlink_args+=("$1")
            shift
            ;;
    esac
done

# If no arguments, show help
if [[ ${#mlxlink_args[@]} -eq 0 && -z "$hca_dev" ]]; then
    show_help
    exit 0
fi

# Validate HCA device if specified
if [[ -n "$hca_dev" ]]; then
    if [[ ! -d "/sys/class/infiniband/$hca_dev" ]]; then
        err "HCA device '$hca_dev' not found in /sys/class/infiniband/"
    fi
    
    # If device is in lid-XXX format and HCA is specified, modify it
    if [[ -n "$device_arg" && "${device_arg:0:4}" == "lid-" ]]; then
        # Construct new device string: lid-<num>,<hca>,<port>
        new_device="${device_arg},${hca_dev},${hca_port}"
        # Update the device argument in mlxlink_args
        # device_idx points to -d, device_idx+1 is the value
        mlxlink_args[$((device_idx + 1))]="$new_device"
    fi
fi

# Execute mlxlink with modified arguments
exec mlxlink "${mlxlink_args[@]}"
