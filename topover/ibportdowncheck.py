#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import subprocess
import re
import csv
import sys
import argparse
import configparser
from datetime import datetime
from collections import defaultdict

class HostsConfigParser:
    """解析类似Ansible hosts配置文件的类"""
    
    def __init__(self, config_file):
        self.config_file = config_file
        self.groups = {}
        self.port_ranges = {}
        self.parse_config()
    
    def parse_config(self):
        """解析配置文件"""
        try:
            with open(self.config_file, 'r', encoding='utf-8') as f:
                lines = f.readlines()
        except FileNotFoundError:
            print(f"错误：找不到配置文件 {self.config_file}")
            sys.exit(1)
        
        current_group = None
        current_port_range = None
        
        # 第一遍解析：解析所有基本组和GUID
        for line in lines:
            line = line.strip()
            
            # 跳过空行和注释
            if not line or line.startswith('#'):
                continue
            
            # 检查是否是组定义
            if line.startswith('[') and line.endswith(']'):
                group_def = line[1:-1]  # 去掉方括号
                
                # 检查是否是children组，如果是则跳过第一遍处理
                if group_def.endswith(':children'):
                    continue
                
                # 解析端口范围 (例如: leaf:33-64)
                if ':' in group_def:
                    group_name, port_range = group_def.split(':', 1)
                    current_group = group_name
                    
                    # 解析端口范围
                    if '-' in port_range:
                        start_port, end_port = port_range.split('-', 1)
                        try:
                            current_port_range = (int(start_port), int(end_port))
                        except ValueError:
                            print(f"警告：无效的端口范围格式 '{port_range}'，将使用全部端口")
                            current_port_range = None
                    else:
                        try:
                            port_num = int(port_range)
                            current_port_range = (1, port_num)
                        except ValueError:
                            print(f"警告：无效的端口范围格式 '{port_range}'，将使用全部端口")
                            current_port_range = None
                else:
                    current_group = group_def
                    current_port_range = None
                
                # 初始化组
                if current_group not in self.groups:
                    self.groups[current_group] = []
                
                # 设置端口范围
                if current_port_range:
                    self.port_ranges[current_group] = current_port_range
                
                continue
            
            # 检查是否是GUID
            if line.startswith('0x') and current_group:
                self.groups[current_group].append(line.lower())
        
        # 第二遍解析：处理children组
        current_group = None
        for line in lines:
            line = line.strip()
            
            # 跳过空行和注释
            if not line or line.startswith('#'):
                continue
            
            # 检查是否是children组定义
            if line.startswith('[') and line.endswith(']'):
                group_def = line[1:-1]  # 去掉方括号
                
                if group_def.endswith(':children'):
                    current_group = group_def[:-9]  # 去掉 ':children'
                    current_port_range = None
                    # 初始化组（如果不存在）
                    if current_group not in self.groups:
                        self.groups[current_group] = []
                    continue
                else:
                    current_group = None
                    continue
            
            # 处理子组引用
            if current_group and line in self.groups:
                # 将子组的GUID添加到父组，并继承端口范围（如果父组没有设置的话）
                self.groups[current_group].extend(self.groups[line])
                if current_group not in self.port_ranges and line in self.port_ranges:
                    self.port_ranges[current_group] = self.port_ranges[line]
                print(f"  将组 '{line}' 添加到父组 '{current_group}' ({len(self.groups[line])} 个设备)")
    
    def get_groups(self):
        """获取所有组"""
        return list(self.groups.keys())
    
    def get_group_guids(self, group_name):
        """获取指定组的GUID列表"""
        return self.groups.get(group_name, [])
    
    def get_port_range(self, group_name):
        """获取指定组的端口范围"""
        return self.port_ranges.get(group_name, None)
    
    def get_all_guids(self):
        """获取所有GUID"""
        all_guids = set()
        for guids in self.groups.values():
            all_guids.update(guids)
        return list(all_guids)

def run_iblinkinfo(ca_name=None):
    """执行 iblinkinfo 命令"""
    try:
        # 构建命令
        cmd = ['iblinkinfo']
        if ca_name:
            cmd.extend(['-C', ca_name])
        cmd.extend(['-l', '--switches-only'])
        
        print(f"执行命令: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout
    except subprocess.CalledProcessError as e:
        print(f"错误：执行 iblinkinfo 命令失败: {e}")
        print(f"错误输出: {e.stderr}")
        sys.exit(1)
    except FileNotFoundError:
        print("错误：找不到 iblinkinfo 命令")
        sys.exit(1)

def parse_line(line):
    """解析单行数据"""
    # 跳过空行
    if not line.strip():
        return None
    
    # 跳过包含 "Mellanox Technologies Aggregation Node" 的行
    if "Mellanox Technologies Aggregation Node" in line:
        return None
    
    # 基本信息正则表达式
    basic_pattern = r'^(0x[a-f0-9]+)\s+"([^"]+)"\s+(\d+)\s+(\d+)'
    basic_match = re.match(basic_pattern, line)
    
    if not basic_match:
        return None
    
    source_guid = basic_match.group(1).lower()
    source_name = basic_match.group(2).strip()
    source_lid = basic_match.group(3)
    source_port = basic_match.group(4)
    
    # 检查是否为Down状态
    if "Down" in line or "Polling" in line:
        return {
            'source_guid': source_guid,
            'source_name': source_name,
            'source_lid': source_lid,
            'source_port': source_port,
            'connection_type': 'N/A',
            'speed': 'N/A',
            'status': 'Down',
            'target_guid': 'N/A',
            'target_lid': 'N/A',
            'target_port': 'N/A',
            'target_name': 'N/A',
            'comment': 'N/A',
            'group': 'Unknown'
        }
    
    # 处理LinkUp状态
    if "LinkUp" in line and "Active" in line:
        # 提取连接信息
        connection_type = 'N/A'
        speed = 'N/A'
        target_guid = 'N/A'
        target_lid = 'N/A'
        target_port = 'N/A'
        target_name = 'N/A'
        comment = 'N/A'
        
        # 提取速度信息
        speed_pattern = r'(4X\s+[\d.]+\s*Gbps)'
        speed_match = re.search(speed_pattern, line)
        if speed_match:
            speed = speed_match.group(1).strip()
            connection_type = '4X'
        
        # 提取目标设备信息
        target_pattern = r'==>\s*(0x[a-f0-9]+)\s+(\d+)\s+(\d+)\[\s*\]\s*"([^"]*)"'
        target_match = re.search(target_pattern, line)
        if target_match:
            target_guid = target_match.group(1).lower()
            target_lid = target_match.group(2)
            target_port = target_match.group(3)
            target_name = target_match.group(4).strip()
        
        # 提取注释
        comment_pattern = r'\(\s*([^)]*)\s*\)\s*$'
        comment_match = re.search(comment_pattern, line)
        if comment_match:
            comment = comment_match.group(1).strip()
        
        return {
            'source_guid': source_guid,
            'source_name': source_name,
            'source_lid': source_lid,
            'source_port': source_port,
            'connection_type': connection_type,
            'speed': speed,
            'status': 'LinkUp',
            'target_guid': target_guid,
            'target_lid': target_lid,
            'target_port': target_port,
            'target_name': target_name,
            'comment': comment,
            'group': 'Unknown'
        }
    
    return None

def filter_data_by_config(data, config_parser, target_groups=None):
    """根据配置过滤数据"""
    if not config_parser:
        return data, []
    
    filtered_data = []
    excluded_data = []
    
    # 确定要处理的组
    if target_groups:
        groups_to_process = [g for g in target_groups if g in config_parser.get_groups()]
        if not groups_to_process:
            print(f"警告：指定的组 {target_groups} 在配置文件中未找到")
            return data, []
    else:
        groups_to_process = config_parser.get_groups()
    
    # 为每个数据项分配组信息
    for item in data:
        item_guid = item['source_guid'].lower()
        item_port = int(item['source_port'])
        item_included = False
        
        # 检查每个要处理的组
        for group_name in groups_to_process:
            group_guids = config_parser.get_group_guids(group_name)
            port_range = config_parser.get_port_range(group_name)
            
            # 检查GUID是否在组中
            if item_guid in group_guids:
                item['group'] = group_name
                
                # 检查端口范围
                if port_range:
                    start_port, end_port = port_range
                    if start_port <= item_port <= end_port:
                        filtered_data.append(item)
                        item_included = True
                        break
                    else:
                        # 端口不在范围内，排除
                        excluded_data.append(item)
                        item_included = True
                        break
                else:
                    # 没有端口范围限制，包含所有端口
                    filtered_data.append(item)
                    item_included = True
                    break
        
        # 如果没有找到匹配的组，标记为未知
        if not item_included:
            item['group'] = 'Unknown'
            excluded_data.append(item)
    
    return filtered_data, excluded_data

def write_csv(data, filename, fieldnames):
    """写入CSV文件的通用函数"""
    with open(filename, 'w', newline='', encoding='utf-8') as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        
        # 写入头部
        header_row = {
            'source_guid': 'Source_GUID',
            'source_name': 'Source_Name', 
            'source_lid': 'Source_LID',
            'source_port': 'Source_Port',
            'connection_type': 'Connection_Type',
            'speed': 'Speed',
            'status': 'Status',
            'target_guid': 'Target_GUID',
            'target_lid': 'Target_LID',
            'target_port': 'Target_Port',
            'target_name': 'Target_Name',
            'comment': 'Comment',
            'group': 'Group'
        }
        writer.writerow(header_row)
        
        # 写入数据
        writer.writerows(data)

def print_statistics(data, config_parser=None, groups=None):
    """打印统计信息"""
    total_links = len(data)
    down_data = [item for item in data if item['status'] == 'Down']
    down_links = len(down_data)
    up_links = total_links - down_links
    
    print(f"\n=== 总体统计信息 ===")
    print(f"  总连接数：{total_links}")
    print(f"  正常连接：{up_links}")
    print(f"  Down连接：{down_links}")
    
    if down_links > 0:
        print(f"  Down连接占比：{down_links/total_links*100:.1f}%")
    
    # 按组统计
    if config_parser:
        target_groups = groups if groups else config_parser.get_groups()
        
        print(f"\n=== 按组统计信息 ===")
        for group_name in target_groups:
            group_data = [item for item in data if item.get('group') == group_name]
            group_down = [item for item in group_data if item['status'] == 'Down']
            port_range = config_parser.get_port_range(group_name)
            
            range_str = f" (端口范围: {port_range[0]}-{port_range[1]})" if port_range else ""
            print(f"  [{group_name}]{range_str}:")
            print(f"    总连接: {len(group_data)}, 正常: {len(group_data) - len(group_down)}, Down: {len(group_down)}")
            
            if group_down:
                # 按设备统计Down端口
                down_by_device = defaultdict(list)
                for item in group_down:
                    down_by_device[item['source_name']].append(item['source_port'])
                
                for device, ports in down_by_device.items():
                    ports_str = ', '.join(sorted(ports, key=int))
                    print(f"      {device}: 端口 {ports_str}")

def main():
    # 命令行参数解析
    parser = argparse.ArgumentParser(description='IB LinkInfo Parser - 解析InfiniBand链路信息')
    parser.add_argument('ca_name', nargs='?', help='CA名称 (例如: mlx5_4)')
    parser.add_argument('-o', '--output', help='输出文件名前缀 (默认: ib_linkinfo)')
    parser.add_argument('-c', '--config', help='配置文件路径 (类似Ansible hosts格式)')
    parser.add_argument('-g', '--groups', nargs='+', help='指定要查询的组名 (多个组用空格分隔)')
    parser.add_argument('--no-down-report', action='store_true', help='不生成Down状态统计表格')
    parser.add_argument('--show-excluded', action='store_true', help='显示被排除的连接信息')
    
    args = parser.parse_args()
    
    # 解析配置文件
    config_parser = None
    if args.config:
        print(f"正在解析配置文件: {args.config}")
        config_parser = HostsConfigParser(args.config)
        print(f"发现组: {', '.join(config_parser.get_groups())}")
        
        if args.groups:
            # 验证指定的组是否存在
            available_groups = config_parser.get_groups()
            invalid_groups = [g for g in args.groups if g not in available_groups]
            if invalid_groups:
                print(f"错误：以下组在配置文件中未找到: {', '.join(invalid_groups)}")
                print(f"可用的组: {', '.join(available_groups)}")
                sys.exit(1)
            print(f"指定查询组: {', '.join(args.groups)}")
    
    # 显示执行信息
    if args.ca_name:
        print(f"正在执行 iblinkinfo -C {args.ca_name} -l --switches-only 命令...")
    else:
        print("正在执行 iblinkinfo -l --switches-only 命令...")
    
    # 获取数据
    output = run_iblinkinfo(args.ca_name)
    
    print("正在处理数据...")
    
    # 解析数据
    parsed_data = []
    for line in output.split('\n'):
        parsed_line = parse_line(line)
        if parsed_line:
            parsed_data.append(parsed_line)
    
    # 根据配置过滤数据
    if config_parser:
        filtered_data, excluded_data = filter_data_by_config(parsed_data, config_parser, args.groups)
        print(f"根据配置过滤后：包含 {len(filtered_data)} 条记录，排除 {len(excluded_data)} 条记录")
    else:
        filtered_data = parsed_data
        excluded_data = []
    
    # 生成输出文件名
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    prefix = args.output if args.output else "ib_linkinfo"
    
    if args.ca_name:
        base_name = f"{prefix}_{args.ca_name}_{timestamp}"
    else:
        base_name = f"{prefix}_{timestamp}"
    
    if args.groups:
        group_suffix = "_".join(args.groups)
        base_name = f"{base_name}_{group_suffix}"
    
    output_file = f"{base_name}.csv"
    down_output_file = f"{base_name}_down.csv"
    excluded_output_file = f"{base_name}_excluded.csv"
    
    # 字段名
    fieldnames = [
        'source_guid', 'source_name', 'source_lid', 'source_port',
        'connection_type', 'speed', 'status', 'target_guid', 'target_lid',
        'target_port', 'target_name', 'comment', 'group'
    ]
    
    # 写入过滤后的数据CSV文件
    write_csv(filtered_data, output_file, fieldnames)
    
    # 分离Down状态数据
    down_data = [item for item in filtered_data if item['status'] == 'Down']
    
    # 生成Down状态统计表格
    if not args.no_down_report and down_data:
        write_csv(down_data, down_output_file, fieldnames)
        print(f"Down状态统计文件：{down_output_file}")
    
    # 生成排除数据文件
    if excluded_data and args.show_excluded:
        write_csv(excluded_data, excluded_output_file, fieldnames)
        print(f"排除的连接文件：{excluded_output_file}")
    
    print("处理完成！")
    print(f"主要数据文件：{output_file}")
    
    # 显示统计信息
    print_statistics(filtered_data, config_parser, args.groups)
    
    # 预览前5行
    print(f"\n=== 前5行数据预览 ===")
    with open(output_file, 'r', encoding='utf-8') as f:
        for i, line in enumerate(f):
            if i >= 6:  # 显示头部+5行数据
                break
            print(f"  {line.rstrip()}")

if __name__ == "__main__":
    main()
