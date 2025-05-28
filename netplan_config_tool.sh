#!/bin/bash
# Ubuntu 22.04 Comprehensive Network Configuration Tool using Netplan
# This script allows configuration of single interfaces and bond interfaces,
# as well as cleaning up existing network configurations.

# Set text colors - using green for all interactive text
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration file path
NETPLAN_DIR="/etc/netplan"
CONFIG_FILE="$NETPLAN_DIR/01-netcfg.yaml"
BACKUP_DIR="/etc/netplan/backup"

# Default file permissions for netplan configs
NETPLAN_PERMISSIONS="600"

# Display script title
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   Ubuntu 22.04 Netplan Configuration Tool      ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo

# Check if running with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script requires root privileges!${NC}"
    echo -e "${GREEN}Please run with sudo or as root user.${NC}"
    exit 1
fi

# Create backup directory if not exists
mkdir -p "$BACKUP_DIR"

# Function to set proper file permissions
set_netplan_permissions() {
    local config_file="$1"
    if [ -f "$config_file" ]; then
        chmod "$NETPLAN_PERMISSIONS" "$config_file"
        chown root:root "$config_file"
    fi
}

# Function to backup existing configuration
backup_config() {
    local backup_file="$BACKUP_DIR/netplan-backup-$(date +%Y%m%d_%H%M%S).yaml"
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$backup_file"
        set_netplan_permissions "$backup_file"
        echo -e "${GREEN}Configuration backed up to: $backup_file${NC}"
    fi
}

# Function to fix permissions on all netplan files
fix_netplan_permissions() {
    echo -e "${GREEN}Fixing netplan file permissions...${NC}"
    for config_file in "$NETPLAN_DIR"/*.yaml; do
        if [ -f "$config_file" ]; then
            set_netplan_permissions "$config_file"
            echo -e "${GREEN}Fixed permissions for: $(basename "$config_file")${NC}"
        fi
    done
}

# Function to disable cloud-init network configuration
disable_cloud_init() {
    local cloud_config="/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg"
    if [ ! -f "$cloud_config" ]; then
        echo -e "${GREEN}Disabling cloud-init network configuration...${NC}"
        cat > "$cloud_config" << 'EOF'
network: {config: disabled}
EOF
        echo -e "${GREEN}Cloud-init network configuration disabled.${NC}"
    fi
}

# Function to display current network status
show_network_status() {
    echo -e "${GREEN}Current network interfaces:${NC}"
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo
    echo
    
    echo -e "${GREEN}Current IP addresses:${NC}"
    ip addr show | grep -E "inet " | grep -v "127.0.0.1"
    echo
    
    echo -e "${GREEN}Current netplan configuration:${NC}"
    if ls "$NETPLAN_DIR"/*.yaml >/dev/null 2>&1; then
        for config_file in "$NETPLAN_DIR"/*.yaml; do
            if [ -f "$config_file" ]; then
                echo "=== $(basename "$config_file") ==="
                cat "$config_file"
                echo
            fi
        done
    else
        echo "No netplan configuration found."
    fi
    
    echo -e "${GREEN}Active routes:${NC}"
    ip route show
    echo
}

# Function to get available interfaces
get_interfaces() {
    ip link show | grep -E "^[0-9]+:" | awk -F': ' '{print $2}' | grep -v lo | tr -d '@'
}

# Function to validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to validate gateway format
validate_gateway() {
    local gw="$1"
    if [[ $gw =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to fix deprecated syntax (gateway4 -> routes)
fix_deprecated_syntax() {
    echo -e "${GREEN}Fixing deprecated syntax in netplan configurations...${NC}"
    
    for config_file in "$NETPLAN_DIR"/*.yaml; do
        if [ -f "$config_file" ] && grep -q "gateway4:" "$config_file"; then
            echo -e "${GREEN}Processing: $(basename "$config_file")${NC}"
            
            # Create backup
            backup_file="$BACKUP_DIR/$(basename "$config_file")-syntax-fix-$(date +%Y%m%d_%H%M%S).yaml"
            cp "$config_file" "$backup_file"
            echo -e "${GREEN}Backup created: $backup_file${NC}"
            
            # Convert gateway4 to routes
            local temp_file=$(mktemp)
            local interface_indent=""
            
            while IFS= read -r line; do
                if [[ "$line" =~ ^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                    # Starting a new interface
                    interface_indent=$(echo "$line" | sed 's/[^ ].*//')
                    echo "$line" >> "$temp_file"
                elif [[ "$line" =~ ^[[:space:]]*gateway4:[[:space:]]*(.+)$ ]]; then
                    # Found gateway4, extract value and convert to routes
                    gateway_value=$(echo "$line" | sed 's/^[[:space:]]*gateway4:[[:space:]]*//')
                    echo "${interface_indent}  routes:" >> "$temp_file"
                    echo "${interface_indent}    - to: default" >> "$temp_file"
                    echo "${interface_indent}      via: $gateway_value" >> "$temp_file"
                else
                    # Regular line, just copy
                    echo "$line" >> "$temp_file"
                fi
            done < "$config_file"
            
            # Replace original file
            mv "$temp_file" "$config_file"
            set_netplan_permissions "$config_file"
            echo -e "${GREEN}Converted gateway4 to routes syntax in $(basename "$config_file")${NC}"
        fi
    done
    
    echo -e "${GREEN}Applying updated configuration...${NC}"
    if netplan apply; then
        echo -e "${GREEN}Configuration applied successfully.${NC}"
        echo -e "${GREEN}Deprecated syntax has been fixed.${NC}"
    else
        echo -e "${RED}Failed to apply configuration. Check syntax with 'netplan try'${NC}"
    fi
}

# Function to clean up network configurations
cleanup_network() {
    echo -e "${GREEN}Network Configuration Cleanup${NC}"
    echo -e "${GREEN}---------------------------${NC}"

    echo -e "${GREEN}Select cleanup option:${NC}"
    select CLEANUP_METHOD in "Remove custom netplan configuration" "Reset to DHCP for all interfaces" "Remove specific interface configuration" "Return to main menu"; do
        case $CLEANUP_METHOD in
            "Remove custom netplan configuration")
                if [ -f "$CONFIG_FILE" ]; then
                    echo -e "${GREEN}Current configuration will be removed:${NC}"
                    cat "$CONFIG_FILE"
                    echo
                    echo -e "${GREEN}Confirm removal of custom netplan configuration? (y/n)${NC}"
                    read CONFIRM
                    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                        backup_config
                        rm -f "$CONFIG_FILE"
                        netplan apply
                        echo -e "${GREEN}Custom netplan configuration removed.${NC}"
                    else
                        echo -e "${GREEN}Operation canceled.${NC}"
                    fi
                else
                    echo -e "${YELLOW}No custom netplan configuration found.${NC}"
                fi
                break
                ;;

            "Reset to DHCP for all interfaces")
                INTERFACES=($(get_interfaces))
                if [ ${#INTERFACES[@]} -eq 0 ]; then
                    echo -e "${RED}Error: No network interfaces found!${NC}"
                    break
                fi

                echo -e "${GREEN}This will reset all interfaces to DHCP:${NC}"
                for INTERFACE in "${INTERFACES[@]}"; do
                    echo "- $INTERFACE"
                done
                echo
                echo -e "${GREEN}Confirm reset to DHCP for all interfaces? (y/n)${NC}"
                read CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    backup_config
                    disable_cloud_init
                    
                    cat > "$CONFIG_FILE" << EOF
network:
  version: 2
  ethernets:
EOF
                    for INTERFACE in "${INTERFACES[@]}"; do
                        cat >> "$CONFIG_FILE" << EOF
    $INTERFACE:
      dhcp4: true
EOF
                    done
                    
                    set_netplan_permissions "$CONFIG_FILE"
                    netplan apply
                    echo -e "${GREEN}All interfaces reset to DHCP.${NC}"
                else
                    echo -e "${GREEN}Operation canceled.${NC}"
                fi
                break
                ;;

            "Remove specific interface configuration")
                # Extract configured interfaces from all netplan files
                CONFIGURED_INTERFACES=()
                for config_file in "$NETPLAN_DIR"/*.yaml; do
                    if [ -f "$config_file" ]; then
                        local in_ethernets=false
                        local in_bonds=false
                        
                        while IFS= read -r line; do
                            # Check if we're entering ethernets or bonds section
                            if [[ "$line" =~ ^[[:space:]]*ethernets:[[:space:]]*$ ]]; then
                                in_ethernets=true
                                in_bonds=false
                                continue
                            elif [[ "$line" =~ ^[[:space:]]*bonds:[[:space:]]*$ ]]; then
                                in_bonds=true
                                in_ethernets=false
                                continue
                            elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ethernets|bonds ]]; then
                                # Reset flags when entering other top-level sections
                                in_ethernets=false
                                in_bonds=false
                                continue
                            fi
                            
                            # If we're in ethernets or bonds section, look for interface definitions
                            if [[ "$in_ethernets" == true ]] || [[ "$in_bonds" == true ]]; then
                                # Look for interface definition (any indentation + interface_name + colon)
                                if [[ "$line" =~ ^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                                    # Extract the interface name
                                    interface=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/:.*//')
                                    # Exclude YAML keywords and properties
                                    if [[ ! "$interface" =~ ^(dhcp4|addresses|routes|nameservers|gateway4|parameters|interfaces|mode|primary|lacp-rate|mii-monitor-interval|version)$ ]]; then
                                        # Check if interface is not already in the list
                                        if [[ ! " ${CONFIGURED_INTERFACES[@]} " =~ " ${interface} " ]]; then
                                            CONFIGURED_INTERFACES+=("$interface")
                                        fi
                                    fi
                                fi
                            fi
                        done < "$config_file"
                    fi
                done
                
                if [ ${#CONFIGURED_INTERFACES[@]} -eq 0 ]; then
                    echo -e "${YELLOW}No configured interfaces found in netplan.${NC}"
                    break
                fi

                echo -e "${GREEN}Select interface to remove from configuration:${NC}"
                select INTERFACE in "${CONFIGURED_INTERFACES[@]}"; do
                    if [ -n "$INTERFACE" ]; then
                        echo -e "${GREEN}Selected interface: $INTERFACE${NC}"
                        
                        # Find which file(s) contain this interface
                        CONTAINING_FILES=()
                        for config_file in "$NETPLAN_DIR"/*.yaml; do
                            if [ -f "$config_file" ] && grep -q "^[[:space:]]*$INTERFACE:" "$config_file"; then
                                CONTAINING_FILES+=("$config_file")
                            fi
                        done
                        
                        if [ ${#CONTAINING_FILES[@]} -eq 0 ]; then
                            echo -e "${RED}Error: Interface $INTERFACE not found in any configuration file.${NC}"
                            break
                        elif [ ${#CONTAINING_FILES[@]} -eq 1 ]; then
                            TARGET_FILE="${CONTAINING_FILES[0]}"
                            echo -e "${GREEN}Interface found in: $(basename "$TARGET_FILE")${NC}"
                        else
                            echo -e "${GREEN}Interface found in multiple files. Select which file to modify:${NC}"
                            select TARGET_FILE in "${CONTAINING_FILES[@]}"; do
                                if [ -n "$TARGET_FILE" ]; then
                                    echo -e "${GREEN}Selected file: $(basename "$TARGET_FILE")${NC}"
                                    break
                                else
                                    echo -e "${RED}Invalid selection, please try again.${NC}"
                                fi
                            done
                        fi
                        
                        echo -e "${GREEN}Confirm removal of $INTERFACE configuration from $(basename "$TARGET_FILE")? (y/n)${NC}"
                        read CONFIRM
                        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                            # Backup the target file
                            backup_file="$BACKUP_DIR/$(basename "$TARGET_FILE")-backup-$(date +%Y%m%d_%H%M%S).yaml"
                            cp "$TARGET_FILE" "$backup_file"
                            echo -e "${GREEN}Configuration backed up to: $backup_file${NC}"
                            
                            # Create a temporary file to rebuild the configuration
                            local temp_file=$(mktemp)
                            local in_target_interface=false
                            local indent_level=0
                            
                            while IFS= read -r line; do
                                # Check if this line starts the target interface
                                if [[ "$line" =~ ^[[:space:]]*$INTERFACE:[[:space:]]*$ ]]; then
                                    in_target_interface=true
                                    indent_level=$(echo "$line" | sed 's/[^ ].*//' | wc -c)
                                    continue
                                fi
                                
                                # If we're in the target interface, check for end
                                if [ "$in_target_interface" = true ]; then
                                    # Check if this line has same or less indentation and is not empty
                                    if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                                        current_indent=$(echo "$line" | sed 's/[^ ].*//' | wc -c)
                                        if [ "$current_indent" -le "$indent_level" ]; then
                                            in_target_interface=false
                                        fi
                                    elif [[ "$line" =~ ^[a-zA-Z] ]]; then
                                        in_target_interface=false
                                    fi
                                fi
                                
                                # Write line if not in target interface
                                if [ "$in_target_interface" = false ]; then
                                    echo "$line" >> "$temp_file"
                                fi
                            done < "$TARGET_FILE"
                            
                            # Clean up empty ethernets/bonds sections and empty files
                            local clean_temp_file=$(mktemp)
                            local has_interfaces=false
                            local in_ethernets=false
                            local in_bonds=false
                            
                            # First pass: check if we have any interfaces left
                            while IFS= read -r line; do
                                if [[ "$line" =~ ^[[:space:]]*ethernets:[[:space:]]*$ ]]; then
                                    in_ethernets=true
                                    in_bonds=false
                                elif [[ "$line" =~ ^[[:space:]]*bonds:[[:space:]]*$ ]]; then
                                    in_bonds=true
                                    in_ethernets=false
                                elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ethernets|bonds ]]; then
                                    in_ethernets=false
                                    in_bonds=false
                                elif ([ "$in_ethernets" = true ] || [ "$in_bonds" = true ]) && [[ "$line" =~ ^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                                    interface_name=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/:.*//')
                                    if [[ ! "$interface_name" =~ ^(dhcp4|addresses|routes|nameservers|gateway4|parameters|interfaces|mode|primary|lacp-rate|mii-monitor-interval|version)$ ]]; then
                                        has_interfaces=true
                                        break
                                    fi
                                fi
                            done < "$temp_file"
                            
                            # Second pass: rebuild file appropriately
                            if [ "$has_interfaces" = false ]; then
                                # No interfaces left, create minimal valid config or remove file
                                if [[ "$(basename "$TARGET_FILE")" == "01-netcfg.yaml" ]]; then
                                    # For our custom config file, create minimal config
                                    cat > "$clean_temp_file" << EOF
network:
  version: 2
EOF
                                else
                                    # For other files, just remove them if they become empty
                                    rm -f "$TARGET_FILE"
                                    rm -f "$temp_file"
                                    echo -e "${GREEN}Configuration file $(basename "$TARGET_FILE") removed as it became empty.${NC}"
                                    netplan apply
                                    echo -e "${GREEN}Configuration for $INTERFACE removed.${NC}"
                                    return
                                fi
                            else
                                # We have interfaces, so rebuild the file properly
                                local skip_empty_section=false
                                
                                while IFS= read -r line; do
                                    if [[ "$line" =~ ^[[:space:]]*ethernets:[[:space:]]*$ ]]; then
                                        # Check if ethernets section has any real interfaces
                                        if grep -A 50 "^[[:space:]]*ethernets:[[:space:]]*$" "$temp_file" | grep -q "^[[:space:]]\+[a-zA-Z0-9_-]\+:[[:space:]]*$"; then
                                            echo "$line" >> "$clean_temp_file"
                                            skip_empty_section=false
                                        else
                                            skip_empty_section=true
                                        fi
                                    elif [[ "$line" =~ ^[[:space:]]*bonds:[[:space:]]*$ ]]; then
                                        # Check if bonds section has any real interfaces
                                        local bonds_has_interfaces=false
                                        local temp_check=$(mktemp)
                                        
                                        # Extract just the bonds section to check
                                        awk '/^[[:space:]]*bonds:[[:space:]]*$/{flag=1; next} 
                                             /^[[:space:]]*[a-zA-Z]+:[[:space:]]*$/ && !/^[[:space:]]*bonds:[[:space:]]*$/{flag=0} 
                                             flag' "$temp_file" > "$temp_check"
                                        
                                        # Check if there are any interface definitions in bonds section
                                        while IFS= read -r bond_line; do
                                            if [[ "$bond_line" =~ ^[[:space:]]+[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                                                bond_interface_name=$(echo "$bond_line" | sed 's/^[[:space:]]*//' | sed 's/:.*//')
                                                if [[ ! "$bond_interface_name" =~ ^(dhcp4|addresses|routes|nameservers|gateway4|parameters|interfaces|mode|primary|lacp-rate|mii-monitor-interval|version)$ ]]; then
                                                    bonds_has_interfaces=true
                                                    break
                                                fi
                                            fi
                                        done < "$temp_check"
                                        rm -f "$temp_check"
                                        
                                        if [ "$bonds_has_interfaces" = true ]; then
                                            echo "$line" >> "$clean_temp_file"
                                            skip_empty_section=false
                                        else
                                            skip_empty_section=true
                                        fi
                                    elif [[ "$line" =~ ^[[:space:]]*[a-zA-Z]+:[[:space:]]*$ ]] && [[ ! "$line" =~ ethernets|bonds ]]; then
                                        # Other sections (network, version, etc.)
                                        echo "$line" >> "$clean_temp_file"
                                        skip_empty_section=false
                                    elif [[ "$line" =~ ^[a-zA-Z] ]]; then
                                        # Top-level entries
                                        echo "$line" >> "$clean_temp_file"
                                        skip_empty_section=false
                                    elif [ "$skip_empty_section" = false ]; then
                                        # Content lines (not in empty sections)
                                        echo "$line" >> "$clean_temp_file"
                                    fi
                                done < "$temp_file"
                            fi
                            
                            # Replace the original file
                            mv "$clean_temp_file" "$TARGET_FILE"
                            rm -f "$temp_file"
                            set_netplan_permissions "$TARGET_FILE"
                            netplan apply
                            echo -e "${GREEN}Configuration for $INTERFACE removed from $(basename "$TARGET_FILE").${NC}"
                        else
                            echo -e "${GREEN}Operation canceled.${NC}"
                        fi
                        break
                    else
                        echo -e "${RED}Invalid selection, please try again.${NC}"
                    fi
                done
                break
                ;;

            "Return to main menu")
                return
                ;;

            *)
                echo -e "${RED}Invalid selection, please try again.${NC}"
                ;;
        esac
    done

    echo
    show_network_status
}

# Function to configure a single network interface
configure_single_interface() {
    echo -e "${GREEN}Single Interface Configuration${NC}"
    echo -e "${GREEN}-----------------------------${NC}"

    # Get available interfaces
    INTERFACES=($(get_interfaces))

    if [ ${#INTERFACES[@]} -eq 0 ]; then
        echo -e "${RED}Error: No available network interfaces detected!${NC}"
        return
    fi

    echo -e "${GREEN}Available network interfaces:${NC}"
    for INTERFACE in "${INTERFACES[@]}"; do
        echo "- $INTERFACE"
    done
    echo

    # Select interface
    echo -e "${GREEN}Select interface to configure:${NC}"
    select INTERFACE in "${INTERFACES[@]}"; do
        if [ -n "$INTERFACE" ]; then
            echo -e "${GREEN}Selected interface: $INTERFACE${NC}"
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done

    # Select IP configuration method
    echo -e "${GREEN}Select IP configuration method for $INTERFACE:${NC}"
    select IP_METHOD in "Static configuration" "DHCP (automatic)"; do
        if [ "$IP_METHOD" = "Static configuration" ]; then
            CONFIG_TYPE="static"
            break
        elif [ "$IP_METHOD" = "DHCP (automatic)" ]; then
            CONFIG_TYPE="dhcp"
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done

    # If static IP is selected, gather IP information
    if [ "$CONFIG_TYPE" = "static" ]; then
        # Get IP address and netmask
        while true; do
            echo -e "${GREEN}Enter IP address and netmask (e.g., 192.168.1.100/24):${NC}"
            read IP_ADDRESS
            if validate_ip "$IP_ADDRESS"; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please use xxx.xxx.xxx.xxx/xx format.${NC}"
            fi
        done

        # Get gateway address (optional)
        while true; do
            echo -e "${GREEN}Enter gateway address (press Enter to skip if no gateway needed):${NC}"
            read GATEWAY
            if [ -z "$GATEWAY" ]; then
                echo -e "${YELLOW}No gateway configured - suitable for internal networks.${NC}"
                break
            elif validate_gateway "$GATEWAY"; then
                break
            else
                echo -e "${RED}Invalid gateway address format. Please use xxx.xxx.xxx.xxx format.${NC}"
            fi
        done

        # Get DNS servers
        echo -e "${GREEN}Enter primary DNS server (default: 8.8.8.8):${NC}"
        read DNS1
        if [ -z "$DNS1" ]; then
            DNS1="8.8.8.8"
        fi

        echo -e "${GREEN}Enter secondary DNS server (default: 1.1.1.1):${NC}"
        read DNS2
        if [ -z "$DNS2" ]; then
            DNS2="1.1.1.1"
        fi

        # Confirm configuration
        echo -e "${GREEN}===== Configuration Summary =====${NC}"
        echo "Interface: $INTERFACE"
        echo "IP configuration: Static"
        echo "IP address/netmask: $IP_ADDRESS"
        if [ -n "$GATEWAY" ]; then
            echo "Gateway address: $GATEWAY"
        else
            echo "Gateway: None (internal network)"
        fi
        echo "DNS servers: $DNS1 $DNS2"
    else
        # Confirm DHCP configuration
        echo -e "${GREEN}===== Configuration Summary =====${NC}"
        echo "Interface: $INTERFACE"
        echo "IP configuration: DHCP (automatic)"
    fi

    echo -e "${GREEN}Is this configuration correct? (y/n)${NC}"
    read CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Configuration canceled.${NC}"
        return
    fi

    # Backup existing configuration
    backup_config
    
    # Disable cloud-init
    disable_cloud_init

    # Create netplan configuration
    echo -e "${GREEN}Creating netplan configuration...${NC}"

    if [ "$CONFIG_TYPE" = "static" ]; then
        cat > "$CONFIG_FILE" << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: false
      addresses:
        - $IP_ADDRESS
EOF
        # Add gateway only if provided
        if [ -n "$GATEWAY" ]; then
            cat >> "$CONFIG_FILE" << EOF
      routes:
        - to: default
          via: $GATEWAY
EOF
        fi
        # Add DNS configuration
        cat >> "$CONFIG_FILE" << EOF
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF
    else
        cat > "$CONFIG_FILE" << EOF
network:
  version: 2
  ethernets:
    $INTERFACE:
      dhcp4: true
EOF
    fi

    # Apply configuration
    echo -e "${GREEN}Applying netplan configuration...${NC}"
    set_netplan_permissions "$CONFIG_FILE"
    if netplan apply; then
        echo -e "${GREEN}Configuration applied successfully.${NC}"
        
        # Wait for network to stabilize
        sleep 3
        
        # Show results
        echo -e "${GREEN}Current IP configuration for $INTERFACE:${NC}"
        ip addr show "$INTERFACE"
        echo
        echo -e "${GREEN}Current routes:${NC}"
        ip route show
    else
        echo -e "${RED}Failed to apply netplan configuration!${NC}"
        echo -e "${GREEN}Restoring backup...${NC}"
        if [ -f "$BACKUP_DIR/netplan-backup-"*".yaml" ]; then
            latest_backup=$(ls -t "$BACKUP_DIR/netplan-backup-"*".yaml" | head -1)
            cp "$latest_backup" "$CONFIG_FILE"
            netplan apply
            echo -e "${GREEN}Backup restored.${NC}"
        fi
    fi

    echo -e "${GREEN}Single interface configuration completed.${NC}"
}

# Function to configure bond interface
configure_bond() {
    echo -e "${GREEN}Bond Interface Configuration${NC}"
    echo -e "${GREEN}---------------------------${NC}"

    # Get available interfaces
    AVAILABLE_INTERFACES=($(get_interfaces))

    # Check if there are enough interfaces
    if [ ${#AVAILABLE_INTERFACES[@]} -lt 2 ]; then
        echo -e "${RED}Error: Bond configuration requires at least two network interfaces, but only ${#AVAILABLE_INTERFACES[@]} available interfaces were detected!${NC}"
        return
    fi

    echo -e "${GREEN}Available network interfaces:${NC}"
    for INTERFACE in "${AVAILABLE_INTERFACES[@]}"; do
        echo "- $INTERFACE"
    done
    echo

    # Get bond name
    echo -e "${GREEN}Enter bond interface name (default: bond0):${NC}"
    read BOND_NAME
    if [ -z "$BOND_NAME" ]; then
        BOND_NAME="bond0"
    fi

    # Select bond mode
    echo -e "${GREEN}Select bond mode:${NC}"
    select BOND_MODE in "Active-Backup (mode 1)" "802.3ad LACP (mode 4)" "Balance-RR (mode 0)"; do
        case $BOND_MODE in
            "Active-Backup (mode 1)")
                MODE_NAME="active-backup"
                MODE_NUM="1"
                break
                ;;
            "802.3ad LACP (mode 4)")
                MODE_NAME="802.3ad"
                MODE_NUM="4"
                break
                ;;
            "Balance-RR (mode 0)")
                MODE_NAME="balance-rr"
                MODE_NUM="0"
                break
                ;;
            *)
                echo -e "${RED}Invalid selection, please try again.${NC}"
                ;;
        esac
    done

    # Select interfaces for bond
    BOND_INTERFACES=()
    echo -e "${GREEN}How many interfaces to include in the bond? (2-${#AVAILABLE_INTERFACES[@]})${NC}"
    read NUM_INTERFACES

    # Validate input
    if ! [[ "$NUM_INTERFACES" =~ ^[2-9]$ ]] || [ "$NUM_INTERFACES" -gt ${#AVAILABLE_INTERFACES[@]} ]; then
        echo -e "${RED}Invalid number. Using default of 2 interfaces.${NC}"
        NUM_INTERFACES=2
    fi

    # Select interfaces
    for ((i=1; i<=NUM_INTERFACES; i++)); do
        echo -e "${GREEN}Select interface #$i for the bond:${NC}"
        select INTERFACE in "${AVAILABLE_INTERFACES[@]}"; do
            if [ -n "$INTERFACE" ]; then
                echo -e "${GREEN}Selected interface: $INTERFACE${NC}"
                BOND_INTERFACES+=("$INTERFACE")
                # Remove selected interface from available list
                AVAILABLE_INTERFACES=(${AVAILABLE_INTERFACES[@]/$INTERFACE/})
                break
            else
                echo -e "${RED}Invalid selection, please try again.${NC}"
            fi
        done
    done

    # For active-backup mode, ask for primary interface
    PRIMARY_INTERFACE=""
    if [ "$MODE_NUM" = "1" ]; then
        echo -e "${GREEN}Select primary interface for active-backup mode:${NC}"
        select PRIMARY_INTERFACE in "${BOND_INTERFACES[@]}"; do
            if [ -n "$PRIMARY_INTERFACE" ]; then
                echo -e "${GREEN}Selected primary interface: $PRIMARY_INTERFACE${NC}"
                break
            else
                echo -e "${RED}Invalid selection, please try again.${NC}"
            fi
        done
    fi

    # Select IP configuration method
    echo -e "${GREEN}Select IP configuration method for the bond interface:${NC}"
    select IP_METHOD in "Static configuration" "DHCP (automatic)"; do
        if [ "$IP_METHOD" = "Static configuration" ]; then
            CONFIG_TYPE="static"
            break
        elif [ "$IP_METHOD" = "DHCP (automatic)" ]; then
            CONFIG_TYPE="dhcp"
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done

    # If static IP is selected, get IP information
    if [ "$CONFIG_TYPE" = "static" ]; then
        while true; do
            echo -e "${GREEN}Enter IP address and netmask (e.g., 192.168.1.100/24):${NC}"
            read IP_ADDRESS
            if validate_ip "$IP_ADDRESS"; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please use xxx.xxx.xxx.xxx/xx format.${NC}"
            fi
        done

        while true; do
            echo -e "${GREEN}Enter gateway address (press Enter to skip if no gateway needed):${NC}"
            read GATEWAY
            if [ -z "$GATEWAY" ]; then
                echo -e "${YELLOW}No gateway configured - suitable for internal networks.${NC}"
                break
            elif validate_gateway "$GATEWAY"; then
                break
            else
                echo -e "${RED}Invalid gateway address format. Please use xxx.xxx.xxx.xxx format.${NC}"
            fi
        done

        echo -e "${GREEN}Enter primary DNS server (default: 8.8.8.8):${NC}"
        read DNS1
        if [ -z "$DNS1" ]; then
            DNS1="8.8.8.8"
        fi

        echo -e "${GREEN}Enter secondary DNS server (default: 1.1.1.1):${NC}"
        read DNS2
        if [ -z "$DNS2" ]; then
            DNS2="1.1.1.1"
        fi
    fi

    # Display configuration summary
    echo -e "${GREEN}===== Bond Configuration Summary =====${NC}"
    echo "Bond name: $BOND_NAME"
    echo "Bond mode: $BOND_MODE"
    echo "Bond interfaces:"
    for INTERFACE in "${BOND_INTERFACES[@]}"; do
        echo "- $INTERFACE"
    done
    if [ -n "$PRIMARY_INTERFACE" ]; then
        echo "Primary interface: $PRIMARY_INTERFACE"
    fi
    
    if [ "$CONFIG_TYPE" = "static" ]; then
        echo "IP configuration: Static"
        echo "IP address/netmask: $IP_ADDRESS"
        if [ -n "$GATEWAY" ]; then
            echo "Gateway address: $GATEWAY"
        else
            echo "Gateway: None (internal network)"
        fi
        echo "DNS servers: $DNS1 $DNS2"
    else
        echo "IP configuration: DHCP (automatic)"
    fi

    echo -e "${GREEN}Is this configuration correct? (y/n)${NC}"
    read CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Configuration canceled.${NC}"
        return
    fi

    # Backup existing configuration
    backup_config
    
    # Disable cloud-init
    disable_cloud_init

    # Create netplan configuration
    echo -e "${GREEN}Creating bond netplan configuration...${NC}"

    cat > "$CONFIG_FILE" << EOF
network:
  version: 2
  bonds:
    $BOND_NAME:
      interfaces:
EOF

    # Add interfaces to bond
    for INTERFACE in "${BOND_INTERFACES[@]}"; do
        echo "        - $INTERFACE" >> "$CONFIG_FILE"
    done

    # Add bond parameters
    cat >> "$CONFIG_FILE" << EOF
      parameters:
        mode: $MODE_NAME
        mii-monitor-interval: 100
EOF

    # Add primary interface for active-backup mode
    if [ -n "$PRIMARY_INTERFACE" ]; then
        echo "        primary: $PRIMARY_INTERFACE" >> "$CONFIG_FILE"
    fi

    # Add LACP rate for 802.3ad mode
    if [ "$MODE_NUM" = "4" ]; then
        echo "        lacp-rate: fast" >> "$CONFIG_FILE"
    fi

    # Add IP configuration
    if [ "$CONFIG_TYPE" = "static" ]; then
        cat >> "$CONFIG_FILE" << EOF
      dhcp4: false
      addresses:
        - $IP_ADDRESS
EOF
        # Add gateway only if provided
        if [ -n "$GATEWAY" ]; then
            cat >> "$CONFIG_FILE" << EOF
      routes:
        - to: default
          via: $GATEWAY
EOF
        fi
        # Add DNS configuration
        cat >> "$CONFIG_FILE" << EOF
      nameservers:
        addresses:
          - $DNS1
          - $DNS2
EOF
    else
        cat >> "$CONFIG_FILE" << EOF
      dhcp4: true
EOF
    fi

    # Add ethernet section to prevent individual interface configuration
    cat >> "$CONFIG_FILE" << EOF
  ethernets:
EOF
    for INTERFACE in "${BOND_INTERFACES[@]}"; do
        cat >> "$CONFIG_FILE" << EOF
    $INTERFACE:
      dhcp4: false
EOF
    done

    # Apply configuration
    echo -e "${GREEN}Applying bond netplan configuration...${NC}"
    set_netplan_permissions "$CONFIG_FILE"
    if netplan apply; then
        echo -e "${GREEN}Bond configuration applied successfully.${NC}"
        
        # Wait for bond to come up
        sleep 5
        
        # Show bond status
        echo -e "${GREEN}Bond status:${NC}"
        if [ -f "/proc/net/bonding/$BOND_NAME" ]; then
            cat "/proc/net/bonding/$BOND_NAME"
        else
            echo "Bond information not available in /proc/net/bonding/"
        fi
        
        echo -e "${GREEN}Current IP configuration for $BOND_NAME:${NC}"
        ip addr show "$BOND_NAME" 2>/dev/null || echo "Bond interface not found"
        
        echo -e "${GREEN}Current routes:${NC}"
        ip route show
    else
        echo -e "${RED}Failed to apply bond netplan configuration!${NC}"
        echo -e "${GREEN}Restoring backup...${NC}"
        if [ -f "$BACKUP_DIR/netplan-backup-"*".yaml" ]; then
            latest_backup=$(ls -t "$BACKUP_DIR/netplan-backup-"*".yaml" | head -1)
            cp "$latest_backup" "$CONFIG_FILE"
            netplan apply
            echo -e "${GREEN}Backup restored.${NC}"
        fi
        return
    fi

    echo -e "${GREEN}Bond configuration completed.${NC}"

    # Show testing instructions
    if [ "$MODE_NUM" = "1" ]; then
        echo -e "${YELLOW}Note: You can test the bond failover functionality with these commands:${NC}"
        echo -e "${GREEN}   sudo ip link set $PRIMARY_INTERFACE down (simulate primary interface failure)${NC}"
        echo -e "${GREEN}   sudo ip link set $PRIMARY_INTERFACE up (restore primary interface)${NC}"
        echo -e "${GREEN}   Check bond status: cat /proc/net/bonding/$BOND_NAME${NC}"
    fi

    if [ "$MODE_NUM" = "4" ]; then
        echo -e "${YELLOW}Note: For LACP mode to work correctly:${NC}"
        echo -e "${GREEN}   1. The switch ports must be configured for LACP${NC}"
        echo -e "${GREEN}   2. All interfaces in the bond should be connected to the same switch${NC}"
        echo -e "${GREEN}   3. Check bond status: cat /proc/net/bonding/$BOND_NAME${NC}"
    fi
}

# Function to view configuration backups
view_backups() {
    echo -e "${GREEN}Configuration Backups${NC}"
    echo -e "${GREEN}-------------------${NC}"
    
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
        echo -e "${YELLOW}No configuration backups found.${NC}"
        return
    fi
    
    echo -e "${GREEN}Available backups:${NC}"
    ls -la "$BACKUP_DIR/"
    echo
    
    echo -e "${GREEN}Select backup to view or restore:${NC}"
    BACKUPS=($(ls "$BACKUP_DIR/"*.yaml 2>/dev/null))
    
    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo -e "${YELLOW}No backup files found.${NC}"
        return
    fi
    
    BACKUPS+=("Return to main menu")
    
    select BACKUP in "${BACKUPS[@]}"; do
        if [ "$BACKUP" = "Return to main menu" ]; then
            return
        elif [ -n "$BACKUP" ]; then
            echo -e "${GREEN}Content of $(basename "$BACKUP"):${NC}"
            cat "$BACKUP"
            echo
            echo -e "${GREEN}Do you want to restore this backup? (y/n)${NC}"
            read CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                # Determine target file based on backup filename
                if [[ "$(basename "$BACKUP")" =~ ^01-netcfg ]]; then
                    target_file="$CONFIG_FILE"
                else
                    # For other files, try to determine the original name
                    original_name=$(basename "$BACKUP" | sed 's/-backup-[0-9_]*\.yaml/.yaml/')
                    target_file="$NETPLAN_DIR/$original_name"
                fi
                
                cp "$BACKUP" "$target_file"
                set_netplan_permissions "$target_file"
                netplan apply
                echo -e "${GREEN}Backup restored to $(basename "$target_file") and applied.${NC}"
            fi
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done
}

# Main menu loop
while true; do
    # Show current network status
    show_network_status

    # Display main menu
    echo -e "${GREEN}Select an option:${NC}"
    select OPTION in "Configure single interface" "Configure bond interface" "Clean up network configurations" "Fix permissions and deprecated syntax" "View/restore configuration backups" "Exit"; do
        case $OPTION in
            "Configure single interface")
                configure_single_interface
                break
                ;;
            "Configure bond interface")
                configure_bond
                break
                ;;
            "Clean up network configurations")
                cleanup_network
                break
                ;;
            "Fix permissions and deprecated syntax")
                fix_netplan_permissions
                fix_deprecated_syntax
                break
                ;;
            "View/restore configuration backups")
                view_backups
                break
                ;;
            "Exit")
                echo -e "${GREEN}Exiting netplan configuration tool.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid selection, please try again.${NC}"
                ;;
        esac
    done
done
