#!/bin/bash

# InfiniBand Switch Port Down Checker - Group-based Configuration
# Author: Refactored with Ansible-like inventory style

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TIMESTAMP=$(date +%m%d.%H%M)
readonly OUTPUT_DIR="${SCRIPT_DIR}/output"
readonly GUIDS_FILE="${SCRIPT_DIR}/guids.txt"

# File paths
readonly IBLINKINFO_OUTPUT="${OUTPUT_DIR}/iblinkinfo_switches_only.${TIMESTAMP}.txt"
readonly RESULT_OUTPUT="${OUTPUT_DIR}/ibswitch_port_down_check.${TIMESTAMP}.txt"
readonly LOG_FILE="${OUTPUT_DIR}/script.${TIMESTAMP}.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Global variables - 修复后的数据结构
declare -A GROUP_GUIDS       # 组名 -> GUIDs列表 (空格分隔)
declare -A GUID_PORT_SPECS   # GUID:组名 -> 端口规格
declare -A GROUP_PORT_SPECS  # 组名 -> 端口规格
declare -A CHILD_GROUPS      # 父组 -> 子组列表
declare VERBOSE=false
declare QUIET=false
declare DRY_RUN=false
declare HCA_DEVICE=""
declare TARGET_GROUP=""

# Function to print colored output
print_color() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

# Function to log messages
log() {
    local message="$(date '+%Y-%m-%d %H:%M:%S') - $*"
    echo "$message"
    # Only write to log file if output directory exists
    if [[ -d "$OUTPUT_DIR" ]]; then
        echo "$message" >> "$LOG_FILE"
    fi
}

# Function to show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS] [GROUP_NAME]

Options:
    -h, --help              Show this help message
    -g, --guids-file FILE   Path to guids configuration file (default: ./guids.txt)
    -o, --output-dir DIR    Set output directory (default: ./output)
    -C, --hca DEVICE        Specify HCA device (default: auto-detect, e.g., mlx5_0, mlx5_4)
    -q, --quiet             Quiet mode - minimal output
    -v, --verbose           Verbose mode - detailed output
    --list-groups           List all available groups and exit
    --dry-run              Show what would be done without executing
    --no-color             Disable colored output

Arguments:
    GROUP_NAME              Run only for specific group(s). Use 'all' to run for all groups.

Configuration file format (guids.txt):
    # Standardized group format: [name:ports] or [name:all]
    # Legacy formats still supported for backward compatibility
    
    # Modern format (recommended):
    [spine:32]              # Spine switches, check ports 1-32
    0xfc6a1c0300c11a00
    0xfc6a1c0300ba6300
    
    [leaf:48]               # Leaf switches, check ports 1-48  
    0xfc6a1c0300ba6a40
    0xfc6a1c0300d09740
    
    [storage:1-30]          # Storage switches, check ports 1-30
    0xfc6a1c0300c114c0
    
    [storage:41-64]         # Same switch, check ports 41-64  
    0xfc6a1c0300c114c0
    
    [border:all]            # Border switches, check all ports
    0xfc6a1c0300c11c80
    
    # Multiple ranges for same GUID (non-contiguous ports)
    [compute:1-24,33-48]    # Check ports 1-24 and 33-48
    0xfc6a1c0300abc123
    
    # Group inheritance
    [datacenter:children]
    spine
    leaf
    storage
    
    # Legacy format (still supported):
    [port40]                # Check ports 1-40
    [any_name]              # Check all ports

Supported port specifications:
    ##              - Check ports 1-## (e.g., :32 = ports 1-32)
    ##-##           - Check port range (e.g., :41-64 = ports 41-64)
    ##,##,##        - Check specific ports (e.g., :1,5,10 = ports 1,5,10)
    ##-##,##-##     - Multiple ranges (e.g., :1-24,33-48)
    all             - Check all ports
    [name:children] - Group inheritance (combines multiple groups)

Examples:
    $0                              # Run with default settings (all groups)
    $0 -v                           # Run in verbose mode (all groups)
    $0 spine                        # Run only spine switches
    $0 storage                      # Run only storage switches  
    $0 datacenter                   # Run datacenter group (all children)
    $0 -C mlx5_4 spine             # Use mlx5_4 with spine switches
    $0 --list-groups               # List all available groups
    $0 --guids-file prod.txt       # Use production configuration file
    $0 --output-dir /tmp           # Use /tmp as output directory

EOF
}

# Function to setup directories
setup_directories() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        log "Creating output directory: $OUTPUT_DIR"
        mkdir -p "$OUTPUT_DIR"
    fi
}

# Function to parse port specification and generate port list
parse_port_spec() {
    local port_spec=$1
    local ports=()
    
    if [[ "$port_spec" == "all" ]]; then
        echo "all"
        return 0
    fi
    
    # Split by comma for multiple ranges/ports
    IFS=',' read -ra parts <<< "$port_spec"
    
    for part in "${parts[@]}"; do
        part=$(echo "$part" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # trim whitespace
        
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # Range format: start-end
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            
            if [[ $start -le $end ]]; then
                for ((i=start; i<=end; i++)); do
                    ports+=("$i")
                done
            else
                echo "ERROR: Invalid range $part (start > end)" >&2
                return 1
            fi
            
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            # Single port or "1-N" format (if it's the only part)
            if [[ ${#parts[@]} -eq 1 ]]; then
                # Single number means 1-N
                for ((i=1; i<=part; i++)); do
                    ports+=("$i")
                done
            else
                # Part of comma-separated list, single port
                ports+=("$part")
            fi
            
        else
            echo "ERROR: Invalid port specification: $part" >&2
            return 1
        fi
    done
    
    # Sort and remove duplicates
    printf '%s\n' "${ports[@]}" | sort -n | uniq | tr '\n' ' '
    return 0
}

# Function to check if a port should be monitored for a GUID in a specific group
should_monitor_port() {
    local guid=$1
    local port=$2
    local target_group=$3
    
    # Get the port specification for this GUID in the specified group
    local port_spec="${GUID_PORT_SPECS["$guid:$target_group"]:-}"
    
    # If no specific GUID:group spec, use the group's default spec
    if [[ -z "$port_spec" ]]; then
        port_spec="${GROUP_PORT_SPECS[$target_group]:-all}"
    fi
    
    if [[ -z "$port_spec" || "$port_spec" == "all" ]]; then
        return 0  # Monitor all ports
    fi
    
    # Parse the port specification for this group
    local valid_ports
    valid_ports=$(parse_port_spec "$port_spec")
    
    if [[ "$valid_ports" == "all" ]]; then
        return 0
    fi
    
    # Check if our port is in the valid ports list
    if [[ " $valid_ports " =~ " $port " ]]; then
        return 0
    else
        return 1
    fi
}

# Function to expand child groups recursively
expand_child_groups() {
    local group_name=$1
    local expanded_groups=()
    
    if [[ "$VERBOSE" == true ]]; then
        log "DEBUG: expand_child_groups called with group_name='$group_name'"
    fi
    
    if [[ -n "${CHILD_GROUPS[$group_name]:-}" ]]; then
        # This is a parent group with children
        if [[ "$VERBOSE" == true ]]; then
            log "DEBUG: '$group_name' is a parent group with children: '${CHILD_GROUPS[$group_name]}'"
        fi
        
        IFS=' ' read -ra children <<< "${CHILD_GROUPS[$group_name]}"
        for child in "${children[@]}"; do
            # Recursively expand each child
            local child_expanded
            child_expanded=($(expand_child_groups "$child"))
            expanded_groups+=("${child_expanded[@]}")
        done
    else
        # This is a leaf group
        if [[ "$VERBOSE" == true ]]; then
            log "DEBUG: '$group_name' is a leaf group"
        fi
        expanded_groups+=("$group_name")
    fi
    
    echo "${expanded_groups[@]}"
}

# Function to get all GUIDs for a group (including children)
get_group_guids() {
    local target_group=$1
    local all_guids=()
    
    # Expand the group to include all children
    local expanded_groups
    expanded_groups=($(expand_child_groups "$target_group"))
    
    if [[ "$VERBOSE" == true ]]; then
        log "Group '$target_group' expands to: ${expanded_groups[*]}"
    fi
    
    # Collect all GUIDs from expanded groups
    for exp_group in "${expanded_groups[@]}"; do
        if [[ -n "${GROUP_GUIDS[$exp_group]:-}" ]]; then
            local group_guids_array=(${GROUP_GUIDS[$exp_group]})
            all_guids+=("${group_guids_array[@]}")
        fi
    done
    
    # Remove duplicates while preserving order
    local unique_guids=($(printf '%s\n' "${all_guids[@]}" | awk '!seen[$0]++'))
    
    echo "${unique_guids[@]}"
}

# Function to list all groups
list_groups() {
    print_color "$BLUE" "=== Available Groups ==="
    
    # Show regular groups
    print_color "$GREEN" "\nRegular Groups:"
    for group in "${!GROUP_GUIDS[@]}"; do
        if [[ "$group" != "default" ]]; then
            local guids_in_group=(${GROUP_GUIDS[$group]})
            local count=${#guids_in_group[@]}
            local port_spec="${GROUP_PORT_SPECS[$group]:-all}"
            
            local spec_text="all ports"
            if [[ "$port_spec" != "all" ]]; then
                if [[ "$port_spec" =~ ^[0-9]+$ ]]; then
                    spec_text="ports 1-$port_spec"
                else
                    local parsed_ports
                    if parsed_ports=$(parse_port_spec "$port_spec" 2>/dev/null); then
                        local port_count=$(echo "$parsed_ports" | wc -w)
                        spec_text="$port_count ports ($port_spec)"
                    else
                        spec_text="invalid spec ($port_spec)"
                    fi
                fi
            fi
            echo "  [$group]: $count GUIDs ($spec_text)"
        fi
    done
    
    # Show default group if exists
    if [[ -n "${GROUP_GUIDS[default]:-}" ]]; then
        local guids_in_default=(${GROUP_GUIDS[default]})
        local count=${#guids_in_default[@]}
        echo "  [default]: $count GUIDs (all ports, no brackets)"
    fi
    
    # Show parent groups
    if [[ ${#CHILD_GROUPS[@]} -gt 0 ]]; then
        print_color "$GREEN" "\nParent Groups (with children):"
        for parent in "${!CHILD_GROUPS[@]}"; do
            local children="${CHILD_GROUPS[$parent]}"
            echo "  [$parent]: children=($children)"
            
            local parent_guids
            parent_guids=($(get_group_guids "$parent"))
            echo "    Total GUIDs: ${#parent_guids[@]}"
        done
    fi
    
    print_color "$YELLOW" "\nUsage: $0 [group_name]"
    print_color "$YELLOW" "       $0 all  (run all groups)"
}

# Function to detect HCA devices
detect_hca_devices() {
    local devices=()
    
    if command -v ibstat &> /dev/null; then
        # Use ibstat to list devices
        while IFS= read -r line; do
            if [[ "$line" =~ ^CA[[:space:]]\'([^\']+)\' ]]; then
                devices+=("${BASH_REMATCH[1]}")
            fi
        done < <(ibstat -l 2>/dev/null)
    fi
    
    # Fallback: check /sys/class/infiniband/
    if [[ ${#devices[@]} -eq 0 && -d "/sys/class/infiniband" ]]; then
        for device in /sys/class/infiniband/mlx*; do
            if [[ -d "$device" ]]; then
                devices+=("$(basename "$device")")
            fi
        done
    fi
    
    echo "${devices[@]}"
}

# Function to validate HCA device
validate_hca_device() {
    local device=$1
    local available_devices
    available_devices=($(detect_hca_devices))
    
    if [[ ${#available_devices[@]} -eq 0 ]]; then
        print_color "$YELLOW" "Warning: No InfiniBand devices detected"
        return 0  # Continue anyway, let iblinkinfo handle it
    fi
    
    if [[ -n "$device" ]]; then
        # Check if specified device exists
        local found=false
        for dev in "${available_devices[@]}"; do
            if [[ "$dev" == "$device" ]]; then
                found=true
                break
            fi
        done
        
        if [[ "$found" == false ]]; then
            print_color "$RED" "Error: HCA device '$device' not found"
            print_color "$YELLOW" "Available devices: ${available_devices[*]}"
            return 1
        fi
        
        log "Using specified HCA device: $device"
    else
        # Auto-detect: use first available device
        device="${available_devices[0]}"
        log "Auto-detected HCA device: $device"
        print_color "$BLUE" "Using HCA device: $device (auto-detected)"
        
        if [[ ${#available_devices[@]} -gt 1 ]]; then
            print_color "$YELLOW" "Multiple devices available: ${available_devices[*]}"
            print_color "$YELLOW" "Use -C <device> to specify a different device"
        fi
    fi
    
    # Set global variable
    HCA_DEVICE="$device"
    return 0
}

# Function to auto-fix guids file format
auto_fix_guids_file() {
    local backup_file="${GUIDS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    print_color "$YELLOW" "Would you like to automatically fix the format? [y/N]"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        # Create backup
        cp "$GUIDS_FILE" "$backup_file"
        print_color "$GREEN" "Backup created: $backup_file"
        
        # Check if file starts with GUIDs (no group header)
        if head -1 "$GUIDS_FILE" | grep -q "^0x"; then
            # Add [all] header at the beginning
            {
                echo "# Auto-generated group header"
                echo "[all]"
                cat "$GUIDS_FILE"
            } > "${GUIDS_FILE}.tmp" && mv "${GUIDS_FILE}.tmp" "$GUIDS_FILE"
            
            print_color "$GREEN" "Fixed: Added [all] group header to your GUIDs"
            print_color "$YELLOW" "All your switches will now check all ports"
            print_color "$YELLOW" "You can edit $GUIDS_FILE to use different groups like [port40], [port32], etc."
            return 0
        fi
    fi
    
    return 1
}

# Function to create sample configuration
create_sample_config() {
    cat > "$GUIDS_FILE" << 'EOF'
# InfiniBand Switch GUIDs Configuration
# Format: [group_name] followed by GUIDs (one per line)
# Supported groups: [all], [port##] where ## is the port limit

[all]
# These switches will check all ports
0xfc6a1c0300c11a00
0xfc6a1c0300ba6300
0xfc6a1c0300d0b640

[port40]
# These switches will check ports 1-40 only
0xfc6a1c0300ba6a40
0xfc6a1c0300d09740

[port32]
# These switches will check ports 1-32 only
0xfc6a1c0300c114c0

[port48]
# These switches will check ports 1-48 only
0xfc6a1c0300c11c80
EOF
    print_color "$GREEN" "Sample configuration file created: $GUIDS_FILE"
    print_color "$YELLOW" "Please edit this file with your actual switch GUIDs."
}

# Function to parse guids configuration file - 完全重写
parse_guids_file() {
    if [[ ! -f "$GUIDS_FILE" ]]; then
        print_color "$YELLOW" "Configuration file not found: $GUIDS_FILE"
        print_color "$YELLOW" "Creating sample configuration file..."
        create_sample_config
        return 1
    fi
    
    local current_group="default"
    local line_num=0
    
    # Set default group settings
    GROUP_PORT_SPECS["default"]="all"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip empty lines and comments
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        
        # Check for group header
        if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
            local full_header="${BASH_REMATCH[1]}"
            
            # Handle children groups
            if [[ "$full_header" =~ ^([^:]+):children$ ]]; then
                local parent_group="${BASH_REMATCH[1]}"
                current_group=""
                
                if [[ "$VERBOSE" == true ]]; then
                    log "Found parent group: [$parent_group:children]"
                fi
                
                # Read child group names
                local child_groups=""
                while IFS= read -r child_line || [[ -n "$child_line" ]]; do
                    ((line_num++))
                    
                    if [[ -z "$child_line" || "$child_line" =~ ^[[:space:]]*# ]]; then
                        continue
                    fi
                    
                    child_line=$(echo "$child_line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                    
                    if [[ "$child_line" =~ ^\[([^\]]+)\]$ ]] || [[ "$child_line" =~ ^0x[0-9a-fA-F]+$ ]]; then
                        line="$child_line"
                        ((line_num--))
                        break
                    fi
                    
                    if [[ -n "$child_line" ]]; then
                        if [[ -n "$child_groups" ]]; then
                            child_groups="$child_groups $child_line"
                        else
                            child_groups="$child_line"
                        fi
                        
                        if [[ "$VERBOSE" == true ]]; then
                            log "  Added child: $child_line"
                        fi
                    fi
                done
                
                CHILD_GROUPS["$parent_group"]="$child_groups"
                continue
                
            # Handle port specification groups [name:ports]
            elif [[ "$full_header" =~ ^([^:]+):([^:]+)$ ]]; then
                current_group="${BASH_REMATCH[1]}"
                local port_spec="${BASH_REMATCH[2]}"
                
                GROUP_PORT_SPECS["$current_group"]="$port_spec"
                
                # Validate port specification
                if [[ "$port_spec" == "all" ]]; then
                    local spec_text="all ports"
                elif [[ "$port_spec" =~ ^[0-9]+$ ]]; then
                    local spec_text="ports 1-$port_spec"
                elif [[ "$port_spec" =~ ^[0-9,-]+$ ]]; then
                    local parsed_ports
                    if parsed_ports=$(parse_port_spec "$port_spec" 2>/dev/null); then
                        if [[ "$parsed_ports" == "all" ]]; then
                            local spec_text="all ports"
                        else
                            local port_count=$(echo "$parsed_ports" | wc -w)
                            local spec_text="$port_count ports ($port_spec)"
                        fi
                    else
                        print_color "$RED" "Error: Invalid port specification '$port_spec' for group '$current_group' at line $line_num"
                        return 1
                    fi
                else
                    print_color "$RED" "Error: Invalid port specification '$port_spec' for group '$current_group' at line $line_num"
                    return 1
                fi
                
                if [[ "$VERBOSE" == true ]]; then
                    log "Found group: [$current_group:$port_spec] ($spec_text)"
                fi
                
            else
                # Legacy group header format
                current_group="$full_header"
                
                if [[ "$current_group" =~ ^port([0-9]+)$ ]]; then
                    GROUP_PORT_SPECS["$current_group"]="${BASH_REMATCH[1]}"
                else
                    GROUP_PORT_SPECS["$current_group"]="all"
                fi
                
                if [[ "$VERBOSE" == true ]]; then
                    log "Found legacy group: [$current_group]"
                fi
            fi
            
        # Handle GUID
        elif [[ "$line" =~ ^0x[0-9a-fA-F]+$ ]]; then
            local guid=$(echo "$line" | tr '[:upper:]' '[:lower:]')
            
            # Add GUID to current group's list
            if [[ -n "${GROUP_GUIDS[$current_group]:-}" ]]; then
                GROUP_GUIDS["$current_group"]="${GROUP_GUIDS[$current_group]} $guid"
            else
                GROUP_GUIDS["$current_group"]="$guid"
            fi
            
            # Store the port specification for this GUID in this group
            local port_spec="${GROUP_PORT_SPECS[$current_group]:-all}"
            GUID_PORT_SPECS["$guid:$current_group"]="$port_spec"
            
            if [[ "$VERBOSE" == true ]]; then
                log "  Added GUID: $guid to group: $current_group (spec: $port_spec)"
            fi
            
        else
            print_color "$RED" "Error: Invalid line format at line $line_num: $line"
            return 1
        fi
        
    done < "$GUIDS_FILE"
    
    # Summary
    local total_groups=${#GROUP_GUIDS[@]}
    local total_port_specs=${#GROUP_PORT_SPECS[@]}
    local total_parents=${#CHILD_GROUPS[@]}
    
    # Count unique GUIDs
    local all_guids_temp=""
    for group in "${!GROUP_GUIDS[@]}"; do
        all_guids_temp="$all_guids_temp ${GROUP_GUIDS[$group]}"
    done
    local unique_guids=($(echo "$all_guids_temp" | tr ' ' '\n' | sort -u | grep -v '^$'))
    local total_unique_guids=${#unique_guids[@]}
    
    log "Configuration loaded: $total_unique_guids unique GUIDs in $total_groups groups ($total_parents parent groups)"
    
    if [[ "$VERBOSE" == true ]]; then
        for group in "${!GROUP_GUIDS[@]}"; do
            local guids_in_group=(${GROUP_GUIDS[$group]})
            local count=${#guids_in_group[@]}
            local port_spec="${GROUP_PORT_SPECS[$group]:-all}"
            
            echo "  Group [$group]: $count GUIDs (spec: $port_spec)"
            for guid in ${GROUP_GUIDS[$group]}; do
                echo "    - $guid"
            done
        done
        
        for parent in "${!CHILD_GROUPS[@]}"; do
            log "  Parent [$parent]: children=(${CHILD_GROUPS[$parent]})"
        done
    fi
    
    return 0
}

# Function to convert port number to the new format
convert_port() {
    local port=$1
    
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "Invalid"
        return 1
    fi
    
    if [ "$port" -eq 65 ]; then
        echo "Skipped"
    elif [ "$port" -le 64 ]; then
        local group=$(( (port - 1) / 2 + 1 ))
        local subport=$(( port % 2 == 0 ? 2 : 1 ))
        echo "$group/$subport"
    else
        echo "Invalid"
    fi
}

# Function to generate iblinkinfo output
generate_iblinkinfo() {
    log "Generating iblinkinfo output..."
    
    # Build iblinkinfo command
    local cmd="iblinkinfo"
    if [[ -n "$HCA_DEVICE" ]]; then
        cmd="$cmd -C $HCA_DEVICE"
    fi
    cmd="$cmd --switches-only"
    
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN: Would execute: $cmd > $IBLINKINFO_OUTPUT"
        return 0
    fi
    
    if ! command -v iblinkinfo &> /dev/null; then
        print_color "$RED" "Error: iblinkinfo command not found. Please install InfiniBand utilities."
        return 1
    fi
    
    log "Executing: $cmd"
    
    if [[ -n "$HCA_DEVICE" ]]; then
        if ! iblinkinfo -C "$HCA_DEVICE" --switches-only > "$IBLINKINFO_OUTPUT"; then
            print_color "$RED" "Error: Failed to generate iblinkinfo output using device $HCA_DEVICE"
            print_color "$YELLOW" "Try running: ibstat -l (to list available devices)"
            return 1
        fi
    else
        if ! iblinkinfo --switches-only > "$IBLINKINFO_OUTPUT"; then
            print_color "$RED" "Error: Failed to generate iblinkinfo output"
            return 1
        fi
    fi
    
    log "iblinkinfo output saved to: $IBLINKINFO_OUTPUT"
    
    # Check if output file has content
    if [[ ! -s "$IBLINKINFO_OUTPUT" ]]; then
        print_color "$RED" "Warning: iblinkinfo output is empty"
        print_color "$YELLOW" "This might indicate:"
        print_color "$YELLOW" "  - No switches found on the specified HCA device"
        print_color "$YELLOW" "  - Network connectivity issues"
        print_color "$YELLOW" "  - Wrong HCA device specified"
        if [[ -n "$HCA_DEVICE" ]]; then
            print_color "$YELLOW" "  - Try a different HCA device or omit -C parameter"
        fi
        return 1
    fi
}

# Function to process iblinkinfo output - 完全重写
process_iblinkinfo() {
    log "Processing iblinkinfo output..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log "DRY RUN: Would process $IBLINKINFO_OUTPUT and output to $RESULT_OUTPUT"
        return 0
    fi
    
    local current_guid=""
    local switch_name=""
    local processed_count=0
    local down_ports_count=0
    local skipped_count=0
    
    # Get target GUIDs for the specified group
    local target_guids=()
    if [[ -n "$TARGET_GROUP" && "$TARGET_GROUP" != "all" ]]; then
        target_guids=($(get_group_guids "$TARGET_GROUP"))
        if [[ "$VERBOSE" == true ]]; then
            log "Target group '$TARGET_GROUP' contains GUIDs: ${target_guids[*]}"
        fi
    else
        # If no specific group or "all", collect all GUIDs from all groups
        local all_guids_temp=""
        for group in "${!GROUP_GUIDS[@]}"; do
            all_guids_temp="$all_guids_temp ${GROUP_GUIDS[$group]}"
        done
        target_guids=($(echo "$all_guids_temp" | tr ' ' '\n' | sort -u | grep -v '^$'))
    fi
    
    # Create result file with header
    {
        echo "# InfiniBand Switch Down Ports Report - Generated on $(date)"
        echo "# Configuration file: $GUIDS_FILE"
        if [[ -n "$TARGET_GROUP" && "$TARGET_GROUP" != "all" ]]; then
            echo "# Target group: $TARGET_GROUP"
        fi
        echo "# Format: GUID,Port,SwitchName,ConvertedPort,Group,PortSpec"
        echo "#"
    } > "$RESULT_OUTPUT"
    
    while IFS= read -r line; do
        # Match switch line
        if [[ $line =~ ^Switch:[[:space:]]*(0x[0-9a-fA-F]+)[[:space:]]+(.*):$ ]]; then
            current_guid=$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
            switch_name="${BASH_REMATCH[2]}"
            
            if [[ "$VERBOSE" == true ]]; then
                # Check which groups this GUID belongs to
                local guid_groups=()
                for group in "${!GROUP_GUIDS[@]}"; do
                    if [[ " ${GROUP_GUIDS[$group]} " =~ " $current_guid " ]]; then
                        guid_groups+=("$group")
                    fi
                done
                log "Processing switch: $switch_name ($current_guid) [belongs to groups: ${guid_groups[*]}]"
            fi
            
        # Match port line with Down status
        elif [[ $line =~ ^[[:space:]]+[0-9]+[[:space:]]+([0-9]+)\[.*\][[:space:]]+==\([[:space:]]*Down/ ]]; then
            local port="${BASH_REMATCH[1]}"
            
            # Check if current GUID is in our target list
            local guid_in_target=false
            for target_guid in "${target_guids[@]}"; do
                if [[ "$target_guid" == "$current_guid" ]]; then
                    guid_in_target=true
                    break
                fi
            done
            
            if [[ "$guid_in_target" == false ]]; then
                ((skipped_count++))
                continue
            fi
            
            # Determine which group context to use for port checking
            local effective_group=""
            if [[ -n "$TARGET_GROUP" && "$TARGET_GROUP" != "all" ]]; then
                # We're targeting a specific group
                local expanded_groups
                expanded_groups=($(expand_child_groups "$TARGET_GROUP"))
                
                # Find which of the expanded groups contains this GUID
                for exp_group in "${expanded_groups[@]}"; do
                    if [[ " ${GROUP_GUIDS[$exp_group]:-} " =~ " $current_guid " ]]; then
                        effective_group="$exp_group"
                        break
                    fi
                done
            else
                # We're running all groups - need to decide which group's rules to use
                # For now, use the first group that contains this GUID
                for group in "${!GROUP_GUIDS[@]}"; do
                    if [[ " ${GROUP_GUIDS[$group]} " =~ " $current_guid " ]]; then
                        effective_group="$group"
                        break
                    fi
                done
            fi
            
            if [[ -z "$effective_group" ]]; then
                if [[ "$VERBOSE" == true ]]; then
                    log "  Skipping port $port: GUID not found in target group context"
                fi
                ((skipped_count++))
                continue
            fi
            
            # Check if this port should be monitored based on group specification
            if ! should_monitor_port "$current_guid" "$port" "$effective_group"; then
                if [[ "$VERBOSE" == true ]]; then
                    local port_spec="${GROUP_PORT_SPECS[$effective_group]:-all}"
                    log "  Skipping port $port (not in range: $port_spec for group: $effective_group)"
                fi
                ((skipped_count++))
                continue
            fi
            
            local new_port
            new_port=$(convert_port "$port")
            
            if [[ "$new_port" != "Skipped" && "$new_port" != "Invalid" ]]; then
                local port_spec="${GROUP_PORT_SPECS[$effective_group]:-all}"
                local spec_display="$port_spec"
                if [[ "$port_spec" == "all" ]]; then
                    spec_display="all"
                fi
                
                echo "$current_guid,$port,$switch_name,$new_port,$effective_group,$spec_display" >> "$RESULT_OUTPUT"
                ((down_ports_count++))
                
                if [[ "$VERBOSE" == true ]]; then
                    print_color "$YELLOW" "  Down port found: $port -> $new_port (group: $effective_group, spec: $spec_display)"
                fi
            fi
            
            ((processed_count++))
        fi
    done < "$IBLINKINFO_OUTPUT"
    
    log "Processing complete:"
    log "  Total ports processed: $processed_count"
    log "  Down ports found: $down_ports_count" 
    log "  Ports skipped (not in config or exceeds limit): $skipped_count"
    log "Results saved to: $RESULT_OUTPUT"
}

# Function to display summary - 修复后的版本
show_summary() {
    if [[ -f "$RESULT_OUTPUT" && "$DRY_RUN" == false ]]; then
        local down_ports_count
        # 修复：正确处理 grep -c 的返回值
        if down_ports_count=$(grep -c "^0x" "$RESULT_OUTPUT" 2>/dev/null); then
            # grep 成功找到匹配项，down_ports_count 已经设置
            :
        else
            # grep 失败或没有匹配项，设置为 0
            down_ports_count=0
        fi
        
        print_color "$BLUE" "=== Summary ==="
        print_color "$GREEN" "Configuration: $GUIDS_FILE"
        print_color "$GREEN" "Groups loaded: ${#GROUP_GUIDS[@]}"
        local all_guids_temp=""
        for group in "${!GROUP_GUIDS[@]}"; do
            all_guids_temp="$all_guids_temp ${GROUP_GUIDS[$group]}"
        done
        local unique_guids=($(echo "$all_guids_temp" | tr ' ' '\n' | sort -u | grep -v '^$'))
        print_color "$GREEN" "GUIDs configured: ${#unique_guids[@]}"
        print_color "$GREEN" "Down ports found: $down_ports_count"
        print_color "$GREEN" "Results file: $RESULT_OUTPUT"
        print_color "$GREEN" "Log file: $LOG_FILE"
        
        if [[ "$down_ports_count" -gt 0 && "$QUIET" == false ]]; then
            print_color "$YELLOW" "\nDown ports by group:"
            if command -v column &> /dev/null; then
                grep "^0x" "$RESULT_OUTPUT" | cut -d',' -f5,6 | sort | uniq -c | column -t
            else
                grep "^0x" "$RESULT_OUTPUT" | cut -d',' -f5,6 | sort | uniq -c
            fi
            
            print_color "$YELLOW" "\nFirst 10 down ports:"
            grep "^0x" "$RESULT_OUTPUT" | head -10 | while IFS=',' read -r guid port switch_name converted_port group spec; do
                echo "  $switch_name: port $port -> $converted_port (group: $group, spec: $spec)"
            done
        fi
        
        # Show HCA device used
        if [[ -n "$HCA_DEVICE" ]]; then
            print_color "$BLUE" "HCA device used: $HCA_DEVICE"
        fi
    fi
}

# Main function
main() {
    local CUSTOM_OUTPUT_DIR=""
    local CUSTOM_GUIDS_FILE=""
    local DISABLE_COLOR=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -g|--guids-file)
                CUSTOM_GUIDS_FILE="$2"
                shift 2
                ;;
            -o|--output-dir)
                CUSTOM_OUTPUT_DIR="$2"
                shift 2
                ;;
            -C|--hca)
                HCA_DEVICE="$2"
                shift 2
                ;;
            -q|--quiet)
                QUIET=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --list-groups)
                # Special flag to list groups
                setup_directories >/dev/null 2>&1
                if parse_guids_file >/dev/null 2>&1; then
                    list_groups
                else
                    print_color "$RED" "Error: Cannot parse configuration file"
                fi
                exit 0
                ;;
            --no-color)
                DISABLE_COLOR=true
                shift
                ;;
            *)
                # Check if this is a group name (no dash prefix)
                if [[ ! "$1" =~ ^- ]]; then
                    TARGET_GROUP="$1"
                    shift
                else
                    print_color "$RED" "Unknown option: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done
    
    # Update paths if custom ones provided
    if [[ -n "$CUSTOM_OUTPUT_DIR" ]]; then
        readonly OUTPUT_DIR="$CUSTOM_OUTPUT_DIR"
        readonly IBLINKINFO_OUTPUT="${OUTPUT_DIR}/iblinkinfo_switches_only.${TIMESTAMP}.txt"
        readonly RESULT_OUTPUT="${OUTPUT_DIR}/ibswitch_port_down_check.${TIMESTAMP}.txt"
        readonly LOG_FILE="${OUTPUT_DIR}/script.${TIMESTAMP}.log"
    fi
    
    if [[ -n "$CUSTOM_GUIDS_FILE" ]]; then
        readonly GUIDS_FILE="$CUSTOM_GUIDS_FILE"
    fi
    
    # Disable colors if requested or if not in terminal
    if [[ "$DISABLE_COLOR" == true ]] || [[ ! -t 1 ]]; then
        RED=''
        GREEN=''
        YELLOW=''
        BLUE=''
        NC=''
    fi
    
    if [[ "$QUIET" == false ]]; then
        print_color "$BLUE" "=== InfiniBand Switch Port Down Checker ==="
        print_color "$BLUE" "Timestamp: $(date)"
        print_color "$BLUE" "Configuration: $GUIDS_FILE"
        print_color "$BLUE" "Output directory: $OUTPUT_DIR"
        if [[ -n "$HCA_DEVICE" ]]; then
            print_color "$BLUE" "HCA device: $HCA_DEVICE (specified)"
        fi
        if [[ -n "$TARGET_GROUP" ]]; then
            print_color "$BLUE" "Target group: $TARGET_GROUP"
        else
            print_color "$BLUE" "Target group: all"
        fi
    fi
    
    # Setup and validation
    setup_directories
    
    # Initialize log file after directory is created
    log "=== InfiniBand Switch Port Down Checker Started ==="
    log "Configuration file: $GUIDS_FILE"
    log "Output directory: $OUTPUT_DIR"
    
    # Validate and set HCA device
    if ! validate_hca_device "$HCA_DEVICE"; then
        exit 1
    fi
    
    if ! parse_guids_file; then
        print_color "$RED" "Failed to parse configuration file."
        
        # Try to auto-fix common format issues
        if auto_fix_guids_file; then
            print_color "$GREEN" "Configuration fixed. Retrying..."
            if ! parse_guids_file; then
                print_color "$RED" "Still unable to parse configuration file. Please check the format manually."
                exit 1
            fi
        else
            print_color "$YELLOW" "Please check the file format. Example:"
            print_color "$YELLOW" "  [all]"
            print_color "$YELLOW" "  0xfc6a1c0300cdc9c0"
            print_color "$YELLOW" "  [port40]" 
            print_color "$YELLOW" "  0xfc6a1c0300ba6a40"
            exit 1
        fi
    fi
    
    # Count total unique GUIDs
    local all_guids_temp=""
    for group in "${!GROUP_GUIDS[@]}"; do
        all_guids_temp="$all_guids_temp ${GROUP_GUIDS[$group]}"
    done
    local unique_guids=($(echo "$all_guids_temp" | tr ' ' '\n' | sort -u | grep -v '^$'))
    
    if [[ ${#unique_guids[@]} -eq 0 ]]; then
        print_color "$RED" "No GUIDs found in configuration file."
        exit 1
    fi
    
    # Validate target group if specified
    if [[ -n "$TARGET_GROUP" && "$TARGET_GROUP" != "all" ]]; then
        # Check if target group exists (either as regular group or parent group)
        local group_exists=false
        
        # Check regular groups
        for group in "${!GROUP_GUIDS[@]}"; do
            if [[ "$group" == "$TARGET_GROUP" ]]; then
                group_exists=true
                break
            fi
        done
        
        # Check parent groups
        if [[ "$group_exists" == false ]]; then
            for parent in "${!CHILD_GROUPS[@]}"; do
                if [[ "$parent" == "$TARGET_GROUP" ]]; then
                    group_exists=true
                    break
                fi
            done
        fi
        
        if [[ "$group_exists" == false ]]; then
            print_color "$RED" "Error: Group '$TARGET_GROUP' not found in configuration"
            print_color "$YELLOW" "Available groups:"
            list_groups
            exit 1
        fi
        
        # Show what will be processed
        local target_guids
        target_guids=($(get_group_guids "$TARGET_GROUP"))
        log "Target group '$TARGET_GROUP' contains ${#target_guids[@]} GUIDs"
    fi
    
    # Main processing
    generate_iblinkinfo || exit 1
    process_iblinkinfo || exit 1
    
    # Show results
    if [[ "$QUIET" == false ]]; then
        show_summary
    fi
    
    print_color "$GREEN" "Script completed successfully!"
}

# Run main function with all arguments
main "$@"
