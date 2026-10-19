import Foundation

public struct UsagePair: Codable, Equatable {
    public let page: UInt32
    public let usage: UInt32
    public init(page: UInt32, usage: UInt32) { self.page = page; self.usage = usage }
}

public struct DeviceInfo: Codable, Identifiable, Equatable {
    public let id: String
    public let product: String
    public let vendorID: UInt32
    public let productID: UInt32
    public let transport: String
    public let primaryUsage: UsagePair
    public let usages: [UsagePair]
    public let maxInputBytes: Int
    public let maxOutputBytes: Int
    public let maxFeatureBytes: Int
    public let descriptor: [UInt8]
    public let summary: DescriptorSummary
    public var usbInterfaceNumber: Int? = nil

    /// Matches the observed interface, not a firmware/model identity proof.
    public var canAttemptDPIRead: Bool {
        vendorID == 0x24AE && productID == 0x4500 && isUSB && usbInterfaceNumber == 1 &&
        primaryUsage == UsagePair(page: 1, usage: 6) &&
        usages.contains(UsagePair(page: 0xFF00, usage: 0x000E)) &&
        summary.lengthsAreReliable &&
        summary.reports.contains { $0.kind == .input && $0.reportID == 0xBA && $0.bitCount == 248 } &&
        summary.reports.contains { $0.kind == .output && $0.reportID == 0xBA && $0.bitCount == 248 }
    }

    public var isUSB: Bool { transport.caseInsensitiveCompare("USB") == .orderedSame }
    public var isVendorCandidate: Bool {
        vendorID == 0x24AE && isUSB &&
        ([primaryUsage] + usages).contains { (0xFF00...0xFFFF).contains($0.page) }
    }
    public var matchesDocumentHint: Bool {
        isVendorCandidate && ([primaryUsage] + usages).contains { $0.page == 0xFF0B && $0.usage == 0x0104 }
    }
    public var status: String {
        if canAttemptDPIRead { return L("匹配 MT760 温读取接口 · 型号/固件需确认", "Matches the MT760 warm-read interface · model/firmware to be confirmed") }
        if isVendorCandidate { return L("USB 厂商接口候选 · 不启用读取", "USB vendor interface candidate · reads not enabled") }
        if isUSB { return L("USB 标准接口 · 不用于配置", "Standard USB interface · not used for configuration") }
        return L("非 USB 连接 · 不用于配置", "Non-USB connection · not used for configuration")
    }
}

public struct DiagnosticSnapshot: Codable {
    public let schemaVersion: Int
    public let appVersion: String
    public let generatedAt: Date
    public let operatingSystem: String
    public let mode: String
    public let devices: [DeviceInfo]
    public let notes: [String]

    public init(devices: [DeviceInfo]) {
        schemaVersion = 1
        appVersion = "0.2.0"
        generatedAt = Date()
        operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
        mode = "This snapshot contains enumeration only. Device read / write transactions are exported separately from the App's activity log."
        self.devices = devices
        notes = [
            L("仅枚举 VID 0x24AE；厂商接口候选不等于已确认 MT760 配置接口。", "Only VID 0x24AE is enumerated; a vendor interface candidate is not a confirmed MT760 configuration interface."),
            L("Report ID/长度来自描述符，不证明某条配置命令可用。", "Report IDs/lengths come from descriptors and do not prove that any configuration command works."),
            L("普通 MT760 V0.1.4.4 已有单次官方温读取样本；独立读取、冷启动及设置写入须分别验证。", "A single official warm-read sample exists for the standard MT760 V0.1.4.4; independent reads, cold start and settings writes must each be verified separately."), 
            L("未采集序列号、蓝牙地址、按键、光标或用户路径。", "No serial numbers, Bluetooth addresses, keystrokes, cursor data or user paths are collected.")
        ]
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
