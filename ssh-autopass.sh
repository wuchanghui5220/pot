#!/usr/bin/env bash

# =======================================================================
# 脚本名称: ssh_deploy_v8.sh
# 功能:
#   local : CPU 管理节点 -> 所有 GPU 节点免密
#   full  : CPU -> GPU 免密 + GPU 集群统一密钥 + GPU 节点间互信
# =======================================================================

USER_NAME="root"
PASSWORD="123456"
PORT="22"
HOST_FILE="hostfile.txt"
MODE="local"
BATCH_SIZE=15
CONNECT_TIMEOUT=5

# 是否按照 hostfile 第二列设置远端主机名
# 0: 默认，不修改主机名
# 1: 使用 -N 参数后启用，例如: 192.168.200.10 server01
SET_HOSTNAME=0

# 是否把 hostfile 中的 IP + hostname 映射同步到所有远端节点 /etc/hosts
# 0: 默认不修改 /etc/hosts
# 1: 使用 -H 参数后启用
SYNC_HOSTS=0

# full 模式验证方式:
#   ring : GPU1->GPU2->...->GPUn->GPU1，推荐，大集群速度快
#   all  : 所有 GPU 两两验证，节点很多时会比较慢
FULL_VERIFY="ring"

CPU_PRI_KEY="$HOME/.ssh/id_rsa"
CPU_PUB_KEY="$HOME/.ssh/id_rsa.pub"

CLUSTER_KEY_DIR="$HOME/.gpu_cluster_keys"
CLUSTER_PRI_KEY="$CLUSTER_KEY_DIR/id_rsa"
CLUSTER_PUB_KEY="$CLUSTER_KEY_DIR/id_rsa.pub"
CLUSTER_KNOWN_HOSTS="$CLUSTER_KEY_DIR/known_hosts"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo -e "${YELLOW}用法: $0 [选项]${NC}"
    echo "  -u <user>     SSH 用户名，默认 root"
    echo "  -p <pass>     SSH 初始密码，默认 123456"
    echo "  -P <port>     SSH 端口，默认 22"
    echo "  -f <file>     主机文件，默认 hostfile.txt"
    echo "  -m <mode>     local | full，默认 local"
    echo "  -b <num>      并发数，默认 15"
    echo "  -V [mode]     启用 Full 验证；不带值默认 ring，可指定 ring | all"
    echo "  -N            使用 hostfile 第二列设置远端主机名（默认不修改）"
    echo "  -H            将 hostfile 的 IP/hostname 映射同步到所有节点 /etc/hosts"
    echo "  -h            显示帮助"
    echo
    echo "hostfile 示例:"
    echo "  192.168.200.10 server01"
    echo "  192.168.200.11 server02"
}

# 参数解析：手工解析是为了让 -V 同时支持：
#   -V            -> 默认 ring
#   -V ring       -> ring
#   -V all        -> all
# 并避免 getopts 将后面的 -H / -N 错当作 -V 的参数。
while (( $# > 0 )); do
    case "$1" in
        -u|-p|-P|-f|-m|-b)
            opt="$1"
            if (( $# < 2 )) || [[ "$2" == -* ]]; then
                echo -e "${RED}[Error] $opt 缺少参数${NC}"
                usage
                exit 1
            fi
            case "$opt" in
                -u) USER_NAME="$2" ;;
                -p) PASSWORD="$2" ;;
                -P) PORT="$2" ;;
                -f) HOST_FILE="$2" ;;
                -m) MODE="$2" ;;
                -b) BATCH_SIZE="$2" ;;
            esac
            shift 2
            ;;
        -V)
            # -V 后面没有值，或者紧跟下一个选项：默认使用 ring。
            if (( $# == 1 )) || [[ "$2" == -* ]]; then
                FULL_VERIFY="ring"
                shift
            elif [[ "$2" == "ring" || "$2" == "all" ]]; then
                FULL_VERIFY="$2"
                shift 2
            else
                echo -e "${RED}[Error] -V 只能是 ring 或 all；也可以只写 -V（默认 ring）${NC}"
                exit 1
            fi
            ;;
        -N)
            SET_HOSTNAME=1
            shift
            ;;
        -H)
            SYNC_HOSTS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            echo -e "${RED}[Error] 未知参数: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

if [[ "$MODE" != "local" && "$MODE" != "full" ]]; then
    echo -e "${RED}[Error] MODE 只能是 local 或 full${NC}"
    exit 1
fi

if [[ "$FULL_VERIFY" != "ring" && "$FULL_VERIFY" != "all" ]]; then
    echo -e "${RED}[Error] -V 只能是 ring 或 all${NC}"
    exit 1
fi

if ! [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    echo -e "${RED}[Error] BATCH_SIZE 必须是正整数${NC}"
    exit 1
fi

HOSTS=()
declare -A HOSTNAME_BY_IP=()
declare -A DESIRED_HOSTNAME_BY_IP=()

load_hosts() {
    if [[ ! -f "$HOST_FILE" ]]; then
        echo -e "${RED}[Error] 找不到主机文件: $HOST_FILE${NC}"
        exit 1
    fi

    local line ip host extra
    local -A seen_ip=()
    local -A seen_hostname=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # 去掉注释；空行直接跳过
        line="${line%%#*}"
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        read -r ip host extra <<< "$line"
        [[ -z "$ip" ]] && continue

        # IP 重复时仅保留第一次；启用 -N 时若同一 IP 对应不同 hostname 则报错
        if [[ -n "${seen_ip[$ip]+x}" ]]; then
            if (( SET_HOSTNAME == 1 || SYNC_HOSTS == 1 )) && [[ -n "$host" && "${DESIRED_HOSTNAME_BY_IP[$ip]:-}" != "$host" ]]; then
                echo -e "${RED}[Error] $HOST_FILE 中 IP $ip 重复且 hostname 不一致${NC}"
                exit 1
            fi
            continue
        fi

        seen_ip["$ip"]=1
        HOSTS+=("$ip")

        if [[ -n "$host" ]]; then
            DESIRED_HOSTNAME_BY_IP["$ip"]="$host"
        fi
    done < "$HOST_FILE"

    if (( ${#HOSTS[@]} == 0 )); then
        echo -e "${RED}[Error] $HOST_FILE 中没有有效主机${NC}"
        exit 1
    fi

    if (( SET_HOSTNAME == 1 || SYNC_HOSTS == 1 )); then
        local name label
        local -a labels

        for ip in "${HOSTS[@]}"; do
            name="${DESIRED_HOSTNAME_BY_IP[$ip]:-}"

            if [[ -z "$name" ]]; then
                echo -e "${RED}[Error] 已启用 -N 或 -H，但 $ip 缺少第二列 hostname${NC}"
                exit 1
            fi

            if (( ${#name} > 253 )); then
                echo -e "${RED}[Error] 非法 hostname: $name（长度超过 253）${NC}"
                exit 1
            fi

            IFS='.' read -ra labels <<< "$name"
            for label in "${labels[@]}"; do
                if [[ ! "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ && ! "$label" =~ ^[A-Za-z0-9]$ ]]; then
                    echo -e "${RED}[Error] 非法 hostname: $name${NC}"
                    echo "        每个标签只能包含字母、数字、-，且不能以 - 开头或结尾"
                    exit 1
                fi
            done

            if [[ -n "${seen_hostname[$name]+x}" ]]; then
                echo -e "${RED}[Error] hostname 重复: $name${NC}"
                exit 1
            fi
            seen_hostname["$name"]="$ip"
        done
    fi

    echo -e "${BLUE}[System] 读取到 ${#HOSTS[@]} 个节点${NC}"
    if (( SET_HOSTNAME == 1 )); then
        echo -e "${YELLOW}[System] 已启用主机名配置：将使用 hostfile 第二列修改远端 hostname${NC}"
    else
        echo -e "${BLUE}[System] 主机名配置未启用：不会修改远端 hostname${NC}"
    fi

    if (( SYNC_HOSTS == 1 )); then
        echo -e "${YELLOW}[System] 已启用 /etc/hosts 同步：所有节点将获得完整 IP/hostname 映射${NC}"
    else
        echo -e "${BLUE}[System] /etc/hosts 同步未启用${NC}"
        if (( SET_HOSTNAME == 1 )); then
            echo -e "${YELLOW}[Warn] 已使用 -N 修改 hostname，但未使用 -H；除非已有 DNS，否则 ssh node02 这类名称可能无法解析${NC}"
        fi
    fi
}

install_expect_if_needed() {
    if command -v expect >/dev/null 2>&1; then
        return 0
    fi

    echo -e "${YELLOW}[System] 未检测到 expect，正在安装...${NC}"
    if command -v dnf >/dev/null 2>&1; then
        dnf install -y expect >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        yum install -y expect >/dev/null
    elif command -v apt-get >/dev/null 2>&1; then
        apt-get update >/dev/null && apt-get install -y expect >/dev/null
    else
        echo -e "${RED}[Error] 无法自动安装 expect，请手工安装${NC}"
        exit 1
    fi
}

prepare_environment() {
    install_expect_if_needed

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    if [[ ! -f "$CPU_PRI_KEY" || ! -f "$CPU_PUB_KEY" ]]; then
        echo -e "${BLUE}[System] 生成 CPU 管理端 SSH 密钥...${NC}"
        ssh-keygen -q -t rsa -b 3072 -N "" -f "$CPU_PRI_KEY"
    fi

    if [[ "$MODE" == "full" ]]; then
        mkdir -p "$CLUSTER_KEY_DIR"
        chmod 700 "$CLUSTER_KEY_DIR"

        if [[ -f "$CLUSTER_PRI_KEY" && -f "$CLUSTER_PUB_KEY" ]]; then
            echo -e "${BLUE}[System] 使用现有 GPU 集群密钥，支持增量扩容${NC}"
        else
            echo -e "${BLUE}[System] 生成 GPU 集群统一互信密钥...${NC}"
            rm -f "$CLUSTER_PRI_KEY" "$CLUSTER_PUB_KEY"
            ssh-keygen -q -t rsa -b 3072 -N "" -f "$CLUSTER_PRI_KEY"
        fi
    fi
}

# 正确返回 ssh-copy-id 子进程退出码，而不是 expect 自己的假成功状态
copy_cpu_key_with_expect() {
    local ip="$1"

    SSH_DEPLOY_USER="$USER_NAME" \
    SSH_DEPLOY_PASS="$PASSWORD" \
    SSH_DEPLOY_HOST="$ip" \
    SSH_DEPLOY_PORT="$PORT" \
    SSH_DEPLOY_PUBKEY="$CPU_PUB_KEY" \
    expect <<'EXPECT_EOF' >/dev/null 2>&1
set timeout 15
set user $env(SSH_DEPLOY_USER)
set pass $env(SSH_DEPLOY_PASS)
set host $env(SSH_DEPLOY_HOST)
set port $env(SSH_DEPLOY_PORT)
set pubkey $env(SSH_DEPLOY_PUBKEY)

spawn ssh-copy-id -i $pubkey -p $port -o StrictHostKeyChecking=no -o ConnectTimeout=5 $user@$host

expect {
    -re "(?i)yes/no" {
        send -- "yes\r"
        exp_continue
    }
    -re "(?i)password:" {
        send -- "$pass\r"
        exp_continue
    }
    -re "(?i)permission denied" {
        exit 10
    }
    timeout {
        exit 124
    }
    eof
}

set result [wait]
set os_error [lindex $result 2]
set exit_code [lindex $result 3]
if {$os_error != 0} {
    exit 125
}
exit $exit_code
EXPECT_EOF
}

cpu_ssh() {
    local ip="$1"
    shift
    ssh \
        -p "$PORT" \
        -i "$CPU_PRI_KEY" \
        -o BatchMode=yes \
        -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$CONNECT_TIMEOUT" \
        "$USER_NAME@$ip" "$@"
}

cpu_scp() {
    local src="$1"
    local ip="$2"
    local dst="$3"

    scp \
        -P "$PORT" \
        -i "$CPU_PRI_KEY" \
        -o BatchMode=yes \
        -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$CONNECT_TIMEOUT" \
        "$src" "$USER_NAME@$ip:$dst"
}


# 以 root 权限执行远端命令。
# root 用户直接执行；普通用户优先使用 sudo -n，若需要 sudo 密码则使用初始 SSH 密码通过 stdin 提交。
cpu_ssh_root_cmd() {
    local ip="$1"
    local command="$2"

    if [[ "$USER_NAME" == "root" ]]; then
        cpu_ssh "$ip" "bash -c $(printf '%q' "$command")"
        return $?
    fi

    if cpu_ssh "$ip" 'sudo -n true' >/dev/null 2>&1; then
        cpu_ssh "$ip" "sudo -n bash -c $(printf '%q' "$command")"
        return $?
    fi

    printf '%s\n' "$PASSWORD" | ssh \
        -p "$PORT" \
        -i "$CPU_PRI_KEY" \
        -o BatchMode=yes \
        -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="$CONNECT_TIMEOUT" \
        "$USER_NAME@$ip" \
        "sudo -S -p '' bash -c $(printf '%q' "$command")"
}

set_hostname_on_node() {
    local ip="$1"
    local desired="${DESIRED_HOSTNAME_BY_IP[$ip]:-}"
    local current actual quoted

    if [[ -z "$desired" ]]; then
        echo -e "${RED}[Hostname FAIL] $ip 未定义目标 hostname${NC}"
        return 1
    fi

    current=$(cpu_ssh "$ip" 'hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || hostname' 2>/dev/null | head -n1 | tr -d '\r' || true)

    if [[ "$current" == "$desired" ]]; then
        HOSTNAME_BY_IP["$ip"]="$desired"
        echo -e "${GREEN}[Hostname PASS] $ip 已是 $desired，无需修改${NC}"
        return 0
    fi

    printf -v quoted '%q' "$desired"

    # hostnamectl 会持久写入 /etc/hostname。
    # 对 Ubuntu/Debian 常见的 127.0.1.1 条目同步更新，避免 sudo/本机解析仍引用旧 hostname。
    local remote_cmd="
set -e
new_hostname=$quoted

if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname \"\$new_hostname\"
else
    printf '%s\\n' \"\$new_hostname\" > /etc/hostname
    hostname \"\$new_hostname\"
fi

if [[ -f /etc/hosts ]] && grep -qE '^127\\.0\\.1\\.1([[:space:]]|$)' /etc/hosts; then
    cp -a /etc/hosts /etc/hosts.before_ssh_deploy_hostname 2>/dev/null || true
    sed -i -E \"s/^127\\.0\\.1\\.1([[:space:]].*)?$/127.0.1.1\\t\$new_hostname/\" /etc/hosts
fi
"

    if ! cpu_ssh_root_cmd "$ip" "$remote_cmd" >/dev/null 2>&1; then
        echo -e "${RED}[Hostname FAIL] $ip -> $desired（需要 root/sudo 权限）${NC}"
        return 1
    fi

    actual=$(cpu_ssh "$ip" 'hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null || hostname' 2>/dev/null | head -n1 | tr -d '\r' || true)

    if [[ "$actual" != "$desired" ]]; then
        echo -e "${RED}[Hostname FAIL] $ip 目标=$desired 实际=${actual:-unknown}${NC}"
        return 1
    fi

    HOSTNAME_BY_IP["$ip"]="$desired"
    echo -e "${GREEN}[Hostname PASS] $ip : ${current:-unknown} -> $desired${NC}"
    return 0
}

build_cluster_hosts_map() {
    local map_file="$1"
    : > "$map_file"

    local ip name
    for ip in "${HOSTS[@]}"; do
        name="${DESIRED_HOSTNAME_BY_IP[$ip]:-}"
        if [[ -z "$name" ]]; then
            echo -e "${RED}[Error] $ip 缺少第二列 hostname，无法生成 /etc/hosts 映射${NC}"
            return 1
        fi
        printf '%s\t%s\n' "$ip" "$name" >> "$map_file"
    done
}

sync_hosts_on_node() {
    local ip="$1"
    local map_file="$2"
    local remote_tmp remote_cmd quoted_tmp

    # 先以普通 SSH 用户身份在其 HOME 下创建临时文件，随后由 sudo/root 更新 /etc/hosts。
    remote_tmp=$(cpu_ssh "$ip" 'mktemp "$HOME/.ssh_deploy_hosts.XXXXXX"' 2>/dev/null | head -n1 | tr -d '\r')
    if [[ -z "$remote_tmp" ]]; then
        echo -e "${RED}[Hosts FAIL] $ip 无法创建远端临时文件${NC}"
        return 1
    fi

    if ! cpu_scp "$map_file" "$ip" "$remote_tmp" >/dev/null 2>&1; then
        cpu_ssh "$ip" "rm -f $(printf '%q' "$remote_tmp")" >/dev/null 2>&1 || true
        echo -e "${RED}[Hosts FAIL] $ip 分发主机映射失败${NC}"
        return 1
    fi

    printf -v quoted_tmp '%q' "$remote_tmp"
    remote_cmd="
set -e
map_file=$quoted_tmp
hosts_file=/etc/hosts
start_marker='# BEGIN SSH_DEPLOY_CLUSTER_HOSTS'
end_marker='# END SSH_DEPLOY_CLUSTER_HOSTS'
tmp=\$(mktemp)

# 保留 /etc/hosts 原有内容，仅替换本脚本管理的区块，保证脚本可重复执行。
awk -v start=\"\$start_marker\" -v end=\"\$end_marker\" '
    \$0 == start { skip=1; next }
    \$0 == end   { skip=0; next }
    !skip { print }
' \"\$hosts_file\" > \"\$tmp\"

# 去掉尾部多余空行后追加受管区块。
sed -i ':a;/^[[:space:]]*\$/ { \$d; N; ba; }' \"\$tmp\" 2>/dev/null || true
printf '\\n%s\\n' \"\$start_marker\" >> \"\$tmp\"
cat \"\$map_file\" >> \"\$tmp\"
printf '%s\\n' \"\$end_marker\" >> \"\$tmp\"

# 第一次修改时保存一份原始备份。
if [[ ! -f /etc/hosts.before_ssh_deploy_cluster ]]; then
    cp -a \"\$hosts_file\" /etc/hosts.before_ssh_deploy_cluster
fi

cat \"\$tmp\" > \"\$hosts_file\"
rm -f \"\$tmp\"

# NSS 解析验证：每个 hostname 必须能解析到 hostfile 指定 IP。
while read -r expected_ip expected_name _; do
    [[ -z \"\$expected_ip\" || -z \"\$expected_name\" ]] && continue
    if ! getent ahostsv4 \"\$expected_name\" 2>/dev/null | awk '{print \$1}' | grep -Fxq \"\$expected_ip\"; then
        echo \"resolution_failed:\$expected_name:\$expected_ip\" >&2
        rm -f \"\$map_file\"
        exit 20
    fi
done < \"\$map_file\"

rm -f \"\$map_file\"
"

    if ! cpu_ssh_root_cmd "$ip" "$remote_cmd" >/dev/null 2>&1; then
        cpu_ssh "$ip" "rm -f $(printf '%q' "$remote_tmp")" >/dev/null 2>&1 || true
        echo -e "${RED}[Hosts FAIL] $ip 更新或解析验证失败${NC}"
        return 1
    fi

    echo -e "${GREEN}[Hosts PASS] $ip /etc/hosts 已同步${NC}"
    return 0
}

sync_cluster_hosts() {
    local map_file
    map_file=$(mktemp)

    if ! build_cluster_hosts_map "$map_file"; then
        rm -f "$map_file"
        return 1
    fi

    local rc=0
    local -a pids=()
    local ip

    for ip in "${HOSTS[@]}"; do
        sync_hosts_on_node "$ip" "$map_file" &
        pids+=("$!")

        if (( ${#pids[@]} >= BATCH_SIZE )); then
            wait_pid_batch "${pids[@]}" || rc=1
            pids=()
        fi
    done

    if (( ${#pids[@]} > 0 )); then
        wait_pid_batch "${pids[@]}" || rc=1
    fi

    rm -f "$map_file"
    return "$rc"
}

build_cluster_known_hosts() {
    [[ "$MODE" == "full" ]] || return 0

    : > "$CLUSTER_KNOWN_HOSTS"

    echo -e "${BLUE}[System] 收集 GPU 节点 Host Key + hostname/FQDN...${NC}"

    local ip short_name fqdn desired_name aliases scan_host
    local scan_file
    scan_file=$(mktemp)

    for ip in "${HOSTS[@]}"; do
        # 此函数必须在 CPU -> GPU 免密已经建立后调用。
        # 同时获取 short hostname 与 FQDN，用来解决：
        #   ssh 192.168.200.13 已知，但 ssh server04 仍提示确认指纹的问题。
        short_name=$(cpu_ssh "$ip" 'hostname -s 2>/dev/null || hostname' 2>/dev/null | head -n1 | tr -d '\r' || true)
        fqdn=$(cpu_ssh "$ip" 'hostname -f 2>/dev/null || hostname' 2>/dev/null | head -n1 | tr -d '\r' || true)

        desired_name="${DESIRED_HOSTNAME_BY_IP[$ip]:-}"
        if (( SYNC_HOSTS == 1 )) && [[ -n "$desired_name" ]]; then
            HOSTNAME_BY_IP["$ip"]="$desired_name"
        else
            HOSTNAME_BY_IP["$ip"]="$short_name"
        fi

        aliases="$ip"
        if [[ -n "$desired_name" && "$desired_name" != "$ip" ]]; then
            aliases+=",$desired_name"
        fi
        if [[ -n "$short_name" && "$short_name" != "$ip" && "$short_name" != "$desired_name" ]]; then
            aliases+=",$short_name"
        fi
        if [[ -n "$fqdn" && "$fqdn" != "$ip" && "$fqdn" != "$short_name" && "$fqdn" != "$desired_name" ]]; then
            aliases+=",$fqdn"
        fi

        : > "$scan_file"
        if ! ssh-keyscan -T "$CONNECT_TIMEOUT" -p "$PORT" "$ip" 2>/dev/null > "$scan_file"; then
            echo -e "${YELLOW}[Warn] $ip 无法通过 ssh-keyscan 获取 Host Key${NC}"
            continue
        fi

        if [[ ! -s "$scan_file" ]]; then
            echo -e "${YELLOW}[Warn] $ip 未获取到 Host Key${NC}"
            continue
        fi

        # known_hosts 第一列必须与实际 ssh 使用方式一致。
        # 默认 22 端口使用: IP,hostname,FQDN
        # 非 22 端口使用: [IP]:PORT,[hostname]:PORT,[FQDN]:PORT
        if [[ "$PORT" == "22" ]]; then
            awk -v aliases="$aliases" 'NF >= 3 && $1 !~ /^#/ {$1=aliases; print}' OFS=' ' "$scan_file" \
                >> "$CLUSTER_KNOWN_HOSTS"
        else
            scan_host=""
            IFS=',' read -ra _alias_array <<< "$aliases"
            local a
            for a in "${_alias_array[@]}"; do
                [[ -n "$scan_host" ]] && scan_host+=","
                scan_host+="[$a]:$PORT"
            done
            awk -v aliases="$scan_host" 'NF >= 3 && $1 !~ /^#/ {$1=aliases; print}' OFS=' ' "$scan_file" \
                >> "$CLUSTER_KNOWN_HOSTS"
        fi

        echo -e "${GREEN}[HostKey] $ip -> ${short_name:-unknown}${fqdn:+ | $fqdn}${NC}"
    done

    rm -f "$scan_file"

    if [[ ! -s "$CLUSTER_KNOWN_HOSTS" ]]; then
        echo -e "${RED}[Error] 未能生成 GPU 集群 known_hosts${NC}"
        return 1
    fi

    sort -u "$CLUSTER_KNOWN_HOSTS" -o "$CLUSTER_KNOWN_HOSTS"
    chmod 600 "$CLUSTER_KNOWN_HOSTS"

    echo -e "${GREEN}[System] known_hosts 已生成，包含 IP/hostname/FQDN 别名${NC}"
}

install_cluster_key_on_node() {
    local ip="$1"
    local log_prefix="[Proc: $ip]"

    # 此处已经完成 CPU -> GPU 免密，所以后续不再使用 expect/password
    if ! cpu_ssh "$ip" 'mkdir -p ~/.ssh && chmod 700 ~/.ssh'; then
        echo -e "${RED}$log_prefix 无法通过 CPU 密钥登录${NC}"
        return 1
    fi

    if ! cpu_scp "$CLUSTER_PRI_KEY" "$ip" "~/.ssh/.gpu_cluster_id_rsa.tmp"; then
        echo -e "${RED}$log_prefix 分发 GPU 集群私钥失败${NC}"
        return 1
    fi

    if ! cpu_scp "$CLUSTER_PUB_KEY" "$ip" "~/.ssh/.gpu_cluster_id_rsa.pub.tmp"; then
        echo -e "${RED}$log_prefix 分发 GPU 集群公钥失败${NC}"
        return 1
    fi

    if [[ -s "$CLUSTER_KNOWN_HOSTS" ]]; then
        if ! cpu_scp "$CLUSTER_KNOWN_HOSTS" "$ip" "~/.ssh/.gpu_cluster_known_hosts.tmp"; then
            echo -e "${RED}$log_prefix 分发 known_hosts 失败${NC}"
            return 1
        fi
    fi

    # 用 bash -s 可避免把公钥内容嵌套到远程命令字符串中导致引号问题
    if ! cpu_ssh "$ip" 'bash -s' <<'REMOTE_EOF'
set -e

mkdir -p ~/.ssh
chmod 700 ~/.ssh

# 如果目标机已有不同的 id_rsa，第一次覆盖前留一份备份
if [[ -f ~/.ssh/id_rsa ]] && ! cmp -s ~/.ssh/id_rsa ~/.ssh/.gpu_cluster_id_rsa.tmp; then
    [[ -f ~/.ssh/id_rsa.before_gpu_cluster ]] || cp -p ~/.ssh/id_rsa ~/.ssh/id_rsa.before_gpu_cluster
fi
if [[ -f ~/.ssh/id_rsa.pub ]] && ! cmp -s ~/.ssh/id_rsa.pub ~/.ssh/.gpu_cluster_id_rsa.pub.tmp; then
    [[ -f ~/.ssh/id_rsa.pub.before_gpu_cluster ]] || cp -p ~/.ssh/id_rsa.pub ~/.ssh/id_rsa.pub.before_gpu_cluster
fi

install -m 600 ~/.ssh/.gpu_cluster_id_rsa.tmp ~/.ssh/id_rsa
install -m 644 ~/.ssh/.gpu_cluster_id_rsa.pub.tmp ~/.ssh/id_rsa.pub
rm -f ~/.ssh/.gpu_cluster_id_rsa.tmp ~/.ssh/.gpu_cluster_id_rsa.pub.tmp

touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys

grep -qxF "$(cat ~/.ssh/id_rsa.pub)" ~/.ssh/authorized_keys || cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

if [[ -f ~/.ssh/.gpu_cluster_known_hosts.tmp ]]; then
    touch ~/.ssh/known_hosts
    cat ~/.ssh/.gpu_cluster_known_hosts.tmp >> ~/.ssh/known_hosts
    sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts
    rm -f ~/.ssh/.gpu_cluster_known_hosts.tmp
fi

if command -v restorecon >/dev/null 2>&1; then
    restorecon -R ~/.ssh >/dev/null 2>&1 || true
fi
REMOTE_EOF
    then
        echo -e "${RED}$log_prefix GPU 集群密钥安装失败${NC}"
        return 1
    fi

    echo -e "${GREEN}$log_prefix Full 互信配置完成${NC}"
}

process_cpu_node() {
    local ip="$1"
    local log_prefix="[Proc: $ip]"

    if ! copy_cpu_key_with_expect "$ip"; then
        echo -e "${RED}$log_prefix CPU->GPU 免密失败：网络、SSH、密码或 PermitRootLogin 请检查${NC}"
        return 1
    fi

    # 立即用 BatchMode 验证，杜绝 ssh-copy-id 假成功
    if ! cpu_ssh "$ip" 'true' >/dev/null 2>&1; then
        echo -e "${RED}$log_prefix CPU->GPU Key 验证失败${NC}"
        return 1
    fi

    echo -e "${GREEN}$log_prefix CPU->GPU 免密配置完成${NC}"
}

process_full_node() {
    local ip="$1"
    install_cluster_key_on_node "$ip"
}

wait_pid_batch() {
    local rc=0
    local pid
    for pid in "$@"; do
        if ! wait "$pid"; then
            rc=1
        fi
    done
    return "$rc"
}

run_batched() {
    local func="$1"
    shift
    local -a items=("$@")
    local -a pids=()
    local item
    local rc=0

    for item in "${items[@]}"; do
        "$func" "$item" &
        pids+=("$!")

        if (( ${#pids[@]} >= BATCH_SIZE )); then
            wait_pid_batch "${pids[@]}" || rc=1
            pids=()
        fi
    done

    if (( ${#pids[@]} > 0 )); then
        wait_pid_batch "${pids[@]}" || rc=1
    fi

    return "$rc"
}

verify_cpu_to_gpu_node() {
    local ip="$1"
    local out

    if out=$(cpu_ssh "$ip" 'hostname' 2>/dev/null); then
        echo -e "${GREEN}[CPU->GPU PASS] $ip -> $out${NC}"
        return 0
    else
        echo -e "${RED}[CPU->GPU FAIL] $ip${NC}"
        return 1
    fi
}

# CPU 登录 source，再从 source 使用 GPU 集群私钥 SSH 到 target
verify_gpu_pair() {
    local source="$1"
    local target="$2"
    local target_name="${HOSTNAME_BY_IP[$target]:-}"
    local ssh_target="$target"
    local display_target="$target"

    # 如果目标 short hostname 能在源节点解析，则优先使用 hostname 验证。
    # 这样可以直接捕获“IP 已在 known_hosts，但 ssh server04 仍提示 yes/no”的问题。
    if [[ -n "$target_name" && "$target_name" != "$target" ]]; then
        if cpu_ssh "$source" "getent hosts '$target_name' >/dev/null 2>&1" >/dev/null 2>&1; then
            ssh_target="$target_name"
            display_target="$target_name($target)"
        fi
    fi

    if cpu_ssh "$source" \
        "ssh -p '$PORT' -o BatchMode=yes -o PasswordAuthentication=no -o StrictHostKeyChecking=yes -o ConnectTimeout='$CONNECT_TIMEOUT' '$USER_NAME@$ssh_target' hostname" \
        >/dev/null 2>&1; then
        echo -e "${GREEN}[GPU->GPU PASS] $source -> $display_target${NC}"
        return 0
    else
        echo -e "${RED}[GPU->GPU FAIL] $source -> $display_target${NC}"
        return 1
    fi
}

verify_gpu_ring() {
    local n=${#HOSTS[@]}
    local i src dst
    local rc=0
    local -a pids=()

    if (( n == 1 )); then
        echo -e "${YELLOW}[Warn] Full 模式只有 1 个 GPU 节点，无节点间互信可验证${NC}"
        return 0
    fi

    for ((i=0; i<n; i++)); do
        src="${HOSTS[$i]}"
        dst="${HOSTS[$(((i+1)%n))]}"
        verify_gpu_pair "$src" "$dst" &
        pids+=("$!")

        if (( ${#pids[@]} >= BATCH_SIZE )); then
            wait_pid_batch "${pids[@]}" || rc=1
            pids=()
        fi
    done

    if (( ${#pids[@]} > 0 )); then
        wait_pid_batch "${pids[@]}" || rc=1
    fi

    return "$rc"
}

verify_gpu_all() {
    local src dst
    local rc=0
    local -a pids=()

    for src in "${HOSTS[@]}"; do
        for dst in "${HOSTS[@]}"; do
            [[ "$src" == "$dst" ]] && continue

            verify_gpu_pair "$src" "$dst" &
            pids+=("$!")

            if (( ${#pids[@]} >= BATCH_SIZE )); then
                wait_pid_batch "${pids[@]}" || rc=1
                pids=()
            fi
        done
    done

    if (( ${#pids[@]} > 0 )); then
        wait_pid_batch "${pids[@]}" || rc=1
    fi

    return "$rc"
}

main() {
    load_hosts
    prepare_environment

    echo -e "${YELLOW}=== 阶段 1: CPU -> GPU 免密部署 | MODE=$MODE | Nodes=${#HOSTS[@]} | Concurrency=$BATCH_SIZE ===${NC}"

    local deploy_rc=0
    run_batched process_cpu_node "${HOSTS[@]}" || deploy_rc=1

    echo -e "${YELLOW}=== 阶段 2: CPU -> GPU 免密验证 ===${NC}"
    local cpu_verify_rc=0
    run_batched verify_cpu_to_gpu_node "${HOSTS[@]}" || cpu_verify_rc=1

    local hostname_rc=0
    local hosts_rc=0
    local hostkey_rc=0
    local cluster_install_rc=0
    local gpu_verify_rc=0

    if (( SET_HOSTNAME == 1 )); then
        echo -e "${YELLOW}=== 阶段 3: 根据 hostfile 第二列配置服务器主机名 ===${NC}"

        # hostname 配置依赖阶段 1 建立的 CPU -> GPU Key。
        # 若 CPU Key 有失败项，这里仍尝试其余正常节点，并在最终结果中统一报错。
        run_batched set_hostname_on_node "${HOSTS[@]}" || hostname_rc=1
    else
        echo -e "${BLUE}[System] 阶段 3: 未指定 -N，跳过服务器主机名修改${NC}"
    fi

    if (( SYNC_HOSTS == 1 )); then
        echo -e "${YELLOW}=== 阶段 4: 将 hostfile IP/hostname 映射同步到所有节点 /etc/hosts ===${NC}"
        if (( hostname_rc != 0 )); then
            hosts_rc=1
            echo -e "${RED}[Error] 主机名配置存在失败项，跳过 /etc/hosts 同步${NC}"
        else
            sync_cluster_hosts || hosts_rc=1
        fi
    else
        echo -e "${BLUE}[System] 阶段 4: 未指定 -H，跳过 /etc/hosts 同步${NC}"
    fi

    if [[ "$MODE" == "full" ]]; then
        echo -e "${YELLOW}=== 阶段 5: 构建 IP/hostname/FQDN known_hosts + 安装 GPU 集群互信 ===${NC}"

        if (( hostname_rc != 0 || hosts_rc != 0 )); then
            hostkey_rc=1
            cluster_install_rc=1
            echo -e "${RED}[Error] hostname 或 /etc/hosts 配置存在失败项，为避免生成错误状态，跳过 Full 互信安装${NC}"
        elif ! build_cluster_known_hosts; then
            hostkey_rc=1
        else
            run_batched process_full_node "${HOSTS[@]}" || cluster_install_rc=1
        fi

        echo -e "${YELLOW}=== 阶段 6: GPU -> GPU 互信验证 | $FULL_VERIFY ===${NC}"

        if (( hostkey_rc == 0 && cluster_install_rc == 0 )); then
            if [[ "$FULL_VERIFY" == "all" ]]; then
                verify_gpu_all || gpu_verify_rc=1
            else
                verify_gpu_ring || gpu_verify_rc=1
            fi
        else
            gpu_verify_rc=1
            echo -e "${RED}[Error] known_hosts 或 GPU 集群密钥安装失败，跳过 GPU->GPU 验证${NC}"
        fi
    else
        echo -e "${BLUE}[System] local 模式完成，不执行 GPU 节点间互信配置${NC}"
    fi

    echo
    echo -e "${BLUE}=== 执行完成 ===${NC}"
    echo "MODE                : $MODE"
    echo "Node count          : ${#HOSTS[@]}"
    echo "Set hostname        : $([[ $SET_HOSTNAME -eq 1 ]] && echo yes || echo no)"
    echo "Sync /etc/hosts     : $([[ $SYNC_HOSTS -eq 1 ]] && echo yes || echo no)"
    echo "CPU key             : $CPU_PRI_KEY"
    if [[ "$MODE" == "full" ]]; then
        echo "GPU cluster key dir : $CLUSTER_KEY_DIR"
        echo "GPU known_hosts     : $CLUSTER_KNOWN_HOSTS"
        echo "GPU verify mode     : $FULL_VERIFY"
    fi

    if (( deploy_rc != 0 || cpu_verify_rc != 0 || hostname_rc != 0 || hosts_rc != 0 || hostkey_rc != 0 || cluster_install_rc != 0 || gpu_verify_rc != 0 )); then
        echo -e "${RED}Result: 存在失败项，请查看上面的 FAIL/Error 输出${NC}"
        exit 1
    fi

    echo -e "${GREEN}Result: 全部通过${NC}"
}

main "$@"
