#!/bin/bash

# SSH免密登录自动部署脚本
# 作者: AI助手
# 版本: 1.0
# 用法: ./sshlogin.sh -H <主机名/IP> -u <用户名> -p <密码>

# 默认值
HOST=""
USERNAME=""
PASSWORD=""
NEW_PASSWORD=""
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
SSH_PORT=22
DEVICE_TYPE="server"  # server 或 cumulus

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示帮助信息
show_help() {
    cat << EOF
SSH免密登录自动部署脚本

用法: $0 -H <主机名/IP> -u <用户名> -p <密码> [选项]

必需参数:
    -H, --host       目标主机名或IP地址
    -u, --username   目标主机用户名
    -p, --password   目标主机密码

可选参数:
    -P, --port       SSH端口 (默认: 22)
    -k, --key        SSH私钥路径 (默认: ~/.ssh/id_rsa)
    -t, --type       设备类型 (server|cumulus, 默认: server)
    -n, --new-pass   新密码 (仅用于cumulus设备首次登录)
    -h, --help       显示此帮助信息

示例:
    # 普通服务器
    $0 -H server01 -u ubuntu -p nvidia
    
    # Cumulus交换机 (首次登录需要更改密码)
    $0 -H spine02 -u cumulus -p cumulus -t cumulus -n newpassword
    
    # 指定端口
    $0 -H 192.168.1.100 -u root -p mypassword -P 2222

EOF
}

# 检查依赖
check_dependencies() {
    log_info "检查依赖组件..."
    
    local missing_deps=()
    
    # 检查ssh-keygen
    if ! command -v ssh-keygen &> /dev/null; then
        missing_deps+=("openssh-client")
    fi
    
    # 检查sshpass
    if ! command -v sshpass &> /dev/null; then
        missing_deps+=("sshpass")
    fi
    
    # 检查ssh-copy-id
    if ! command -v ssh-copy-id &> /dev/null; then
        missing_deps+=("openssh-client")
    fi
    
    # 检查expect (用于处理交互式密码更改)
    if [ "$DEVICE_TYPE" = "cumulus" ] && ! command -v expect &> /dev/null; then
        missing_deps+=("expect")
    fi
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "缺少依赖组件: ${missing_deps[*]}"
        log_info "请运行以下命令安装依赖:"
        echo "sudo apt update && sudo apt install -y ${missing_deps[*]}"
        exit 1
    fi
    
    log_success "所有依赖组件已安装"
}

# 生成SSH密钥对
generate_ssh_key() {
    if [ -f "$SSH_KEY_PATH" ]; then
        log_info "SSH密钥已存在: $SSH_KEY_PATH"
        return 0
    fi
    
    log_info "生成SSH密钥对..."
    
    # 确保.ssh目录存在
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    chmod 700 "$(dirname "$SSH_KEY_PATH")"
    
    # 生成密钥对
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -q
    
    if [ $? -eq 0 ]; then
        log_success "SSH密钥对生成成功"
        log_info "私钥: $SSH_KEY_PATH"
        log_info "公钥: ${SSH_KEY_PATH}.pub"
        
        # 设置正确的权限
        chmod 600 "$SSH_KEY_PATH"
        chmod 644 "${SSH_KEY_PATH}.pub"
    else
        log_error "SSH密钥对生成失败"
        exit 1
    fi
}

# 处理Cumulus首次登录密码更改
handle_cumulus_password_change() {
    log_info "处理Cumulus交换机首次登录密码更改..."
    
    if [ -z "$NEW_PASSWORD" ]; then
        log_error "Cumulus设备需要指定新密码 (-n 参数)"
        exit 1
    fi
    
    # 创建expect脚本
    local expect_script=$(mktemp)
    cat > "$expect_script" << 'EOF'
#!/usr/bin/expect -f
set timeout 30
set host [lindex $argv 0]
set port [lindex $argv 1]
set username [lindex $argv 2]
set old_password [lindex $argv 3]
set new_password [lindex $argv 4]

# 连接到主机
spawn ssh -o StrictHostKeyChecking=no -p $port $username@$host
expect {
    "Are you sure you want to continue connecting" {
        send "yes\r"
        exp_continue
    }
    "password:" {
        send "$old_password\r"
    }
    timeout {
        puts "连接超时"
        exit 1
    }
}

# 处理密码更改提示
expect {
    "You are required to change your password immediately" {
        expect "Current password:"
        send "$old_password\r"
        expect "New password:"
        send "$new_password\r"
        expect "Retype new password:"
        send "$new_password\r"
        expect {
            "passwd: password updated successfully" {
                puts "密码更改成功"
                exit 0
            }
            "passwd:" {
                puts "密码更改失败"
                exit 1
            }
        }
    }
    "Last login:" {
        puts "密码已经更改过了"
        exit 0
    }
    timeout {
        puts "密码更改超时"
        exit 1
    }
}
EOF

    chmod +x "$expect_script"
    
    # 执行expect脚本
    if "$expect_script" "$HOST" "$SSH_PORT" "$USERNAME" "$PASSWORD" "$NEW_PASSWORD"; then
        log_success "Cumulus密码更改成功"
        PASSWORD="$NEW_PASSWORD"  # 更新密码变量
        rm -f "$expect_script"
        return 0
    else
        log_error "Cumulus密码更改失败"
        rm -f "$expect_script"
        return 1
    fi
}

# 测试SSH连接
test_ssh_connection() {
    log_info "测试SSH连接到 $USERNAME@$HOST:$SSH_PORT..."
    
    # 对于Cumulus设备，先处理密码更改
    if [ "$DEVICE_TYPE" = "cumulus" ]; then
        if ! handle_cumulus_password_change; then
            return 1
        fi
    fi
    
    # 使用sshpass测试连接
    sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" "$USERNAME@$HOST" "echo 'SSH连接测试成功'" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "SSH连接测试成功"
        return 0
    else
        log_error "SSH连接失败，请检查主机地址、用户名、密码和端口"
        return 1
    fi
}

# 复制公钥到目标主机
copy_ssh_key() {
    log_info "复制SSH公钥到目标主机..."
    
    # 使用ssh-copy-id复制公钥
    sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no -i "${SSH_KEY_PATH}.pub" -p "$SSH_PORT" "$USERNAME@$HOST" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "SSH公钥复制成功"
        return 0
    else
        log_error "SSH公钥复制失败"
        return 1
    fi
}

# 测试免密登录
test_passwordless_login() {
    log_info "测试免密登录..."
    
    # 测试免密登录
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p "$SSH_PORT" -i "$SSH_KEY_PATH" "$USERNAME@$HOST" "echo 'SSH免密登录测试成功'" 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_success "SSH免密登录配置成功！"
        echo
        log_info "现在可以使用以下命令免密登录:"
        echo "ssh -p $SSH_PORT $USERNAME@$HOST"
        return 0
    else
        log_error "SSH免密登录测试失败"
        return 1
    fi
}

# 清理临时文件
cleanup() {
    # 清理known_hosts中的临时条目（如果需要）
    log_info "清理完成"
}

# 主函数
main() {
    log_info "开始SSH免密登录自动部署..."
    echo
    
    # 检查依赖
    check_dependencies
    echo
    
    # 生成SSH密钥
    generate_ssh_key
    echo
    
    # 测试SSH连接
    if ! test_ssh_connection; then
        exit 1
    fi
    echo
    
    # 复制SSH公钥
    if ! copy_ssh_key; then
        exit 1
    fi
    echo
    
    # 测试免密登录
    if ! test_passwordless_login; then
        exit 1
    fi
    echo
    
    # 清理
    cleanup
    
    log_success "SSH免密登录部署完成！"
}

# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -H|--host)
            HOST="$2"
            shift 2
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -P|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        -t|--type)
            DEVICE_TYPE="$2"
            shift 2
            ;;
        -n|--new-pass)
            NEW_PASSWORD="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            show_help
            exit 1
            ;;
    esac
done

# 验证必需参数
if [ -z "$HOST" ] || [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    log_error "缺少必需参数"
    show_help
    exit 1
fi

# 验证设备类型
if [ "$DEVICE_TYPE" != "server" ] && [ "$DEVICE_TYPE" != "cumulus" ]; then
    log_error "无效的设备类型: $DEVICE_TYPE (支持: server, cumulus)"
    exit 1
fi

# 验证Cumulus设备的新密码
if [ "$DEVICE_TYPE" = "cumulus" ] && [ -z "$NEW_PASSWORD" ]; then
    log_warning "Cumulus设备建议指定新密码 (-n 参数)"
    log_info "如果设备密码已更改过，可以忽略此警告"
fi

# 验证端口号
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    log_error "无效的端口号: $SSH_PORT"
    exit 1
fi

# 显示配置信息
echo "=================================="
echo "SSH免密登录部署配置"
echo "=================================="
echo "目标主机: $HOST"
echo "用户名: $USERNAME"
echo "设备类型: $DEVICE_TYPE"
echo "SSH端口: $SSH_PORT"
echo "SSH密钥: $SSH_KEY_PATH"
if [ "$DEVICE_TYPE" = "cumulus" ] && [ -n "$NEW_PASSWORD" ]; then
    echo "新密码: [已设置]"
fi
echo "=================================="
echo

# 确认执行
read -p "确认执行部署？(y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_info "部署已取消"
    exit 0
fi

# 执行主函数
main
