#!/bin/bash

# ============================================================
# 系统优化配置脚本（合并版）
# 功能:
#   1. nvidia-fabricmanager 开机启动
#   2. ulimit 限制配置
#   3. 网络优化: ARP 设置 + rp_filter 严格模式(反向路径过滤)
#   4. IOMMU: 显式设置 intel_iommu=on iommu=pt (内核层面, 不改BIOS)
#   5. 禁用 GPU<->NIC/存储 相关 PCIe Switch 的 ACS (原 acs.sh)
#   6. 18张 RoCE 网卡 PFC/QoS 配置 (原 pfc.sh)
#   7. RoCE PFC/ECN 幂等下发脚本 + udev 事件触发(bond/驱动重载后自动重刷)
#   8. 开机自启动服务: 每次开机自动执行 GPU持久模式/IB重启/CPU性能模式/ACS禁用/PFC配置
#
# 用法:
#   sudo ./开机优化脚本_合并版.sh              # 执行全部优化配置
#   sudo ./开机优化脚本_合并版.sh acs-check     # 仅查看当前ACS状态，不修改
#   sudo ./开机优化脚本_合并版.sh acs-restore   # 恢复ACS默认设置(重新打开)
# ============================================================

set -e  # 遇到错误立即退出（注意: acs-check/acs-restore 分支内部对单点失败做了容错，不会因单张卡异常整体退出）

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

REBOOT_REQUIRED=0

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 备份配置文件
backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.backup.$(date +%Y%m%d_%H%M%S)"
        log_info "已备份 $file"
    fi
}

# ============================================================
# ACS 相关配置 (对应原 acs.sh)
# 仅对 GPU<->NIC / GPU<->存储 相关的 PCIe Switch 桥禁用 ACS
# ============================================================
ACS_BDF_LIST=(
  # --- Group1: root 0000:14, NIC(mlx5)=17, GPU=1a ---
  0000:15:00.0 0000:16:00.0 0000:16:02.0 0000:18:00.0 0000:19:00.0
  # --- Group2: root 0000:57, NIC=5a, GPU=5d ---
  0000:58:00.0 0000:59:00.0 0000:59:02.0 0000:5b:00.0 0000:5c:00.0
  # --- Group3: root 0000:70, NIC=73, GPU=76 ---
  0000:71:00.0 0000:72:00.0 0000:72:02.0 0000:74:00.0 0000:75:00.0
  # --- Group4: root 0000:77, NIC=7a, GPU=7d ---
  0000:78:00.0 0000:79:00.0 0000:79:02.0 0000:7b:00.0 0000:7c:00.0
  # --- Group5: root 0000:94, NIC=97, GPU=9a ---
  0000:95:00.0 0000:96:00.0 0000:96:02.0 0000:98:00.0 0000:99:00.0
  # --- Group6: root 0000:d4, NIC=d7, GPU=da ---
  0000:d5:00.0 0000:d6:00.0 0000:d6:02.0 0000:d8:00.0 0000:d9:00.0
  # --- Group7: root 0000:ed, NIC=f0, GPU=f3 ---
  0000:ee:00.0 0000:ef:00.0 0000:ef:02.0 0000:f1:00.0 0000:f2:00.0
  # --- Group8: root 0000:f4, NIC=f7, GPU=fa ---
  0000:f5:00.0 0000:f6:00.0 0000:f6:02.0 0000:f8:00.0 0000:f9:00.0
  # --- Group9: root 0000:5e, CX7(mlx5_18/19 双口) + 4x NVMe ---
  0000:5f:00.0 0000:60:0c.0 0000:6a:00.0 0000:6b:00.0
)

acs_check_one() {
    local bdf="$1"
    if ! lspci -s "$bdf" >/dev/null 2>&1; then
        echo "  [跳过] $bdf 不存在于当前拓扑"
        return
    fi
    local out
    out=$(lspci -vvv -s "$bdf" 2>/dev/null) || true
    if ! grep -q "Access Control Services" <<< "$out"; then
        echo "  [跳过] $bdf 没有 ACS capability"
        return
    fi
    local srcvalid
    srcvalid=$(grep -A2 "Access Control Services" <<< "$out" | grep "ACSCtl") || true
    echo "  $bdf : $srcvalid"
}

acs_disable_one() {
    local bdf="$1"
    if ! lspci -s "$bdf" >/dev/null 2>&1; then
        log_warn "  [跳过] $bdf 不存在于当前拓扑"
        return
    fi
    local out
    out=$(lspci -vvv -s "$bdf" 2>/dev/null) || true
    if ! grep -q "Access Control Services" <<< "$out"; then
        log_warn "  [跳过] $bdf 没有 ACS capability"
        return
    fi
    log_info "  [关闭 ACS] $bdf"
    setpci -s "$bdf" ECAP_ACS+0x6.w=0000
}

acs_restore_one() {
    local bdf="$1"
    if ! lspci -s "$bdf" >/dev/null 2>&1; then
        return
    fi
    local out
    out=$(lspci -vvv -s "$bdf" 2>/dev/null) || true
    if ! grep -q "Access Control Services" <<< "$out"; then
        return
    fi
    log_info "  [恢复默认 ACS] $bdf"
    setpci -s "$bdf" ECAP_ACS+0x6.w=00ff
}

disable_acs_all() {
    log_info "禁用 GPU<->NIC/存储 相关 PCIe Switch 的 ACS (共 ${#ACS_BDF_LIST[@]} 个目标桥)..."
    for bdf in "${ACS_BDF_LIST[@]}"; do
        acs_disable_one "$bdf"
    done
}

# ============================================================
# PFC / QoS 相关配置 (对应原 pfc.sh)
# 18张 RoCE 网卡: 优先级5、DSCP40/TOS162、cable_len=50、CNP优先级6/DSCP48
#
# 【关于 sroce0/sroce1 已经做成 bond0 的说明】
#   PFC/ECN/QoS 全部是网卡硬件(mlx5)上"每个物理口"的寄存器配置,
#   bond0 只是内核里的一个逻辑聚合设备,没有对应的硬件队列,因此:
#     - 必须继续对物理口 sroce0 / sroce1 分别配置(下面 PFC_NIC_MAP 保持不变);
#     - 绝对不要对 bond0 执行 mlnx_qos,bond0 下面没有
#       /sys/class/net/bond0/ecn 目录,mlnx_qos -i bond0 会直接报错;
#     - 网卡被 enslave 进 bond 之后,mlnx_qos / ecn sysfs 依然正常可用,
#       所以做不做 bond 对这一段配置没有任何影响,照配即可;
#     - RoCE 流量本来也是 srdma0/srdma1 直接走物理口出去的,不经过 bond 的
#       发包逻辑,所以按物理口配置才是对的。
#   下面的 pfc_config_one 增加了保护: 传入 bond 主设备会被自动展开成成员口,
#   传入不存在的网卡会跳过并告警,不会因为 set -e 把整个脚本中断。
# ============================================================
PFC_NIC_MAP=(
    "roce1_1:rdma1_1" "roce1_2:rdma1_2"
    "roce2_1:rdma2_1" "roce2_2:rdma2_2"
    "roce3_1:rdma3_1" "roce3_2:rdma3_2"
    "roce4_1:rdma4_1" "roce4_2:rdma4_2"
    "roce5_1:rdma5_1" "roce5_2:rdma5_2"
    "roce6_1:rdma6_1" "roce6_2:rdma6_2"
    "roce7_1:rdma7_1" "roce7_2:rdma7_2"
    "roce8_1:rdma8_1" "roce8_2:rdma8_2"
    # 存储/业务网卡: 即使已经 enslave 进 bond0,这里依然写物理口
    "sroce0:srdma0" "sroce1:srdma1"
)

# 判断一个网络设备是不是 bond 主设备
pfc_is_bond_master() {
    [[ -d "/sys/class/net/$1/bonding" ]]
}

pfc_config_one() {
    local inf="$1" mlx="$2"

    # --- 保护1: 网卡不存在则跳过 ---
    if [[ ! -d "/sys/class/net/$inf" ]]; then
        log_warn "  [跳过] 网卡 $inf 不存在"
        return 0
    fi

    # --- 保护2: 误传 bond 主设备时,自动展开成物理成员口 ---
    if pfc_is_bond_master "$inf"; then
        log_warn "  $inf 是 bond 主设备,PFC/QoS 必须配在物理成员口上,自动展开:"
        local slave
        for slave in $(cat "/sys/class/net/$inf/bonding/slaves" 2>/dev/null); do
            # 成员口对应的 IB 设备名自动反查
            local sm
            sm="$(basename "$(readlink -f /sys/class/net/$slave/device/infiniband/* 2>/dev/null | head -1)" 2>/dev/null)"
            [[ -n "$sm" && "$sm" != "*" ]] || sm="$mlx"
            pfc_config_one "$slave" "$sm"
        done
        return 0
    fi

    # --- 保护3: 对应的 IB 设备不存在则跳过 ---
    if [[ ! -d "/sys/class/infiniband/$mlx" ]]; then
        log_warn "  [跳过] $inf 对应的 IB 设备 $mlx 不存在"
        return 0
    fi

    echo "----------------------------------------------------"
    if [[ -n "$(cat /sys/class/net/$inf/master/uevent 2>/dev/null)" ]]; then
        local master
        master="$(basename "$(readlink -f /sys/class/net/$inf/master)")"
        log_info "配置 RoCE 网卡 $inf ($mlx)  [已 enslave 到 $master,仍按物理口配置]"
    else
        log_info "配置 RoCE 网卡 $inf ($mlx)"
    fi
    echo "----------------------------------------------------"

    cma_roce_mode -d "$mlx" -p 1 -m 2 || log_warn "  cma_roce_mode 失败: $mlx"
    cma_roce_tos  -d "$mlx" -t 162    || log_warn "  cma_roce_tos 失败: $mlx"
    echo 162 > /sys/class/infiniband/"$mlx"/tc/1/traffic_class || log_warn "  traffic_class 写入失败: $mlx"

    # ECN(DCQCN): CNP 用 DSCP48, 数据流优先级 5 上开 NP/RP
    if [[ -d /sys/class/net/"$inf"/ecn ]]; then
        echo 48 > /sys/class/net/"$inf"/ecn/roce_np/cnp_dscp   || log_warn "  cnp_dscp 写入失败: $inf"
        echo 1  > /sys/class/net/"$inf"/ecn/roce_np/enable/5   || log_warn "  roce_np/enable/5 写入失败: $inf"
        echo 1  > /sys/class/net/"$inf"/ecn/roce_rp/enable/5   || log_warn "  roce_rp/enable/5 写入失败: $inf"
    else
        log_warn "  [跳过 ECN] /sys/class/net/$inf/ecn 不存在(该口可能不是 mlx5 物理口)"
    fi

    # PFC/QoS: 全部打在物理口上,bond 主设备不参与
    mlnx_qos -i "$inf" --cable_len 50            || log_warn "  mlnx_qos cable_len 失败: $inf"
    mlnx_qos -i "$inf" --trust=dscp              || log_warn "  mlnx_qos trust=dscp 失败: $inf"
    mlnx_qos -i "$inf" --pfc 0,0,0,0,0,1,0,0     || log_warn "  mlnx_qos pfc 失败: $inf"
    mlnx_qos -i "$inf" --prio_tc=0,1,2,3,4,5,6,7 || log_warn "  mlnx_qos prio_tc 失败: $inf"
    mlnx_qos -i "$inf" --dscp2prio='set,40,5'    || log_warn "  mlnx_qos dscp2prio 40->5 失败: $inf"
    mlnx_qos -i "$inf" --dscp2prio='set,48,6'    || log_warn "  mlnx_qos dscp2prio 48->6 失败: $inf"

    cma_roce_mode -d "$mlx" -p 1 -m 2 || true
    cma_roce_tos  -d "$mlx" -t 162    || true
    echo 162 > /sys/class/infiniband/"$mlx"/tc/1/traffic_class || true

    log_info "$inf ($mlx) 配置完成"
}

setup_pfc_all() {
    log_info "开始配置 RoCE 网卡 QoS/PFC (共 ${#PFC_NIC_MAP[@]} 个物理口)..."
    log_info "注意: sroce0/sroce1 即使已经 enslave 进 bond0,也按物理口单独配置"
    for pair in "${PFC_NIC_MAP[@]}"; do
        local inf="${pair%%:*}"
        local mlx="${pair##*:}"
        pfc_config_one "$inf" "$mlx"
    done
    log_info "全部 RoCE 网卡 PFC/QoS 配置完成"
}

# ============================================================
# 1. 启动nvidia-fabricmanager并设定开机执行
# ============================================================
setup_nvidia_fabricmanager() {
    log_info "配置nvidia-fabricmanager..."

    if systemctl list-unit-files | grep -q nvidia-fabricmanager; then
        systemctl enable nvidia-fabricmanager --now
        if systemctl is-active --quiet nvidia-fabricmanager; then
            log_info "nvidia-fabricmanager 启动成功"
        else
            log_error "nvidia-fabricmanager 启动失败"
            return 1
        fi
    else
        log_warn "nvidia-fabricmanager 服务不存在，请检查是否已正确安装"
        return 1
    fi
}

# ============================================================
# 2. 配置ulimit
#    同样采用逐行核对，而非整块判断，避免文件历史状态导致部分行缺失
# ============================================================

# 确保某一行精确存在于文件中，不存在才追加(不会重复添加，也不会因为标题
# 存在就跳过其余行的检查)
ensure_line_in_file() {
    local line="$1"
    local file="$2"
    grep -qxF "$line" "$file" || echo "$line" >> "$file"
}

setup_ulimit() {
    log_info "配置ulimit限制(逐行核对)..."

    backup_config "/etc/security/limits.conf"

    local f="/etc/security/limits.conf"

    if ! grep -q "# Custom ulimit settings" "$f"; then
        { echo ""; echo "# Custom ulimit settings"; } >> "$f"
    fi

    ensure_line_in_file "* hard nofile 655360" "$f"
    ensure_line_in_file "* soft nofile 655360" "$f"
    ensure_line_in_file "* soft memlock unlimited" "$f"
    ensure_line_in_file "* hard memlock unlimited" "$f"
    ensure_line_in_file "root soft core 10485760" "$f"
    ensure_line_in_file "root hard nofile 655360" "$f"
    ensure_line_in_file "root soft nofile 655360" "$f"

    log_info "ulimit配置已核对完成(缺失的行已自动补齐)"
}

# ============================================================
# 3. 网络优化: ARP设置 + rp_filter 严格模式
#    rp_filter=1 为严格模式(反向路径过滤)，禁止其他网卡回复报文
#
#    注意: 此处采用"逐项检查"而非"整块存在性判断"。
#    如果只判断"# Custom ARP settings"标题存在与否就跳过整个块，
#    一旦文件里已有旧版本的部分配置(比如历史上跑过缺少某几行的旧脚本)，
#    新增的参数就永远补不进去、也发现不了错误的值(比如被误改成2)。
#    因此这里对每一条 key=value 单独核对: 只要文件里已有的值不对，
#    就删除旧行、写入正确值；没有则直接追加。无论重复执行多少次、
#    无论文件历史状态如何混乱，最终都会收敛到正确结果。
# ============================================================

# 确保 /etc/sysctl.conf 中某个参数为指定的值:
#   - 若已存在该参数的有效配置行(不管值对不对)，一律删除旧行
#   - 然后追加一行正确的 key = value
# 这样可以自动修正"参数存在但值错误"和"参数缺失"两种情况
set_sysctl_param() {
    local key="$1"
    local value="$2"
    local file="/etc/sysctl.conf"

    # 删除该参数已存在的所有非注释配置行(兼容 "key=value" 和 "key = value" 两种写法)
    sed -i -E "/^[[:space:]]*${key//./\\.}[[:space:]]*=.*/d" "$file"

    echo "${key} = ${value}" >> "$file"
}

setup_arp_config() {
    log_info "配置ARP及rp_filter设置(逐项核对，自动修正缺失或错误的值)..."

    backup_config "/etc/sysctl.conf"

    if ! grep -q "# Custom ARP settings" /etc/sysctl.conf; then
        {
            echo ""
            echo "# Custom ARP settings"
        } >> /etc/sysctl.conf
    fi

    set_sysctl_param "net.ipv4.conf.all.arp_announce" "2"
    set_sysctl_param "net.ipv4.conf.all.arp_ignore" "1"
    set_sysctl_param "net.ipv4.conf.default.accept_source_route" "0"
    set_sysctl_param "net.ipv4.conf.default.arp_announce" "2"
    set_sysctl_param "net.ipv4.conf.default.arp_ignore" "1"
    # rp_filter 严格模式(1=严格，仅接受来源于对应路由的接口回复的报文，防止多网卡场景下的异常回包)
    set_sysctl_param "net.ipv4.conf.all.rp_filter" "1"
    set_sysctl_param "net.ipv4.conf.default.rp_filter" "1"

    sysctl --system >/dev/null 2>&1
    log_info "ARP/rp_filter配置已核对完成并生效"

    # 打印最终实际生效值，方便直接确认，不用再手动逐条sysctl查询
    log_info "当前实际生效值:"
    for p in all.arp_announce all.arp_ignore default.accept_source_route \
             default.arp_announce default.arp_ignore all.rp_filter default.rp_filter; do
        echo "  net.ipv4.conf.${p} = $(sysctl -n net.ipv4.conf.${p} 2>/dev/null)"
    done
}

# ============================================================
# 4. IOMMU 方案1: 不动BIOS，内核层面显式加 intel_iommu=on iommu=pt
# ============================================================
setup_iommu() {
    log_info "配置 IOMMU (intel_iommu=on iommu=pt)..."

    if [[ ! -f /etc/default/grub ]]; then
        log_error "/etc/default/grub 不存在，请手动检查GRUB配置方式"
        return 1
    fi

    backup_config "/etc/default/grub"

    if grep -q "iommu=pt" /etc/default/grub; then
        log_warn "iommu=pt 已存在于 /etc/default/grub，跳过"
        return 0
    fi

    if ! grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
        log_warn "未找到 GRUB_CMDLINE_LINUX 变量，追加一行新配置"
        echo 'GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"' >> /etc/default/grub
    else
        sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/GRUB_CMDLINE_LINUX="\1 intel_iommu=on iommu=pt"/' /etc/default/grub
    fi

    log_info "已在 /etc/default/grub 中追加 intel_iommu=on iommu=pt，请核对以下内容:"
    grep '^GRUB_CMDLINE_LINUX=' /etc/default/grub

    update-grub
    log_info "update-grub 执行完成"
    REBOOT_REQUIRED=1
}

# ============================================================
# 5. 创建独立的 RoCE PFC/ECN 幂等下发脚本 + 事件触发机制
#
#    为什么要独立出来:
#      PFC/ECN 是网卡硬件配置,任何一次 openibd restart / 驱动重载 /
#      网口 down-up / bond 重建,都会把它清空。开机时"按固定顺序跑一次"
#      是不可靠的 —— 那时 bond 往往还没成型、IB 设备还没稳定。
#
#    这里的方案:
#      1) /usr/local/sbin/roce_pfc_apply.sh  幂等下发脚本,可反复执行
#         - 物理口 -> ibdev 全部动态反查(不再硬编码 srdma0/srdma1),
#           RoCE LAG 合并成一个 ibdev 时自动去重,只配一次
#         - 带 flock,udev 和 systemd 同时触发也不会打架
#         - 带等待逻辑,网口刚出现还没 ready 时会重试
#      2) roce-pfc@.service  单口下发的模板服务
#      3) /etc/udev/rules.d/99-roce-pfc.rules
#         只要 mlx5 物理口出现或状态变化,就自动触发对应的单口下发
#         -> 无论 bond 什么时候成型、驱动重载多少次,配置都会被重新刷上去
# ============================================================
PFC_APPLY_SCRIPT="/usr/local/sbin/roce_pfc_apply.sh"

create_pfc_apply_script() {
    log_info "创建 RoCE PFC/ECN 幂等下发脚本: $PFC_APPLY_SCRIPT"

    mkdir -p /usr/local/sbin

    cat > "$PFC_APPLY_SCRIPT" << 'PFCEOF'
#!/bin/bash
# ------------------------------------------------------------
# RoCE PFC/ECN/QoS 幂等下发脚本 (由 systemc_optimize.sh 自动生成)
#
# 用法:
#   roce_pfc_apply.sh              # 刷所有 RoCE 物理口
#   roce_pfc_apply.sh sroce0       # 只刷指定物理口(udev 钩子用这个)
#
# 设计要点:
#   - 只对"物理口"下发。bond0 是逻辑设备,没有硬件队列,遇到直接跳过。
#   - ibdev 由 netdev 动态反查,不依赖 srdma0/srdma1 这类固定名字;
#     RoCE LAG 把两个口合并成一个 ibdev 时自动去重,不会重复配。
#   - 全程幂等,重复执行安全;单点失败只记日志,不影响其他网口。
# ------------------------------------------------------------
LOG=/var/log/roce_pfc.log
LOCK=/var/run/roce_pfc.lock

# 需要配置的 RoCE 物理口(注意: 这里写物理口,不写 bond0)
PFC_PORTS=(
    roce1_1 roce1_2 roce2_1 roce2_2
    roce3_1 roce3_2 roce4_1 roce4_2
    roce5_1 roce5_2 roce6_1 roce6_2
    roce7_1 roce7_2 roce8_1 roce8_2
    sroce0  sroce1
)

# QoS 参数
PFC_PRIO=5              # 无损优先级
CNP_PRIO=6              # CNP 优先级
DATA_DSCP=40            # 数据流 DSCP
CNP_DSCP=48             # CNP DSCP
ROCE_TOS=162            # = DSCP40 << 2
CABLE_LEN=50

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# 由 netdev 反查对应的 ibdev(拿不到返回空)
resolve_ibdev() {
    local nic="$1" p
    p="$(readlink -f /sys/class/net/"$nic"/device/infiniband/* 2>/dev/null | head -1)"
    [[ -n "$p" && -d "$p" ]] && basename "$p"
}

# 等待网口就绪(驱动刚重载时 sysfs 可能还没建全)
wait_ready() {
    local nic="$1" i
    for i in $(seq 1 30); do
        [[ -d /sys/class/net/"$nic" ]] && [[ -d /sys/class/net/"$nic"/ecn ]] && return 0
        sleep 1
    done
    [[ -d /sys/class/net/"$nic" ]]
}

# 对单个物理口下发 netdev 层配置(PFC / trust / dscp2prio / ECN)
apply_netdev() {
    local nic="$1"

    if [[ ! -d /sys/class/net/"$nic" ]]; then
        log "[skip] $nic : netdev 不存在"
        return 1
    fi
    # bond 主设备直接跳过,PFC 不能配在 bond 上
    if [[ -d /sys/class/net/"$nic"/bonding ]]; then
        log "[skip] $nic : 是 bond 主设备,应配置其成员口"
        return 1
    fi
    if ! wait_ready "$nic"; then
        log "[skip] $nic : 等待就绪超时"
        return 1
    fi

    local master=""
    [[ -e /sys/class/net/"$nic"/master ]] && \
        master="$(basename "$(readlink -f /sys/class/net/"$nic"/master)")"
    log "[apply] $nic ${master:+(已 enslave 到 $master,仍按物理口配置)}"

    # ECN / DCQCN
    if [[ -d /sys/class/net/"$nic"/ecn ]]; then
        echo "$CNP_DSCP" > /sys/class/net/"$nic"/ecn/roce_np/cnp_dscp        2>>"$LOG" || log "  ! cnp_dscp 失败 $nic"
        echo 1           > /sys/class/net/"$nic"/ecn/roce_np/enable/$PFC_PRIO 2>>"$LOG" || log "  ! roce_np enable 失败 $nic"
        echo 1           > /sys/class/net/"$nic"/ecn/roce_rp/enable/$PFC_PRIO 2>>"$LOG" || log "  ! roce_rp enable 失败 $nic"
    else
        log "  ! $nic 无 ecn sysfs,跳过 ECN"
    fi

    # PFC / QoS
    mlnx_qos -i "$nic" --cable_len "$CABLE_LEN"          >/dev/null 2>>"$LOG" || log "  ! cable_len 失败 $nic"
    mlnx_qos -i "$nic" --trust=dscp                      >/dev/null 2>>"$LOG" || log "  ! trust=dscp 失败 $nic"
    mlnx_qos -i "$nic" --pfc 0,0,0,0,0,1,0,0             >/dev/null 2>>"$LOG" || log "  ! pfc 失败 $nic"
    mlnx_qos -i "$nic" --prio_tc=0,1,2,3,4,5,6,7         >/dev/null 2>>"$LOG" || log "  ! prio_tc 失败 $nic"
    mlnx_qos -i "$nic" --dscp2prio="set,${DATA_DSCP},${PFC_PRIO}" >/dev/null 2>>"$LOG" || log "  ! dscp2prio $DATA_DSCP 失败 $nic"
    mlnx_qos -i "$nic" --dscp2prio="set,${CNP_DSCP},${CNP_PRIO}"  >/dev/null 2>>"$LOG" || log "  ! dscp2prio $CNP_DSCP 失败 $nic"
    return 0
}

# 对单个 ibdev 下发 RDMA 层配置(每个 ibdev 只做一次)
apply_ibdev() {
    local ib="$1"
    [[ -z "$ib" ]] && return 0
    if [[ ! -d /sys/class/infiniband/"$ib" ]]; then
        log "  ! ibdev $ib 不存在,跳过 RDMA 层配置"
        return 1
    fi
    cma_roce_mode -d "$ib" -p 1 -m 2      >/dev/null 2>>"$LOG" || log "  ! cma_roce_mode 失败 $ib"
    cma_roce_tos  -d "$ib" -t "$ROCE_TOS" >/dev/null 2>>"$LOG" || log "  ! cma_roce_tos 失败 $ib"
    echo "$ROCE_TOS" > /sys/class/infiniband/"$ib"/tc/1/traffic_class 2>>"$LOG" || log "  ! traffic_class 失败 $ib"
    log "  ibdev $ib 已配置 (tos=$ROCE_TOS)"
    return 0
}

main() {
    local targets=()
    if [[ $# -gt 0 ]]; then
        targets=("$@")
    else
        targets=("${PFC_PORTS[@]}")
    fi

    log "===== roce_pfc_apply 开始 (目标: ${targets[*]}) ====="

    local done_ib=" "   # 已配置过的 ibdev,用于 LAG 场景去重
    local nic ib
    for nic in "${targets[@]}"; do
        apply_netdev "$nic" || continue
        ib="$(resolve_ibdev "$nic")"
        if [[ -z "$ib" ]]; then
            log "  ! $nic 反查不到 ibdev,跳过 RDMA 层配置"
            continue
        fi
        if [[ "$done_ib" == *" $ib "* ]]; then
            log "  ibdev $ib 已配置过(RoCE LAG 共用),跳过"
            continue
        fi
        apply_ibdev "$ib" && done_ib+="$ib "
    done

    log "===== roce_pfc_apply 结束 ====="
}

# flock: udev 和 systemd 可能同时触发,串行化避免互相打架
exec 9>"$LOCK"
flock -w 120 9 || { log "获取锁超时,本次跳过"; exit 0; }
main "$@"
PFCEOF

    chmod +x "$PFC_APPLY_SCRIPT"
    log_info "已创建 $PFC_APPLY_SCRIPT"

    # --- 单口下发的模板服务(给 udev 用,避免在 udev RUN 里跑耗时命令) ---
    cat > /etc/systemd/system/roce-pfc@.service << EOF
[Unit]
Description=Apply RoCE PFC/ECN on %i
After=openibd.service

[Service]
Type=oneshot
ExecStart=$PFC_APPLY_SCRIPT %i
TimeoutStartSec=180
EOF

    # --- udev: mlx5 物理口一出现/变化就触发下发 ---
    # 注意 RUN 里只做 systemctl --no-block,真正耗时的动作交给上面的服务,
    # 否则会卡住 udev worker 导致超时。
    cat > /etc/udev/rules.d/99-roce-pfc.rules << 'UDEVEOF'
# RoCE 物理口出现或状态变化时,自动重新下发 PFC/ECN 配置
# 排除 bond/vlan 等虚拟设备,只匹配 mlx5 驱动的真实物理口
ACTION=="add|change", SUBSYSTEM=="net", ENV{ID_NET_DRIVER}=="mlx5_core", \
  ENV{DEVTYPE}!="bond", KERNEL=="roce*|sroce*", \
  RUN+="/usr/bin/systemctl --no-block start roce-pfc@$name.service"
UDEVEOF

    systemctl daemon-reload
    udevadm control --reload-rules
    log_info "已创建 roce-pfc@.service 与 udev 触发规则 99-roce-pfc.rules"
}

# ============================================================
# 6. 创建开机执行脚本
#    每次开机自动执行: GPU持久模式 -> 禁用ACS -> 重启IB -> 加载nvidia-peermem
#    -> CPU性能模式 -> 配置PFC/QoS
# ============================================================
create_startup_script() {
    log_info "创建开机执行脚本(含GPU持久模式/IB重启/CPU性能模式/ACS禁用/PFC配置)..."

    local startup_script="/etc/rc.local.d/performance_setup.sh"

    mkdir -p /etc/rc.local.d

    cat > "$startup_script" << 'BOOTEOF'
#!/bin/bash
# 性能优化开机脚本 (由合并版优化脚本自动生成)

LOG=/var/log/performance_setup.log
echo "===== Performance setup started at $(date) =====" >> "$LOG"


# ---------- 1. 重启 IB ----------
rmmod nvidia-peermem 2>/dev/null || true
systemctl restart openibd --force >> "$LOG" 2>&1
sleep 30



# ---------- 2 确保 ib_umad 加载后再重启 fabricmanager ----------
if ! lsmod | grep -q "^ib_umad"; then
    modprobe ib_umad 2>>"$LOG" || echo "Warning: modprobe ib_umad 失败" >> "$LOG"
fi

# 等待 ib_umad 就绪（最多等5秒，避免设备节点还没建出来）
for i in $(seq 1 5); do
    lsmod | grep -q "^ib_umad" && break
    sleep 1
done

systemctl restart nvidia-fabricmanager 2>/dev/null || echo "Warning: fabricmanager restart failed" >> "$LOG"

# ---------- 2.5 加载 nvidia-peermem ----------
modprobe nvidia-peermem 2>/dev/null || echo "Warning: nvidia-peermem module not available" >> "$LOG"


# ---------- 3. GPU 持久模式 ----------
nvidia-smi -pm 1 2>/dev/null || echo "Warning: nvidia-smi command failed" >> "$LOG"


# ---------- 4. CPU 性能模式 ----------
cpupower frequency-set -g performance 2>/dev/null || echo "Warning: cpupower frequency command failed" >> "$LOG"
cpupower idle-set -D 0 2>/dev/null || echo "Warning: cpupower idle command failed" >> "$LOG"

# ---------- 5. 禁用 ACS (GPU<->NIC/存储 相关 PCIe Switch) ----------
ACS_BDF_LIST=(
  0000:15:00.0 0000:16:00.0 0000:16:02.0 0000:18:00.0 0000:19:00.0
  0000:58:00.0 0000:59:00.0 0000:59:02.0 0000:5b:00.0 0000:5c:00.0
  0000:71:00.0 0000:72:00.0 0000:72:02.0 0000:74:00.0 0000:75:00.0
  0000:78:00.0 0000:79:00.0 0000:79:02.0 0000:7b:00.0 0000:7c:00.0
  0000:95:00.0 0000:96:00.0 0000:96:02.0 0000:98:00.0 0000:99:00.0
  0000:d5:00.0 0000:d6:00.0 0000:d6:02.0 0000:d8:00.0 0000:d9:00.0
  0000:ee:00.0 0000:ef:00.0 0000:ef:02.0 0000:f1:00.0 0000:f2:00.0
  0000:f5:00.0 0000:f6:00.0 0000:f6:02.0 0000:f8:00.0 0000:f9:00.0
  0000:5f:00.0 0000:60:0c.0 0000:6a:00.0 0000:6b:00.0
)
for bdf in "${ACS_BDF_LIST[@]}"; do
    if lspci -s "$bdf" >/dev/null 2>&1; then
        out=$(lspci -vvv -s "$bdf" 2>/dev/null) || true
        if grep -q "Access Control Services" <<< "$out"; then
            setpci -s "$bdf" ECAP_ACS+0x6.w=0000
            echo "[ACS] disabled on $bdf" >> "$LOG"
        fi
    fi
done

# ---------- 6. PFC / QoS 配置 ----------
# 不再在这里内联下发。统一交给幂等脚本 /usr/local/sbin/roce_pfc_apply.sh:
#   - 物理口 -> ibdev 动态反查,RoCE LAG 合并时自动去重
#   - udev 规则会在每个 mlx5 物理口 add/change 时再触发一次,
#     所以就算这里跑得太早(bond 还没成型),后面也会被自动补上
echo "[PFC] invoking roce_pfc_apply.sh (all ports)" >> "$LOG"
/usr/local/sbin/roce_pfc_apply.sh >> "$LOG" 2>&1 || echo "Warning: roce_pfc_apply.sh failed" >> "$LOG"

echo "===== Performance setup completed at $(date) =====" >> "$LOG"
BOOTEOF

    chmod +x "$startup_script"
    log_info "开机脚本已创建: $startup_script"

    cat > /etc/systemd/system/performance-setup.service << EOF
[Unit]
Description=Performance Setup Service (GPU/ACS/IB/CPU/PFC)
After=multi-user.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$startup_script
RemainAfterExit=yes
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable performance-setup.service --now
    log_info "性能优化服务已启用(含GPU/ACS/IB/CPU/PFC全部配置)，首次已立即执行"
}

# ============================================================
# 主函数
# ============================================================
main() {
    log_info "开始系统优化配置..."
    log_info "================================================"

    check_root

    setup_nvidia_fabricmanager
    setup_ulimit
    setup_arp_config
    setup_iommu
    create_pfc_apply_script   # 幂等 PFC 下发脚本 + udev 事件触发(bond/驱动重载后自动重刷)
    create_startup_script   # 内部已包含 ACS 禁用与 PFC 配置，并注册为开机服务、首次立即执行一次

    log_info "================================================"
    log_info "系统优化配置完成！"
    log_info "Ubuntu 22.04.5 特别提醒："
    log_info "1. IOMMU(intel_iommu=on iommu=pt) 配置需要重启系统才能生效"
    log_info "2. ulimit配置需要重新登录才能生效"
    log_info "3. 如果使用SSH，建议重新连接会话"
    log_info "4. ACS 日志见 /var/log/performance_setup.log; PFC 下发日志见 /var/log/roce_pfc.log"
    echo "可以使用以下命令检查配置："
    echo "  - systemctl status nvidia-fabricmanager"
    echo "  - systemctl status performance-setup.service"
    echo "  - ulimit -n (检查文件句柄限制)"
    echo "  - sysctl net.ipv4.conf.all.arp_announce (检查ARP设置)"
    echo "  - sysctl net.ipv4.conf.all.rp_filter (检查rp_filter严格模式)"
    echo "  - cat /proc/cmdline (重启后检查 iommu=pt 是否生效)"
    echo "  - sudo ./$(basename "$0") acs-check (查看ACS状态)"
    echo "  - mlnx_qos -i sroce0 (确认物理口 PFC 是否在 prio5 上开启)"
    echo "  - tail -f /var/log/roce_pfc.log (PFC 下发日志)"
    echo "  - sudo /usr/local/sbin/roce_pfc_apply.sh (手动全量重刷 PFC)"

    if [[ "$REBOOT_REQUIRED" -eq 1 ]]; then
        log_warn "检测到 IOMMU 相关改动，请尽快重启系统使其生效！"
    fi
}

# ============================================================
# 命令行参数分发
# ============================================================
case "${1:-}" in
    acs-check)
        check_root
        echo "=== 当前 ACS 状态 (共 ${#ACS_BDF_LIST[@]} 个目标桥) ==="
        for bdf in "${ACS_BDF_LIST[@]}"; do
            acs_check_one "$bdf"
        done
        ;;
    acs-restore)
        check_root
        echo "=== 恢复 ACS 默认设置 (共 ${#ACS_BDF_LIST[@]} 个目标桥) ==="
        for bdf in "${ACS_BDF_LIST[@]}"; do
            acs_restore_one "$bdf"
        done
        ;;
    *)
        main "$@"
        ;;
esac
