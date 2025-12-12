#!/bin/bash
# -*- coding: utf-8 -*-
#
# InfiniBand Data Collector and Analyzer - Streamlined Version
# 精简版：只采集和保存筛选后的有效数据（7列温度/8列错误）
#
# Author: Vincent Wu <Vincentwu@zhengytech.com>
# Version: 3.1 (温度监控专版)
#

# ================= 配置区域 =================
SOURCE_FILE="${SOURCE_FILE:-/var/tmp/ibdiagnet2/ibdiagnet2.db_csv}"
OUTPUT_DIR="${OUTPUT_DIR:-./ibdiag_filtered_data}"
CHECK_INTERVAL="${CHECK_INTERVAL:-5}"
AUTO_ANALYZE="${AUTO_ANALYZE:-1}"
TEMP_THRESHOLD=70.0
# ===========================================

# Color codes
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_BLUE='\033[0;34m'
COLOR_RESET='\033[0m'

# Mode flags
MODE=""
ONCE_MODE=0
LIST_SECTIONS=0

#==============================================================================
# Helper Functions
#==============================================================================

log_info() {
    echo -e "${COLOR_GREEN}✓${COLOR_RESET} $1"
}

log_warn() {
    echo -e "${COLOR_YELLOW}⚠️${COLOR_RESET}  $1"
}

log_error() {
    echo -e "${COLOR_RED}❌${COLOR_RESET} $1" >&2
}

print_usage() {
    cat << EOF
========================================================================
  InfiniBand 数据采集与分析工具 (精简版)
  IB Data Collector & Analyzer (Streamlined)
========================================================================

用法: $(basename $0) [模式] [选项]

运行模式:
  collect-once           采集一次筛选后的数据
  collect                持续监控并采集（默认）
  analyze FILE           分析指定的CSV文件
  --list-sections        列出所有可用板块

选项参数:
  -i, --input FILE       输入文件路径
                         默认: ${SOURCE_FILE}

  -o, --output DIR       数据输出目录
                         默认: ${OUTPUT_DIR}

  -c, --check-interval N 文件检查间隔（秒）
                         默认: ${CHECK_INTERVAL}

  -h, --help             显示此帮助信息

示例:
  # 采集一次（推荐）
  $(basename $0) collect-once

  # 持续监控采集
  $(basename $0) collect

  # 分析指定文件
  $(basename $0) analyze ${OUTPUT_DIR}/ib_CABLE_INFO_filtered_*.csv

  # 后台持续采集
  nohup $(basename $0) collect > collector.log 2>&1 &

输出文件:
  ${OUTPUT_DIR}/ib_CABLE_INFO_filtered_YYYYMMDD_HHMMSS.csv   (7列: 温度监控)
  ${OUTPUT_DIR}/ib_PM_INFO_filtered_YYYYMMDD_HHMMSS.csv      (8列: 端口错误)

快速查询:
  grep "ABNORMAL" ${OUTPUT_DIR}/ib_CABLE_INFO_filtered_*.csv  # 温度异常(>70°C)
  grep "ERROR" ${OUTPUT_DIR}/ib_PM_INFO_filtered_*.csv        # 端口错误

版本: 3.1 (温度监控专版)
作者: Vincent Wu <Vincentwu@zhengytech.com>
========================================================================
EOF
}

#==============================================================================
# 采集筛选后的 CABLE_INFO 数据（7列：温度监控）
#==============================================================================
collect_cable_info_filtered() {
    local source_file=$1
    local output_csv=$2
    local append_mode=$3

    log_info "采集 CABLE_INFO 数据（温度监控）..."

    # 如果是追加模式且文件已存在，跳过header
    local skip_header=0
    if [ "${append_mode}" == "true" ] && [ -f "${output_csv}" ]; then
        skip_header=1
    fi

    awk -F',' -v threshold="${TEMP_THRESHOLD}" -v timestamp="$(date '+%Y-%m-%d %H:%M:%S')" -v skip_header="${skip_header}" '
    BEGIN {
        OFS=","
        in_section = 0
        header_found = 0
    }

    $1 ~ /^START_CABLE_INFO/ {
        in_section = 1
        next
    }

    $1 ~ /^END_CABLE_INFO/ {
        exit
    }

    in_section == 1 {
        if (header_found == 0) {
            for (i=1; i<=NF; i++) {
                col[$i] = i
            }
            if (skip_header == 0) {
                print "Scan_Time", "NodeGuid", "PortGuid", "PortNum", "SN", "Temperature", "Temperature_Status"
            }
            header_found = 1
            next
        }

        node_guid = $(col["NodeGuid"])
        port_guid = $(col["PortGuid"])
        port_num = $(col["PortNum"])
        sn = $(col["SN"])
        temp = $(col["Temperature"])

        # 提取温度数值（去掉引号和"C"后缀）
        temp_str = temp
        gsub(/"/, "", temp_str)  # 去掉双引号
        gsub(/C/, "", temp_str)  # 去掉C
        temp_num = temp_str + 0  # 转换为数值

        # 温度判断：> 70度为异常，<= 70度为正常
        temp_status = (temp_num > threshold) ? sprintf("%.0f°C (ABNORMAL)", temp_num) : sprintf("%.0f°C (OK)", temp_num)

        print timestamp, node_guid, port_guid, port_num, sn, temp, temp_status
    }
    ' "${source_file}" >> "${output_csv}"

    local new_records=$(awk -F',' 'NR>1 && $1 ~ /^'$(date '+%Y-%m-%d')'/' "${output_csv}" | wc -l)
    local total=$(($(wc -l < "${output_csv}") - 1))
    local temp_abnormal=$(awk -F',' 'NR>1 && $NF ~ /ABNORMAL/ { count++ } END { print count+0 }' "${output_csv}")

    log_info "CABLE_INFO: 新增 ${new_records} 条, 总计 ${total} 条记录, ${temp_abnormal} 温度异常（>70°C）"
    echo "  文件: ${output_csv}"
}

#==============================================================================
# 采集筛选后的 PM_INFO 数据（8列）
#==============================================================================
collect_pm_info_filtered() {
    local source_file=$1
    local output_csv=$2
    local append_mode=$3

    log_info "采集 PM_INFO 数据..."

    # 如果是追加模式且文件已存在，跳过header
    local skip_header=0
    if [ "${append_mode}" == "true" ] && [ -f "${output_csv}" ]; then
        skip_header=1
    fi

    awk -F',' -v timestamp="$(date '+%Y-%m-%d %H:%M:%S')" -v skip_header="${skip_header}" '
    BEGIN {
        OFS=","
        in_section = 0
        header_found = 0
    }

    $1 ~ /^START_PM_INFO/ {
        in_section = 1
        next
    }

    $1 ~ /^END_PM_INFO/ {
        exit
    }

    in_section == 1 {
        if (header_found == 0) {
            for (i=1; i<=NF; i++) {
                col[$i] = i
            }
            if (skip_header == 0) {
                print "Scan_Time", "NodeGUID", "PortGUID", "PortNumber", "LinkDownedCounter", "SymbolErrorCounter", "LinkDowned_Status", "SymbolError_Status"
            }
            header_found = 1
            next
        }

        node_guid = $(col["NodeGUID"])
        port_guid = $(col["PortGUID"])
        port_num = $(col["PortNumber"])
        ld = $(col["LinkDownedCounter"])
        se = $(col["SymbolErrorCounter"])

        ld_status = (ld != 0) ? sprintf("%s (ERROR)", ld) : sprintf("%s (OK)", ld)
        se_status = (se != 0) ? sprintf("%s (ERROR)", se) : sprintf("%s (OK)", se)

        print timestamp, node_guid, port_guid, port_num, ld, se, ld_status, se_status
    }
    ' "${source_file}" >> "${output_csv}"

    local new_records=$(awk -F',' 'NR>1 && $1 ~ /^'$(date '+%Y-%m-%d')'/' "${output_csv}" | wc -l)
    local total=$(($(wc -l < "${output_csv}") - 1))
    local ld_errors=$(awk -F',' 'NR>1 && $(NF-1) ~ /ERROR/ { count++ } END { print count+0 }' "${output_csv}")
    local se_errors=$(awk -F',' 'NR>1 && $NF ~ /ERROR/ { count++ } END { print count+0 }' "${output_csv}")

    log_info "PM_INFO: 新增 ${new_records} 条, 总计 ${total} 条记录, ${ld_errors} 链路错误, ${se_errors} 符号错误"
    echo "  文件: ${output_csv}"
}

#==============================================================================
# 检查文件稳定性
#==============================================================================
check_file_stability() {
    local filepath=$1
    local wait_time=${2:-2}  # 默认等待2秒

    if [ ! -f "${filepath}" ]; then
        return 1
    fi

    local size1=$(stat -c %s "${filepath}" 2>/dev/null || stat -f %z "${filepath}" 2>/dev/null)
    sleep ${wait_time}
    local size2=$(stat -c %s "${filepath}" 2>/dev/null || stat -f %z "${filepath}" 2>/dev/null)

    if [ "${size1}" == "${size2}" ]; then
        return 0  # 文件稳定
    else
        return 1  # 文件仍在写入
    fi
}

#==============================================================================
# 采集筛选后的数据
#==============================================================================
collect_filtered_data() {
    local filepath=$1
    local append_mode=${2:-false}  # 默认不追加

    if [ ! -f "${filepath}" ]; then
        log_error "源文件不存在: ${filepath}"
        return 1
    fi

    # 检查文件稳定性
    log_info "检查文件稳定性..."
    if ! check_file_stability "${filepath}" 2; then
        log_warn "文件仍在写入，等待文件稳定..."
        sleep 3
        if ! check_file_stability "${filepath}" 2; then
            log_error "文件不稳定，跳过本次采集"
            return 1
        fi
    fi
    log_info "文件稳定，开始采集"

    # 创建输出目录
    mkdir -p "${OUTPUT_DIR}"

    # 根据模式确定文件名
    if [ "${append_mode}" == "true" ]; then
        # 持续采集模式：使用固定文件名（按日期）
        local date_str=$(date "+%Y%m%d")
        local cable_csv="${OUTPUT_DIR}/ib_CABLE_INFO_${date_str}.csv"
        local pm_csv="${OUTPUT_DIR}/ib_PM_INFO_${date_str}.csv"
    else
        # 一次性采集模式：使用时间戳文件名
        local timestamp=$(date "+%Y%m%d_%H%M%S")
        local cable_csv="${OUTPUT_DIR}/ib_CABLE_INFO_filtered_${timestamp}.csv"
        local pm_csv="${OUTPUT_DIR}/ib_PM_INFO_filtered_${timestamp}.csv"
    fi

    echo ""
    echo "========================================"
    echo "  开始采集数据 - $(date '+%Y-%m-%d %H:%M:%S')"
    echo "========================================"
    echo "源文件: ${filepath}"
    echo "模式: $([ "${append_mode}" == "true" ] && echo "追加" || echo "新建")"
    echo ""

    # 采集 CABLE_INFO（16列）
    collect_cable_info_filtered "${filepath}" "${cable_csv}" "${append_mode}"
    echo ""

    # 采集 PM_INFO（8列）
    collect_pm_info_filtered "${filepath}" "${pm_csv}" "${append_mode}"
    echo ""

    log_info "采集完成！"
    echo ""
}

#==============================================================================
# 分析指定的CSV文件
#==============================================================================
analyze_csv_file() {
    local csv_file=$1

    if [ ! -f "${csv_file}" ]; then
        log_error "文件不存在: ${csv_file}"
        return 1
    fi

    echo ""
    echo "========================================"
    echo "  分析文件: $(basename ${csv_file})"
    echo "========================================"

    local total=$(($(wc -l < "${csv_file}") - 1))
    echo "总记录数: ${total}"

    # 根据文件名判断类型
    if [[ "${csv_file}" == *"CABLE_INFO"* ]]; then
        local temp_abnormal=$(awk -F',' 'NR>1 && $NF ~ /ABNORMAL/ { count++ } END { print count+0 }' "${csv_file}")
        echo "温度异常 (>70°C): ${temp_abnormal}"

        if [ "${temp_abnormal}" -gt 0 ]; then
            echo ""
            echo "前10个温度异常:"
            awk -F',' 'NR>1 && $NF ~ /ABNORMAL/' "${csv_file}" | head -10
        fi

    elif [[ "${csv_file}" == *"PM_INFO"* ]]; then
        local ld_errors=$(awk -F',' 'NR>1 && $(NF-1) ~ /ERROR/ { count++ } END { print count+0 }' "${csv_file}")
        local se_errors=$(awk -F',' 'NR>1 && $NF ~ /ERROR/ { count++ } END { print count+0 }' "${csv_file}")
        echo "链路错误: ${ld_errors}"
        echo "符号错误: ${se_errors}"

        if [ "${ld_errors}" -gt 0 ]; then
            echo ""
            echo "前10个链路错误:"
            awk -F',' 'NR>1 && $(NF-1) ~ /ERROR/' "${csv_file}" | head -10
        fi
    fi

    echo ""
}

#==============================================================================
# 持续监控模式
#==============================================================================
monitor_and_collect() {
    local last_mtime=0

    log_info "开始监控文件: ${SOURCE_FILE}"
    log_info "检查间隔: ${CHECK_INTERVAL} 秒"
    log_info "输出目录: ${OUTPUT_DIR}"
    log_info "模式: 追加到每日文件"
    echo ""

    while true; do
        if [ -f "${SOURCE_FILE}" ]; then
            local current_mtime=$(stat -c %Y "${SOURCE_FILE}" 2>/dev/null || stat -f %m "${SOURCE_FILE}" 2>/dev/null)

            if [ "${current_mtime}" != "${last_mtime}" ]; then
                log_info "检测到文件更新: ${SOURCE_FILE}"
                collect_filtered_data "${SOURCE_FILE}" "true"  # 追加模式
                last_mtime=${current_mtime}
            fi
        else
            log_warn "源文件不存在: ${SOURCE_FILE}"
        fi

        sleep ${CHECK_INTERVAL}
    done
}

#==============================================================================
# 列出可用板块
#==============================================================================
list_available_sections() {
    if [ ! -f "${SOURCE_FILE}" ]; then
        log_error "源文件不存在: ${SOURCE_FILE}"
        return 1
    fi

    echo "可用的数据板块:"
    grep "^START_" "${SOURCE_FILE}" | sed 's/^START_/  - /' | sort -u
}

#==============================================================================
# Main
#==============================================================================
main() {
    # 解析参数
    while [[ $# -gt 0 ]]; do
        case $1 in
            collect-once)
                MODE="collect-once"
                ONCE_MODE=1
                shift
                ;;
            collect)
                MODE="collect"
                shift
                ;;
            analyze)
                MODE="analyze"
                ANALYZE_FILE="$2"
                shift 2
                ;;
            --list-sections)
                LIST_SECTIONS=1
                shift
                ;;
            -i|--input)
                SOURCE_FILE="$2"
                shift 2
                ;;
            -o|--output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            -c|--check-interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                log_error "未知选项: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    # 列出板块
    if [ ${LIST_SECTIONS} -eq 1 ]; then
        list_available_sections
        exit 0
    fi

    # 分析模式
    if [ "${MODE}" == "analyze" ]; then
        if [ -z "${ANALYZE_FILE}" ]; then
            log_error "请指定要分析的文件"
            exit 1
        fi
        analyze_csv_file "${ANALYZE_FILE}"
        exit 0
    fi

    # 采集模式
    if [ "${MODE}" == "collect-once" ]; then
        collect_filtered_data "${SOURCE_FILE}" "false"  # 不追加，创建新文件
        exit 0
    fi

    # 持续监控模式（默认）
    monitor_and_collect
}

main "$@"
