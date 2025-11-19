#!/bin/bash

# 获取 BMC IP 地址
BMC_IP=$(ipmitool lan print 1 | grep -E "IP Address\s+:" | awk '{print $4}')

if [ -z "$BMC_IP" ]; then
    BMC_IP="N/A"
fi

# 获取 SM LID
SM_LID=$(sminfo | grep -oP 'sm lid \K\d+')

if [ -z "$SM_LID" ]; then
    echo "错误: 无法获取 SM LID" >&2
    exit 1
fi

# 获取 GPU-NIC 映射关系
nvidia-smi topo -m | awk '
BEGIN {
    in_nic_legend = 0
}

/^NIC Legend:/ {
    in_nic_legend = 1
    next
}

in_nic_legend == 1 {
    if (length($0) == 0 || $0 ~ /^[ \t]*$/) {
        next
    }

    if ($0 ~ /^ *NIC[0-9]+:/) {
        gsub(/:/, "", $1)
        nic_num = substr($1, 4)
        nic_dev[nic_num] = $2
        next
    }

    in_nic_legend = 0
}

/^NIC[0-9]/ && in_nic_legend == 0 {
    nic_name = $1
    nic_num = substr(nic_name, 4)

    for (i=2; i<=9; i++) {
        if ($i == "PIX") {
            gpu_num = i - 2
            gpu_nic_map[gpu_num] = nic_name "," nic_num
        }
    }
}

END {
    for (gpu in gpu_nic_map) {
        split(gpu_nic_map[gpu], parts, ",")
        nic_name = parts[1]
        nic_num = parts[2]
        device = (nic_num in nic_dev) ? nic_dev[nic_num] : "unknown"
        print gpu "," nic_name "," device
    }
}
' | sort -V | while IFS=',' read -r gpu nic_name mlx_dev; do

    # 获取 Base LID
    BASE_LID=$(ibstat "$mlx_dev" 2>/dev/null | grep -i "base lid" | awk '{print $3}')

    if [ -z "$BASE_LID" ]; then
        echo "${HOSTNAME} - ${BMC_IP} - GPU${gpu} - ${nic_name} - ${mlx_dev} -> 错误: 无法获取 Base LID"
        continue
    fi

    # 获取交换机信息
    SWITCH_RAW=$(ibtracert "$BASE_LID" "$SM_LID" 2>/dev/null | head -2 | tail -1)

    if [ -z "$SWITCH_RAW" ]; then
        echo "${HOSTNAME} - ${BMC_IP} - GPU${gpu} - ${nic_name} - ${mlx_dev} -> 错误: 无法获取交换机信息"
        continue
    fi

    # 提取端口号和交换机名称
    PORT=$(echo "$SWITCH_RAW" | grep -oP '\[(\d+)\]' | tail -1)
    SWITCH_NAME=$(echo "$SWITCH_RAW" | grep -oP '"[^"]+"')

    # 输出完整信息（添加主机名和 BMC IP 作为前两列）
    echo "${HOSTNAME} - ${BMC_IP} - GPU${gpu} - ${nic_name} - ${mlx_dev} -> ${PORT} ${SWITCH_NAME}"
done
