#!/bin/bash

# ParaPerf工具包离线安装脚本

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "开始安装ParaPerf工具包..."

# 检查已安装的工具
tools=("iperf3" "jq" "sshpass" "bc")
installed=()
missing=()

for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        installed+=("$tool")
    else
        missing+=("$tool")
    fi
done

echo "已安装的工具: ${installed[*]:-无}"
echo "缺少的工具: ${missing[*]:-无}"

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "所有工具都已安装！"
    read -p "是否要重新安装? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "安装取消"
        exit 0
    fi
fi

cd "$SCRIPT_DIR"

# 安装所有.deb包
echo "安装.deb包..."
sudo dpkg -i *.deb 2>/dev/null || {
    echo "解决依赖问题..."
    sudo apt-get update
    sudo apt-get install -f -y
    sudo dpkg -i *.deb
}

# 验证安装
echo "验证安装结果..."
all_success=true
for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        echo "✓ $tool 安装成功"
        case "$tool" in
            iperf3) echo "  版本: $(iperf3 --version | head -1)" ;;
            jq) echo "  版本: $(jq --version)" ;;
            bc) echo "  版本: $(bc --version | head -1)" ;;
            sshpass) echo "  版本: $(sshpass -V 2>&1 | head -1)" ;;
        esac
    else
        echo "✗ $tool 安装失败"
        all_success=false
    fi
done

if [[ $all_success == true ]]; then
    echo
    echo "所有ParaPerf工具包安装成功！"
else
    echo
    echo "部分工具安装失败，请检查错误信息"
    exit 1
fi
