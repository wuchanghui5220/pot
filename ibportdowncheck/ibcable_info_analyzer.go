package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

// 配置常量
const (
	DefaultInputFile  = "/var/tmp/ibdiagnet2/ibdiagne2.db_csv"
	DefaultOutputFile = "cable_info_extracted.csv"
	DefaultStatsFile  = "sn_statistics.txt"
)

// 颜色常量
const (
	ColorRed    = "\033[0;31m"
	ColorGreen  = "\033[0;32m"
	ColorYellow = "\033[1;33m"
	ColorBlue   = "\033[0;34m"
	ColorNone   = "\033[0m"
)

// 所需的列
var RequiredColumns = []string{"NodeGuid", "PortGuid", "PortNum", "Source", "Vendor", "OUI", "PN", "SN"}

// 双端口收发器类型
var DualPortPatterns = []string{"SR8", "DR8"}

// SN信息结构
type SNInfo struct {
	Count  int
	PN     string
	Vendor string
}

// 问题SN结构
type ProblemSN struct {
	SN       string
	PN       string
	Vendor   string
	Actual   int
	Expected int
}

// 打印函数
func printInfo(message string) {
	fmt.Printf("%s[INFO]%s %s\n", ColorBlue, ColorNone, message)
}

func printSuccess(message string) {
	fmt.Printf("%s[SUCCESS]%s %s\n", ColorGreen, ColorNone, message)
}

func printWarning(message string) {
	fmt.Printf("%s[WARNING]%s %s\n", ColorYellow, ColorNone, message)
}

func printError(message string) {
	fmt.Printf("%s[ERROR]%s %s\n", ColorRed, ColorNone, message)
}

// 检查是否为双端口收发器
func isDualPortTransceiver(pn string) bool {
	for _, pattern := range DualPortPatterns {
		if strings.Contains(pn, pattern) {
			return true
		}
	}
	return false
}

// 清理字段内容（去除引号和空格）
func cleanField(field string) string {
	field = strings.TrimSpace(field)
	field = strings.Trim(field, `"`)
	return field
}

// 提取CABLE_INFO数据
func extractCableInfo(inputFile string) ([]string, error) {
	printInfo("开始提取CABLE_INFO数据...")

	file, err := os.Open(inputFile)
	if err != nil {
		return nil, fmt.Errorf("无法打开文件: %v", err)
	}
	defer file.Close()

	var cableLines []string
	inCableSection := false
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.Contains(line, "START_CABLE_INFO") {
			inCableSection = true
			continue
		} else if strings.Contains(line, "END_CABLE_INFO") {
			break
		} else if inCableSection {
			cableLines = append(cableLines, line)
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("读取文件时出错: %v", err)
	}

	if len(cableLines) == 0 {
		return nil, fmt.Errorf("未找到CABLE_INFO数据或数据为空")
	}

	printSuccess(fmt.Sprintf("成功提取CABLE_INFO数据，共 %d 行", len(cableLines)))
	return cableLines, nil
}

// 过滤所需列并保存为CSV
func filterAndSaveColumns(cableLines []string, outputFile string) ([][]string, error) {
	printInfo(fmt.Sprintf("过滤所需列: %s", strings.Join(RequiredColumns, ", ")))

	if len(cableLines) == 0 {
		return nil, fmt.Errorf("没有数据可处理")
	}

	// 解析表头
	headerLine := cableLines[0]
	headers := strings.Split(headerLine, ",")
	for i, header := range headers {
		headers[i] = cleanField(header)
	}

	// 找到所需列的索引
	columnIndices := make(map[string]int)
	var missingColumns []string

	for _, col := range RequiredColumns {
		found := false
		for i, header := range headers {
			if header == col {
				columnIndices[col] = i
				found = true
				break
			}
		}
		if !found {
			missingColumns = append(missingColumns, col)
		}
	}

	if len(missingColumns) > 0 {
		printWarning(fmt.Sprintf("以下列在数据中未找到: %s", strings.Join(missingColumns, ", ")))
		printInfo(fmt.Sprintf("可用的列: %s", strings.Join(headers, ", ")))
	}

	// 提取数据
	var extractedData [][]string

	// 添加表头
	extractedData = append(extractedData, RequiredColumns)

	// 处理数据行
	for i := 1; i < len(cableLines); i++ {
		line := strings.TrimSpace(cableLines[i])
		if line == "" {
			continue
		}

		row := strings.Split(line, ",")
		for j, cell := range row {
			row[j] = cleanField(cell)
		}

		// 提取所需列的数据
		var extractedRow []string
		for _, col := range RequiredColumns {
			if idx, exists := columnIndices[col]; exists && idx < len(row) {
				extractedRow = append(extractedRow, row[idx])
			} else {
				extractedRow = append(extractedRow, "")
			}
		}

		extractedData = append(extractedData, extractedRow)
	}

	// 保存到CSV文件
	file, err := os.Create(outputFile)
	if err != nil {
		return nil, fmt.Errorf("无法创建输出文件: %v", err)
	}
	defer file.Close()

	writer := csv.NewWriter(file)
	defer writer.Flush()

	for _, record := range extractedData {
		if err := writer.Write(record); err != nil {
			return nil, fmt.Errorf("写入CSV文件时出错: %v", err)
		}
	}

	printSuccess(fmt.Sprintf("数据已保存到: %s", outputFile))
	return extractedData, nil
}

// 显示详细记录
func showDetailedRecords(data [][]string, problemSNs []ProblemSN) {
	if len(problemSNs) == 0 {
		return
	}

	// 获取SN列索引
	snIdx := -1
	for i, header := range data[0] {
		if header == "SN" {
			snIdx = i
			break
		}
	}

	if snIdx == -1 {
		printError("找不到SN列用于显示详细记录")
		return
	}

	for _, item := range problemSNs {
		fmt.Printf("\nSN %s 的所有记录:\n", item.SN)

		// 查找所有匹配的记录
		var matchingRecords [][]string
		for i := 1; i < len(data); i++ {
			if len(data[i]) > snIdx {
				rowSN := cleanField(data[i][snIdx])
				targetSN := cleanField(item.SN)
				if rowSN == targetSN {
					matchingRecords = append(matchingRecords, data[i])
				}
			}
		}

		if len(matchingRecords) == 0 {
			fmt.Println("  未找到匹配的记录")
			continue
		}

		// 显示表头
		fmt.Printf("%-4s %-20s %-20s %-6s %-12s %-8s %-8s %-16s %-14s\n",
			"No.", "NodeGuid", "PortGuid", "Port", "Source", "Vendor", "OUI", "PN", "SN")
		fmt.Println(strings.Repeat("-", 110))

		// 显示每条记录
		uniqueNodes := make(map[string]bool)
		uniquePorts := make(map[string]bool)

		for i, row := range matchingRecords {
			// 确保有足够的列数据
			for len(row) < 8 {
				row = append(row, "")
			}

			nodeGuid := cleanField(row[0])
			portGuid := cleanField(row[1])
			portNum := cleanField(row[2])
			source := cleanField(row[3])
			vendor := cleanField(row[4])
			oui := cleanField(row[5])
			pn := cleanField(row[6])
			snField := cleanField(row[7])

			// 截断过长的GUID显示
			displayNode := nodeGuid
			if len(nodeGuid) > 18 {
				displayNode = "..." + nodeGuid[len(nodeGuid)-15:]
				uniqueNodes[nodeGuid] = true
			}

			displayPort := portGuid
			if len(portGuid) > 18 {
				displayPort = "..." + portGuid[len(portGuid)-15:]
				uniquePorts[portGuid] = true
			}

			fmt.Printf("%-4d %-20s %-20s %-6s %-12s %-8s %-8s %-16s %-14s\n",
				i+1, displayNode, displayPort, portNum, source, vendor, oui, pn, snField)
		}

		// 显示完整GUID信息
		if len(uniqueNodes) > 0 {
			fmt.Println("\n完整NodeGuid信息:")
			var nodes []string
			for node := range uniqueNodes {
				nodes = append(nodes, node)
			}
			sort.Strings(nodes)
			for i, node := range nodes {
				fmt.Printf("  节点%d: %s\n", i+1, node)
			}
		}

		if len(uniquePorts) > 0 {
			fmt.Println("\n完整PortGuid信息:")
			var ports []string
			for port := range uniquePorts {
				ports = append(ports, port)
			}
			sort.Strings(ports)
			for i, port := range ports {
				fmt.Printf("  端口%d: %s\n", i+1, port)
			}
		}

		fmt.Println(strings.Repeat("-", 110))
	}
}

// 分析SN重复情况
func analyzeSNDuplicates(data [][]string, statsFile string) error {
	printInfo("开始分析SN重复情况（基于收发器类型）...")

	if len(data) < 2 {
		return fmt.Errorf("没有有效数据进行分析")
	}

	// 获取列索引
	headers := data[0]
	snIdx, pnIdx, vendorIdx := -1, -1, -1

	for i, header := range headers {
		switch header {
		case "SN":
			snIdx = i
		case "PN":
			pnIdx = i
		case "Vendor":
			vendorIdx = i
		}
	}

	if snIdx == -1 || pnIdx == -1 || vendorIdx == -1 {
		return fmt.Errorf("找不到必需的列")
	}

	// 统计SN信息
	snInfo := make(map[string]*SNInfo)
	validRecords := 0

	for i := 1; i < len(data); i++ {
		row := data[i]
		maxIdx := max(snIdx, max(pnIdx, vendorIdx))
		if len(row) > maxIdx {
			sn := cleanField(row[snIdx])
			if sn != "" {
				if _, exists := snInfo[sn]; !exists {
					snInfo[sn] = &SNInfo{
						Count:  0,
						PN:     cleanField(row[pnIdx]),
						Vendor: cleanField(row[vendorIdx]),
					}
				}
				snInfo[sn].Count++
				validRecords++
			}
		}
	}

	// 分析问题SN
	var duplicateSNs []ProblemSN
	var incompleteSNs []ProblemSN

	for sn, info := range snInfo {
		expectedCount := 1
		if isDualPortTransceiver(info.PN) {
			expectedCount = 2
		}

		if info.Count > expectedCount {
			duplicateSNs = append(duplicateSNs, ProblemSN{
				SN:       sn,
				PN:       info.PN,
				Vendor:   info.Vendor,
				Actual:   info.Count,
				Expected: expectedCount,
			})
		} else if info.Count < expectedCount {
			incompleteSNs = append(incompleteSNs, ProblemSN{
				SN:       sn,
				PN:       info.PN,
				Vendor:   info.Vendor,
				Actual:   info.Count,
				Expected: expectedCount,
			})
		}
	}

	// 生成报告
	err := generateReport(data, snInfo, duplicateSNs, incompleteSNs, validRecords, statsFile)
	if err != nil {
		return err
	}

	return nil
}

// 生成报告
func generateReport(data [][]string, snInfo map[string]*SNInfo, duplicateSNs, incompleteSNs []ProblemSN, validRecords int, statsFile string) error {
	// 统计收发器类型
	dualPortCount := 0
	singlePortCount := 0
	pnIdx := -1

	for i, header := range data[0] {
		if header == "PN" {
			pnIdx = i
			break
		}
	}

	if pnIdx != -1 {
		for i := 1; i < len(data); i++ {
			if len(data[i]) > pnIdx {
				pn := cleanField(data[i][pnIdx])
				if pn != "" {
					if isDualPortTransceiver(pn) {
						dualPortCount++
					} else {
						singlePortCount++
					}
				}
			}
		}
	}

	totalRecords := len(data) - 1
	uniqueSNs := len(snInfo)
	totalProblems := len(duplicateSNs) + len(incompleteSNs)

	// 写入文件报告
	file, err := os.Create(statsFile)
	if err != nil {
		return fmt.Errorf("无法创建统计文件: %v", err)
	}
	defer file.Close()

	fmt.Fprintf(file, "================== IB收发器SN问题报告 ==================\n")
	fmt.Fprintf(file, "生成时间: %s\n", time.Now().Format("2006-01-02 15:04:05"))
	fmt.Fprintf(file, "分析说明: 双端口收发器(SR8/DR8)正常出现2次，单端口收发器正常出现1次\n\n")

	fmt.Fprintf(file, "📊 总体统计:\n")
	fmt.Fprintf(file, "  总记录数: %d\n", totalRecords)
	fmt.Fprintf(file, "  有效SN数: %d\n", validRecords)
	fmt.Fprintf(file, "  唯一SN数: %d\n\n", uniqueSNs)

	fmt.Fprintf(file, "🔌 收发器类型分布:\n")
	fmt.Fprintf(file, "  双端口收发器(SR8/DR8): %d 条记录\n", dualPortCount)
	fmt.Fprintf(file, "  单端口收发器(其他): %d 条记录\n\n", singlePortCount)

	if totalProblems == 0 {
		fmt.Fprintf(file, "✅ 检查结果: 所有SN都正常，未发现重复或缺失问题\n")
	} else {
		fmt.Fprintf(file, "⚠️  检查结果: 发现 %d 个问题SN\n\n", totalProblems)

		if len(duplicateSNs) > 0 {
			fmt.Fprintf(file, "🚨 物理重复SN (%d 个) - 可能存在重复收发器:\n", len(duplicateSNs))
			fmt.Fprintf(file, "%s\n", strings.Repeat("-", 60))
			fmt.Fprintf(file, "%-18s %-16s %-12s %8s %8s\n", "SN", "PN", "Vendor", "Count", "Expect")
			fmt.Fprintf(file, "%s\n", strings.Repeat("-", 60))

			sort.Slice(duplicateSNs, func(i, j int) bool {
				return duplicateSNs[i].SN < duplicateSNs[j].SN
			})

			for _, item := range duplicateSNs {
				fmt.Fprintf(file, "%-18s %-16s %-12s %8d %8d\n",
					item.SN, item.PN, item.Vendor, item.Actual, item.Expected)
			}
			fmt.Fprintf(file, "\n")
		}

		if len(incompleteSNs) > 0 {
			fmt.Fprintf(file, "⚠️  不完整SN (%d 个) - 可能存在故障或连接问题:\n", len(incompleteSNs))
			fmt.Fprintf(file, "%s\n", strings.Repeat("-", 60))
			fmt.Fprintf(file, "%-18s %-16s %-12s %8s %8s\n", "SN", "PN", "Vendor", "Count", "Expect")
			fmt.Fprintf(file, "%s\n", strings.Repeat("-", 60))

			sort.Slice(incompleteSNs, func(i, j int) bool {
				return incompleteSNs[i].SN < incompleteSNs[j].SN
			})

			for _, item := range incompleteSNs {
				fmt.Fprintf(file, "%-18s %-16s %-12s %8d %8d\n",
					item.SN, item.PN, item.Vendor, item.Actual, item.Expected)
			}
			fmt.Fprintf(file, "\n")
		}

		fmt.Fprintf(file, "💡 提示: 详细的端口信息可在 cable_info_extracted.csv 中查看\n")
	}

	printSuccess(fmt.Sprintf("SN问题报告已保存到: %s", statsFile))

	// 在终端显示摘要和问题详情
	fmt.Println("\n" + strings.Repeat("=", 50))
	fmt.Println("📊 总体统计:")
	fmt.Printf("  总记录数: %d\n", totalRecords)
	fmt.Printf("  有效SN数: %d\n", validRecords)
	fmt.Printf("  唯一SN数: %d\n", uniqueSNs)
	fmt.Println()

	fmt.Println("🔌 收发器类型分布:")
	fmt.Printf("  双端口收发器(SR8/DR8): %d 条记录\n", dualPortCount)
	fmt.Printf("  单端口收发器(其他): %d 条记录\n", singlePortCount)
	fmt.Println()

	fmt.Println("处理摘要:")

	if totalProblems == 0 {
		printSuccess("没有发现物理重复的SN")
	} else {
		if len(duplicateSNs) > 0 {
			printWarning(fmt.Sprintf("发现 %d 个物理重复的SN", len(duplicateSNs)))
			fmt.Println("\n🚨 物理重复SN详情:")
			fmt.Println(strings.Repeat("-", 60))
			fmt.Printf("%-18s %-16s %-12s %-6s %-6s\n", "SN", "PN", "Vendor", "Count", "Expect")
			fmt.Println(strings.Repeat("-", 60))

			for _, item := range duplicateSNs {
				fmt.Printf("%-18s %-16s %-12s %-6d %-6d\n",
					item.SN, item.PN, item.Vendor, item.Actual, item.Expected)
			}

			fmt.Println("\n📋 详细记录信息:")
			showDetailedRecords(data, duplicateSNs)
		}

		if len(incompleteSNs) > 0 {
			printWarning(fmt.Sprintf("发现 %d 个不完整的SN", len(incompleteSNs)))
			fmt.Println("\n⚠️  不完整SN详情:")
			fmt.Println(strings.Repeat("-", 60))
			fmt.Printf("%-18s %-16s %-12s %-6s %-6s\n", "SN", "PN", "Vendor", "Count", "Expect")
			fmt.Println(strings.Repeat("-", 60))

			for _, item := range incompleteSNs {
				fmt.Printf("%-18s %-16s %-12s %-6d %-6d\n",
					item.SN, item.PN, item.Vendor, item.Actual, item.Expected)
			}

			fmt.Println("\n📋 详细记录信息:")
			showDetailedRecords(data, incompleteSNs)
		}
	}

	fmt.Printf("\n生成的文件:\n")
	fmt.Printf("  - 提取数据: %s\n", DefaultOutputFile)
	fmt.Printf("  - SN统计: %s\n", statsFile)

	return nil
}

// max 函数
func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

func main() {
	// 命令行参数
	var inputFile = flag.String("i", DefaultInputFile, "输入文件路径")
	var outputFile = flag.String("o", DefaultOutputFile, "输出CSV文件路径")
	var statsFile = flag.String("s", DefaultStatsFile, "统计报告文件路径")
	flag.Parse()

	fmt.Println("Cable Info提取和SN统计工具 - Go版本")
	fmt.Println(strings.Repeat("=", 50))

	// 提取CABLE_INFO数据
	cableLines, err := extractCableInfo(*inputFile)
	if err != nil {
		printError(err.Error())
		os.Exit(1)
	}

	// 过滤所需列并保存
	data, err := filterAndSaveColumns(cableLines, *outputFile)
	if err != nil {
		printError(err.Error())
		os.Exit(1)
	}

	// 分析SN重复情况
	err = analyzeSNDuplicates(data, *statsFile)
	if err != nil {
		printError(err.Error())
		os.Exit(1)
	}

	printSuccess("处理完成！")
}
