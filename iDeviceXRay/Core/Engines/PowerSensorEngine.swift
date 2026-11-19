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

        // 适配器（充电器本身）
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

        if let rated = power.adapterRatedWatts {
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

        // USB-C 输入端实测
        let inputVoltage = snapshot.voltage("VQ0u") ?? snapshot.voltage("VP0u")
        let inputCurrent = snapshot.current("IQ0u")

        var hasInputRail = false
        if let inputVoltage {
            hasInputRail = true
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
            hasInputRail = true
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

        let inputWatts = (inputVoltage?.value).flatMap { v in
            inputCurrent.map { abs($0.value) * v }
        }
        if let inputWatts {
            fields.append(ReportField(
                key: "power.input.watts",
                title: "输入功率",
                value: number(inputWatts, digits: 2),
                unit: "W",
                source: .privateAPI,
                confidence: .verified,
                note: "测点在 USB-C 口，VQ0u × IQ0u"
            ))
        }

        // 电池侧
        let batteryVoltage = snapshot.voltage("VP0u") ?? snapshot.voltage("VQ0l")
        let batteryCurrent = snapshot.current("IQ0B") ?? snapshot.current("IQ0l")

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
        if let batteryCurrent {
            fields.append(ReportField(
                key: "power.battery.current",
                title: "充入电池电流",
                value: number(abs(batteryCurrent.value), digits: 2),
                unit: "A",
                source: .privateAPI,
                confidence: .verified,
                note: railNote(batteryCurrent)
            ))
        }

        let batteryWatts = (batteryVoltage?.value).flatMap { v in
            batteryCurrent.map { abs($0.value) * v }
        }
        if let batteryWatts {
            fields.append(ReportField(
                key: "power.battery.watts",
                title: "充入电池功率",
                value: number(batteryWatts, digits: 2),
                unit: "W",
                source: .privateAPI,
                confidence: .verified,
                note: "VP0u × IQ0B"
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

        // 标称与实测核对：这是二手验机最实用的一条
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

        if power.externalConnected && !hasInputRail {
            fields.append(unavailable("power.input.watts", "输入功率", "适配器已连接，但 USB-PD 通道未上报电压电流"))
        }

        return ReportSection(key: "power", title: "充电与功率", symbol: "bolt.fill", accentHex: 0xFBBF24, fields: fields)
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
