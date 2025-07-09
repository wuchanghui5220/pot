package main

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// PortRange 端口范围结构
type PortRange struct {
	Start int
	End   int
}

// HostsConfigParser 配置解析器
type HostsConfigParser struct {
	ConfigFile       string
	Groups           map[string][]string
	PortRanges       map[string]*PortRange
	GuidPortRanges   map[string]*PortRange
}

// LinkInfo 链路信息结构
type LinkInfo struct {
	SourceGuid     string
	SourceName     string
	SourceLid      string
	SourcePort     string
	ConnectionType string
	Speed          string
	Status         string
	TargetGuid     string
	TargetLid      string
	TargetPort     string
	TargetName     string
	Comment        string
	Group          string
}

// NewHostsConfigParser 创建新的配置解析器
func NewHostsConfigParser(configFile string) (*HostsConfigParser, error) {
	parser := &HostsConfigParser{
		ConfigFile:     configFile,
		Groups:         make(map[string][]string),
		PortRanges:     make(map[string]*PortRange),
		GuidPortRanges: make(map[string]*PortRange),
	}

	err := parser.parseConfig()
	if err != nil {
		return nil, err
	}

	return parser, nil
}

// parseConfig 解析配置文件
func (p *HostsConfigParser) parseConfig() error {
	file, err := os.Open(p.ConfigFile)
	if err != nil {
		return fmt.Errorf("无法打开配置文件 %s: %v", p.ConfigFile, err)
	}
	defer file.Close()

	var lines []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("读取配置文件失败: %v", err)
	}

	// 第一遍解析：解析所有基本组和GUID
	var currentGroup string
	var currentPortRange *PortRange

	for _, line := range lines {
		line = strings.TrimSpace(line)

		// 跳过空行和注释
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// 检查是否是组定义
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			groupDef := line[1 : len(line)-1]

			// 检查是否是children组，如果是则跳过第一遍处理
			if strings.HasSuffix(groupDef, ":children") {
				continue
			}

			// 解析端口范围 (例如: leaf:33-64)
			if strings.Contains(groupDef, ":") {
				parts := strings.SplitN(groupDef, ":", 2)
				currentGroup = parts[0]
				portRange := parts[1]

				// 解析端口范围
				if strings.Contains(portRange, "-") {
					rangeParts := strings.SplitN(portRange, "-", 2)
					startPort, err1 := strconv.Atoi(rangeParts[0])
					endPort, err2 := strconv.Atoi(rangeParts[1])
					if err1 != nil || err2 != nil {
						fmt.Printf("警告：无效的端口范围格式 '%s'，将使用全部端口\n", portRange)
						currentPortRange = nil
					} else {
						currentPortRange = &PortRange{Start: startPort, End: endPort}
					}
				} else {
					portNum, err := strconv.Atoi(portRange)
					if err != nil {
						fmt.Printf("警告：无效的端口范围格式 '%s'，将使用全部端口\n", portRange)
						currentPortRange = nil
					} else {
						currentPortRange = &PortRange{Start: 1, End: portNum}
					}
				}
			} else {
				currentGroup = groupDef
				currentPortRange = nil
			}

			// 初始化组
			if _, exists := p.Groups[currentGroup]; !exists {
				p.Groups[currentGroup] = []string{}
			}

			// 设置端口范围
			if currentPortRange != nil {
				p.PortRanges[currentGroup] = currentPortRange
			}

			continue
		}

		// 检查是否是GUID
		if strings.HasPrefix(line, "0x") && currentGroup != "" {
			guid := strings.ToLower(line)
			p.Groups[currentGroup] = append(p.Groups[currentGroup], guid)
			// 为每个GUID记录其端口范围
			if currentPortRange != nil {
				p.GuidPortRanges[guid] = currentPortRange
			}
		}
	}

	// 第二遍解析：处理children组
	currentGroup = ""
	for _, line := range lines {
		line = strings.TrimSpace(line)

		// 跳过空行和注释
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// 检查是否是children组定义
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			groupDef := line[1 : len(line)-1]

			if strings.HasSuffix(groupDef, ":children") {
				currentGroup = groupDef[:len(groupDef)-9] // 去掉 ':children'
				// 初始化组（如果不存在）
				if _, exists := p.Groups[currentGroup]; !exists {
					p.Groups[currentGroup] = []string{}
				}
				continue
			} else {
				currentGroup = ""
				continue
			}
		}

		// 处理子组引用
		if currentGroup != "" && contains(p.GetGroups(), line) {
			// 将子组的GUID添加到父组
			if childGuids, exists := p.Groups[line]; exists {
				p.Groups[currentGroup] = append(p.Groups[currentGroup], childGuids...)
				fmt.Printf("  将组 '%s' 添加到父组 '%s' (%d 个设备)\n", line, currentGroup, len(childGuids))
			}
		}
	}

	return nil
}

// GetGroups 获取所有组
func (p *HostsConfigParser) GetGroups() []string {
	var groups []string
	for group := range p.Groups {
		groups = append(groups, group)
	}
	return groups
}

// GetGroupGuids 获取指定组的GUID列表
func (p *HostsConfigParser) GetGroupGuids(groupName string) []string {
	if guids, exists := p.Groups[groupName]; exists {
		return guids
	}
	return []string{}
}

// GetPortRange 获取指定组的端口范围
func (p *HostsConfigParser) GetPortRange(groupName string) *PortRange {
	return p.PortRanges[groupName]
}

// GetPortRangeForGuid 获取指定GUID的端口范围
func (p *HostsConfigParser) GetPortRangeForGuid(guid string) *PortRange {
	return p.GuidPortRanges[strings.ToLower(guid)]
}

// GetAllGuids 获取所有GUID
func (p *HostsConfigParser) GetAllGuids() []string {
	guidSet := make(map[string]bool)
	for _, guids := range p.Groups {
		for _, guid := range guids {
			guidSet[guid] = true
		}
	}

	var allGuids []string
	for guid := range guidSet {
		allGuids = append(allGuids, guid)
	}
	return allGuids
}

// runIblinkinfo 执行 iblinkinfo 命令
func runIblinkinfo(caName string) (string, error) {
	var cmd *exec.Cmd
	if caName != "" {
		cmd = exec.Command("iblinkinfo", "-C", caName, "-l", "--switches-only")
		fmt.Printf("执行命令: iblinkinfo -C %s -l --switches-only\n", caName)
	} else {
		cmd = exec.Command("iblinkinfo", "-l", "--switches-only")
		fmt.Printf("执行命令: iblinkinfo -l --switches-only\n")
	}

	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("执行 iblinkinfo 命令失败: %v", err)
	}

	return string(output), nil
}

// readFromFile 从文件读取 iblinkinfo 输出
func readFromFile(filename string) (string, error) {
	content, err := os.ReadFile(filename)
	if err != nil {
		return "", fmt.Errorf("读取文件 %s 失败: %v", filename, err)
	}

	fmt.Printf("从文件读取数据: %s\n", filename)
	return string(content), nil
}

// parseLine 解析单行数据
func parseLine(line string) *LinkInfo {
	// 跳过空行
	if strings.TrimSpace(line) == "" {
		return nil
	}

	// 跳过包含 "Mellanox Technologies Aggregation Node" 的行
	if strings.Contains(line, "Mellanox Technologies Aggregation Node") {
		return nil
	}

	// 基本信息正则表达式
	basicPattern := regexp.MustCompile(`^(0x[a-f0-9]+)\s+"([^"]+)"\s+(\d+)\s+(\d+)`)
	basicMatch := basicPattern.FindStringSubmatch(line)

	if len(basicMatch) < 5 {
		return nil
	}

	sourceGuid := strings.ToLower(basicMatch[1])
	sourceName := strings.TrimSpace(basicMatch[2])
	sourceLid := basicMatch[3]
	sourcePort := basicMatch[4]

	// 检查是否为Down状态
	if strings.Contains(line, "Down") || strings.Contains(line, "Polling") {
		return &LinkInfo{
			SourceGuid:     sourceGuid,
			SourceName:     sourceName,
			SourceLid:      sourceLid,
			SourcePort:     sourcePort,
			ConnectionType: "N/A",
			Speed:          "N/A",
			Status:         "Down",
			TargetGuid:     "N/A",
			TargetLid:      "N/A",
			TargetPort:     "N/A",
			TargetName:     "N/A",
			Comment:        "N/A",
			Group:          "Unknown",
		}
	}

	// 处理LinkUp状态
	if strings.Contains(line, "LinkUp") && strings.Contains(line, "Active") {
		// 提取连接信息
		connectionType := "N/A"
		speed := "N/A"
		targetGuid := "N/A"
		targetLid := "N/A"
		targetPort := "N/A"
		targetName := "N/A"
		comment := "N/A"

		// 提取速度信息
		speedPattern := regexp.MustCompile(`(4X\s+[\d.]+\s*Gbps)`)
		speedMatch := speedPattern.FindStringSubmatch(line)
		if len(speedMatch) > 1 {
			speed = strings.TrimSpace(speedMatch[1])
			connectionType = "4X"
		}

		// 提取目标设备信息
		targetPattern := regexp.MustCompile(`==>\s*(0x[a-f0-9]+)\s+(\d+)\s+(\d+)\[\s*\]\s*"([^"]*)"`)
		targetMatch := targetPattern.FindStringSubmatch(line)
		if len(targetMatch) > 4 {
			targetGuid = strings.ToLower(targetMatch[1])
			targetLid = targetMatch[2]
			targetPort = targetMatch[3]
			targetName = strings.TrimSpace(targetMatch[4])
		}

		// 提取注释
		commentPattern := regexp.MustCompile(`\(\s*([^)]*)\s*\)\s*$`)
		commentMatch := commentPattern.FindStringSubmatch(line)
		if len(commentMatch) > 1 {
			comment = strings.TrimSpace(commentMatch[1])
		}

		return &LinkInfo{
			SourceGuid:     sourceGuid,
			SourceName:     sourceName,
			SourceLid:      sourceLid,
			SourcePort:     sourcePort,
			ConnectionType: connectionType,
			Speed:          speed,
			Status:         "LinkUp",
			TargetGuid:     targetGuid,
			TargetLid:     targetLid,
			TargetPort:     targetPort,
			TargetName:     targetName,
			Comment:        comment,
			Group:          "Unknown",
		}
	}

	return nil
}

// filterDataByConfig 根据配置过滤数据
func filterDataByConfig(data []*LinkInfo, configParser *HostsConfigParser, targetGroups []string) ([]*LinkInfo, []*LinkInfo) {
	if configParser == nil {
		return data, []*LinkInfo{}
	}

	var filteredData []*LinkInfo
	var excludedData []*LinkInfo

	// 确定要处理的组
	var groupsToProcess []string
	if len(targetGroups) > 0 {
		availableGroups := configParser.GetGroups()
		for _, group := range targetGroups {
			if contains(availableGroups, group) {
				groupsToProcess = append(groupsToProcess, group)
			}
		}
		if len(groupsToProcess) == 0 {
			fmt.Printf("警告：指定的组 %v 在配置文件中未找到\n", targetGroups)
			return data, []*LinkInfo{}
		}
	} else {
		groupsToProcess = configParser.GetGroups()
	}

	// 为每个数据项分配组信息
	for _, item := range data {
		itemGuid := strings.ToLower(item.SourceGuid)
		itemPort, err := strconv.Atoi(item.SourcePort)
		if err != nil {
			item.Group = "Unknown"
			excludedData = append(excludedData, item)
			continue
		}

		itemIncluded := false

		// 检查每个要处理的组
		for _, groupName := range groupsToProcess {
			groupGuids := configParser.GetGroupGuids(groupName)

			// 检查GUID是否在组中
			if contains(groupGuids, itemGuid) {
				item.Group = groupName

				// 首先检查GUID特定的端口范围，然后检查组的端口范围
				guidPortRange := configParser.GetPortRangeForGuid(itemGuid)
				groupPortRange := configParser.GetPortRange(groupName)

				// 优先使用GUID特定的端口范围
				var portRange *PortRange
				if guidPortRange != nil {
					portRange = guidPortRange
				} else {
					portRange = groupPortRange
				}

				// 检查端口范围
				if portRange != nil {
					if portRange.Start <= itemPort && itemPort <= portRange.End {
						filteredData = append(filteredData, item)
						itemIncluded = true
						break
					} else {
						// 端口不在范围内，排除
						excludedData = append(excludedData, item)
						itemIncluded = true
						break
					}
				} else {
					// 没有端口范围限制，包含所有端口
					filteredData = append(filteredData, item)
					itemIncluded = true
					break
				}
			}
		}

		// 如果没有找到匹配的组，标记为未知
		if !itemIncluded {
			item.Group = "Unknown"
			excludedData = append(excludedData, item)
		}
	}

	return filteredData, excludedData
}

// writeCSV 写入CSV文件
func writeCSV(data []*LinkInfo, filename string) error {
	file, err := os.Create(filename)
	if err != nil {
		return fmt.Errorf("创建文件 %s 失败: %v", filename, err)
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	// 写入头部
	headers := []string{
		"Source_GUID", "Source_Name", "Source_LID", "Source_Port",
		"Connection_Type", "Speed", "Status", "Target_GUID", "Target_LID",
		"Target_Port", "Target_Name", "Comment", "Group",
	}
	if err := writer.Write(headers); err != nil {
		return fmt.Errorf("写入CSV头部失败: %v", err)
	}

	// 写入数据
	for _, item := range data {
		record := []string{
			item.SourceGuid, item.SourceName, item.SourceLid, item.SourcePort,
			item.ConnectionType, item.Speed, item.Status, item.TargetGuid, item.TargetLid,
			item.TargetPort, item.TargetName, item.Comment, item.Group,
		}
		if err := writer.Write(record); err != nil {
			return fmt.Errorf("写入CSV数据失败: %v", err)
		}
	}

	return nil
}

// printStatistics 打印统计信息
func printStatistics(data []*LinkInfo, configParser *HostsConfigParser, groups []string) {
	totalLinks := len(data)
	downLinks := 0
	for _, item := range data {
		if item.Status == "Down" {
			downLinks++
		}
	}
	upLinks := totalLinks - downLinks

	fmt.Printf("\n=== 总体统计信息 ===\n")
	fmt.Printf("  总连接数：%d\n", totalLinks)
	fmt.Printf("  正常连接：%d\n", upLinks)
	fmt.Printf("  Down连接：%d\n", downLinks)

	if downLinks > 0 {
		fmt.Printf("  Down连接占比：%.1f%%\n", float64(downLinks)/float64(totalLinks)*100)
	}

	// 按组统计
	if configParser != nil {
		var targetGroups []string
		if len(groups) > 0 {
			targetGroups = groups
		} else {
			targetGroups = configParser.GetGroups()
		}

		fmt.Printf("\n=== 按组统计信息 ===\n")
		for _, groupName := range targetGroups {
			var groupData []*LinkInfo
			var groupDown []*LinkInfo
			for _, item := range data {
				if item.Group == groupName {
					groupData = append(groupData, item)
					if item.Status == "Down" {
						groupDown = append(groupDown, item)
					}
				}
			}

			// 对于children组，显示所有子组的端口范围信息
			groupPortRange := configParser.GetPortRange(groupName)

			// 检查是否包含多个不同端口范围的GUID
			guidRanges := make(map[PortRange]bool)
			for _, item := range groupData {
				if guidRange := configParser.GetPortRangeForGuid(item.SourceGuid); guidRange != nil {
					guidRanges[*guidRange] = true
				}
			}

			var rangeStr string
			if len(guidRanges) > 1 {
				// 多个端口范围，显示为混合范围
				var ranges []string
				for r := range guidRanges {
					ranges = append(ranges, fmt.Sprintf("%d-%d", r.Start, r.End))
				}
				sort.Strings(ranges)
				rangeStr = fmt.Sprintf(" (混合端口范围: %s)", strings.Join(ranges, ", "))
			} else if groupPortRange != nil {
				rangeStr = fmt.Sprintf(" (端口范围: %d-%d)", groupPortRange.Start, groupPortRange.End)
			} else if len(guidRanges) == 1 {
				for r := range guidRanges {
					rangeStr = fmt.Sprintf(" (端口范围: %d-%d)", r.Start, r.End)
					break
				}
			}

			fmt.Printf("  [%s]%s:\n", groupName, rangeStr)
			fmt.Printf("    总连接: %d, 正常: %d, Down: %d\n", len(groupData), len(groupData)-len(groupDown), len(groupDown))

			if len(groupDown) > 0 {
				// 按设备统计Down端口
				downByDevice := make(map[string][]string)
				for _, item := range groupDown {
					deviceKey := item.SourceGuid + " " + item.SourceName
					downByDevice[deviceKey] = append(downByDevice[deviceKey], item.SourcePort)
				}

				for deviceKey, ports := range downByDevice {
					// 排序端口号
					sort.Slice(ports, func(i, j int) bool {
						p1, _ := strconv.Atoi(ports[i])
						p2, _ := strconv.Atoi(ports[j])
						return p1 < p2
					})
					portsStr := strings.Join(ports, ", ")
					fmt.Printf("      %s: 端口 %s\n", deviceKey, portsStr)
				}
			}
		}
	}
}

// contains 检查字符串切片是否包含指定字符串
func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

// parseArgs 自定义参数解析函数，支持-C参数
func parseArgs() (caName, output, config, groups, inputFile string, noDownReport, showExcluded, help bool) {
	args := os.Args[1:]

	for i := 0; i < len(args); i++ {
		arg := args[i]

		switch {
		case arg == "-h" || arg == "--help":
			help = true
		case arg == "-o" || arg == "--output":
			if i+1 < len(args) {
				output = args[i+1]
				i++
			}
		case arg == "-c" || arg == "--config":
			if i+1 < len(args) {
				config = args[i+1]
				i++
			}
		case arg == "-C":
			if i+1 < len(args) {
				caName = args[i+1]
				i++
			}
		case arg == "-g" || arg == "--groups":
			if i+1 < len(args) {
				groups = args[i+1]
				i++
			}
		case arg == "-f" || arg == "--file":
			if i+1 < len(args) {
				inputFile = args[i+1]
				i++
			}
		case arg == "--no-down-report":
			noDownReport = true
		case arg == "--show-excluded":
			showExcluded = true
		}
	}

	// 如果没有指定-C参数且也没有-f参数，则默认使用mlx5_0
	if caName == "" && inputFile == "" {
		caName = "mlx5_0"
	}

	return
}

func main() {
	// 自定义参数解析
	caName, output, config, groups, inputFile, noDownReport, showExcluded, help := parseArgs()

	// 处理help
	if help {
		programName := "ibpdc"
		if len(os.Args) > 0 {
			programName = filepath.Base(os.Args[0])
		}

		fmt.Fprintf(os.Stderr, "Author: VincentWu@zhengytech.com\n")
		fmt.Fprintf(os.Stderr, "IB LinkInfo Parser - 解析InfiniBand链路信息\n\n")
		fmt.Fprintf(os.Stderr, "Usage: %s [options]\n\n", programName)
		fmt.Fprintf(os.Stderr, "Options:\n")
		fmt.Fprintf(os.Stderr, "  -h, --help            显示此帮助信息并退出\n")
		fmt.Fprintf(os.Stderr, "  -C CA_NAME            CA名称 (例如: mlx5_4，默认: mlx5_0)\n")
		fmt.Fprintf(os.Stderr, "  -o, --output OUTPUT   输出文件名前缀 (默认: ib_linkinfo)\n")
		fmt.Fprintf(os.Stderr, "  -c, --config CONFIG   配置文件路径 (类似Ansible hosts格式)\n")
		fmt.Fprintf(os.Stderr, "  -g, --groups GROUPS   指定要查询的组名 (多个组用空格分隔)\n")
		fmt.Fprintf(os.Stderr, "  -f, --file FILE       从指定文件读取iblinkinfo输出结果\n")
		fmt.Fprintf(os.Stderr, "  --no-down-report      不生成Down状态统计表格\n")
		fmt.Fprintf(os.Stderr, "  --show-excluded       显示被排除的连接信息\n")
		os.Exit(0)
	}

	// 调试信息
	fmt.Printf("调试: caName='%s', config='%s', groups='%s', inputFile='%s'\n", caName, config, groups, inputFile)

	// 检查参数冲突
	if inputFile != "" && caName != "" {
		fmt.Fprintf(os.Stderr, "错误：-f 和 -C 参数不能同时使用\n")
		os.Exit(1)
	}

	// 解析配置文件
	var configParser *HostsConfigParser
	if config != "" {
		fmt.Printf("正在解析配置文件: %s\n", config)
		var err error
		configParser, err = NewHostsConfigParser(config)
		if err != nil {
			fmt.Fprintf(os.Stderr, "错误：%v\n", err)
			os.Exit(1)
		}
		fmt.Printf("发现组: %s\n", strings.Join(configParser.GetGroups(), ", "))

		if groups != "" {
			// 验证指定的组是否存在
			groupList := strings.Fields(groups)
			availableGroups := configParser.GetGroups()
			var invalidGroups []string
			for _, g := range groupList {
				if !contains(availableGroups, g) {
					invalidGroups = append(invalidGroups, g)
				}
			}
			if len(invalidGroups) > 0 {
				fmt.Fprintf(os.Stderr, "错误：以下组在配置文件中未找到: %s\n", strings.Join(invalidGroups, ", "))
				fmt.Fprintf(os.Stderr, "可用的组: %s\n", strings.Join(availableGroups, ", "))
				os.Exit(1)
			}
			fmt.Printf("指定查询组: %s\n", strings.Join(groupList, ", "))
		}
	} else if groups != "" {
		fmt.Fprintf(os.Stderr, "警告：指定了组参数但未提供配置文件，将忽略组过滤\n")
	}

	// 获取数据
	var outputData string
	var err error
	if inputFile != "" {
		outputData, err = readFromFile(inputFile)
	} else {
		outputData, err = runIblinkinfo(caName)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "错误：%v\n", err)
		os.Exit(1)
	}

	fmt.Println("正在处理数据...")

	// 解析数据
	var parsedData []*LinkInfo
	lines := strings.Split(outputData, "\n")
	for _, line := range lines {
		if parsed := parseLine(line); parsed != nil {
			parsedData = append(parsedData, parsed)
		}
	}

	// 根据配置过滤数据
	var filteredData, excludedData []*LinkInfo
	var targetGroups []string
	if groups != "" {
		targetGroups = strings.Fields(groups)
	}

	if configParser != nil {
		filteredData, excludedData = filterDataByConfig(parsedData, configParser, targetGroups)
		fmt.Printf("根据配置过滤后：包含 %d 条记录，排除 %d 条记录\n", len(filteredData), len(excludedData))
	} else {
		filteredData = parsedData
		excludedData = []*LinkInfo{}
	}

	// 生成输出文件名
	timestamp := time.Now().Format("20060102_150405")
	prefix := "ib_linkinfo"
	if output != "" {
		prefix = output
	}

	var baseName string
	if inputFile != "" {
		fileBasename := strings.TrimSuffix(filepath.Base(inputFile), filepath.Ext(inputFile))
		baseName = fmt.Sprintf("%s_%s_%s", prefix, fileBasename, timestamp)
	} else if caName != "" {
		baseName = fmt.Sprintf("%s_%s_%s", prefix, caName, timestamp)
	} else {
		baseName = fmt.Sprintf("%s_%s", prefix, timestamp)
	}

	if groups != "" {
		groupSuffix := strings.ReplaceAll(groups, " ", "_")
		baseName = fmt.Sprintf("%s_%s", baseName, groupSuffix)
	}

	outputFile := fmt.Sprintf("%s.csv", baseName)
	downOutputFile := fmt.Sprintf("%s_down.csv", baseName)
	excludedOutputFile := fmt.Sprintf("%s_excluded.csv", baseName)

	// 写入过滤后的数据CSV文件
	if err := writeCSV(filteredData, outputFile); err != nil {
		fmt.Fprintf(os.Stderr, "错误：%v\n", err)
		os.Exit(1)
	}

	// 分离Down状态数据
	var downData []*LinkInfo
	for _, item := range filteredData {
		if item.Status == "Down" {
			downData = append(downData, item)
		}
	}

	// 生成Down状态统计表格
	if !noDownReport && len(downData) > 0 {
		if err := writeCSV(downData, downOutputFile); err != nil {
			fmt.Fprintf(os.Stderr, "错误：%v\n", err)
			os.Exit(1)
		}
		fmt.Printf("Down状态统计文件：%s\n", downOutputFile)
	}

	// 生成排除数据文件
	if len(excludedData) > 0 && showExcluded {
		if err := writeCSV(excludedData, excludedOutputFile); err != nil {
			fmt.Fprintf(os.Stderr, "错误：%v\n", err)
			os.Exit(1)
		}
		fmt.Printf("排除的连接文件：%s\n", excludedOutputFile)
	}

	fmt.Println("处理完成！")
	fmt.Printf("主要数据文件：%s\n", outputFile)

	// 显示统计信息
	printStatistics(filteredData, configParser, targetGroups)
}
