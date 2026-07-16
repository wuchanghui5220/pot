#!/bin/bash
# =============================================
# Mac 网络模式切换脚本（本地 DHCP ↔ 互联网共享）
# =============================================

INTERFACE="en11"                    # 你的以太网接口
LOCAL_IP="192.168.10.1"

show_usage() {
    echo "用法："
    echo "  sudo $0 local     # 纯本地 DHCP（推荐无网络环境）"
    echo "  sudo $0 share     # 开启系统互联网共享模式"
    echo "  sudo $0 stop      # 完全停止"
    echo "  sudo $0 status    # 查看当前状态"
    exit 1
}

show_status() {
    echo "══════════════════════════════════════════════"
    echo "               🌐 当前网络状态"
    echo "══════════════════════════════════════════════"
    
    echo "| 项目             | 状态                                      |"
    echo "|------------------|-------------------------------------------|"
    
    local ip=$(ifconfig "$INTERFACE" | grep "inet " | awk '{print $2}' | head -n 1)
    echo "| 接口 $INTERFACE        | $ip                              |"
    
    local status_line=$(ifconfig "$INTERFACE" | grep "status:" | sed 's/^[ \t]*//')
    echo "| 链路状态         | ${status_line:-未知}                         |"
    
    if pgrep -x bootpd >/dev/null; then
        echo "| DHCP 服务        | ✅ 运行中                                 |"
    else
        echo "| DHCP 服务        | ❌ 未运行                                 |"
    fi
    echo "| Mac IP           | $LOCAL_IP                              |"
    echo "|------------------|-------------------------------------------|"
    echo
    
    echo "📍 在线客户端："
    echo "| IP地址           | MAC地址                                   |"
    echo "|------------------|-------------------------------------------|"
    
    # 收集客户端信息
    local clients_output=$(arp -a | grep -E "192.168.10.|192.168.2." | grep -v "incomplete")
    
    if [ -n "$clients_output" ]; then
        echo "$clients_output" | while read -r line; do
            local ip=$(echo "$line" | awk '{print $2}' | tr -d '()')
            local mac=$(echo "$line" | awk '{print $4}')
            printf "| %-16s | %-41s |\n" "$ip" "$mac"
        done
    else
        echo "| (暂无客户端)     | -                                         |"
    fi
    
    echo "══════════════════════════════════════════════"
}

stop_all() {
    echo "正在停止所有网络共享服务..."
    launchctl stop com.apple.bootpd 2>/dev/null || true
    launchctl unload -w /System/Library/LaunchDaemons/bootps.plist 2>/dev/null || true
    ifconfig "$INTERFACE" down 2>/dev/null || true
    sleep 1
    echo "✅ 已停止所有服务"
}

start_local() {
    echo "切换到【纯本地 DHCP 模式】..."
    stop_all
    
    ifconfig "$INTERFACE" "$LOCAL_IP" netmask 255.255.255.0 up
    sleep 1
    
    # 创建本地 DHCP 配置
    cat > /etc/bootpd.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>bootp_enabled</key><false/>
    <key>dhcp_enabled</key><array><string>en11</string></array>
    <key>Subnets</key>
    <array>
        <dict>
            <key>allocate</key><true/>
            <key>dhcp_router</key><string>192.168.10.1</string>
            <key>net_address</key><string>192.168.10.0</string>
            <key>net_mask</key><string>255.255.255.0</string>
            <key>net_range</key><array><string>192.168.10.100</string><string>192.168.10.200</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

    launchctl load -w /System/Library/LaunchDaemons/bootps.plist 2>/dev/null || true
    launchctl start com.apple.bootpd
    
    echo "✅ 纯本地 DHCP 模式已启动！"
    echo "Mac IP: $LOCAL_IP"
    show_status
}

start_share() {
    echo "切换到【系统互联网共享模式】..."
    stop_all
    echo "请手动在「系统设置 → 通用 → 共享」中开启 Internet Sharing"
    echo "（从 Wi-Fi 或其他接口共享到 en11）"
    echo "开启后运行：sudo $0 status"
}

case "${1:-status}" in
    local)
        start_local
        ;;
    share)
        start_share
        ;;
    stop)
        stop_all
        ;;
    status)
        show_status
        ;;
    *)
        show_usage
        ;;
esac
