#!/usr/bin/env python3
"""
mquery.py - Mellanox IB Switch 批量查询工具
使用方法: ./mquery.py -i iplist.txt -u admin -p admin -c "show inventory"
"""

import paramiko
import argparse
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
import os

class Colors:
    """颜色定义"""
    GREEN = '\033[92m'
    RED = '\033[91m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    WHITE = '\033[97m'
    BOLD = '\033[1m'
    END = '\033[0m'

def print_colored(text, color):
    """打印带颜色的文本"""
    print(f"{color}{text}{Colors.END}")

def print_header(ip, success=True):
    """打印IP头部"""
    status = "SUCCESS" if success else "FAILED"
    color = Colors.GREEN if success else Colors.RED
    print_colored(f"\n{'='*60}", Colors.CYAN)
    print_colored(f"HOST: {ip} - {status}", color)
    print_colored(f"{'='*60}", Colors.CYAN)

def connect_and_execute(ip, username, password, commands, timeout=30):
    """连接交换机并执行命令（支持多个命令）- 优化速度版本"""
    try:
        # 如果是字符串，转换为列表
        if isinstance(commands, str):
            # 按逗号分割命令，并去除空格
            command_list = [cmd.strip() for cmd in commands.split(',') if cmd.strip()]
        else:
            command_list = commands
        
        # 创建SSH客户端
        ssh = paramiko.SSHClient()
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        
        # 连接交换机
        ssh.connect(
            hostname=ip,
            username=username,
            password=password,
            timeout=timeout,
            allow_agent=False,
            look_for_keys=False
        )
        
        # 创建交互式shell
        shell = ssh.invoke_shell(width=200, height=50)
        shell.settimeout(10)  # 减少超时时间
        
        # 快速等待登录完成
        time.sleep(0.5)  # 减少等待时间
        
        # 清空缓冲区
        if shell.recv_ready():
            shell.recv(8192)
        
        # 快速处理初始连接提示
        initial_prompts = [
            ("Are you sure you want to continue connecting", "yes"),
            ("Would you like to connect to the master SM", "no"),
            ("password:", password)
        ]
        
        for prompt, response in initial_prompts:
            time.sleep(0.1)  # 大幅减少等待时间
            if shell.recv_ready():
                data = shell.recv(8192).decode('utf-8', errors='ignore')
                if prompt in data:
                    shell.send(response + '\n')
                    time.sleep(0.2)
        
        # 发送enable命令
        shell.send('enable\n')
        time.sleep(0.3)  # 减少等待时间
        
        # 清空缓冲区
        if shell.recv_ready():
            shell.recv(8192)
        
        # 不再尝试禁用分页命令，直接处理分页即可
        # 现在的分页处理机制已经足够好了
        
        # 执行所有命令并收集结果
        all_outputs = {}
        
        for cmd in command_list:
            # 发送命令
            shell.send(cmd + '\n')
            time.sleep(0.2)  # 减少初始等待时间
            
            # 快速接收输出
            output = ""
            max_wait_time = 15  # 减少最大等待时间
            start_time = time.time()
            last_data_time = start_time
            
            while (time.time() - start_time) < max_wait_time:
                if shell.recv_ready():
                    data = shell.recv(8192).decode('utf-8', errors='ignore')
                    if data:
                        output += data
                        last_data_time = time.time()
                        
                        # 快速检查分页提示
                        import re
                        lines_pattern = re.compile(r'lines\s+\d+-\d+', re.IGNORECASE)
                        
                        found_paging = False
                        
                        # 检查 lines x-xx 格式或其他分页提示
                        if (lines_pattern.search(data) or 
                            '--More--' in data or 
                            '-- More --' in data or
                            'more' in data.lower()):
                            shell.send(' ')
                            time.sleep(0.1)  # 减少分页等待时间
                            found_paging = True
                        
                        # 快速检查命令结束提示符
                        if not found_paging:
                            prompt_indicators = ['#', '>', '$ ']
                            for prompt in prompt_indicators:
                                if data.strip().endswith(prompt):
                                    # 快速确认没有更多数据
                                    time.sleep(0.1)
                                    if not shell.recv_ready():
                                        break
                else:
                    # 如果1秒没有数据，认为命令完成
                    if (time.time() - last_data_time) > 1:
                        break
                    time.sleep(0.05)  # 减少轮询间隔
            
            all_outputs[cmd] = output
            
            # 减少命令间间隔
            time.sleep(0.1)
        
        # 关闭连接
        ssh.close()
        
        return True, all_outputs
        
    except paramiko.AuthenticationException:
        return False, f"认证失败: 用户名或密码错误"
    except paramiko.SSHException as e:
        return False, f"SSH连接错误: {str(e)}"
    except Exception as e:
        return False, f"连接失败: {str(e)}"

def clean_output(output):
    """清理输出内容（参考sino.py的处理方式）"""
    lines = output.split('\n')
    cleaned_lines = []
    
    # 导入正则表达式模块
    import re
    lines_pattern = re.compile(r'lines\s+\d+-\d+', re.IGNORECASE)
    
    for line in lines:
        stripped = line.strip()
        
        # 跳过各种提示符、分页符和控制字符
        skip_patterns = [
            stripped.endswith('#'),
            stripped.endswith('>'),
            stripped.endswith('$ '),
            '--More--' in stripped,
            '-- More --' in stripped,
            'Press any key' in stripped,
            'Continue?' in stripped,
            'q to quit' in stripped,
            stripped == 'more',
            stripped == '',
            len(stripped) < 2,
            'Are you sure you want to continue' in stripped,
            'Would you like to connect' in stripped,
            'password:' in stripped.lower(),
            lines_pattern.search(stripped),  # 匹配 lines x-xx 格式
            '(END)' in stripped,
            '[K' in stripped,
            'Unrecognized command' in stripped,  # 过滤命令错误提示
            'Type "no ?' in stripped,  # 过滤帮助提示
            'terminal length' in stripped.lower(),  # 过滤 terminal length 命令回显
            '% ' in stripped and len(stripped) < 80,  # 过滤错误消息
        ]
        
        if any(skip_patterns):
            continue
            
        # 移除ANSI转义序列和控制字符
        ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
        cleaned_line = ansi_escape.sub('', line)
        
        # 移除回车符和其他控制字符
        cleaned_line = cleaned_line.replace('\r', '').replace('\x08', '')
        
        # 如果清理后的行仍有内容，添加到结果中
        if cleaned_line.strip():
            cleaned_lines.append(cleaned_line)
    
    return '\n'.join(cleaned_lines)

def process_single_host(ip, username, password, commands, timeout):
    """处理单个主机（支持多个命令）"""
    success, result = connect_and_execute(ip.strip(), username, password, commands, timeout)
    
    if success:
        print_header(ip, True)
        
        # 如果是字符串，说明只有一个命令
        if isinstance(result, str):
            cleaned_result = clean_output(result)
            print(cleaned_result)
        # 如果是字典，说明有多个命令
        elif isinstance(result, dict):
            for i, (cmd, output) in enumerate(result.items()):
                if i > 0:  # 命令间添加分隔符
                    print_colored(f"\n{'-'*50}", Colors.YELLOW)
                
                print_colored(f"命令: {cmd}", Colors.CYAN)
                print_colored(f"{'-'*50}", Colors.YELLOW)
                cleaned_result = clean_output(output)
                print(cleaned_result)
    else:
        print_header(ip, False)
        print_colored(f"错误: {result}", Colors.RED)
    
    return success

def read_ip_list(filename):
    """读取IP列表文件"""
    try:
        with open(filename, 'r') as f:
            ips = [line.strip() for line in f.readlines() if line.strip() and not line.startswith('#')]
        return ips
    except FileNotFoundError:
        print_colored(f"错误: 文件 {filename} 不存在", Colors.RED)
        sys.exit(1)
    except Exception as e:
        print_colored(f"错误: 读取文件失败 - {str(e)}", Colors.RED)
        sys.exit(1)

def main():
    """主函数"""
    parser = argparse.ArgumentParser(
        description='Mellanox IB Switch 批量查询工具',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''
使用示例:
  # 使用IP列表文件
  %(prog)s -i iplist.txt -u admin -p admin -c "show inventory"
  %(prog)s -i iplist.txt -c "show version"  # 使用默认账号密码
  
  # 单个IP地址查询
  %(prog)s -H 192.168.1.100 -u admin -p admin -c "show inventory"
  %(prog)s -H 192.168.1.100 -c "show version"  # 使用默认账号密码
  
  # 多个命令查询（用逗号分隔）
  %(prog)s -H 192.168.1.100 -c "show version, show inventory"
  %(prog)s -i iplist.txt -c "show system, show interfaces ib, show route"
  
  # 其他选项
  %(prog)s -i iplist.txt -c "show interfaces ib" -t 60 -j 5

IP列表文件格式:
  192.168.1.100
  192.168.1.101
  192.168.1.102
  # 这是注释行
        '''
    )
    
    # IP输入方式：文件或单个IP（互斥）
    ip_group = parser.add_mutually_exclusive_group(required=True)
    ip_group.add_argument('-i', '--iplist',
                        help='IP列表文件路径')
    ip_group.add_argument('-H', '--host',
                        help='单个IP地址')
    
    # 认证信息（可选，有默认值）
    parser.add_argument('-u', '--username', default='admin',
                        help='用户名 (默认: admin)')
    parser.add_argument('-p', '--password', default='admin',
                        help='密码 (默认: admin)')
    
    parser.add_argument('-c', '--command', required=True,
                        help='要执行的命令（多个命令用逗号分隔）')
    parser.add_argument('-t', '--timeout', type=int, default=30,
                        help='连接超时时间(秒), 默认30秒')
    parser.add_argument('-j', '--jobs', type=int, default=10,
                        help='并发连接数, 默认10')
    parser.add_argument('--no-color', action='store_true',
                        help='禁用颜色输出')
    
    args = parser.parse_args()
    
    # 禁用颜色输出
    if args.no_color:
        Colors.GREEN = Colors.RED = Colors.YELLOW = Colors.BLUE = Colors.CYAN = Colors.WHITE = Colors.BOLD = Colors.END = ''
    
    # 获取IP列表
    if args.iplist:
        ip_list = read_ip_list(args.iplist)
    else:
        ip_list = [args.host]
    
    if not ip_list:
        print_colored("错误: IP列表为空", Colors.RED)
        sys.exit(1)
    
    # 显示执行信息
    device_count = len(ip_list)
    device_text = "个设备" if device_count > 1 else "个设备"
    
    # 解析命令数量
    command_list = [cmd.strip() for cmd in args.command.split(',') if cmd.strip()]
    command_count = len(command_list)
    command_text = f"{command_count}个命令" if command_count > 1 else "1个命令"
    
    print_colored(f"开始处理 {device_count} {device_text}...", Colors.BLUE)
    print_colored(f"用户名: {args.username}", Colors.BLUE)
    print_colored(f"执行 {command_text}: {args.command}", Colors.BLUE)
    if device_count > 1:
        print_colored(f"并发数: {args.jobs}", Colors.BLUE)
    
    # 统计结果
    success_count = 0
    total_count = len(ip_list)
    
    # 使用线程池并发处理（单个IP时也使用，保持代码一致性）
    max_workers = 1 if len(ip_list) == 1 else args.jobs
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        # 提交所有任务
        futures = {
            executor.submit(process_single_host, ip, args.username, args.password, args.command, args.timeout): ip
            for ip in ip_list
        }
        
        # 处理完成的任务
        for future in as_completed(futures):
            ip = futures[future]
            try:
                success = future.result()
                if success:
                    success_count += 1
            except Exception as e:
                print_header(ip, False)
                print_colored(f"处理异常: {str(e)}", Colors.RED)
    
    # 打印统计结果
    if total_count > 1:
        print_colored(f"\n{'='*60}", Colors.CYAN)
        print_colored(f"执行完成!", Colors.BOLD)
        print_colored(f"成功: {success_count}/{total_count}", Colors.GREEN)
        print_colored(f"失败: {total_count - success_count}/{total_count}", Colors.RED)
        print_colored(f"{'='*60}", Colors.CYAN)
    else:
        # 单个设备时不显示统计信息
        pass

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print_colored("\n\n用户中断执行", Colors.YELLOW)
        sys.exit(1)
    except Exception as e:
        print_colored(f"\n程序异常: {str(e)}", Colors.RED)
        sys.exit(1)
