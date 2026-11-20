import Foundation

/// 把私有传感器快照翻译成报告分区：充电与功率、温度传感器矩阵。
///
/// 每一条都写清测点（SMC 键）与换算方式：这一层存在的意义是给结论，
/// 但结论必须带着依据，用户点开能看到「这个 8.9 W 是哪两个数乘出来的」。
struct PowerSensorEngine {

    func sections(from snapshot: EnergySnapshot) -> [ReportSection] {
        [
            powerSection(snapshot),
            thermalSection(snapshot)
        ]
    }

    /// 用实时快照重算分区。充电、温度、电池这三页挂在监控循环上，
    /// 每次采样都走这里重建字段，界面上的数字才会真的每秒变。
    func liveSection(for base: ReportSection, from snapshot: EnergySnapshot) -> ReportSection {
        switch base.key {
        case "power": return powerSection(snapshot)
        case "thermal": return thermalSection(snapshot)
        case "battery": return batterySection(base, snapshot: snapshot)
        default: return base
        }
    }

    /// 把私有接口拿到的值回填到原有分区，避免「电池状态」里写着不可读、
    /// 隔壁「充电与功率」却摆着同一个数。只填原本读不到（< .verified）的字段。
    func backfill(_ sections: [ReportSection], from snapshot: EnergySnapshot) -> [ReportSection] {
        var replacements: [String: (value: String, unit: String, note: String)] = [:]

        if let battery = snapshot.hottest(in: [.battery]) {
            replacements["battery.temperature"] = (
                number(battery.value, digits: 1),
                "°C",
                "私有 HID 接口实时读取 · \(battery.name)"
            )
        }
        if let soc = snapshot.hottest(in: [.soc]) {
            replacements["system.cpuTemperature"] = (
                number(soc.value, digits: 1),
                "°C",
                "私有 HID 接口实时读取 · \(soc.name) · SMC \(soc.key)"
            )
        }
        if let voltage = snapshot.voltage("VP0u") ?? snapshot.voltage("VQ0l") {
            replacements["battery.voltage"] = (
                number(voltage.value, digits: 2),
                "V",
                "私有 HID 接口实时读取 · SMC \(voltage.key)"
            )
        }

        guard !replacements.isEmpty else { return sections }

        return sections.map { section in
            let fields = section.fields.map { field -> ReportField in
                guard field.confidence < .verified, let hit = replacements[field.key] else { return field }
                return ReportField(
                    key: field.key,
                    title: field.title,
                    value: hit.value,
                    unit: hit.unit,
                    source: .privateAPI,
                    confidence: .verified,
                    note: hit.note
                )
            }
            return ReportSection(
                key: section.key,
                title: section.title,
                symbol: section.symbol,
                accentHex: section.accentHex,
                fields: fields
            )
        }
    }

    // MARK: - 充电与功率

    private func powerSection(_ snapshot: EnergySnapshot) -> ReportSection {
        var fields: [ReportField] = []

        guard snapshot.iokitAvailable else {
            fields.append(unavailable("power.connected", "电源连接", "IOKit 不可用：本机或系统版本已限制该接口"))
            return ReportSection(key: "power", title: "充电与功率", symbol: "bolt.fill", accentHex: 0xFBBF24, fields: fields)
        }

        let power = snapshot.power
        let batteryVoltage = snapshot.voltage("VP0u") ?? snapshot.voltage("VQ0l")
        let batteryCurrent = snapshot.current("IQ0B") ?? snapshot.current("IQ0l")

        if power.externalConnected {
            fields.append(ReportField(
                key: "power.connected",
                title: "电源连接",
                value: power.charging ? "已连接 · 充电中" : (power.fullCharge ? "已连接 · 已充满" : "已连接"),
                source: .privateAPI,
                confidence: .verified,
                note: "IOPSGetPowerSourceDescription"
            ))
        } else {
            fields.append(ReportField(
                key: "power.connected",
                title: "电源连接",
                value: "未连接",
                source: .privateAPI,
                confidence: .verified,
                note: "使用电池供电。放电功率没有传感器可读，本页不给估算值"
            ))
        }

        if let name = power.adapterName, !name.isEmpty {
            fields.append(ReportField(
                key: "power.adapter.name",
                title: "适配器",
                value: name,
                source: .privateAPI,
                confidence: .high,
                note: "适配器握手信息"
            ))
        }

        if let rated = power.adapterRatedWatts, rated > 0 {
            var note = "适配器标称上限，不是实测输入"
            if power.adapterProfileCount > 0 {
                note += "；握手到 \(power.adapterProfileCount) 个电压档位"
            }
            fields.append(ReportField(
                key: "power.adapter.rated",
                title: "适配器标称",
                value: number(rated, digits: 0),
                unit: "W",
                source: .privateAPI,
                confidence: .high,
                note: note
            ))
        }

        // 输入端：没插电时这两个通道会停在 0.01 V 之类的残值，
        // 这不是读数而是「通道没工作」，所以按连接状态决定显示还是说明。
        var inputWatts: Double?
        if power.externalConnected {
            let inputVoltage = snapshot.voltage("VQ0u")
            let inputCurrent = snapshot.current("IQ0u")

            if let inputVoltage {
                fields.append(ReportField(
                    key: "power.input.voltage",
                    title: "输入电压",
                    value: number(inputVoltage.value, digits: 2),
                    unit: "V",
                    source: .privateAPI,
                    confidence: .verified,
                    note: railNote(inputVoltage)
                ))
            }
            if let inputCurrent {
                fields.append(ReportField(
                    key: "power.input.current",
                    title: "输入电流",
                    value: number(abs(inputCurrent.value), digits: 2),
                    unit: "A",
                    source: .privateAPI,
                    confidence: .verified,
                    note: railNote(inputCurrent)
                ))
            }

            if let voltage = inputVoltage?.value, let current = inputCurrent.map({ abs($0.value) }), current > 0.05 {
                inputWatts = voltage * current
                fields.append(ReportField(
                    key: "power.input.watts",
                    title: "输入功率",
                    value: number(voltage * current, digits: 2),
                    unit: "W",
                    source: .privateAPI,
                    confidence: .verified,
                    note: "测点在 USB-C 口，VQ0u × IQ0u"
                ))
            } else {
                fields.append(unavailable(
                    "power.input.watts",
                    "输入功率",
                    "适配器已连接但未取电，输入通道读数接近零（已充满或握手未完成）"
                ))
            }
        } else {
            fields.append(unavailable("power.input.voltage", "输入电压", "未连接电源，输入通道不工作"))
            fields.append(unavailable("power.input.watts", "输入功率", "未连接电源，没有输入功率可测"))
        }

        if let batteryVoltage {
            fields.append(ReportField(
                key: "power.battery.voltage",
                title: "电池端电压",
                value: number(batteryVoltage.value, digits: 2),
                unit: "V",
                source: .privateAPI,
                confidence: .verified,
                note: railNote(batteryVoltage)
            ))
        }

        var batteryWatts: Double?
        if power.charging, let batteryCurrent, abs(batteryCurrent.value) > 0.02 {
            fields.append(ReportField(
                key: "power.battery.current",
                title: "充入电池电流",
                value: number(abs(batteryCurrent.value), digits: 2),
                unit: "A",
                source: .privateAPI,
                confidence: .verified,
                note: railNote(batteryCurrent)
            ))
            if let voltage = batteryVoltage?.value {
                batteryWatts = voltage * abs(batteryCurrent.value)
                fields.append(ReportField(
                    key: "power.battery.watts",
                    title: "充入电池功率",
                    value: number(voltage * abs(batteryCurrent.value), digits: 2),
                    unit: "W",
                    source: .privateAPI,
                    confidence: .verified,
                    note: "VP0u × IQ0B"
                ))
            }
        } else if power.externalConnected {
            fields.append(unavailable(
                "power.battery.current",
                "充入电池电流",
                "已连接电源但当前未向电池充电（可能已充满或触发了温度保护）"
            ))
        } else {
            fields.append(unavailable(
                "power.battery.current",
                "充入电池电流",
                "未连接电源，电池处于放电状态；放电电流没有可读的传感器通道"
            ))
        }

        if let inputWatts, let batteryWatts, inputWatts > 0.5, batteryWatts > 0 {
            let efficiency = min(120, batteryWatts / inputWatts * 100)
            var note = "入电池功率 ÷ 输入功率。差值变成热，由机身与充电 IC 散掉"
            if efficiency < 70 {
                note += "；低于 70% 说明链路损耗偏大（线材、接口氧化或无线充电）"
            }
            fields.append(ReportField(
                key: "power.efficiency",
                title: "充电效率",
                value: number(efficiency, digits: 0),
                unit: "%",
                source: .privateAPI,
                confidence: .inferred,
                note: note
            ))
        }

        if let rated = power.adapterRatedWatts, let inputWatts, rated > 0 {
            let ratio = inputWatts / rated
            let verdict: String
            let confidence: Confidence
            if ratio < 0.7 {
                verdict = "明显偏低"
                confidence = .inferred
            } else if ratio > 1.15 {
                verdict = "高于标称"
                confidence = .inferred
            } else {
                verdict = "与标称相符"
                confidence = .high
            }
            fields.append(ReportField(
                key: "power.verdict",
                title: "功率核对",
                value: verdict,
                source: .privateAPI,
                confidence: confidence,
                note: "实测 \(number(inputWatts, digits: 1)) W / 标称 \(number(rated, digits: 0)) W = \(number(ratio * 100, digits: 0))%"
            ))
        }

        return ReportSection(key: "power", title: "充电与功率", symbol: "bolt.fill", accentHex: 0xFBBF24, fields: fields)
    }

    // MARK: - 电池（实时回填）

    /// 电池页里的电量、状态、电压、温度本来就是实时量，只是扫描时读了一次。
    /// 监视充电时顺手把它们换成当前值，并补上电流与功率两行。
    private func batterySection(_ base: ReportSection, snapshot: EnergySnapshot) -> ReportSection {
        guard snapshot.batteryLevel != nil || snapshot.iokitAvailable || snapshot.hidAvailable else {
            return base
        }

        let power = snapshot.power
        var replacements: [String: ReportField] = [:]

        if let level = snapshot.batteryLevel {
            replacements["battery.level"] = ReportField(
                key: "battery.level",
                title: "当前电量",
                value: number(level * 100, digits: 0),
                unit: "%",
                source: .live,
                confidence: .verified,
                note: "UIDevice 实时上报，每次采样刷新"
            )
        }

        let stateText: String
        if power.charging {
            stateText = "充电中"
        } else if power.fullCharge {
            stateText = "已充满"
        } else if power.externalConnected {
            stateText = "已连接电源"
        } else if snapshot.iokitAvailable {
            stateText = "使用电池"
        } else {
            stateText = "未知"
        }
        replacements["battery.state"] = ReportField(
            key: "battery.state",
            title: "充电状态",
            value: stateText,
            source: .live,
            confidence: .verified,
            note: "系统电源状态实时读取"
        )

        let voltage = snapshot.voltage("VP0u") ?? snapshot.voltage("VQ0l")
        if let voltage {
            replacements["battery.voltage"] = ReportField(
                key: "battery.voltage",
                title: "电池电压",
                value: number(voltage.value, digits: 2),
                unit: "V",
                source: .privateAPI,
                confidence: .verified,
                note: "SMC \(voltage.key) · \(voltage.name)"
            )
        }

        if let battery = snapshot.hottest(in: [.battery]) {
            replacements["battery.temperature"] = ReportField(
                key: "battery.temperature",
                title: "电池温度",
                value: number(battery.value, digits: 1),
                unit: "°C",
                source: .privateAPI,
                confidence: .verified,
                note: "SMC \(battery.key) · \(battery.name)"
            )
        }

        var extras: [ReportField] = []
        if let current = snapshot.current("IQ0B") ?? snapshot.current("IQ0l") {
            extras.append(ReportField(
                key: "battery.current",
                title: current.value >= 0 ? "充入电流" : "放电电流",
                value: number(current.value, digits: 2),
                unit: "A",
                source: .privateAPI,
                confidence: .verified,
                note: "SMC \(current.key) · 有符号，正为充入电池"
            ))
            if let voltage {
                extras.append(ReportField(
                    key: "battery.power",
                    title: "实时功率",
                    value: number(voltage.value * current.value, digits: 2),
                    unit: "W",
                    source: .privateAPI,
                    confidence: .verified,
                    note: "电池端 \(number(voltage.value, digits: 2)) V × \(number(current.value, digits: 2)) A"
                ))
            }
        }

        var fields: [ReportField] = []
        for field in base.fields {
            if let hit = replacements[field.key] {
                fields.append(hit)
                if field.key == "battery.voltage" {
                    fields.append(contentsOf: extras)
                    extras.removeAll()
                }
            } else if field.key == "battery.current" || field.key == "battery.power" {
                continue
            } else {
                fields.append(field)
            }
        }

        if !extras.isEmpty {
            if let index = fields.firstIndex(where: { $0.key == "battery.level" }) {
                fields.insert(contentsOf: extras, at: index + 1)
            } else {
                fields.append(contentsOf: extras)
            }
        }

        return ReportSection(
            key: base.key,
            title: base.title,
            symbol: base.symbol,
            accentHex: base.accentHex,
            fields: fields
        )
    }

    // MARK: - 温度矩阵

    private func thermalSection(_ snapshot: EnergySnapshot) -> ReportSection {
        var fields: [ReportField] = []
        let sensors = snapshot.temperatures

        guard snapshot.hidAvailable, !sensors.isEmpty else {
            fields.append(unavailable(
                "thermal.count",
                "温度传感器",
                snapshot.hidAvailable
                    ? "本次枚举到 0 个温度通道。模拟器没有传感器；部分系统版本会关闭该接口"
                    : "HID 接口不可用：本机或系统版本已限制该接口"
            ))
            return ReportSection(key: "thermal", title: "温度传感器", symbol: "thermometer.medium", accentHex: 0xF87171, fields: fields)
        }

        if let battery = snapshot.hottest(in: [.battery]) {
            fields.append(ReportField(
                key: "thermal.battery",
                title: "电池温度",
                value: number(battery.value, digits: 1),
                unit: "°C",
                source: .privateAPI,
                confidence: .verified,
                note: "\(battery.name) · SMC \(battery.key)"
            ))
        }

        if let charger = snapshot.hottest(in: [.charger]) {
            fields.append(ReportField(
                key: "thermal.charger",
                title: "充电 IC 温度",
                value: number(charger.value, digits: 1),
                unit: "°C",
                source: .privateAPI,
                confidence: .verified,
                note: "\(charger.name) · SMC \(charger.key)"
            ))
        }

        if let soc = snapshot.hottest(in: [.soc]) {
            fields.append(ReportField(
                key: "thermal.soc",
                title: "SoC 最高温度",
                value: number(soc.value, digits: 1),
                unit: "°C",
                source: .privateAPI,
                confidence: .verified,
                note: "\(soc.name) · SMC \(soc.key)"
            ))
        }

        let hottest = sensors.max { $0.value < $1.value }
        if let hottest {
            fields.append(ReportField(
                key: "thermal.hottest",
                title: "最热测点",
                value: number(hottest.value, digits: 1),
                unit: "°C",
                source: .privateAPI,
                confidence: .verified,
                note: "\(hottest.zone.title) · \(hottest.name)"
            ))
        }

        var countNote = "枚举 \(snapshot.serviceCount) 个服务，合并重复后 \(sensors.count) 个温度通道"
        if snapshot.droppedValues > 0 {
            countNote += "；丢弃 \(snapshot.droppedValues) 个不可能的值（如 −9199 °C 这类哨兵）"
        }
        fields.append(ReportField(
            key: "thermal.count",
            title: "温度通道",
            value: "\(sensors.count)",
            unit: "个",
            source: .privateAPI,
            confidence: .verified,
            note: countNote
        ))

        if let battery = snapshot.hottest(in: [.battery]), let charger = snapshot.hottest(in: [.charger]) {
            let delta = charger.value - battery.value
            var note = "充电 IC 与电池的温度差 \(number(delta, digits: 1)) °C"
            var verdict = "正常"
            var confidence = Confidence.high
            if battery.value >= 42 {
                verdict = "电池偏热"
                confidence = .inferred
                note += "。电池温度超过 42 °C 会加速老化，建议暂停充电待其降到 35 °C 以下"
            } else if delta >= 15 {
                verdict = "温差偏大"
                confidence = .inferred
                note += "。充电 IC 与电池温差过大，散热或导热路径可能异常"
            }
            fields.append(ReportField(
                key: "thermal.verdict",
                title: "发热评估",
                value: verdict,
                source: .privateAPI,
                confidence: confidence,
                note: note
            ))
        }

        // 全部通道，按机型位置排序；名字会重复，所以标题后括注 SMC 键
        for sensor in sensors {
            let key = sensor.key.isEmpty ? sensor.identifier : sensor.key
            fields.append(ReportField(
                key: "thermal.sensor.\(key)",
                title: sensor.name,
                value: number(sensor.value, digits: 1),
                unit: "°C",
                source: .privateAPI,
                confidence: .verified,
                note: "\(sensor.zone.title) · SMC \(key)\(sensor.copies > 1 ? " · \(sensor.copies) 个服务取平均" : "")"
            ))
        }

        return ReportSection(key: "thermal", title: "温度传感器", symbol: "thermometer.medium", accentHex: 0xF87171, fields: fields)
    }

    // MARK: - 工具

    private func railNote(_ reading: SensorReading) -> String {
        let key = reading.key.isEmpty ? reading.name : reading.key
        return "SMC \(key) · \(reading.name)"
    }

    private func unavailable(_ key: String, _ title: String, _ reason: String) -> ReportField {
        ReportField(
            key: key,
            title: title,
            value: "",
            source: .privateAPI,
            confidence: .unavailable,
            note: reason
        )
    }

    private func number(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }
}
