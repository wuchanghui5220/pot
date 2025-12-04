#!/bin/bash

# =======================================================================
# 脚本名称: ssh_deploy_v3_pro.sh
# 功能: CPU->GPU 单向免密 | GPU 集群互信 | 并发执行 | 结果验证
# =======================================================================

# --- 配置参数 ---
USER_NAME="root"
PASSWORD="123456"
PORT="22"
HOST_FILE="hostfile.txt"
MODE="local" 
BATCH_SIZE=15  # 并发控制：每批同时处理多少台主机

# --- 密钥持久化路径 ---
CLUSTER_KEY_DIR="$HOME/.gpu_cluster_keys"
CLUSTER_PRI_KEY="$CLUSTER_KEY_DIR/id_rsa"
CLUSTER_PUB_KEY="$CLUSTER_KEY_DIR/id_rsa.pub"

# --- 颜色定义 ---
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- 帮助函数 ---
usage() {
    echo -e "${YELLOW}用法: $0 [选项]${NC}"
    echo "  -u <user>     SSH 用户名 (默认: root)"
    echo "  -p <pass>     SSH 密码 (默认: 123456)"
    echo "  -P <port>     SSH 端口 (默认: 22)"
    echo "  -f <file>     IP 列表文件 (默认: hostfile.txt)"
    echo "  -m <mode>     模式: local 或 full (默认: local)"
    exit 1
}

# --- 参数解析 ---
while getopts "u:p:P:f:m:h" opt; do
    case $opt in
        u) USER_NAME=$OPTARG ;;
        p) PASSWORD=$OPTARG ;;
        P) PORT=$OPTARG ;;
        f) HOST_FILE=$OPTARG ;;
        m) MODE=$OPTARG ;;
        h) usage ;;
        ?) usage ;;
    esac
done

# --- 环境准备 ---
prepare_environment() {
    # 检查 expect
    if ! command -v expect &> /dev/null; then
        echo -e "${YELLOW}[System] 正在安装 expect...${NC}"
        if command -v yum &> /dev/null; then yum install -y expect &>/dev/null
        elif command -v apt-get &> /dev/null; then apt-get update &>/dev/null && apt-get install -y expect &>/dev/null
        else echo -e "${RED}[Error] 请手动安装 expect${NC}"; exit 1; fi
    fi

    # 1. 准备 CPU 管理端密钥
    if [ ! -f ~/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -P "" -f ~/.ssh/id_rsa >/dev/null 2>&1
    fi

    # 2. 准备 GPU 集群互信密钥 (仅 Full 模式)
    if [ "$MODE" == "full" ]; then
        if [ ! -d "$CLUSTER_KEY_DIR" ]; then mkdir -p "$CLUSTER_KEY_DIR"; chmod 700 "$CLUSTER_KEY_DIR"; fi
        if [ -f "$CLUSTER_PRI_KEY" ]; then
            echo -e "${BLUE}[System] 检测到现有的集群密钥，将用于增量扩容。${NC}"
        else
            echo -e "${BLUE}[System] 生成新的集群互信密钥对...${NC}"
            ssh-keygen -t rsa -P "" -f "$CLUSTER_PRI_KEY" >/dev/null 2>&1
        fi
    fi
}

# --- 单个节点处理逻辑 (将被并发调用) ---
process_node() {
    local ip=$1
    local log_prefix="[Proc: $ip]"
    
    # 1. CPU -> GPU 免密 (ssh-copy-id)
    expect -c "
        set timeout 10
        spawn ssh-copy-id -p $PORT -o StrictHostKeyChecking=no $USER_NAME@$ip
        expect {
            \"*yes/no*\" { send \"yes\r\"; exp_continue }
            \"*password:*\" { send \"$PASSWORD\r\" }
            \"*already exist*\" { exit 0 }
        }
        expect eof
    " > /dev/null 2>&1

    if [ $? -ne 0 ]; then
        echo -e "${RED}$log_prefix CPU->GPU 基础免密失败 (密码错误或网络不可达)${NC}"
        return 1
    fi

    # 2. 如果是 Full 模式，配置 GPU 互信
    if [ "$MODE" == "full" ]; then
        # 分发集群私钥
        expect -c "
            set timeout 10
            spawn scp -P $PORT -o StrictHostKeyChecking=no $CLUSTER_PRI_KEY $USER_NAME@$ip:~/.ssh/id_rsa
            expect { \"*password:*\" { send \"$PASSWORD\r\" } }
            expect eof
        " > /dev/null 2>&1

        # 分发集群公钥
        expect -c "
            set timeout 10
            spawn scp -P $PORT -o StrictHostKeyChecking=no $CLUSTER_PUB_KEY $USER_NAME@$ip:~/.ssh/id_rsa.pub
            expect { \"*password:*\" { send \"$PASSWORD\r\" } }
            expect eof
        " > /dev/null 2>&1
        
        # 远程执行: 权限修复 + 追加公钥 + SELinux 修复
        # 这一步非常关键，解决了大多数免密失效的问题
        local remote_cmd="mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
                          grep -qF \"$(cat $CLUSTER_PUB_KEY)\" ~/.ssh/authorized_keys || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys && \
                          chmod 600 ~/.ssh/authorized_keys && chmod 600 ~/.ssh/id_rsa && \
                          which restorecon &>/dev/null && restorecon -R -v ~/.ssh || true"

        expect -c "
            set timeout 10
            spawn ssh -p $PORT -o StrictHostKeyChecking=no $USER_NAME@$ip \"$remote_cmd\"
            expect { \"*password:*\" { send \"$PASSWORD\r\" } }
            expect eof
        " > /dev/null 2>&1
        
        if [ $? -ne 0 ]; then
            echo -e "${RED}$log_prefix GPU 互信配置失败${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}$log_prefix 配置完成${NC}"
    return 0
}

# --- 验证逻辑 ---
verify_node() {
    local ip=$1
    # 尝试无密码执行 hostname 命令
    # -o PasswordAuthentication=no: 禁止使用密码，强制检测 Key 是否生效
    # -o ConnectTimeout=3: 设置 3 秒超时
    ssh -p $PORT -o PasswordAuthentication=no -o StrictHostKeyChecking=no -o ConnectTimeout=3 "$USER_NAME@$ip" "hostname" &>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}[Pass] $ip 验证通过${NC}"
    else
        echo -e "${RED}[Fail] $ip 验证失败 (仍需密码或无法连接)${NC}"
    fi
}

# --- 主程序 ---
main() {
    if [ ! -f "$HOST_FILE" ]; then echo -e "${RED}错误: 找不到文件 $HOST_FILE${NC}"; exit 1; fi
    
    prepare_environment

    echo -e "${YELLOW}=== 开始并发部署 (模式: $MODE |并发数: $BATCH_SIZE) ===${NC}"
    
    # --- 阶段 1: 并发部署 ---
    count=0
    for ip in $(cat "$HOST_FILE"); do
        [[ "$ip" =~ ^#.*$ ]] || [[ -z "$ip" ]] && continue
        
        # 放入后台执行
        process_node "$ip" &
        
        # 简单的并发控制
        ((count++))
        if (( count % BATCH_SIZE == 0 )); then
            wait # 等待当前批次完成
        fi
    done
    wait # 等待剩余的所有后台任务完成
    
    echo -e "${YELLOW}=== 部署结束，开始连通性验证 ===${NC}"

    # --- 阶段 2: 并发验证 ---
    # 验证也可以并发，速度更快
    count=0
    for ip in $(cat "$HOST_FILE"); do
        [[ "$ip" =~ ^#.*$ ]] || [[ -z "$ip" ]] && continue
        
        verify_node "$ip" &
        
        ((count++))
        if (( count % BATCH_SIZE == 0 )); then wait; fi
    done
    wait

    echo -e "${BLUE}=== 所有任务执行完毕 ===${NC}"
    if [ "$MODE" == "full" ]; then
        echo -e "集群密钥保存路径: $CLUSTER_KEY_DIR (请勿删除)"
    fi
}

main
