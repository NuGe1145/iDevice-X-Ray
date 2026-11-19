# iDevice X-Ray

> 探索设备深处，发现更多可能 —— 让每一台 iPhone 都拥有属于自己的「体检报告」

一个完全离线的 iOS / iPadOS 设备体检工具。用 SwiftUI 编写，无后端、无账号、无网络请求。

**核心理念：读得到就读，读不到就说读不到。** 每一个数值都标注来源与可信度，不用估算值填充界面。

---

## 这个 App 到底能干什么

iOS 的沙盒限制比大多数人想象的严格。宣传里常见的「电池循环次数」「屏幕供应商」，第三方 App 根本拿不到。所以本项目把数据分成三层，并在 UI 上如实标注：

| 层级 | 数据来源 | 典型字段 | 可信度 |
|---|---|---|---|
| **实时读取** | 公开 API（UIDevice / sysctl / FileManager / LocalAuthentication） | 机型标识、内存、CPU 核心、分辨率、帧率上限、电量、充电状态、存储容量、热状态、开机时长、生物识别 | 已验证 |
| **机型库匹配** | 内置 `devices.json` | 营销名、芯片、PPI、屏幕尺寸、面板类型、电池设计容量 | 较可信（推断） |
| **诊断档案解析** | 用户导入 `sysdiagnose.tar.gz` | 电池循环次数、健康度、电压、温度、显示组件 ID | 较可信（依日志而定） |
| **不可读取** | 系统不开放 | 面板供应商、CPU 温度、分类存储占用 | 明确显示「—」并说明原因 |

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
| 电池循环次数 / 健康度 | 🟡 需导入档案 | 无公开 API，只能解析 sysdiagnose |
| 电池电压 / 温度 | 🟡 需导入档案 | 同上，依赖日志字段 |
| 面板供应商 | 🔴 不可得 | iOS 完全不暴露，仅能取到组件 ID |
| CPU 温度 | 🔴 不可得 | 无温度传感器接口，用热状态代替 |
| 分类存储占用（照片/App/系统） | 🔴 不可得 | 系统不提供拆分 |

> 任何声称能「实时读取电池循环次数」的第三方 App，要么在猜，要么在骗。

---

## 构建

需要 macOS + Xcode 16 或更高版本。

```bash
brew install xcodegen
git clone <repo>
cd iDevice-X-Ray
xcodegen generate
open iDeviceXRay.xcodeproj
```

在 Xcode 中选择你的开发者 Team，连接真机运行。模拟器可以跑通 UI，但电池、机型等字段会大量显示「不可读取」——这是预期行为。

命令行构建（无需签名）：

```bash
xcodebuild -project iDeviceXRay.xcodeproj \
  -scheme iDeviceXRay \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

CI 使用 GitHub Actions 的 macOS runner 做同样的构建与单元测试，见 `.github/workflows/ci.yml`。

---

## 目录结构

```
iDeviceXRay/
├─ App/                入口、Tab 框架
├─ Core/
│  ├─ Models/          ReportField / ReportSection / ScanReport / Metric 语义
│  ├─ Engines/         五个采集引擎（设备 / 屏幕 / 电池 / 存储 / 系统）
│  ├─ Fusion/          深度数据融合、扫描调度
│  ├─ Catalog/         机型规格库 + devices.json
│  ├─ Storage/         报告本地存档
│  └─ Support/         sysctl 封装、格式化
├─ DeepScan/
│  ├─ Importer/        流式 gunzip、tar 扫描器、扫描服务
│  └─ Parsers/         电池 / 显示字段抽取
├─ Report/             PDF / JSON / 分享长图导出
├─ Features/           各页面
└─ DesignSystem/       主题与组件
```

### 数据模型的核心

```swift
struct ReportField {
    let key: String          // "battery.cycleCount"，用于深度数据覆盖
    let title: String
    let value: String
    let unit: String?
    let source: DataSource   // live / sysdiagnose / catalog / manual
    let confidence: Confidence // verified / high / inferred / unavailable
    let note: String?        // 点击行展开，解释这个数怎么来的
}
```

`DataSource` + `Confidence` 是产品的技术契约：没有来源的数值不允许进入 UI。

---

## 深度检测是怎么做的

### 为什么必须是「导入档案」

`UIDevice` 没有电池健康接口，`IOKit` 的 `AppleSmartBattery` 是私有 API（用了会被 App Store 拒审）。唯一合规的路径是让用户从系统设置里导出诊断包，再在本地解析：

```
设置 › 隐私与安全性 › 分析与改进 › 分析数据 › sysdiagnose_*.tar.gz
```

### 解析链路

```
tar.gz (100–400MB)
  → 流式 gunzip（Compression 框架，64KB 缓冲，内存恒定）
  → tar 512 字节块扫描（只读关键词命中的条目，其余跳过）
  → 文本正则抽取（CycleCount / DesignCapacity / AppleRawMaxCapacity / Temperature / Voltage）
  → 与实时数据融合，替换占位字段
```

关键实现：

- `GzipStreamDecoder` 自己解析 gzip 头（FEXTRA / FNAME / FCOMMENT / FHCRC），再交给 `compression_stream` 增量解压
- `TarScanner` 用状态机推进读指针，1MB 以上才做一次数组压缩，避免 80 万次 `removeFirst`
- 单条目上限 8MB，单文件上限 800MB，全部解析完成后删除临时文件

### 已知限制

1. **格式随系统版本变化**。iOS 18 → 26 的日志结构并不完全一致，正则可能失效。失效时 App 会明确提示「未能提取到有效字段」，而不是静默显示空值。
2. **温度单位不确定**。`AppleSmartBattery` 的 `Temperature` 通常是 0.1K，个别版本是 0.1°C，代码里做了合理性区间判断（-30 ~ 100°C），超出就丢弃。
3. **面板供应商不可映射**。即使拿到 `DisplayVendorID`，也没有可靠的公开映射表，因此只显示 ID，不猜厂商名。
4. **大文件处理**。500MB 以上的档案在低端机型上可能耗时较久，界面上有进度与阶段提示。

---

## 机型库维护

`iDeviceXRay/Core/Catalog/Resources/devices.json` 收录 iPhone 11 – 16 系列与部分 iPad。字段全部经过人工核对，**不包含未核实的机型**（例如新发布的世代需要确认标识符后再加入）。

遇到未收录机型时，App 会显示原始标识符并提示更新库，而不是猜一个名字。

新增机型：在 `devices` 数组里追加一条，注意 `identifier` 必须与 `sysctl hw.machine` 完全一致。

---

## 路线图

- [x] Phase 0 标准检测（五个引擎 + 来源标注）
- [x] Phase 1 完整 UI 与报告导出（PDF / JSON / 长图）
- [x] Phase 2 Sysdiagnose 导入与流式解析
- [ ] Phase 3 更多日志字段（循环次数缺失时的兜底策略）
- [ ] Phase 4 机型库扩充至 iPhone 17 / iPad 全系（需真机核对标识符）
- [ ] Phase 5 验机规则引擎（健康度与循环次数交叉校验、异常提示）
- [ ] Phase 6 兼容性矩阵测试与 TestFlight

---

## 隐私

- 无网络权限，不发起任何请求
- 无账号、无埋点、无第三方 SDK
- 解析全程在沙盒内，临时文件解析后即删
- 报告存在 `Documents/reports.json`，卸载即清除

---

## 许可

MIT
