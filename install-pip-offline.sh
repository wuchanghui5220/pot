#!/bin/bash
# 离线安装 pip 的脚本
# 该脚本分为两部分：
# 1. 在有网络的机器上下载所需文件
# 2. 在离线机器上安装 pip

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 函数定义
print_header() {
    echo -e "${BLUE}====================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}====================================${NC}"
}

print_success() {
    echo -e "${GREEN}[成功] $1${NC}"
}

print_error() {
    echo -e "${RED}[错误] $1${NC}"
    exit 1
}

print_warning() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

print_info() {
    echo -e "[信息] $1"
}

check_python() {
    if ! command -v python &> /dev/null && ! command -v python3 &> /dev/null; then
        print_error "未找到 Python。请先安装 Python 3.x 再运行此脚本。"
    fi
    
    if command -v python3 &> /dev/null; then
        PYTHON_CMD="python3"
    else
        PYTHON_CMD="python"
    fi
    
    PYTHON_VERSION=$($PYTHON_CMD --version 2>&1)
    print_info "检测到 $PYTHON_VERSION"
    
    # 确保 Python 版本 >= 3.6
    PYTHON_MAJOR_VERSION=$($PYTHON_CMD -c "import sys; print(sys.version_info[0])")
    PYTHON_MINOR_VERSION=$($PYTHON_CMD -c "import sys; print(sys.version_info[1])")
    
    if [ "$PYTHON_MAJOR_VERSION" -lt 3 ] || ([ "$PYTHON_MAJOR_VERSION" -eq 3 ] && [ "$PYTHON_MINOR_VERSION" -lt 6 ]); then
        print_warning "推荐使用 Python 3.6 或更高版本。当前版本可能存在兼容性问题。"
    fi
}

# 第一部分：在有网络的机器上下载所需文件
download_files() {
    print_header "第一部分：下载文件（在有网络连接的机器上运行）"
    
    # 创建下载目录
    DOWNLOAD_DIR="pip-offline-install"
    mkdir -p "$DOWNLOAD_DIR"
    cd "$DOWNLOAD_DIR" || print_error "无法创建下载目录"
    
    print_info "下载 get-pip.py..."
    if command -v curl &> /dev/null; then
        curl -s https://bootstrap.pypa.io/get-pip.py -o get-pip.py || print_error "下载 get-pip.py 失败"
    elif command -v wget &> /dev/null; then
        wget -q https://bootstrap.pypa.io/get-pip.py || print_error "下载 get-pip.py 失败"
    else
        print_error "未找到 curl 或 wget 工具，无法下载文件"
    fi
    
    # 创建依赖包目录
    mkdir -p pip-packages
    
    # 如果有 pip，下载依赖包
    if command -v pip &> /dev/null || command -v pip3 &> /dev/null; then
        PIP_CMD="pip"
        if command -v pip3 &> /dev/null; then
            PIP_CMD="pip3"
        fi
        
        print_info "下载 pip、setuptools 和 wheel 包..."
        $PIP_CMD download pip setuptools wheel --dest ./pip-packages || print_warning "下载依赖包失败，将只使用 get-pip.py 安装"
    else
        print_warning "未找到 pip，将只下载 get-pip.py（可能会缺少某些依赖）"
    fi
    
    # 创建安装脚本
    cat > install-pip-offline.sh << 'EOF'
#!/bin/bash
# pip 离线安装脚本

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}====================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}====================================${NC}"
}

print_success() {
    echo -e "${GREEN}[成功] $1${NC}"
}

print_error() {
    echo -e "${RED}[错误] $1${NC}"
    exit 1
}

print_warning() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

print_info() {
    echo -e "[信息] $1"
}

# 检查 Python
if command -v python3 &> /dev/null; then
    PYTHON_CMD="python3"
elif command -v python &> /dev/null; then
    PYTHON_CMD="python"
else
    print_error "未找到 Python。请先安装 Python 3.x 再运行此脚本。"
fi

PYTHON_VERSION=$($PYTHON_CMD --version 2>&1)
print_info "检测到 $PYTHON_VERSION"

print_header "开始离线安装 pip"

# 检查是否存在 pip-packages 目录
if [ -d "pip-packages" ] && [ "$(ls -A pip-packages 2>/dev/null)" ]; then
    print_info "发现预下载的依赖包，使用完整安装模式..."
    $PYTHON_CMD -m pip install --no-index --find-links=./pip-packages pip setuptools wheel || {
        print_warning "使用依赖包安装失败，尝试使用 get-pip.py..."
        $PYTHON_CMD get-pip.py
    }
else
    print_info "使用 get-pip.py 安装..."
    $PYTHON_CMD get-pip.py
fi

# 验证安装
print_header "验证安装"

PIP_INSTALLED=false
for CMD in "pip" "pip3" "$PYTHON_CMD -m pip"; do
    if $CMD --version &>/dev/null; then
        print_success "pip 安装成功！"
        print_info "$($CMD --version)"
        PIP_INSTALLED=true
        break
    fi
done

if [ "$PIP_INSTALLED" = false ]; then
    print_error "pip 安装似乎失败了。请检查上面的错误信息。"
fi

# 提供一些后续建议
print_header "后续步骤"
print_info "如果 pip 命令无法直接使用，可以尝试以下方法："
print_info "1. 使用 '$PYTHON_CMD -m pip' 代替 'pip' 命令"
print_info "2. 将 pip 安装路径添加到环境变量 PATH 中"
print_info "3. 创建 pip 命令的符号链接："
print_info "   sudo ln -s $(which $PYTHON_CMD)-m-pip /usr/local/bin/pip"

print_success "安装脚本执行完毕！"
EOF
    
    chmod +x install-pip-offline.sh
    
    # 创建打包目录
    cd ..
    print_info "创建压缩包..."
    tar -czf pip-offline-install.tar.gz "$DOWNLOAD_DIR" || print_error "创建压缩包失败"
    
    print_success "所有文件已下载并打包到 pip-offline-install.tar.gz"
    print_info "请将此压缩包传输到离线机器，解压后运行 install-pip-offline.sh 脚本"
    print_info "传输命令示例: scp pip-offline-install.tar.gz user@remote-host:~/"
    print_info "解压命令: tar -xzf pip-offline-install.tar.gz"
    print_info "安装命令: cd pip-offline-install && ./install-pip-offline.sh"
    
    exit 0
}

# 第二部分：在离线机器上安装 pip
install_pip() {
    print_header "第二部分：安装 pip（在离线机器上运行）"
    
    check_python
    
    # 检查当前目录是否有 get-pip.py
    if [ ! -f "get-pip.py" ]; then
        print_error "未找到 get-pip.py 文件。请确保在正确的目录中运行此脚本。"
    fi
    
    # 如果存在 pip-packages 目录，使用离线安装模式
    if [ -d "pip-packages" ] && [ "$(ls -A pip-packages 2>/dev/null)" ]; then
        print_info "发现预下载的依赖包，使用完整安装模式..."
        $PYTHON_CMD -m pip install --no-index --find-links=./pip-packages pip setuptools wheel || {
            print_warning "使用依赖包安装失败，尝试使用 get-pip.py..."
            $PYTHON_CMD get-pip.py
        }
    else
        print_info "使用 get-pip.py 安装..."
        $PYTHON_CMD get-pip.py
    fi
    
    # 验证安装
    print_header "验证安装"
    
    PIP_INSTALLED=false
    for CMD in "pip" "pip3" "$PYTHON_CMD -m pip"; do
        if $CMD --version &>/dev/null; then
            print_success "pip 安装成功！"
            print_info "$($CMD --version)"
            PIP_INSTALLED=true
            break
        fi
    done
    
    if [ "$PIP_INSTALLED" = false ]; then
        print_error "pip 安装似乎失败了。请检查上面的错误信息。"
    fi
    
    # 提供一些后续建议
    print_header "后续步骤"
    print_info "如果 pip 命令无法直接使用，可以尝试以下方法："
    print_info "1. 使用 '$PYTHON_CMD -m pip' 代替 'pip' 命令"
    print_info "2. 将 pip 安装路径添加到环境变量 PATH 中"
    print_info "3. 创建 pip 命令的符号链接："
    print_info "   sudo ln -s \$(which $PYTHON_CMD)-m-pip /usr/local/bin/pip"
    
    print_success "安装完成！"
}

# 主程序
print_header "pip 离线安装脚本"

# 根据参数决定执行哪个部分
case "$1" in
    --download)
        download_files
        ;;
    --install)
        install_pip
        ;;
    *)
        echo "pip 离线安装脚本"
        echo "用法: $0 [选项]"
        echo "选项:"
        echo "  --download   在有网络的机器上下载必要的文件"
        echo "  --install    在离线机器上安装 pip"
        echo ""
        echo "示例:"
        echo "  步骤 1: 在有网络的机器上: $0 --download"
        echo "  步骤 2: 将生成的 pip-offline-install.tar.gz 传输到离线机器"
        echo "  步骤 3: 在离线机器上解压并运行: tar -xzf pip-offline-install.tar.gz && cd pip-offline-install && $0 --install"
        ;;
esac
