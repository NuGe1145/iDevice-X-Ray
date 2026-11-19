import Foundation
import UIKit

/// 设备基础信息。全部来自公开 API + 机型库匹配。
/// 标记 @MainActor 是因为 UIDevice 在 iOS 17 SDK 起受主线程隔离约束。
@MainActor
struct DeviceEngine {

    func collect(catalog: DeviceCatalog) -> [ReportField] {
        let identifier = DeviceIdentity.identifier
        let spec = catalog.spec(for: identifier)
        let memoryBytes = ProcessInfo.processInfo.physicalMemory

        var fields: [ReportField] = []

        // 型号名：必须靠机型库，标识符本身是系统上报的
        if let spec {
            fields.append(ReportField(
                key: "device.model",
                title: "设备型号",
                value: spec.name,
                source: .catalog,
                confidence: .high,
                note: "由机型标识 \(identifier) 匹配机型库"
            ))
        } else {
            fields.append(ReportField(
                key: "device.model",
                title: "设备型号",
                value: "未收录机型",
                source: .live,
                confidence: .inferred,
                note: "机型库版本 \(catalog.version) 未收录 \(identifier)，原始标识符见下一项"
            ))
        }

        fields.append(ReportField(
            key: "device.identifier",
            title: "机型标识",
            value: identifier,
            source: .live,
            confidence: .verified,
            note: "sysctl hw.machine"
        ))

        fields.append(ReportField(
            key: "device.family",
            title: "设备类型",
            value: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            source: .live,
            confidence: .verified
        ))

        if let spec {
            fields.append(ReportField(
                key: "device.chip",
                title: "芯片",
                value: spec.chip,
                source: .catalog,
                confidence: .inferred,
                note: "芯片型号无法由系统 API 读取，按机型推断"
            ))
        } else {
            fields.append(.unavailable(key: "device.chip", title: "芯片", reason: "机型未收录，无法推断芯片型号"))
        }

        if let perf = Sysctl.int("hw.perflevel0.physicalcpu"),
           let eff = Sysctl.int("hw.perflevel1.physicalcpu") {
            fields.append(ReportField(
                key: "device.cpuCores",
                title: "CPU 核心",
                value: "\(perf + eff)",
                unit: "核",
                source: .live,
                confidence: .verified,
                note: "\(perf) 性能核 + \(eff) 能效核"
            ))
        } else if let cores = Sysctl.int("hw.ncpu") {
            fields.append(ReportField(
                key: "device.cpuCores",
                title: "CPU 核心",
                value: "\(cores)",
                unit: "核",
                source: .live,
                confidence: .verified
            ))
        }

        // 内存：优先机型库标称值，实时物理内存作为交叉验证
        if let spec {
            fields.append(ReportField(
                key: "device.memory",
                title: "运行内存",
                value: "\(spec.ramGB)",
                unit: "GB",
                source: .catalog,
                confidence: .high,
                note: "标称容量；系统实测 \(Format.gb(Int64(memoryBytes))) GB"
            ))
        } else {
            fields.append(ReportField(
                key: "device.memory",
                title: "运行内存",
                value: Format.gb(Int64(memoryBytes)),
                unit: "GB",
                source: .live,
                confidence: .verified,
                note: "ProcessInfo.physicalMemory"
            ))
        }

        fields.append(ReportField(
            key: "device.osVersion",
            title: "系统版本",
            value: DeviceIdentity.osVersionString,
            source: .live,
            confidence: .verified
        ))

        if let build = DeviceIdentity.buildNumber {
            fields.append(ReportField(
                key: "device.build",
                title: "系统 Build",
                value: build,
                source: .live,
                confidence: .verified,
                note: "sysctl kern.osversion"
            ))
        }

        fields.append(ReportField(
            key: "device.arch",
            title: "系统架构",
            value: DeviceIdentity.cpuArchitecture,
            source: .live,
            confidence: .verified
        ))

        fields.append(ReportField(
            key: "device.uptime",
            title: "开机时长",
            value: Format.uptime(ProcessInfo.processInfo.systemUptime),
            source: .live,
            confidence: .verified,
            note: "据此可推算设备启动时间"
        ))

        if let spec {
            fields.append(ReportField(
                key: "device.releaseYear",
                title: "发布年份",
                value: "\(spec.releaseYear)",
                source: .catalog,
                confidence: .high
            ))
        }

        return fields
    }
}
