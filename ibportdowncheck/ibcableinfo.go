package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// 颜色定义
const (
	ColorReset  = "\033[0m"
	ColorRed    = "\033[31m"
	ColorGreen  = "\033[32m"
	ColorYellow = "\033[33m"
	ColorBlue   = "\033[34m"
)

// 配置结构
type Config struct {
	DataDir      string
	DataFile     string
	SkipScan     bool
	DebugMode    bool
	CustomFile   string
	ShowHelp     bool
	Interface    string // InfiniBand网卡接口
	EnableHostInfo bool // 是否启用主机信息查询
}

// 统计结构
type PNStats struct {
	PN         string
	Count      int
	Percentage float64
}

// 主机信息缓存
type HostInfoCache struct {
	cache map[string]string
}

func NewHostInfoCache() *HostInfoCache {
	return &HostInfoCache{
		cache: make(map[string]string),
	}
}

// 日志函数
func logInfo(msg string) {
	fmt.Printf("%s[INFO]%s %s\n", ColorBlue, ColorReset, msg)
}

func logSuccess(msg string) {
	fmt.Printf("%s[SUCCESS]%s %s\n", ColorGreen, ColorReset, msg)
}

func logWarning(msg string) {
	fmt.Printf("%s[WARNING]%s %s\n", ColorYellow, ColorReset, msg)
}

func logError(msg string) {
	fmt.Printf("%s[ERROR]%s %s\n", ColorRed, ColorReset, msg)
}

// 显示帮助信息
func showHelp() {
	fmt.Println("用法: cable_analyzer [选项]")
	fmt.Println("")
	fmt.Println("选项:")
	fmt.Println("  -h, --help          显示此帮助信息")
	fmt.Println("  -d, --debug         启用调试模式")
	fmt.Println("  -s, --skip-scan     跳过ibdiagnet扫描，直接使用现有数据文件")
	fmt.Println("  -f, --file FILE     指定数据文件路径")
	fmt.Println("  -i, --interface DEV 指定InfiniBand网卡设备 (默认: mlx5_0)")
	fmt.Println("  --enable-host-info  启用主机信息查询 (通过smpquery获取)")
	fmt.Println("")
	fmt.Println("功能:")
	fmt.Println("  1. 检测ibdiagnet工具是否安装")
	fmt.Println("  2. 运行InfiniBand网络扫描")
	fmt.Println("  3. 提取PHY_DB12数据（端口物理信息）")
	fmt.Println("  4. 提取CABLE_INFO数据并生成统计报告")
	fmt.Println("  5. 通过GUID查询主机信息 (需要--enable-host-info)")
	fmt.Println("")
	fmt.Println("示例:")
	fmt.Println("  cable_analyzer                        # 完整运行（使用mlx5_0）")
	fmt.Println("  cable_analyzer -i mlx5_4              # 使用mlx5_4网卡设备")
	fmt.Println("  cable_analyzer -s                     # 跳过扫描，使用现有数据")
	fmt.Println("  cable_analyzer -d                     # 调试模式")
	fmt.Println("  cable_analyzer -f /path/to/data       # 指定数据文件")
	fmt.Println("  cable_analyzer --enable-host-info     # 启用主机信息查询")
	fmt.Println("  cable_analyzer -i mlx5_4 -d --enable-host-info # 完整功能")
}

// 解析命令行参数
func parseArguments() *Config {
	config := &Config{
		DataDir:   "/var/tmp/ibdiagnet2",
		DataFile:  "/var/tmp/ibdiagnet2/ibdiagnet2.db_csv",
		Interface: "mlx5_0", // 默认网卡设备
	}

	flag.BoolVar(&config.ShowHelp, "h", false, "显示帮助信息")
	flag.BoolVar(&config.ShowHelp, "help", false, "显示帮助信息")
	flag.BoolVar(&config.DebugMode, "d", false, "启用调试模式")
	flag.BoolVar(&config.DebugMode, "debug", false, "启用调试模式")
	flag.BoolVar(&config.SkipScan, "s", false, "跳过扫描")
	flag.BoolVar(&config.SkipScan, "skip-scan", false, "跳过扫描")
	flag.StringVar(&config.CustomFile, "f", "", "指定数据文件")
	flag.StringVar(&config.CustomFile, "file", "", "指定数据文件")
	flag.StringVar(&config.Interface, "i", "mlx5_0", "指定InfiniBand网卡设备")
	flag.StringVar(&config.Interface, "interface", "mlx5_0", "指定InfiniBand网卡设备")
	flag.BoolVar(&config.EnableHostInfo, "enable-host-info", false, "启用主机信息查询")

	flag.Parse()

	if config.CustomFile != "" {
		config.DataFile = config.CustomFile
	}

	return config
}

// 检查smpquery工具
func checkSmpquery() error {
	_, err := exec.LookPath("smpquery")
	if err != nil {
		logWarning("smpquery工具未安装或不在PATH中")
		logWarning("主机信息查询功能将被禁用")
		return err
	}
	return nil
}

// 通过GUID查询主机信息
func (h *HostInfoCache) getHostInfo(guid string, config *Config) string {
	// 检查缓存
	if hostInfo, exists := h.cache[guid]; exists {
		return hostInfo
	}

	// 如果GUID为空，返回空字符串
	if guid == "" {
		h.cache[guid] = ""
		return ""
	}

	if config.DebugMode {
		logInfo(fmt.Sprintf("查询GUID %s 的主机信息", guid))
	}

	// 首先通过smpquery -C <interface> -G nodeinfo获取LID
	cmd := exec.Command("smpquery", "-C", config.Interface, "-G", "nodeinfo", guid)
	output, err := cmd.Output()
	if err != nil {
		if config.DebugMode {
			logWarning(fmt.Sprintf("无法获取GUID %s 的nodeinfo (使用设备 %s): %v", guid, config.Interface, err))
		}
		h.cache[guid] = ""
		return ""
	}

	// 解析输出获取LID
	lidPattern := regexp.MustCompile(`# Node info: Lid (\d+)`)
	matches := lidPattern.FindStringSubmatch(string(output))
	if len(matches) < 2 {
		if config.DebugMode {
			logWarning(fmt.Sprintf("无法从nodeinfo输出中解析LID: %s", guid))
		}
		h.cache[guid] = ""
		return ""
	}

	lid := matches[1]
	if config.DebugMode {
		logInfo(fmt.Sprintf("GUID %s 对应的LID: %s (设备: %s)", guid, lid, config.Interface))
	}

	// 通过LID查询节点描述
	cmd = exec.Command("smpquery", "-C", config.Interface, "nd", lid)
	output, err = cmd.Output()
	if err != nil {
		if config.DebugMode {
			logWarning(fmt.Sprintf("无法获取LID %s 的节点描述 (使用设备 %s): %v", lid, config.Interface, err))
		}
		h.cache[guid] = ""
		return ""
	}

	// 解析节点描述
	ndPattern := regexp.MustCompile(`Node Description:\.*(.+)`)
	matches = ndPattern.FindStringSubmatch(string(output))
	if len(matches) < 2 {
		if config.DebugMode {
			logWarning(fmt.Sprintf("无法从节点描述输出中解析主机信息: LID %s", lid))
		}
		h.cache[guid] = ""
		return ""
	}

	hostInfo := strings.TrimSpace(matches[1])
	h.cache[guid] = hostInfo

	if config.DebugMode {
		logInfo(fmt.Sprintf("GUID %s 的主机信息: %s (通过设备 %s 查询)", guid, hostInfo, config.Interface))
	}

	return hostInfo
}

// 检查ibdiagnet工具
func checkIbdiagnet() error {
	logInfo("检测ibdiagnet工具...")

	_, err := exec.LookPath("ibdiagnet")
	if err != nil {
		logError("ibdiagnet工具未安装或不在PATH中")
		fmt.Println("")
		fmt.Println("请安装InfiniBand诊断工具：")
		fmt.Println("  CentOS/RHEL: yum install infiniband-diags")
		fmt.Println("  Ubuntu/Debian: apt-get install infiniband-diags")
		fmt.Println("  或者安装Mellanox OFED驱动包")
		fmt.Println("")
		return err
	}

	// 检查版本
	cmd := exec.Command("ibdiagnet", "--version")
	output, err := cmd.Output()
	if err == nil {
		version := strings.Split(string(output), "\n")[0]
		logSuccess(fmt.Sprintf("找到ibdiagnet工具: %s", version))
	} else {
		logSuccess("找到ibdiagnet工具")
	}

	// 检查权限
	if os.Geteuid() != 0 {
		logWarning("建议使用root权限运行此程序以获得完整的诊断信息")
	}

	return nil
}

// 运行ibdiagnet扫描
func runIbdiagnetScan(config *Config) error {
	logInfo("开始运行InfiniBand网络扫描...")

	// 创建输出目录
	err := os.MkdirAll(config.DataDir, 0755)
	if err != nil {
		return fmt.Errorf("创建目录失败: %v", err)
	}

	// 构建命令（添加网卡设备参数）
	args := []string{
		"-i", config.Interface, // 指定网卡设备
		"--sc",
		"--extended_speeds", "all",
		"--get_cable_info",
		"--cable_info_disconnected",
		"--get_phy_info",
		"--phy_cable_disconnected",
	}

	if config.DebugMode {
		logInfo(fmt.Sprintf("执行命令: ibdiagnet %s", strings.Join(args, " ")))
		logInfo(fmt.Sprintf("使用网卡设备: %s", config.Interface))
	}

	// 显示等待提示
	done := make(chan bool)
	go func() {
		chars := []string{"-", "\\", "|", "/"}
		i := 0
		for {
			select {
			case <-done:
				return
			default:
				fmt.Printf("\r%s[INFO]%s 正在执行网络扫描，请稍候 %s", ColorBlue, ColorReset, chars[i%4])
				i++
				time.Sleep(300 * time.Millisecond)
			}
		}
	}()

	// 执行扫描
	cmd := exec.Command("ibdiagnet", args...)
	var err2 error
	if config.DebugMode {
		err2 = cmd.Run()
	} else {
		cmd.Stdout = ioutil.Discard
		cmd.Stderr = ioutil.Discard
		err2 = cmd.Run()
	}

	done <- true
	fmt.Print("\r\033[K") // 清除等待提示行

	if err2 != nil {
		logError("ibdiagnet扫描失败")
		if !config.DebugMode {
			logInfo("提示: 使用 --debug 选项查看详细错误信息")
		}
		return err2
	}

	logSuccess("ibdiagnet扫描完成")

	// 检查数据文件
	if fileInfo, err := os.Stat(config.DataFile); err == nil {
		size := float64(fileInfo.Size()) / 1024 / 1024
		logSuccess(fmt.Sprintf("数据文件已生成: %s (%.1fM)", config.DataFile, size))
	} else {
		logError(fmt.Sprintf("数据文件未生成: %s", config.DataFile))
		return fmt.Errorf("数据文件不存在")
	}

	return nil
}

// 查找数据块
func findDataBlock(filename, startMarker, endMarker string) ([][]string, error) {
	file, err := os.Open(filename)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var result [][]string
	scanner := bufio.NewScanner(file)
	inBlock := false
	skipFirst := true

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		if line == startMarker {
			inBlock = true
			skipFirst = true
			continue
		}

		if line == endMarker {
			inBlock = false
			continue
		}

		if inBlock {
			if skipFirst {
				skipFirst = false
				// 这是表头行，直接处理
			}
			// 解析CSV行
			if line != "" {
				reader := csv.NewReader(strings.NewReader(line))
				record, err := reader.Read()
				if err == nil {
					// 清理字段
					for i, field := range record {
						record[i] = strings.TrimSpace(strings.Trim(field, "\""))
					}
					result = append(result, record)
				}
			}
		}
	}

	return result, scanner.Err()
}

// 提取PHY数据
func extractPhyData(config *Config, hostCache *HostInfoCache) error {
	logInfo("提取PHY_DB12数据...")

	data, err := findDataBlock(config.DataFile, "START_PHY_DB12", "END_PHY_DB12")
	if err != nil {
		return err
	}

	if len(data) == 0 {
		logWarning("未找到PHY_DB12数据")
		return nil
	}

	// 生成输出文件名
	timestamp := time.Now().Format("20060102_150405")
	outputFile := fmt.Sprintf("phy_output-%s.csv", timestamp)

	// 查找目标列索引
	header := data[0]
	targetCols := []string{"PortGuid", "NodeGuid", "PortNum", "field23", "field26"}
	newCols := []string{"PortGuid", "NodeGuid", "PortNum", "PartNumber", "SerialNumber"}
	
	// 如果启用主机信息查询，添加主机信息列
	if config.EnableHostInfo {
		newCols = append(newCols, "HostInfo")
	}
	
	colIndices := make(map[string]int)

	for i, col := range header {
		for j, target := range targetCols {
			if col == target {
				colIndices[target] = i
				if config.DebugMode {
					logInfo(fmt.Sprintf("找到PHY列: %s -> %s (索引: %d)", target, newCols[j], i))
				}
			}
		}
	}

	// 创建输出文件
	file, err := os.Create(outputFile)
	if err != nil {
		return err
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	// 写入表头
	writer.Write(newCols)

	// 处理数据行并去重
	seenSerials := make(map[string]bool)
	serialColIdx := colIndices["field26"]
	nodeGuidColIdx := colIndices["NodeGuid"]
	recordCount := 0

	for i := 1; i < len(data); i++ {
		row := data[i]
		if len(row) <= serialColIdx {
			continue
		}

		// 检查SerialNumber去重
		serialNumber := row[serialColIdx]
		if serialNumber != "" && seenSerials[serialNumber] {
			continue
		}
		if serialNumber != "" {
			seenSerials[serialNumber] = true
		}

		// 构建输出行
		outputRow := make([]string, len(targetCols))
		for j, target := range targetCols {
			if idx, ok := colIndices[target]; ok && idx < len(row) {
				outputRow[j] = row[idx]
			}
		}

		// 如果启用主机信息查询，获取主机信息并添加到输出行
		if config.EnableHostInfo {
			var hostInfo string
			if nodeGuidColIdx < len(row) {
				nodeGuid := row[nodeGuidColIdx]
				hostInfo = hostCache.getHostInfo(nodeGuid, config)
			}
			outputRow = append(outputRow, hostInfo)
		}

		writer.Write(outputRow)
		recordCount++
	}

	logSuccess(fmt.Sprintf("PHY数据已保存到: %s (记录数: %d)", outputFile, recordCount))
	return nil
}

// 提取Cable数据并生成统计
func extractCableData(config *Config, hostCache *HostInfoCache) error {
	logInfo("提取CABLE_INFO数据并生成统计报告...")

	data, err := findDataBlock(config.DataFile, "START_CABLE_INFO", "END_CABLE_INFO")
	if err != nil {
		return err
	}

	if len(data) == 0 {
		logWarning("未找到CABLE_INFO数据")
		return nil
	}

	// 生成输出文件名
	timestamp := time.Now().Format("20060102_150405")
	outputFile := fmt.Sprintf("cable_output-%s.csv", timestamp)
	statsFile := fmt.Sprintf("cable_stats-%s.csv", timestamp)

	// 查找目标列索引
	header := data[0]
	baseCols := []string{"PortGuid", "NodeGuid", "PortNum", "PN", "SN"}
	targetCols := make([]string, len(baseCols))
	copy(targetCols, baseCols)
	
	// 如果启用主机信息查询，添加主机信息列
	if config.EnableHostInfo {
		targetCols = append(targetCols, "HostInfo")
	}
	
	colIndices := make(map[string]int)

	for i, col := range header {
		for _, target := range baseCols { // 只在基础列中查找索引
			if col == target {
				colIndices[target] = i
				if config.DebugMode {
					logInfo(fmt.Sprintf("找到CABLE列: %s (索引: %d)", target, i))
				}
			}
		}
	}

	// 创建输出文件
	file, err := os.Create(outputFile)
	if err != nil {
		return err
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	// 写入表头
	writer.Write(targetCols)

	// 处理数据行
	seenSerials := make(map[string]bool)
	pnCount := make(map[string]int)
	snColIdx := colIndices["SN"]
	pnColIdx := colIndices["PN"]
	nodeGuidColIdx := colIndices["NodeGuid"]
	recordCount := 0

	// 如果启用主机信息查询，显示进度
	if config.EnableHostInfo {
		logInfo("正在查询主机信息，这可能需要一些时间...")
	}

	for i := 1; i < len(data); i++ {
		row := data[i]
		if len(row) <= snColIdx || len(row) <= pnColIdx {
			continue
		}

		// 检查SN去重
		serialNumber := row[snColIdx]
		if serialNumber != "" && seenSerials[serialNumber] {
			continue
		}
		if serialNumber != "" {
			seenSerials[serialNumber] = true
		}

		// 统计PN
		pnValue := row[pnColIdx]
		if pnValue != "" {
			pnCount[pnValue]++
		}

		// 构建输出行
		outputRow := make([]string, len(baseCols))
		for j, target := range baseCols {
			if idx, ok := colIndices[target]; ok && idx < len(row) {
				outputRow[j] = row[idx]
			}
		}

		// 如果启用主机信息查询，获取主机信息并添加到输出行
		if config.EnableHostInfo {
			var hostInfo string
			if nodeGuidColIdx < len(row) {
				nodeGuid := row[nodeGuidColIdx]
				hostInfo = hostCache.getHostInfo(nodeGuid, config)
			}
			outputRow = append(outputRow, hostInfo)
		}

		writer.Write(outputRow)
		recordCount++

		// 显示进度
		if config.EnableHostInfo && recordCount%10 == 0 {
			fmt.Printf("\r%s[INFO]%s 已处理 %d 条记录...", ColorBlue, ColorReset, recordCount)
		}
	}

	if config.EnableHostInfo {
		fmt.Print("\r\033[K") // 清除进度显示
	}

	logSuccess(fmt.Sprintf("CABLE数据已保存到: %s (记录数: %d)", outputFile, recordCount))

	// 生成统计报告
	err = generateStats(statsFile, pnCount, recordCount)
	if err != nil {
		logWarning(fmt.Sprintf("统计报告生成失败: %v", err))
		return nil
	}

	logSuccess(fmt.Sprintf("统计报告已保存到: %s", statsFile))

	// 显示统计摘要
	displayStats(statsFile)

	return nil
}

// 生成统计报告
func generateStats(filename string, pnCount map[string]int, totalRecords int) error {
	file, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	// 写入表头
	writer.Write([]string{"PN", "Count", "Percentage"})

	if totalRecords == 0 {
		writer.Write([]string{"NO_DATA", "0", "0.00%"})
		return nil
	}

	// 排序PN
	var pns []string
	for pn := range pnCount {
		pns = append(pns, pn)
	}
	sort.Strings(pns)

	// 写入统计数据
	for _, pn := range pns {
		count := pnCount[pn]
		percentage := float64(count) / float64(totalRecords) * 100
		writer.Write([]string{
			pn,
			strconv.Itoa(count),
			fmt.Sprintf("%.2f%%", percentage),
		})
	}

	// 写入总计
	writer.Write([]string{"TOTAL", strconv.Itoa(totalRecords), "100.00%"})

	return nil
}

// 显示统计摘要
func displayStats(filename string) {
	fmt.Println("")
	logInfo("PN统计摘要:")

	file, err := os.Open(filename)
	if err != nil {
		logWarning("无法读取统计文件")
		return
	}
	defer file.Close()

	reader := csv.NewReader(file)
	records, err := reader.ReadAll()
	if err != nil {
		logWarning("解析统计文件失败")
		return
	}

	if len(records) == 0 {
		logWarning("统计文件为空")
		return
	}

	// 计算列宽
	maxCol1, maxCol2, maxCol3 := 15, 8, 12
	for _, record := range records {
		if len(record) >= 3 {
			if len(record[0]) > maxCol1 {
				maxCol1 = len(record[0])
			}
			if len(record[1]) > maxCol2 {
				maxCol2 = len(record[1])
			}
			if len(record[2]) > maxCol3 {
				maxCol3 = len(record[2])
			}
		}
	}

	// 显示数据
	totalLines := len(records)
	for i, record := range records {
		if len(record) >= 3 {
			// 如果超过20行，在第19行显示省略号，然后跳到最后一行
			if totalLines > 20 && i == 19 && i != totalLines-1 {
				fmt.Printf("  %-*s %-*s %-*s\n", maxCol1, "...", maxCol2, "...", maxCol3, "...")
				// 跳到最后一行
				record = records[totalLines-1]
			} else if totalLines > 20 && i > 19 && i != totalLines-1 {
				continue
			}

			fmt.Printf("  %-*s %-*s %-*s\n", maxCol1, record[0], maxCol2, record[1], maxCol3, record[2])
		}
	}

	if totalLines > 20 {
		fmt.Printf("  (完整内容请查看 %s)\n", filename)
	}
}

// 主函数
func main() {
	config := parseArguments()

	if config.ShowHelp {
		showHelp()
		return
	}

	fmt.Println("")
	logInfo("InfiniBand网络Cable分析工具启动")
	fmt.Println("================================================")

	// 显示配置
	if config.DebugMode {
		logInfo("调试模式已启用")
	}

	logInfo(fmt.Sprintf("使用网卡设备: %s", config.Interface))

	if config.EnableHostInfo {
		logInfo("主机信息查询已启用")
		// 检查smpquery工具
		if err := checkSmpquery(); err != nil {
			logError("主机信息查询功能需要smpquery工具")
			logError("请安装infiniband-diags包或禁用主机信息查询")
			os.Exit(1)
		}
	}

	if config.SkipScan {
		logInfo(fmt.Sprintf("跳过扫描模式，使用现有数据文件: %s", config.DataFile))
	} else {
		logInfo(fmt.Sprintf("数据文件路径: %s", config.DataFile))
	}

	fmt.Println("")

	// 步骤1: 检测ibdiagnet工具
	if err := checkIbdiagnet(); err != nil {
		os.Exit(1)
	}

	fmt.Println("")

	// 步骤2: 运行扫描或检查现有文件
	if config.SkipScan {
		if _, err := os.Stat(config.DataFile); err == nil {
			if fileInfo, err := os.Stat(config.DataFile); err == nil {
				size := float64(fileInfo.Size()) / 1024 / 1024
				logSuccess(fmt.Sprintf("使用现有数据文件: %s (%.1fM)", config.DataFile, size))
			}
		} else {
			logError(fmt.Sprintf("数据文件不存在: %s", config.DataFile))
			logInfo("请先运行完整扫描或指定正确的文件路径")
			os.Exit(1)
		}
	} else {
		if err := runIbdiagnetScan(config); err != nil {
			os.Exit(1)
		}
	}

	fmt.Println("")

	// 创建主机信息缓存
	hostCache := NewHostInfoCache()

	// 步骤3: 提取PHY数据
	if err := extractPhyData(config, hostCache); err != nil {
		logError(fmt.Sprintf("提取PHY数据失败: %v", err))
	}

	fmt.Println("")

	// 步骤4: 提取CABLE数据
	if err := extractCableData(config, hostCache); err != nil {
		logError(fmt.Sprintf("提取CABLE数据失败: %v", err))
	}

	fmt.Println("")
	fmt.Println("================================================")
	logSuccess("所有任务完成！")

	// 显示生成的文件
	fmt.Println("")
	logInfo("生成的文件列表:")
	files, _ := filepath.Glob("phy_output-*.csv")
	cableFiles, _ := filepath.Glob("cable_output-*.csv")
	statsFiles, _ := filepath.Glob("cable_stats-*.csv")

	allFiles := append(files, cableFiles...)
	allFiles = append(allFiles, statsFiles...)

	for _, file := range allFiles {
		if fileInfo, err := os.Stat(file); err == nil {
			size := float64(fileInfo.Size()) / 1024
			fmt.Printf("  %s (%.1fK)\n", file, size)
		}
	}

	// 显示主机信息查询统计
	if config.EnableHostInfo && len(hostCache.cache) > 0 {
		fmt.Println("")
		logInfo(fmt.Sprintf("主机信息查询统计: 共查询了 %d 个GUID", len(hostCache.cache)))
		successCount := 0
		for _, info := range hostCache.cache {
			if info != "" {
				successCount++
			}
		}
		logInfo(fmt.Sprintf("成功获取主机信息: %d 个 (%.1f%%)", successCount, float64(successCount)/float64(len(hostCache.cache))*100))
	}
}
