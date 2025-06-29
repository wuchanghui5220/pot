#!/bin/bash
# switch_cpld_update.sh
# QM9790交换机CPLD自动更新脚本 (并发模式)
# 用途：检查交换机CPLD版本，如果需要更新则自动执行

# 配置参数
CPLD_TOOL="./updateswitchcpld"
LOG_FILE="/var/log/switch_cpld_update.log"
MAX_CONCURRENT_UPDATES=5  # 默认并发更新数量
CPLD_UPDATE_TIMEOUT=1200  # CPLD更新超时时间（20分钟）

# 日志函数
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# 检查是否为root用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_message "错误: 请使用root权限运行此脚本"
        exit 1
    fi
}

# 检查必要工具是否存在
check_tools() {
    local tools=("ibswitches")
    for tool in "${tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_message "错误: 未找到必要工具 $tool"
            log_message "请确保已安装 MLNX_OFED 驱动包"
            exit 1
        fi
    done

    # 检查CPLD更新工具
    if [ ! -f "$CPLD_TOOL" ]; then
        log_message "错误: 未找到CPLD更新工具: $CPLD_TOOL"
        log_message "请确保updateswitchcpld工具在当前目录或提供完整路径"
        exit 1
    fi

    # 给CPLD工具执行权限
    chmod +x "$CPLD_TOOL"
    log_message "必要工具检查通过"
}

# 检查单个交换机CPLD状态
check_single_cpld() {
    local device="$1"
    local temp_log="$2"

    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 检查交换机 $device CPLD状态..."

        # 执行CPLD检查
        if timeout 60 "$CPLD_TOOL" --unmanaged --check_cpld -d "$device" --verbose 2>&1; then
            echo "CPLD_CHECK_SUCCESS"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: 无法检查交换机 $device CPLD状态"
            echo "CPLD_CHECK_FAILED"
        fi
    } > "$temp_log" 2>&1
}

# 检查所有交换机CPLD状态
check_all_cpld_status() {
    log_message "检查所有交换机CPLD状态..."

    # 获取所有交换机的LID
    local swlids=$(ibswitches | awk -F"lid" '{print $2}' | awk '{print $1}')

    if [ -z "$swlids" ]; then
        log_message "未找到任何InfiniBand交换机"
        exit 1
    fi

    log_message "发现交换机LID列表: $swlids"

    local devices_to_update=()
    local skip_count=0
    local error_count=0
    local temp_dir=$(mktemp -d)

    # 导出函数供子进程使用
    export -f check_single_cpld
    export CPLD_TOOL

    log_message "开始并发检查CPLD状态，最大并发数: $MAX_CONCURRENT_UPDATES"

    # 分批并发检查
    local lid_array=($swlids)
    local total_devices=${#lid_array[@]}
    local batch_start=0

    while [ $batch_start -lt $total_devices ]; do
        local batch_end=$((batch_start + MAX_CONCURRENT_UPDATES - 1))
        if [ $batch_end -ge $total_devices ]; then
            batch_end=$((total_devices - 1))
        fi

        log_message "检查第 $((batch_start / MAX_CONCURRENT_UPDATES + 1)) 批设备 (设备 $((batch_start + 1))-$((batch_end + 1))/$total_devices)"

        # 启动这一批的并发检查
        local current_pids=()
        for i in $(seq $batch_start $batch_end); do
            local lid="${lid_array[$i]}"
            local device="lid-$lid"
            local temp_log="$temp_dir/${device//\//_}_check.log"

            # 后台执行检查
            bash -c "check_single_cpld '$device' '$temp_log'" &
            local pid=$!
            current_pids+=($pid)

            # 短暂延迟避免同时启动
            sleep 1
        done

        # 等待这一批完成
        for pid in "${current_pids[@]}"; do
            wait $pid
        done

        # 收集检查结果
        for i in $(seq $batch_start $batch_end); do
            local lid="${lid_array[$i]}"
            local device="lid-$lid"
            local temp_log="$temp_dir/${device//\//_}_check.log"

            if [ -f "$temp_log" ]; then
                # 将检查日志合并到主日志
                cat "$temp_log" >> "$LOG_FILE"

                # 分析检查结果 - 检查CPLD更新状态
                if grep -q "CPLD_CHECK_SUCCESS" "$temp_log"; then
                    if grep -q "CPLD update is needed" "$temp_log"; then
                        log_message "✓ 交换机 $device 需要CPLD更新"
                        devices_to_update+=("$device")
                    elif grep -q "No CPLD update is needed" "$temp_log"; then
                        log_message "- 交换机 $device CPLD已是最新版本，无需更新"
                        ((skip_count++))
                    else
                        log_message "? 交换机 $device CPLD状态未知，跳过更新"
                        ((skip_count++))
                    fi
                else
                    log_message "✗ 交换机 $device CPLD状态检查失败"
                    ((error_count++))
                fi
            else
                log_message "✗ 交换机 $device 检查日志文件丢失"
                ((error_count++))
            fi
        done

        # 准备下一批
        batch_start=$((batch_end + 1))

        # 如果还有下一批，等待一段时间
        if [ $batch_start -lt $total_devices ]; then
            log_message "等待5秒后检查下一批..."
            sleep 5
        fi
    done

    # 清理临时文件
    rm -rf "$temp_dir"

    local update_count=${#devices_to_update[@]}
    log_message "CPLD检查完成 - 需要更新: $update_count 台, 已是最新: $skip_count 台, 错误: $error_count 台"

    if [ $update_count -eq 0 ]; then
        log_message "未找到任何需要CPLD更新的交换机"
        return 1
    fi

    # 执行并发更新
    if update_cpld_concurrent "${devices_to_update[@]}"; then
        return 0
    else
        return 1
    fi
}

# 并发更新CPLD
update_cpld_concurrent() {
    local devices_to_update=("$@")
    local total_devices=${#devices_to_update[@]}

    if [ $total_devices -eq 0 ]; then
        log_message "没有需要CPLD更新的设备"
        return 0
    fi

    log_message "开始并发CPLD更新 $total_devices 台交换机，最大并发数: $MAX_CONCURRENT_UPDATES"
    log_message "警告: CPLD更新过程中交换机会重启，每台设备更新可能需要20分钟"

    local update_count=0
    local error_count=0
    local temp_dir=$(mktemp -d)

    # 并发更新函数
    update_single_cpld() {
        local device="$1"
        local temp_dir="$2"
        local device_log="$temp_dir/${device//\//_}_update.log"

        {
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 开始更新交换机 $device 的CPLD..."

            # 显示当前CPLD信息
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 交换机 $device 更新前CPLD信息:"
            timeout 60 "$CPLD_TOOL" --unmanaged --check_cpld -d "$device" --verbose 2>/dev/null

            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 执行CPLD更新命令: $CPLD_TOOL --unmanaged -d $device"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 注意: 更新过程可能需要20分钟，交换机会自动重启"

            # 执行CPLD更新（使用expect自动输入y，如果没有expect则使用echo）
            local update_success=false

            # 方法1: 尝试使用expect自动输入
            if command -v expect &> /dev/null; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 使用expect自动确认更新"
                if timeout $CPLD_UPDATE_TIMEOUT expect -c "
                    spawn $CPLD_TOOL --unmanaged -d $device
                    expect {
                        \"Are you sure you want to update the switch cpld? (y/n):\" {
                            send \"y\r\"
                            exp_continue
                        }
                        eof
                    }
                " 2>&1; then
                    update_success=true
                fi
            else
                # 方法2: 使用printf预先输入y
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 使用printf自动确认更新"
                if printf "y\n" | timeout $CPLD_UPDATE_TIMEOUT "$CPLD_TOOL" --unmanaged -d "$device" 2>&1; then
                    update_success=true
                fi
            fi

            if [ "$update_success" = true ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 交换机 $device CPLD更新成功完成!"

                # 等待交换机重启完成
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 等待交换机重启完成..."
                sleep 60

                # 验证更新结果 - 检查是否显示无需更新
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 验证交换机 $device CPLD更新结果:"
                local retry_count=0
                while [ $retry_count -lt 5 ]; do
                    local verify_output=$(timeout 60 "$CPLD_TOOL" --unmanaged --check_cpld -d "$device" --verbose 2>/dev/null)
                    if [ $? -eq 0 ]; then
                        echo "$verify_output"
                        # 检查更新是否成功（应该显示 "No CPLD update is needed"）
                        if echo "$verify_output" | grep -q "No CPLD update is needed"; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ CPLD更新成功，设备已是最新版本"
                            echo "CPLD_UPDATE_SUCCESS"
                        elif echo "$verify_output" | grep -q "CPLD update is needed"; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠ CPLD更新可能未完全成功，仍显示需要更新"
                            echo "CPLD_UPDATE_PARTIAL"
                        else
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ? 无法确定CPLD更新状态"
                            echo "CPLD_UPDATE_UNKNOWN"
                        fi
                        exit 0
                    else
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 等待交换机 $device 完全启动... (尝试 $((retry_count + 1))/5)"
                        sleep 30
                        ((retry_count++))
                    fi
                done
                echo "CPLD_UPDATE_SUCCESS_PARTIAL"
                exit 0
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 错误: 交换机 $device CPLD更新失败或超时"
                echo "CPLD_UPDATE_FAILED"
                exit 1
            fi
        } > "$device_log" 2>&1
    }

    # 导出函数供子进程使用
    export -f update_single_cpld
    export CPLD_TOOL
    export CPLD_UPDATE_TIMEOUT

    # 分批并发执行（CPLD更新时间较长，建议较小的并发数）
    local batch_start=0
    while [ $batch_start -lt $total_devices ]; do
        local batch_end=$((batch_start + MAX_CONCURRENT_UPDATES - 1))
        if [ $batch_end -ge $total_devices ]; then
            batch_end=$((total_devices - 1))
        fi

        log_message "启动第 $((batch_start / MAX_CONCURRENT_UPDATES + 1)) 批CPLD更新 (设备 $((batch_start + 1))-$((batch_end + 1))/$total_devices)"

        # 启动这一批的并发更新
        local current_pids=()
        for i in $(seq $batch_start $batch_end); do
            local device="${devices_to_update[$i]}"
            log_message "启动并发CPLD更新: $device"

            # 后台执行单设备更新
            bash -c "update_single_cpld '$device' '$temp_dir'" &
            local pid=$!
            current_pids+=($pid)

            # 较长延迟避免同时启动多个CPLD更新
            sleep 10
        done

        # 等待这一批完成
        log_message "等待当前批次 ${#current_pids[@]} 个CPLD更新任务完成（预计需要20分钟）..."
        for pid in "${current_pids[@]}"; do
            wait $pid
        done

        # 收集结果
        for i in $(seq $batch_start $batch_end); do
            local device="${devices_to_update[$i]}"
            local device_log="$temp_dir/${device//\//_}_update.log"

            if [ -f "$device_log" ]; then
                # 将设备日志合并到主日志
                cat "$device_log" >> "$LOG_FILE"

                # 检查更新结果
                if grep -q "CPLD_UPDATE_SUCCESS" "$device_log"; then
                    log_message "✓ 交换机 $device CPLD更新成功（已是最新版本）"
                    ((update_count++))
                elif grep -q "CPLD_UPDATE_PARTIAL" "$device_log"; then
                    log_message "⚠ 交换机 $device CPLD更新部分成功（需要进一步检查）"
                    ((update_count++))
                elif grep -q "CPLD_UPDATE_FAILED" "$device_log"; then
                    log_message "✗ 交换机 $device CPLD更新失败"
                    ((error_count++))
                else
                    log_message "? 交换机 $device CPLD更新状态未知"
                    ((error_count++))
                fi
            else
                log_message "✗ 交换机 $device CPLD更新日志文件丢失"
                ((error_count++))
            fi
        done

        # 准备下一批
        batch_start=$((batch_end + 1))

        # 如果还有下一批，等待一段时间
        if [ $batch_start -lt $total_devices ]; then
            log_message "等待30秒后开始下一批CPLD更新..."
            sleep 30
        fi
    done

    # 清理临时文件
    rm -rf "$temp_dir"

    log_message "并发CPLD更新完成 - 成功: $update_count 台, 失败: $error_count 台"

    if [ $error_count -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# 显示所有交换机CPLD信息
show_cpld_info() {
    log_message "=== 当前所有交换机CPLD信息 ==="

    local swlids=$(ibswitches | awk -F"lid" '{print $2}' | awk '{print $1}')

    if [ -z "$swlids" ]; then
        log_message "未找到任何InfiniBand交换机"
        return
    fi

    for lid in $swlids; do
        local device="lid-$lid"
        log_message "--- 交换机 $device ---"

        if timeout 60 "$CPLD_TOOL" --unmanaged --check_cpld -d "$device" --verbose 2>/dev/null | tee -a "$LOG_FILE"; then
            :
        else
            log_message "无法查询交换机 $device CPLD信息"
        fi
        log_message ""
    done
}

# 主函数
main() {
    log_message "=== 交换机CPLD自动更新脚本开始 ==="
    log_message "CPLD工具: $CPLD_TOOL"

    # 检查运行权限
    check_root

    # 检查必要工具
    check_tools

    # 显示当前所有交换机CPLD信息
    show_cpld_info

    # 检查交换机并更新CPLD
    if check_all_cpld_status; then
        log_message "=== 交换机CPLD更新脚本完成 ==="
        log_message "所有需要CPLD更新的交换机更新已完成"
        log_message "交换机已自动重启以应用新CPLD"
    else
        log_message "=== 未执行任何CPLD更新操作 ==="
    fi
}

# 脚本使用说明
show_usage() {
    echo "交换机CPLD自动更新脚本使用说明 (并发模式):"
    echo "1. 确保以root权限运行"
    echo "2. 确保已安装MLNX_OFED驱动包"
    echo "3. 确保updateswitchcpld工具在当前目录"
    echo "4. 运行脚本: sudo ./switch_cpld_update.sh"
    echo "5. 脚本将自动检测并更新需要CPLD更新的交换机"
    echo ""
    echo "配置参数:"
    echo "  CPLD_TOOL: $CPLD_TOOL"
    echo "  LOG_FILE: $LOG_FILE"
    echo "  MAX_CONCURRENT_UPDATES: $MAX_CONCURRENT_UPDATES"
    echo "  CPLD_UPDATE_TIMEOUT: $CPLD_UPDATE_TIMEOUT 秒"
    echo ""
    echo "功能选项:"
    echo "  (无参数)              自动CPLD更新模式 (支持并发)"
    echo "  -i, --info            显示所有交换机CPLD信息但不更新"
    echo "  --concurrent <数量>   设置并发更新数量 (默认: $MAX_CONCURRENT_UPDATES, 建议1-2)"
    echo "  -h, --help            显示此帮助信息"
    echo ""
    echo "使用示例:"
    echo "  sudo ./switch_cpld_update.sh                    # 自动更新CPLD (默认并发数3)"
    echo "  sudo ./switch_cpld_update.sh --concurrent 2     # 设置并发数为2"
    echo "  sudo ./switch_cpld_update.sh -i                 # 仅查看交换机CPLD信息"
    echo ""
    echo "更新判断条件:"
    echo "  只更新输出 'CPLD update is needed' 的交换机"
    echo "  已更新的设备会显示 'No CPLD update is needed'"
    echo "  无需指定PSID，自动处理所有交换机"
    echo "  自动输入确认信息，无需手动干预"
    echo ""
    echo "重要提醒:"
    echo "  - CPLD更新过程中交换机会重启，每台设备更新需要约20分钟"
    echo "  - 建议使用较小的并发数（1-2）以避免网络过载"
    echo "  - 更新期间请勿断电或中断网络连接"
    echo "  - 脚本会自动输入确认信息，支持expect或printf方式"
    echo ""
    echo "注意: 此脚本为全自动模式，找到需要更新的交换机将立即执行CPLD更新"
}

# 仅显示信息模式
info_only() {
    log_message "=== 交换机CPLD信息查询模式 ==="

    # 检查运行权限
    check_root

    # 检查必要工具
    check_tools

    # 显示所有交换机CPLD信息
    show_cpld_info

    log_message "=== CPLD信息查询完成 ==="
}

# 处理命令行参数
case "${1:-}" in
    -h|--help)
        show_usage
        exit 0
        ;;
    -i|--info)
        info_only
        exit 0
        ;;
    --concurrent)
        if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -gt 0 ]; then
            MAX_CONCURRENT_UPDATES="$2"
            log_message "设置并发CPLD更新数量为: $MAX_CONCURRENT_UPDATES"
            shift 2
            main "$@"
        else
            echo "错误: --concurrent 参数需要一个正整数"
            echo "使用示例: sudo ./switch_cpld_update.sh --concurrent 2"
            echo "注意: CPLD更新建议使用较小的并发数（1-2）"
            exit 1
        fi
        ;;
    *)
        main "$@"
        ;;
esac
