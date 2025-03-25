#!/bin/bash
# Rocky Linux 9.5 网卡IP配置向导脚本
# 使用nmcli命令配置网卡IP地址

# 设置文本颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # 恢复默认颜色

# 显示脚本标题
echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}   Rocky Linux 9.5 网卡配置向导    ${NC}"
echo -e "${GREEN}====================================${NC}"
echo

# 显示当前网络接口
echo -e "${BLUE}当前系统上的网络接口：${NC}"
nmcli device status
echo

# 获取网卡列表
INTERFACES=($(nmcli device status | grep -E "ethernet|wifi" | awk '{print $1}'))

# 选择网卡
if [ ${#INTERFACES[@]} -eq 0 ]; then
    echo -e "${RED}错误：未检测到可用的网络接口！${NC}"
    exit 1
fi

echo -e "${BLUE}请选择要配置的网卡：${NC}"
select INTERFACE in "${INTERFACES[@]}"; do
    if [ -n "$INTERFACE" ]; then
        echo "已选择网卡: $INTERFACE"
        break
    else
        echo -e "${RED}无效选择，请重新选择。${NC}"
    fi
done

# 获取连接名称
echo -e "\n${BLUE}请输入连接名称（默认: static-$INTERFACE）：${NC}"
read CONNECTION_NAME
if [ -z "$CONNECTION_NAME" ]; then
    CONNECTION_NAME="static-$INTERFACE"
fi

# 检查连接是否已存在
if nmcli connection show | grep -q "$CONNECTION_NAME"; then
    echo -e "\n${RED}连接 $CONNECTION_NAME 已存在！${NC}"
    echo -e "${BLUE}是否删除现有连接并重新配置？(y/n)${NC}"
    read CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        nmcli connection delete "$CONNECTION_NAME"
        echo "已删除连接 $CONNECTION_NAME"
    else
        echo "配置取消。"
        exit 0
    fi
fi

# 选择IP配置方式
echo -e "\n${BLUE}请选择IP配置方式：${NC}"
select METHOD in "手动配置(static)" "自动获取(dhcp)"; do
    if [ "$METHOD" = "手动配置(static)" ]; then
        IP_METHOD="manual"
        break
    elif [ "$METHOD" = "自动获取(dhcp)" ]; then
        IP_METHOD="auto"
        break
    else
        echo -e "${RED}无效选择，请重新选择。${NC}"
    fi
done

# 如果选择手动配置，获取IP信息
if [ "$IP_METHOD" = "manual" ]; then
    # 获取IP地址和子网掩码
    while true; do
        echo -e "\n${BLUE}请输入IP地址和子网掩码（例如：192.168.1.100/24）：${NC}"
        read IP_ADDRESS
        if [[ "$IP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
            break
        else
            echo -e "${RED}IP地址格式无效，请使用 xxx.xxx.xxx.xxx/xx 格式。${NC}"
        fi
    done

    # 获取网关地址
    while true; do
        echo -e "\n${BLUE}请输入网关地址：${NC}"
        read GATEWAY
        if [[ "$GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            break
        else
            echo -e "${RED}网关地址格式无效，请使用 xxx.xxx.xxx.xxx 格式。${NC}"
        fi
    done

    # 获取DNS服务器
    echo -e "\n${BLUE}请输入首选DNS服务器（默认：8.8.8.8）：${NC}"
    read DNS1
    if [ -z "$DNS1" ]; then
        DNS1="8.8.8.8"
    fi

    echo -e "\n${BLUE}请输入备用DNS服务器（默认：114.114.114.114）：${NC}"
    read DNS2
    if [ -z "$DNS2" ]; then
        DNS2="114.114.114.114"
    fi
fi

# 确认配置信息
echo -e "\n${GREEN}===== 配置信息确认 =====${NC}"
echo "网卡名称: $INTERFACE"
echo "连接名称: $CONNECTION_NAME"
echo "IP配置方式: $METHOD"

if [ "$IP_METHOD" = "manual" ]; then
    echo "IP地址/子网掩码: $IP_ADDRESS"
    echo "网关地址: $GATEWAY"
    echo "DNS服务器: $DNS1 $DNS2"
fi

echo -e "\n${BLUE}以上配置信息正确吗？(y/n)${NC}"
read CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "配置取消。"
    exit 0
fi

# 创建网络连接
echo -e "\n${GREEN}正在配置网络连接...${NC}"

if [ "$IP_METHOD" = "manual" ]; then
    # 创建静态IP连接
    nmcli connection add type ethernet con-name "$CONNECTION_NAME" ifname "$INTERFACE" \
        ipv4.method manual \
        ipv4.addresses "$IP_ADDRESS" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$DNS1 $DNS2" \
        autoconnect yes
else
    # 创建DHCP连接
    nmcli connection add type ethernet con-name "$CONNECTION_NAME" ifname "$INTERFACE" \
        ipv4.method auto \
        autoconnect yes
fi

# 激活连接
echo -e "\n${GREEN}正在激活网络连接...${NC}"
nmcli connection up "$CONNECTION_NAME"

# 显示连接状态
echo -e "\n${GREEN}连接状态：${NC}"
nmcli connection show "$CONNECTION_NAME" | grep -E 'ipv4|STATE'

# 显示IP配置
echo -e "\n${GREEN}IP配置：${NC}"
ip addr show "$INTERFACE"

echo -e "\n${GREEN}网络配置已完成。${NC}"
