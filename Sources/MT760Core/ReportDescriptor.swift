import Foundation

public struct ReportLayout: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable { case input, output, feature }
    public let kind: Kind
    public let reportID: UInt32
    public var bitCount: UInt64
    public var id: String { "\(kind.rawValue)-\(reportID)" }
    /// Payload only. A numbered report has an additional Report ID byte on the wire.
    public var payloadBytes: UInt64 { (bitCount + 7) / 8 }
    public var wireBytes: UInt64 { payloadBytes + (reportID == 0 ? 0 : 1) }
}

public struct DescriptorSummary: Codable, Equatable {
    public var reports: [ReportLayout] = []
    public var warnings: [String] = []
    /// False means accumulated lengths are partial estimates, not confirmed report sizes.
    public private(set) var lengthsAreReliable = true

    /// Parses report lengths, not configuration command semantics. Never authorizes writes.
    public static func parse(_ bytes: [UInt8]) -> Self {
        struct Globals { var size: UInt32 = 0; var count: UInt32 = 0; var id: UInt32 = 0 }
        var result = Self()
        var globals = Globals()
        var stack: [Globals] = []
        var index = 0
        var collections = 0
        while index < bytes.count {
            let start = index
            let prefix = bytes[index]
            index += 1
            if prefix == 0xFE {
                guard index + 2 <= bytes.count else {
                    result.warnings.append(L("偏移 \(start)：长条目头被截断", "Offset \(start): long item header truncated")); break
                }
                let length = Int(bytes[index])
                index += 2
                guard length <= bytes.count - index else {
                    result.warnings.append(L("偏移 \(start)：长条目内容被截断", "Offset \(start): long item data truncated")); break
                }
                result.warnings.append(L("偏移 \(start)：跳过未解释的长条目", "Offset \(start): skipped uninterpreted long item"))
                index += length
                continue
            }
            let sizeCode = Int(prefix & 3)
            let length = sizeCode == 3 ? 4 : sizeCode
            guard length <= bytes.count - index else {
                result.warnings.append(L("偏移 \(start)：短条目被截断", "Offset \(start): short item truncated")); break
            }
            var value: UInt32 = 0
            for n in 0..<length { value |= UInt32(bytes[index + n]) << (n * 8) }
            index += length
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4
            if type == 1 {
                switch tag {
                case 7: globals.size = value
                case 8:
                    if value == 0 || value > 255 {
                        result.warnings.append(L("偏移 \(start)：Report ID 必须为 1…255", "Offset \(start): Report ID must be 1…255"))
                    }
                    globals.id = value
                case 9: globals.count = value
                case 10: stack.append(globals)
                case 11:
                    if let previous = stack.popLast() { globals = previous }
                    else { result.warnings.append(L("偏移 \(start)：Global Pop 没有对应 Push", "Offset \(start): Global Pop without a matching Push")) }
                default: break
                }
            } else if type == 0 {
                if tag == 10 { collections += 1 }
                if tag == 12 {
                    if collections > 0 { collections -= 1 }
                    else { result.warnings.append(L("偏移 \(start)：End Collection 没有对应 Collection", "Offset \(start): End Collection without a matching Collection")) }
                }
                let kind: ReportLayout.Kind?
                switch tag {
                case 8: kind = .input
                case 9: kind = .output
                case 11: kind = .feature
                default: kind = nil
                }
                if let kind {
                    let bits = UInt64(globals.size) * UInt64(globals.count)
                    // Bound malicious descriptors and avoid accumulation overflow.
                    guard bits > 0, bits <= 8 * 1_048_576 else {
                        result.warnings.append(L("偏移 \(start)：报告长度为零或超过解析上限", "Offset \(start): report length is zero or exceeds the parser limit")); continue
                    }
                    if let slot = result.reports.firstIndex(where: { $0.kind == kind && $0.reportID == globals.id }) {
                        if result.reports[slot].bitCount <= 8 * 1_048_576 - bits {
                            result.reports[slot].bitCount += bits
                        } else { result.warnings.append(L("报告累计长度超过解析上限", "Total report length exceeds the parser limit")) }
                    } else {
                        result.reports.append(ReportLayout(kind: kind, reportID: globals.id, bitCount: bits))
                    }
                }
            }
        }
        if !stack.isEmpty { result.warnings.append(L("Global Push/Pop 不平衡", "Unbalanced Global Push/Pop")) }
        if collections != 0 { result.warnings.append(L("Collection 未闭合", "Unclosed Collection")) }
        if result.reports.contains(where: { $0.reportID == 0 }) && result.reports.contains(where: { $0.reportID != 0 }) {
            result.warnings.append(L("描述符混用了编号和未编号报告", "Descriptor mixes numbered and unnumbered reports"))
        }
        if bytes.isEmpty { result.warnings.append(L("系统未提供 Report Descriptor", "The system did not provide a Report Descriptor")) }
        result.reports.sort { ($0.kind.rawValue, $0.reportID) < ($1.kind.rawValue, $1.reportID) }
        result.lengthsAreReliable = result.warnings.isEmpty
        return result
    }
}

public func hex(_ value: UInt32) -> String { String(format: "0x%04X", value) }
public func hexBytes(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
