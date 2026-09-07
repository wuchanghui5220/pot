root@HRB204-GPU-SERVER-32:~# cat /etc/rc.local.d/performance_setup.sh
#!/bin/bash
# 性能优化开机脚本 (由合并版优化脚本自动生成)

LOG=/var/log/performance_setup.log
echo "===== Performance setup started at $(date) =====" >> "$LOG"

# ---------- 1. GPU 持久模式 ----------
nvidia-smi -pm 1 2>/dev/null || echo "Warning: nvidia-smi command failed" >> "$LOG"
rmmod nvidia-peermem 2>/dev/null || true

# ---------- 2. 重启 IB ----------
systemctl restart openibd --force >> "$LOG" 2>&1
sleep 30

# ---------- 3. 加载 nvidia-peermem ----------
modprobe nvidia-peermem 2>/dev/null || echo "Warning: nvidia-peermem module not available" >> "$LOG"


# ---------- 3.5 确保 ib_umad 加载后再重启 fabricmanager ----------
if ! lsmod | grep -q "^ib_umad"; then
    modprobe ib_umad 2>>"$LOG" || echo "Warning: modprobe ib_umad 失败" >> "$LOG"
fi

# 等待 ib_umad 就绪（最多等5秒，避免设备节点还没建出来）
for i in $(seq 1 5); do
    lsmod | grep -q "^ib_umad" && break
    sleep 1
done

systemctl restart nvidia-fabricmanager 2>/dev/null || echo "Warning: fabricmanager restart failed" >> "$LOG"


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