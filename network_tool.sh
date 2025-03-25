#!/bin/bash
# Rocky Linux 9.5 Comprehensive Network Configuration Tool
# This script allows configuration of single interfaces and bond interfaces,
# as well as cleaning up existing network configurations.

# Set text colors - using green for all interactive text
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Display script title
echo -e "${GREEN}=================================================${NC}"
echo -e "${GREEN}   Rocky Linux 9.5 Network Configuration Tool     ${NC}"
echo -e "${GREEN}=================================================${NC}"
echo

# Check if running with root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script requires root privileges!${NC}"
    echo -e "${GREEN}Please run with sudo or as root user.${NC}"
    exit 1
fi

# Function to display current network status
show_network_status() {
    echo -e "${GREEN}Current network interfaces:${NC}"
    nmcli device status
    echo
    echo -e "${GREEN}Current network connections:${NC}"
    nmcli connection show
    echo
}

# Function to clean up network configurations
cleanup_network() {
    echo -e "${GREEN}Network Configuration Cleanup${NC}"
    echo -e "${GREEN}---------------------------${NC}"
    
    # Display cleanup options
    echo -e "${GREEN}Select cleanup option:${NC}"
    select CLEANUP_METHOD in "Delete specific interface connections" "Delete specific connection" "Delete all connections" "Return to main menu"; do
        case $CLEANUP_METHOD in
            "Delete specific interface connections")
                # Get all interfaces list
                INTERFACES=($(nmcli device status | grep -v "lo\|bond" | awk 'NR>1 {print $1}'))
                
                if [ ${#INTERFACES[@]} -eq 0 ]; then
                    echo -e "${RED}Error: No available network interfaces detected!${NC}"
                    break
                fi
                
                echo -e "${GREEN}Select interface to clean up:${NC}"
                select INTERFACE in "${INTERFACES[@]}"; do
                    if [ -n "$INTERFACE" ]; then
                        echo -e "${GREEN}Selected interface: $INTERFACE${NC}"
                        
                        # Get all connections for the interface
                        CONNECTIONS=($(nmcli -g NAME connection show | grep "$INTERFACE"))
                        
                        if [ ${#CONNECTIONS[@]} -eq 0 ]; then
                            echo -e "${YELLOW}Interface $INTERFACE has no configured connections.${NC}"
                            break
                        fi
                        
                        echo -e "${GREEN}The following connections will be deleted:${NC}"
                        for CONN in "${CONNECTIONS[@]}"; do
                            echo "- $CONN"
                        done
                        
                        echo -e "${GREEN}Confirm deletion of these connections? (y/n)${NC}"
                        read CONFIRM
                        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                            for CONN in "${CONNECTIONS[@]}"; do
                                nmcli connection delete "$CONN"
                                echo -e "${GREEN}Deleted connection: $CONN${NC}"
                            done
                            echo -e "${GREEN}All connections for interface $INTERFACE have been removed.${NC}"
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
                
            "Delete specific connection")
                # Get all connections list
                CONNECTIONS=($(nmcli -g NAME connection show))
                
                if [ ${#CONNECTIONS[@]} -eq 0 ]; then
                    echo -e "${RED}Error: No network connections detected!${NC}"
                    break
                fi
                
                echo -e "${GREEN}Select connection to delete:${NC}"
                select CONN in "${CONNECTIONS[@]}"; do
                    if [ -n "$CONN" ]; then
                        echo -e "${GREEN}Selected connection: $CONN${NC}"
                        
                        echo -e "${GREEN}Confirm deletion of connection $CONN? (y/n)${NC}"
                        read CONFIRM
                        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                            nmcli connection delete "$CONN"
                            echo -e "${GREEN}Connection $CONN has been deleted.${NC}"
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
                
            "Delete all connections")
                # Get all connections list (excluding loopback)
                CONNECTIONS=($(nmcli -g NAME connection show | grep -v "lo"))
                
                if [ ${#CONNECTIONS[@]} -eq 0 ]; then
                    echo -e "${RED}Error: No network connections detected!${NC}"
                    break
                fi
                
                echo -e "${GREEN}The following connections will be deleted:${NC}"
                for CONN in "${CONNECTIONS[@]}"; do
                    echo "- $CONN"
                done
                
                echo -e "${RED}Warning: Deleting all connections may disrupt network connectivity!${NC}"
                echo -e "${GREEN}Confirm deletion of ALL connections? (y/n)${NC}"
                read CONFIRM
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    for CONN in "${CONNECTIONS[@]}"; do
                        nmcli connection delete "$CONN"
                        echo -e "${GREEN}Deleted connection: $CONN${NC}"
                    done
                    echo -e "${GREEN}All network connections have been removed.${NC}"
                else
                    echo -e "${GREEN}Operation canceled.${NC}"
                fi
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
    
    # Show current network status after cleanup
    echo
    show_network_status
}

# Function to configure a single network interface
configure_single_interface() {
    echo -e "${GREEN}Single Interface Configuration${NC}"
    echo -e "${GREEN}-----------------------------${NC}"
    
    # Display available interfaces
    echo -e "${GREEN}Available network interfaces:${NC}"
    nmcli device status | grep -E "ethernet|wifi" | grep -v "bond"
    echo
    
    # Get interface list
    INTERFACES=($(nmcli device status | grep -E "ethernet|wifi" | grep -v "bond" | awk '{print $1}'))
    
    if [ ${#INTERFACES[@]} -eq 0 ]; then
        echo -e "${RED}Error: No available network interfaces detected!${NC}"
        return
    fi
    
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
    
    # Get connection name
    echo -e "${GREEN}Enter connection name (default: static-$INTERFACE):${NC}"
    read CONNECTION_NAME
    if [ -z "$CONNECTION_NAME" ]; then
        CONNECTION_NAME="static-$INTERFACE"
    fi
    
    # Check if connection already exists
    if nmcli connection show | grep -q "$CONNECTION_NAME"; then
        echo -e "${GREEN}Connection $CONNECTION_NAME already exists.${NC}"
        echo -e "${GREEN}Do you want to delete and reconfigure? (y/n)${NC}"
        read CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            nmcli connection delete "$CONNECTION_NAME"
            echo -e "${GREEN}Deleted connection $CONNECTION_NAME${NC}"
        else
            echo -e "${GREEN}Configuration canceled.${NC}"
            return
        fi
    fi
    
    # Select IP configuration method
    echo -e "${GREEN}Select IP configuration method for $INTERFACE:${NC}"
    select IP_METHOD in "Static configuration" "DHCP (automatic)"; do
        if [ "$IP_METHOD" = "Static configuration" ]; then
            CONFIG_TYPE="manual"
            break
        elif [ "$IP_METHOD" = "DHCP (automatic)" ]; then
            CONFIG_TYPE="auto"
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done
    
    # If static IP is selected, gather IP information
    if [ "$CONFIG_TYPE" = "manual" ]; then
        # Get IP address and netmask
        while true; do
            echo -e "${GREEN}Enter IP address and netmask (e.g., 192.168.1.100/24):${NC}"
            read IP_ADDRESS
            if [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please use xxx.xxx.xxx.xxx/xx format.${NC}"
            fi
        done
    
        # Get gateway address
        while true; do
            echo -e "${GREEN}Enter gateway address:${NC}"
            read GATEWAY
            if [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
        echo "Connection name: $CONNECTION_NAME"
        echo "IP configuration: Static"
        echo "IP address/netmask: $IP_ADDRESS"
        echo "Gateway address: $GATEWAY"
        echo "DNS servers: $DNS1 $DNS2"
    else
        # Confirm DHCP configuration
        echo -e "${GREEN}===== Configuration Summary =====${NC}"
        echo "Interface: $INTERFACE"
        echo "Connection name: $CONNECTION_NAME"
        echo "IP configuration: DHCP (automatic)"
    fi
    
    echo -e "${GREEN}Is this configuration correct? (y/n)${NC}"
    read CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Configuration canceled.${NC}"
        return
    fi
    
    # Create network connection
    echo -e "${GREEN}Creating network connection...${NC}"
    
    if [ "$CONFIG_TYPE" = "manual" ]; then
        # Create static IP connection
        nmcli connection add type ethernet con-name "$CONNECTION_NAME" ifname "$INTERFACE" \
            ipv4.method manual \
            ipv4.addresses "$IP_ADDRESS" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "$DNS1 $DNS2" \
            autoconnect yes
    else
        # Create DHCP connection
        nmcli connection add type ethernet con-name "$CONNECTION_NAME" ifname "$INTERFACE" \
            ipv4.method auto \
            autoconnect yes
    fi
    
    # Activate connection
    echo -e "${GREEN}Activating connection...${NC}"
    nmcli connection up "$CONNECTION_NAME"
    
    # Show connection status
    echo -e "${GREEN}Connection status:${NC}"
    nmcli connection show "$CONNECTION_NAME" | grep -E 'ipv4|STATE'
    
    # Show IP configuration
    echo -e "${GREEN}IP configuration:${NC}"
    ip addr show "$INTERFACE"
    
    echo -e "${GREEN}Single interface configuration completed.${NC}"
}

# Function to configure bond interface
configure_bond() {
    echo -e "${GREEN}Bond Interface Configuration${NC}"
    echo -e "${GREEN}---------------------------${NC}"
    
    # Display available interfaces
    echo -e "${GREEN}Available network interfaces:${NC}"
    nmcli device status | grep "ethernet" | grep -v "bond"
    echo
    
    # Get interface list
    AVAILABLE_INTERFACES=($(nmcli device status | grep "ethernet" | grep -v "bond" | awk '{print $1}'))
    
    # Check if there are enough interfaces
    if [ ${#AVAILABLE_INTERFACES[@]} -lt 2 ]; then
        echo -e "${RED}Error: Bond configuration requires at least two network interfaces, but only ${#AVAILABLE_INTERFACES[@]} available interfaces were detected!${NC}"
        return
    fi
    
    # Get bond name
    echo -e "${GREEN}Enter bond interface name (default: bond0):${NC}"
    read BOND_NAME
    if [ -z "$BOND_NAME" ]; then
        BOND_NAME="bond0"
    fi
    
    # Check if bond connection already exists
    if nmcli connection show | grep -q "$BOND_NAME"; then
        echo -e "${GREEN}Bond connection $BOND_NAME already exists.${NC}"
        echo -e "${GREEN}Do you want to delete and reconfigure? (y/n)${NC}"
        read CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            nmcli connection delete "$BOND_NAME"
            echo -e "${GREEN}Deleted connection $BOND_NAME${NC}"
        else
            echo -e "${GREEN}Configuration canceled.${NC}"
            return
        fi
    fi
    
    # Select bond mode
    echo -e "${GREEN}Select bond mode:${NC}"
    select BOND_MODE in "Active-Backup (mode 1)" "802.3ad LACP (mode 4)"; do
        if [ "$BOND_MODE" = "Active-Backup (mode 1)" ]; then
            MODE_NUM="1"
            MODE_NAME="active-backup"
            break
        elif [ "$BOND_MODE" = "802.3ad LACP (mode 4)" ]; then
            MODE_NUM="4"
            MODE_NAME="802.3ad"
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done
    
    # Get interfaces for bond
    # For active-backup mode, we need to identify primary interface
    if [ "$MODE_NUM" = "1" ]; then
        # Select primary interface
        echo -e "${GREEN}Select primary (active) interface for the bond:${NC}"
        select PRIMARY_INTERFACE in "${AVAILABLE_INTERFACES[@]}"; do
            if [ -n "$PRIMARY_INTERFACE" ]; then
                echo -e "${GREEN}Selected primary interface: $PRIMARY_INTERFACE${NC}"
                # Remove primary interface from available list
                AVAILABLE_INTERFACES=(${AVAILABLE_INTERFACES[@]/$PRIMARY_INTERFACE/})
                break
            else
                echo -e "${RED}Invalid selection, please try again.${NC}"
            fi
        done
        
        # Select backup interface
        echo -e "${GREEN}Select backup (standby) interface for the bond:${NC}"
        select BACKUP_INTERFACE in "${AVAILABLE_INTERFACES[@]}"; do
            if [ -n "$BACKUP_INTERFACE" ]; then
                echo -e "${GREEN}Selected backup interface: $BACKUP_INTERFACE${NC}"
                BOND_INTERFACES=("$PRIMARY_INTERFACE" "$BACKUP_INTERFACE")
                break
            else
                echo -e "${RED}Invalid selection, please try again.${NC}"
            fi
        done
        
        # Set bond options
        BOND_OPTIONS="mode=$MODE_NAME,miimon=100,primary=$PRIMARY_INTERFACE"
    else
        # For LACP, just select interfaces
        BOND_INTERFACES=()
        echo -e "${GREEN}How many interfaces to include in the bond? (2-8)${NC}"
        read NUM_INTERFACES
        
        # Validate input
        if ! [[ "$NUM_INTERFACES" =~ ^[2-8]$ ]]; then
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
        
        # Set bond options for LACP
        BOND_OPTIONS="mode=$MODE_NAME,miimon=100,lacp_rate=fast"
    fi
    
    # Check and delete existing connections for the interfaces
    for INTERFACE in "${BOND_INTERFACES[@]}"; do
        CONN=$(nmcli -g NAME connection show | grep "$INTERFACE")
        if [ -n "$CONN" ]; then
            echo -e "${GREEN}Detected existing connection for $INTERFACE: $CONN${NC}"
            echo -e "${GREEN}Do you want to delete this connection for bond configuration? (y/n)${NC}"
            read CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                nmcli connection delete "$CONN"
                echo -e "${GREEN}Deleted connection $CONN${NC}"
            else
                echo -e "${GREEN}Configuration canceled.${NC}"
                return
            fi
        fi
    done
    
    # Select IP configuration method
    echo -e "${GREEN}Select IP configuration method for the bond interface:${NC}"
    select IP_METHOD in "Static configuration" "DHCP (automatic)"; do
        if [ "$IP_METHOD" = "Static configuration" ]; then
            CONFIG_TYPE="manual"
            break
        elif [ "$IP_METHOD" = "DHCP (automatic)" ]; then
            CONFIG_TYPE="auto"
            break
        else
            echo -e "${RED}Invalid selection, please try again.${NC}"
        fi
    done
    
    # If static IP is selected, get IP information
    if [ "$CONFIG_TYPE" = "manual" ]; then
        # Get IP address and netmask
        while true; do
            echo -e "${GREEN}Enter IP address and netmask (e.g., 192.168.1.100/24):${NC}"
            read IP_ADDRESS
            if [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please use xxx.xxx.xxx.xxx/xx format.${NC}"
            fi
        done
    
        # Get gateway address
        while true; do
            echo -e "${GREEN}Enter gateway address:${NC}"
            read GATEWAY
            if [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
        echo -e "${GREEN}===== Bond Configuration Summary =====${NC}"
        echo "Bond name: $BOND_NAME"
        echo "Bond mode: $BOND_MODE"
        
        if [ "$MODE_NUM" = "1" ]; then
            echo "Primary interface: $PRIMARY_INTERFACE"
            echo "Backup interface: $BACKUP_INTERFACE"
        else
            echo "Bond interfaces:"
            for INTERFACE in "${BOND_INTERFACES[@]}"; do
                echo "- $INTERFACE"
            done
        fi
        
        echo "IP configuration: Static"
        echo "IP address/netmask: $IP_ADDRESS"
        echo "Gateway address: $GATEWAY"
        echo "DNS servers: $DNS1 $DNS2"
    else
        # Confirm DHCP configuration
        echo -e "${GREEN}===== Bond Configuration Summary =====${NC}"
        echo "Bond name: $BOND_NAME"
        echo "Bond mode: $BOND_MODE"
        
        if [ "$MODE_NUM" = "1" ]; then
            echo "Primary interface: $PRIMARY_INTERFACE"
            echo "Backup interface: $BACKUP_INTERFACE"
        else
            echo "Bond interfaces:"
            for INTERFACE in "${BOND_INTERFACES[@]}"; do
                echo "- $INTERFACE"
            done
        fi
        
        echo "IP configuration: DHCP (automatic)"
    fi
    
    echo -e "${GREEN}Is this configuration correct? (y/n)${NC}"
    read CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Configuration canceled.${NC}"
        return
    fi
    
    # Create bond connection
    echo -e "${GREEN}Creating bond connection...${NC}"
    
    if [ "$CONFIG_TYPE" = "manual" ]; then
        # Create bond with static IP
        nmcli connection add type bond \
            con-name "$BOND_NAME" \
            ifname "$BOND_NAME" \
            bond.options "$BOND_OPTIONS" \
            ipv4.method manual \
            ipv4.addresses "$IP_ADDRESS" \
            ipv4.gateway "$GATEWAY" \
            ipv4.dns "$DNS1 $DNS2" \
            autoconnect yes
    else
        # Create bond with DHCP
        nmcli connection add type bond \
            con-name "$BOND_NAME" \
            ifname "$BOND_NAME" \
            bond.options "$BOND_OPTIONS" \
            ipv4.method auto \
            autoconnect yes
    fi
    
    # Add interfaces to the bond
    for INTERFACE in "${BOND_INTERFACES[@]}"; do
        echo -e "${GREEN}Adding $INTERFACE to the bond...${NC}"
        nmcli connection add type bond-slave \
            con-name "$BOND_NAME-$INTERFACE" \
            ifname "$INTERFACE" \
            master "$BOND_NAME"
    done
    
    # Activate connections
    echo -e "${GREEN}Activating bond connection...${NC}"
    nmcli connection up "$BOND_NAME"
    sleep 2
    
    for INTERFACE in "${BOND_INTERFACES[@]}"; do
        echo -e "${GREEN}Activating $INTERFACE connection...${NC}"
        nmcli connection up "$BOND_NAME-$INTERFACE"
        sleep 1
    done
    
    # Display bond status
    echo -e "${GREEN}Bond status:${NC}"
    nmcli device status | grep -E "$BOND_NAME|$(echo "${BOND_INTERFACES[@]}" | tr ' ' '|')"
    echo
    
    # Display bond details
    echo -e "${GREEN}Bond detailed information:${NC}"
    cat /proc/net/bonding/$BOND_NAME
    echo
    
    # Display IP configuration
    echo -e "${GREEN}Bond IP configuration:${NC}"
    ip addr show "$BOND_NAME"
    
    echo -e "${GREEN}Bond configuration completed.${NC}"
    
    # Show testing instructions for active-backup mode
    if [ "$MODE_NUM" = "1" ]; then
        echo -e "${YELLOW}Note: You can test the bond failover functionality with these commands:${NC}"
        echo -e "${GREEN}   ifdown $PRIMARY_INTERFACE (simulate primary interface failure)${NC}"
        echo -e "${GREEN}   ifup $PRIMARY_INTERFACE (restore primary interface)${NC}"
        echo -e "${GREEN}   Check bond status: cat /proc/net/bonding/$BOND_NAME${NC}"
    fi
    
    # Show testing instructions for LACP mode
    if [ "$MODE_NUM" = "4" ]; then
        echo -e "${YELLOW}Note: For LACP mode to work correctly:${NC}"
        echo -e "${GREEN}   1. The switch ports must be configured for LACP${NC}"
        echo -e "${GREEN}   2. All interfaces in the bond should be connected to the same switch${NC}"
        echo -e "${GREEN}   3. Check bond status: cat /proc/net/bonding/$BOND_NAME${NC}"
    fi
}

# Main menu loop
while true; do
    # Show current network status
    show_network_status
    
    # Display main menu
    echo -e "${GREEN}Select an option:${NC}"
    select OPTION in "Configure single interface" "Configure bond interface" "Clean up network configurations" "Exit"; do
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
            "Exit")
                echo -e "${GREEN}Exiting network configuration tool.${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid selection, please try again.${NC}"
                ;;
        esac
    done
done
