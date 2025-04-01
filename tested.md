# InfiniBand Network Health Report
Generated on: 2025-04-01 12:17:16
Source log: ibdiagnet2.log
Scan timestamp: 2025-03-01 12:19:52 CST +0800


## Executive Summary
**Network Health Status**: ⚠️ **CRITICAL ISSUES DETECTED**
* **Total Errors**: 32
* **Total Warnings**: 111874

### Critical Issues
#### 🔥 High Temperature Alerts
The following cables have reported high temperature conditions:
* Sfc6a1c030047ee80/Nfc6a1c030047ee80/P1/27/2 - Cable High Temperature detected, current temperature: 54C, threshold: 0C
* Sfc6a1c03006ff580/Nfc6a1c03006ff580/P1/13/1 - Cable High Temperature Alarm reported, current temperature: 64C, threshold: 80C

#### 🔌 Port Counter Errors
The following ports have reported counter errors:
* Sfc6a1c03009be0c0/Nfc6a1c03009be0c0/P1/3/1 - "link_down_counter" increased during the run (difference value=1,difference allowed threshold=1)
* Sfc6a1c0300b00580/Nfc6a1c0300b00580/P1/5/1 - "symbol_error_counter" increased during the run (difference value=27,difference allowed threshold=1)

## Network Topology Overview
* **Total Nodes**: 6003
* **IB Switches**: 480
* **IB Channel Adapters**: 5043
* **Total Links**: 15735

### Link Speeds
* Links at 4x100: 15735

### Subnet Managers
| Type | LID | GUID | Priority | Description |
|------|-----|------|----------|-------------|
| Master | 1 | 0xa088c203005b270c | 15 | ufm-10-43-30-16 mlx5_2 |
| Standby | 7811 | 0xa088c20300e6d550 | 0 | 10-43-3-102 mlx5_0 |
| Standby | 514 | 0xa088c20300e56a4e | 0 | 10-43-3-102 mlx5_1 |
| Standby | 1005 | 0xa088c20300e56dd6 | 0 | 10-43-3-102 mlx5_2 |
| Standby | 1199 | 0xa088c20300e56c16 | 0 | 10-43-3-102 mlx5_4 |
| Standby | 1081 | 0xa088c20300e56c36 | 0 | 10-43-3-102 mlx5_3 |
| Standby | 314 | 0xa088c20300e5697e | 0 | 10-43-3-102 mlx5_5 |
| Standby | 832 | 0xa088c20300e56a0e | 0 | 10-43-3-102 mlx5_7 |
| Standby | 468 | 0xa088c20300e569f6 | 0 | 10-43-3-102 mlx5_6 |

### Routing Configuration
* Adaptive Routing is enabled on 480 switches
* Hashed Based Forwarding is enabled on 480 switches

## Firmware Issues
**Total firmware outdated devices**: 10

### Firmware Issues by Device Type
| Device ID | Count |
|-----------|-------|
| 4129 | 4 |
| 54002 | 1 |
| other | 5 |

### Sample Firmware Issues
* ufm-10-43-30-16/mlx5_2 - Node with Devid:4129(0x1021),PSID:MT_0000000838 has FW version 28.39.3004 while the latest FW version for the same Devid/PSID on this fabric is 28.43.2026
* Sfc6a1c0300afd140/Nfc6a1c0300afd140 - Node with Devid:54002(0xd2f2),PSID:MT_0000000579 has FW version 31.2012.2224 while the latest FW version for the same Devid/PSID on this fabric is 31.2014.2126
* 10-43-2-214/mlx5_0 - Node with Devid:4129(0x1021),PSID:MT_0000000838 has FW version 28.36.1010 while the latest FW version for the same Devid/PSID on this fabric is 28.43.2026
* 10-43-2-226/mlx5_0 - Node with Devid:4129(0x1021),PSID:MT_0000000838 has FW version 28.41.1000 while the latest FW version for the same Devid/PSID on this fabric is 28.43.2026
* 10-43-2-240/mlx5_0 - Node with Devid:4129(0x1021),PSID:MT_0000000838 has FW version 28.36.1010 while the latest FW version for the same Devid/PSID on this fabric is 28.43.2026
* ... and 5 more firmware issues

## Cable Issues
**Total cable issues**: 5

### Other Cable Issues
* 10-43-1-147/mlx5_6/B8D0F0/0/0 - No response for MAD SMPCableInfo
* 10-43-1-148/mlx5_6/B8D0F0/0/0 - No response for MAD SMPCableInfo
* 10-43-1-134/mlx5_6/B8D0F0/0/0 - No response for MAD SMPCableInfo
* 10-43-1-133/mlx5_0/B8D0F0/0/0 - No response for MAD SMPCableInfo
* 10-43-1-136/mlx5_6/B8D0F0/0/0 - No response for MAD SMPCableInfo

## Rail Connectivity Issues
**Total rail connectivity issues**: 5
* Node rail connectivity mismatch by HI source on the switch: "PHRZ_A01_503-1-07 Core01-01" GUID=0xfc6a1c0300962b00
* Node rail connectivity mismatch by HI source on the switch: "PHRZ_A01_203-1-09 Pod2-Leaf14-1" GUID=0xfc6a1c0300700c40
* Node rail connectivity mismatch by HI source on the switch: "PHRZ_A01_203-1-09 Pod2-Leaf14-2" GUID=0xfc6a1c03006feb00
* Node rail connectivity mismatch by HI source on the switch: "PHRZ_A01_203-1-08 Pod2-Leaf13-5" GUID=0xfc6a1c03009a1800
* Node rail connectivity mismatch by HI source on the switch: "PHRZ_A01_203-1-08 Pod2-Leaf13-6" GUID=0xfc6a1c03007cf740

## Detailed Test Results
| Test Stage | Warnings | Errors |
|------------|----------|--------|
| Port Counters | 0 | 30 |
| Cable Report | 10338 | 2 |
| Phy Diagnostic (Plugin) | 95203 | 0 |
| Cable Diagnostic (Plugin) | 5238 | 0 |
| Nodes Information | 1088 | 0 |
| Rail Optimized Topology Validation | 5 | 0 |
| Congestion Control | 2 | 0 |
| Discovery | 0 | 0 |
| Lids Check | 0 | 0 |
| Links Check | 0 | 0 |
| Subnet Manager | 0 | 0 |
| Speed / Width checks | 0 | 0 |
| Virtualization | 0 | 0 |
| Partition Keys | 0 | 0 |
| Temperature Sensing | 0 | 0 |
| Routers | 0 | 0 |
| SHARP | 0 | 0 |
| Routing | 0 | 0 |
| Post Reports Generation | 0 | 0 |
| **TOTAL** | **111874** | **32** |

## Recommendations
* 🔥 **Urgent**: Address high temperature issues in cables - check cooling and airflow in the affected areas.
* 🔌 **High Priority**: Investigate ports with counter errors - may indicate faulty cables or hardware.
* 📊 **Medium Priority**: Update firmware on all devices to the latest versions to ensure optimal performance and security.
* 📝 **Medium Priority**: Review rail connectivity mismatches - may require topology adjustments for optimal performance.
