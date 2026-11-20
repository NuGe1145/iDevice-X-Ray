# iDevice X-Ray

> 探索设备深处，发现更多可能 —— 让每一台 iPhone 都拥有属于自己的「体检报告」

一个完全离线的 iOS / iPadOS 设备体检工具。SwiftUI 编写，无后端、无账号、无网络请求。

**核心理念：读得到就读，读不到就说读不到。** 每一个数值都标注来源与可信度，不用估算值填充界面。

> **侧载专用。** 本 App 通过未公开的 IOKit / HID 接口读取电源轨道与全机温度传感器，
> 这类调用无法通过 App Store 审核，只能自行签名安装。除此之外没有任何越狱或额外权限要求。

---

## 这个 App 到底能干什么

iOS 的沙盒比大多数人想象的严格。宣传里常见的「电池循环次数」「屏幕供应商」，第三方 App 根本拿不到。本项目把数据分成四层，并在 UI 上逐条标注：

| 层级 | 数据来源 | 典型字段 | 可信度 |
|---|---|---|---|
| **实时读取** | 公开 API（UIDevice / sysctl / FileManager） | 机型标识、内存、CPU 核心、分辨率、帧率上限、电量、充电状态、存储容量、热状态、开机时长 | 已验证 |
| **私有接口** | IOKit / HID（`dlsym` 运行期解析） | 全机温度矩阵、USB-C 输入电压电流、充入电池功率、充电效率、适配器标称与档位 | 已验证（随机型可能缺失） |
| **机型库匹配** | 内置 `devices.json` | 营销名、芯片、PPI、屏幕尺寸、面板类型、电池设计容量 | 较可信（推断） |
| **诊断档案解析** | 用户导入 `sysdiagnose.tar.gz` | 电池循环次数、健康度、显示组件 ID | 较可信（依日志而定） |

读不到的字段一律显示「—」并写明原因，绝不填一个看起来合理的数字。

### 能读到 / 读不到 的完整清单

| 字段 | 状态 | 说明 |
|---|---|---|
| 机型标识 / 系统版本 / Build | ✅ 实时 | `sysctl hw.machine`、`kern.osversion` |
| 芯片型号 | ⚠️ 机型库推断 | 无公开 API，只能由型号映射 |
| 内存 / CPU 核心 | ✅ 实时 | `ProcessInfo.physicalMemory`、`hw.perflevel0` |
| 分辨率 / 缩放 / 帧率上限 | ✅ 实时 | `UIScreen.nativeBounds`、`maximumFramesPerSecond` |
| 电量 / 充电状态 | ✅ 实时 | `UIDevice.batteryLevel` |
| 存储总量 / 可用 | ✅ 实时 | `attributesOfFileSystem` |
| 热状态 / 低电量模式 | ✅ 实时 | `ProcessInfo.thermalState` |
| 电池温度 / 充电 IC 温度 / SoC 各 die | ✅ 私有接口 | HID `0xFF00` 温度矩阵，按 SMC 键识别 |
| USB-C 输入电压 / 电流 / 功率 | ✅ 私有接口 | HID `0xFF08`，测点 `VQ0u × IQ0u` |
| 充入电池功率 / 充电效率 | ✅ 私有接口 | `VP0u × IQ0B` 与输入功率之比 |
| 适配器标称功率 / PD 档位数 | ✅ 私有接口 | `IOPSCopyExternalPowerAdapterDetails` |
| 电池循环次数 / 健康度 | 🟡 需导入档案 | 注册表在 iOS 26 上已过滤这两个键，实测确认 |
| 电池端电压 | ✅ 私有接口 | 同时用诊断档案交叉校验 |
| 屏幕面板供应商 | 🔴 不可得 | iOS 不暴露，仅能取到组件 ID |
| 配件电量（Watch / AirPods） | 🔴 不可得 | `BatteryCenter` 可加载但 XPC 被拒 |
| 无线充电输入功率 | 🔴 不可得 | 只有线圈电压，没有电流可乘 |
| 分类存储占用（照片/App/系统） | 🔴 不可得 | 系统不提供拆分 |

> 任何声称能「实时读取电池循环次数」的第三方 App，要么在猜，要么在骗。
> 这条结论有实测依据：`IOPMPowerSource` 注册表在真机上只放行 `BatteryInstalled` 与 `ExternalConnected`。

---

## 安装

### 方式一：下载未签名 ipa（不需要 Mac）

从 [Releases](https://github.com/NuGe1145/iDevice-X-Ray/releases) 下载最新的
`iDeviceXRay-unsigned.ipa`，用 [Sideloadly](https://sideloadly.io)、
[AltStore](https://altstore.io) 或 [SideStore](https://sidestore.io) 以自己的 Apple ID 签名安装。免费 Apple ID 可用，7 天后重签一次。

### 方式二：Xcode

```bash
brew install xcodegen
git clone https://github.com/NuGe1145/iDevice-X-Ray.git
cd iDevice-X-Ray
xcodegen generate
open iDeviceXRay.xcodeproj
```

选择自己的 Team，连接真机运行。模拟器能跑通 UI，但传感器与电池字段会显示「不可读取」——这是预期行为，不是 bug。

---

## 构建

```bash
./scripts/build-ipa.sh      # 未签名 ipa，CI 发布的就是这个
```

需要 macOS + Xcode 16 以上。版本号取自 `v*` 标签，build number 取自提交数，`project.yml` 不用手改。

CI 分两条：`ci.yml` 每次推送跑编译与单元测试；`ipa.yml` 在打标签时构建并发布 ipa。

---

## 目录结构

```
iDeviceXRay/
├─ App/                入口、Tab 框架
├─ Core/
│  ├─ Models/          ReportField / ReportSection / ScanReport
│  ├─ Engines/         采集引擎（设备 / 屏幕 / 电池 / 存储 / 系统 / 电源传感器）
│  ├─ Sensors/         私有接口：HID 传感器、IOKit 电源、合并过滤、实时采样（ChargeMonitor）
│  ├─ Fusion/          深度数据融合、扫描调度
│  ├─ Catalog/         机型规格库 + devices.json
│  ├─ Storage/         报告本地存档
│  └─ Support/         sysctl 封装、格式化
├─ DeepScan/
│  ├─ Importer/        流式 gunzip、tar 扫描器、扫描服务
│  └─ Parsers/         电池 / 显示字段抽取
├─ Report/             PDF / JSON / 分享长图导出
├─ Features/           各页面（Detail/ChargeLiveView 为实时充电卡与曲线）
└─ DesignSystem/       主题与组件
```

### 数据模型的核心

```swift
struct ReportField {
    let key: String            // "battery.cycleCount"，用于深度数据覆盖
    let title: String
    let value: String
    let unit: String?
    let source: DataSource     // live / privateAPI / sysdiagnose / catalog / manual
    let confidence: Confidence // verified / high / inferred / unavailable
    let note: String?          // 点击行展开，解释这个数怎么来的
}
```

`DataSource` + `Confidence` 是产品的技术契约：没有来源的数值不允许进入 UI。

---

## 私有传感器是怎么读的

两个 vendor usage page，全部走运行期 `dlsym`，编译期不链接私有框架：

| 用途 | usage page | 说明 |
|---|---|---|
| 电源轨 | `0xFF08` | usage 2 电流(A)、usage 3 电压(V) |
| 温度 | `0xFF00` usage 5 | 整机温度矩阵 |

几条必须守住的规则，都是踩过的坑：

1. **一个进程只能建一个 `IOHIDEventSystemClient`**。第二个实例对每个 service 都返回 NaN。因此全部读取经由 `SensorProbe` actor 串行执行，全局单例。
2. **按 `LocationID` 里的四字母 SMC 键识别传感器，不能按名字**。名字会重复（同一台机器上可能有四个 `gas gauge battery`），iOS 27 起同一个键还会通过两个 service 各发一遍。
3. **重复 service 取平均，不能相加**。相加会让温度翻倍，而且看起来仍然像个合理数字。
4. **超出 −40…150 °C 的值当作「没有读数」丢弃**。有设备的充电 IC 会报 −9199 °C 这类哨兵值。
5. **读不到不补零**。放电时没有功率传感器，页面直接说明「没有传感器可读」，不给估算值。

### 已知限制

- 传感器名称、量程、存在性随机型变化，没有文档。缺少的通道显示为不存在的行，而不是 0。
- 私有接口可能在任何一次 iOS 更新后失效。失效时整块区域显示「不可用」并说明原因。
- 适配器描述里的电压电流单位（mV 还是 V）不确定，代码用阈值判断，并标注为推断。
- 充电效率是「入电池功率 ÷ 输入功率」，含线材与充电 IC 损耗，不等于电池化学效率。

---

## 实时监控（充电链路）

充电、电池、温度三页不是扫描一次就定住，而是挂在一条持续采样循环上，默认每 1 秒刷新（设置里可改 1 / 2 / 5 秒）。

```
ChargeMonitor（@MainActor @Observable）
  → 每 N 秒 await SensorProbe.shared.snapshot()   // 仍走 actor，保证只有一个 HID client
  → 生成 ChargeSample（输入 V/A/W、电池 V/A/W、三处温度、电量、连接状态）
  → 追加到 300 点环形窗口（1 秒间隔 ≈ 5 分钟）
  → PowerSensorEngine.liveSection(...) 重建分区字段
  → 曲线、统计、本次累计同步更新
```

几个刻意的取舍：

1. **用 token 登记使用方**。首页与详情页可能同时需要数据，用 `begin(token)` / `end(token)` 记引用；最后一个退出才停表，避免互相把采样关掉。
2. **拔掉电源就停**。首页只在检测到充电时开启采样，插拔由 `UIDevice.batteryStateDidChangeNotification` 即时触发；进后台由 `scenePhase` 挂起。
3. **不做假曲线**。某个通道没有读数时，点直接跳过、曲线断开；不插电时也不画一条 0 W 的水平线。
4. **累计只在充电时进行**。`已充入 mAh` 是电流对时间的积分（Σ I × Δt），只在 `IsCharging` 为真时累加，并把单次间隔截断到 4 个周期，避免后台恢复后一次性把长间隔当大电流积进去。
5. **报告仍存快照**。保存的报告标注「扫描时快照」，实时值只在页面里，避免把某一秒的瞬时功耗当成体检结论。

---

## 深度检测（诊断档案）

### 为什么还需要它

循环次数与健康度在 iOS 26 的 `IOPMPowerSource` 注册表里被过滤掉了，私有接口也拿不到。唯一路径是让用户从系统设置导出诊断包，本地解析：

```
设置 › 隐私与安全性 › 分析与改进 › 分析数据 › sysdiagnose_*.tar.gz
```

### 解析链路

```
tar.gz (100–400MB)
  → 流式 gunzip（Compression 框架，64KB 缓冲，内存恒定）
  → tar 512 字节块扫描（只读关键词命中的条目，其余跳过）
  → 文本正则抽取（CycleCount / DesignCapacity / AppleRawMaxCapacity / Temperature / Voltage）
  → 与实时数据融合；已实时读到的字段不会被档案覆盖
```

关键实现：

- `GzipStreamDecoder` 自己解析 gzip 头（FEXTRA / FNAME / FCOMMENT / FHCRC），再交给 `compression_stream` 增量解压
- `TarScanner` 用状态机推进读指针，1MB 以上才做一次数组压缩
- 单条目上限 8MB，单文件上限 800MB，解析完成后删除临时文件

### 已知限制

1. **格式随系统版本变化**。正则失效时会明确提示「未能提取到有效字段」，而不是静默显示空值。
2. **温度单位不确定**。`AppleSmartBattery` 的 `Temperature` 通常是 0.1K，个别版本是 0.1°C，代码做区间判断后丢弃越界值。
3. **面板供应商不可映射**。即使拿到 `DisplayVendorID`，也没有可靠的公开映射表，因此只显示 ID。

---

## 机型库维护

`iDeviceXRay/Core/Catalog/Resources/devices.json` 收录 iPhone 11 – 16 系列与部分 iPad，字段经过人工核对，**不包含未核实的机型**。

遇到未收录机型时，App 会显示原始标识符并提示更新库，而不是猜一个名字。

---

## 路线图

- [x] Phase 0 标准检测（五个引擎 + 来源标注）
- [x] Phase 1 完整 UI 与报告导出（PDF / JSON / 长图）
- [x] Phase 2 Sysdiagnose 导入与流式解析
- [x] Phase 3 私有接口传感器（温度矩阵 / 电源轨 / 适配器）
- [ ] Phase 4 真机字段校准（iPhone 17 及 iPad 的 SMC 键与量程）
- [ ] Phase 5 验机规则引擎（健康度 × 循环次数交叉校验、充电链路异常判定）
- [ ] Phase 6 机型库扩充至 iPhone 17 / iPad 全系

---

## 隐私

- 无网络权限，不发起任何请求
- 无账号、无埋点、无第三方 SDK
- 解析与传感器读取全程在设备内，无数据外传
- 报告存在 `Documents/reports.json`，卸载即清除

---

## 致谢

私有传感器的读取方法参考了 [MiniWatts](https://github.com/ResistanceTo/MiniWatts)（Apache 2.0）与
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor)（MIT）的公开实现，
包括 usage page 选择、单 client 限制与 SMC 键解析。本项目的分区归类、合理值过滤与报告呈现为自主实现。

## 许可

MIT
