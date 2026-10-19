import Foundation

/// Fixed report-rate (polling rate) memory commands for ordinary MT760
/// (MouseForTelink, wired, firmware V0.1.4.4).
///
/// Derived from the official library (static analysis, not a captured transaction):
/// - Address: object member +0x3ac. The MouseForTelink constructor's address table gives
///   0x630 (qword index 0x75 high half; +0x3b4 = 0x638 DPI and +0x3bc = 0x648 auxiliary
///   come from the same table and are confirmed by the observed DPI read).
/// - `MouseForTelink::getReturnRate`: getDeviceMemory `[08][LE32 0x630]` → 8-byte block.
///   Working buffer +0xe4 (data byte 0) = wired rate code, +0xe5 (data byte 1) = wireless code.
///   +0xe4 is data byte 0 here exactly as in getDPIListInfo, whose LE16 slots start at +0xe4.
/// - `MouseForTelink::setReturnRate(int, index)`: first the same 8-byte read, then
///   setDeviceMemory `[04][LE32 0x630][code, code, old data 2, old data 3]`; it writes the
///   SAME code to the wired and the wireless byte regardless of the wired/wireless flag.
///   Data bytes 4…7 of the block are not part of the write.
/// - Code table (BaseDevice ctor, object +0x148, index → code; reverse hash at +0x150):
///   08, 04, 02, 01, 84, 82, 81 for index 0…6; index → Hz list in setReturnRate:
///   125, 250, 500, 1000, 2000, 4000, 8000.
/// - `PollingRatePanel_MT.qml` offers only 125/250/500/1000 Hz unless chipType is 10 or 13;
///   this tool therefore allows only those four as targets.
public enum MT760ReportRateCommand {
    public static let read: [UInt8] = [0xBA, 0xFF, 0xA4, 0x08, 0x30, 0x06, 0x00, 0x00]
    public static let writeHeader: [UInt8] = [0xBA, 0xFF, 0xA5, 0x04, 0x30, 0x06, 0x00, 0x00]
    public static let blockLength = 8
    public static let writeDataLength = 4
    /// Same 4-byte status header as the observed 28-byte DPI read.
    public static let responseDataOffset = 4

    public static let codeTable: [(hz: Int, code: UInt8)] = [
        (125, 0x08), (250, 0x04), (500, 0x02), (1000, 0x01), (2000, 0x84), (4000, 0x82), (8000, 0x81),
    ]
    /// Rates the official MT760 panel offers for this chip type.
    public static let supportedRates = [125, 250, 500, 1000]

    public static func hz(forCode code: UInt8) -> Int? { codeTable.first { $0.code == code }?.hz }
    /// Only for supported targets; 2000+ codes are never written by this tool.
    public static func code(forTarget hz: Int) -> UInt8? {
        guard supportedRates.contains(hz) else { return nil }
        return codeTable.first { $0.hz == hz }?.code
    }
    public static func isValidTarget(_ hz: Int) -> Bool { code(forTarget: hz) != nil }
}

public struct ReportRateSnapshot: Codable, Equatable {
    /// The full 8-byte block at 0x630 (data bytes, without the status header).
    public let block: [UInt8]
    public let wiredHz: Int
    /// Not used by the wired MT760 UI; reported raw because the official setter overwrites it.
    public let wirelessCode: UInt8
    public let wirelessHz: Int?

    private init(block: [UInt8]) throws {
        guard block.count == MT760ReportRateCommand.blockLength else {
            throw DPIReadError.invalid(L("回报率数据块长度无效。", "Invalid report-rate block length."))
        }
        guard let wired = MT760ReportRateCommand.hz(forCode: block[0]) else {
            throw DPIReadError.invalid(L("有线回报率编码 \(hex(UInt32(block[0]))) 不在官方编码表中；未解析。", "Wired report-rate code \(hex(UInt32(block[0]))) is not in the official code table; not parsed."))
        }
        guard MT760ReportRateCommand.supportedRates.contains(wired) else {
            throw DPIReadError.invalid(L("有线回报率 \(wired) Hz 超出官方 MT760 界面提供的 125–1000 Hz；未解析。", "Wired report rate \(wired) Hz is outside the 125–1000 Hz offered by the official MT760 UI; not parsed."))
        }
        self.block = block
        wiredHz = wired
        wirelessCode = block[1]
        wirelessHz = MT760ReportRateCommand.hz(forCode: block[1])
    }

    private enum CodingKeys: String, CodingKey { case block, wiredHz, wirelessCode, wirelessHz }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(block: values.decode([UInt8].self, forKey: .block))
        guard try values.decode(Int.self, forKey: .wiredHz) == wiredHz,
              try values.decode(UInt8.self, forKey: .wirelessCode) == wirelessCode,
              try values.decodeIfPresent(Int.self, forKey: .wirelessHz) == wirelessHz else {
            throw DPIReadError.invalid(L("读取结果 JSON 的回报率模型与原始字节不一致。", "Report-rate model in the read result JSON does not match the raw bytes."))
        }
    }

    /// Response = 4-byte status header + 8 data bytes. The length of this response has not
    /// been observed; accept 12…32 bytes (BA Input capacity) and use only bytes 4…11.
    public static func decode(_ response: [UInt8]) throws -> Self {
        let start = MT760ReportRateCommand.responseDataOffset
        let end = start + MT760ReportRateCommand.blockLength
        guard (end...MT760WarmRead.inputCapacity).contains(response.count) else {
            throw DPIReadError.invalid(L("回报率响应长度为 \(response.count)，不在预期的 \(end)–\(MT760WarmRead.inputCapacity) 字节；未尝试剥头或补零。", "Report-rate response is \(response.count) bytes, outside the expected \(end)–\(MT760WarmRead.inputCapacity) bytes; no header stripping or zero padding was attempted."))
        }
        guard response[0] == 1 else {
            throw DPIReadError.invalid(response[0] == 2 ? L("设备忙；本版不重发请求。", "Device busy; this version does not resend requests.") : L("响应状态未知：\(hex(UInt32(response[0])))。", "Unknown response status: \(hex(UInt32(response[0])))."))
        }
        return try Self(block: Array(response[start..<end]))
    }
}

/// A report-rate change built only from fresh device bytes, mirroring the official setter.
/// Written data: `code, code, block[2], block[3]`. Only block bytes 0 and 1 may differ.
public struct ReportRateWritePlan: Codable, Equatable {
    public let oldHz: Int
    public let newHz: Int
    public let baselineBlock: [UInt8]
    public let data: [UInt8]
    public let request: [UInt8]
    /// The whole 8-byte block expected on readback (bytes 4…7 are not written and must stay).
    public let expectedBlock: [UInt8]

    public static func make(readResponse: [UInt8], targetHz: Int) throws -> Self {
        let snapshot = try ReportRateSnapshot.decode(readResponse)
        guard let code = MT760ReportRateCommand.code(forTarget: targetHz) else {
            throw DPIReadError.invalid(L("目标回报率 \(targetHz) Hz 无效：仅支持 125 / 250 / 500 / 1000 Hz。", "Target report rate \(targetHz) Hz is invalid: only 125 / 250 / 500 / 1000 Hz are supported."))
        }
        guard targetHz != snapshot.wiredHz else {
            throw DPIReadError.invalid(L("当前回报率已经是 \(targetHz) Hz，不发送写入。", "The report rate is already \(targetHz) Hz; no write sent."))
        }
        // The official setter overwrites the wireless byte too; refuse if its current value
        // is outside the known code table rather than overwrite an unexplained value.
        guard snapshot.wirelessHz != nil else {
            throw DPIReadError.invalid(L("无线回报率字节为 \(hex(UInt32(snapshot.wirelessCode)))，不在官方编码表中；官方写入会覆盖它，语义未知，拒绝写入。", "The wireless report-rate byte is \(hex(UInt32(snapshot.wirelessCode))), which is not in the official code table; the official write would overwrite it. Its meaning is unknown, so the write is refused."))
        }
        let baseline = snapshot.block
        let data = [code, code, baseline[2], baseline[3]]
        var expected = baseline
        expected[0] = code; expected[1] = code
        let changed = (0..<expected.count).filter { expected[$0] != baseline[$0] }
        guard !changed.isEmpty, Set(changed).isSubset(of: [0, 1]) else {
            throw DPIReadError.invalid(L("内部校验失败：差异超出回报率字节。", "Internal check failed: differences extend beyond the report-rate bytes."))
        }
        return Self(oldHz: snapshot.wiredHz, newHz: targetHz, baselineBlock: baseline, data: data,
                    request: MT760ReportRateCommand.writeHeader + data, expectedBlock: expected)
    }

    /// Readback must reproduce the written bytes and leave the unwritten bytes unchanged.
    public func verify(readback response: [UInt8]) throws -> ReportRateSnapshot {
        let snapshot = try ReportRateSnapshot.decode(response)
        guard snapshot.block == expectedBlock else {
            throw DPIReadError.invalid(L("读回的回报率数据块与预期不一致。", "Readback report-rate block does not match the expected value."))
        }
        guard snapshot.wiredHz == newHz else {
            throw DPIReadError.invalid(L("读回的回报率与计划不一致。", "Readback report rate does not match the plan."))
        }
        return snapshot
    }
}

public struct ReportRateReadOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public var exchange: HIDExchange?
    public var snapshot: ReportRateSnapshot?
    public var error: String?
    public var configurationWritten = false
    public var scope = "Single explicit MT760 V0.1.4.4 report-rate read of 0x630 (8 bytes); no configuration writes, retries, or automatic initialization."

    public init(registryID: String) { self.registryID = registryID }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Re-derives the snapshot from the raw exchange. Used by the App to reject inconsistent helper output.
    public func validateConsistency() throws {
        guard !configurationWritten else { throw DPIReadError.invalid(L("读取结果声称写入了配置。", "Read result claims that configuration was written.")) }
        if let exchange {
            guard exchange.step == "readRate", exchange.request == MT760ReportRateCommand.read else {
                throw DPIReadError.invalid(L("读取记录包含非预期请求。", "Read record contains unexpected requests."))
            }
        }
        if error == nil {
            guard let exchange, let snapshot, exchange.outputIOReturn == 0, exchange.inputIOReturn == 0,
                  exchange.inputActualLength == exchange.response.count,
                  try ReportRateSnapshot.decode(exchange.response) == snapshot else {
                throw DPIReadError.invalid(L("回报率读取结果未通过完整性验证。", "Report-rate read result failed integrity verification."))
            }
        } else if snapshot != nil {
            throw DPIReadError.invalid(L("失败结果包含旧的回报率数据，已拒绝显示。", "The failed result contains stale report-rate data; refused to display it."))
        }
    }
}

public struct ReportRateWriteOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public let targetHz: Int
    /// The 8-byte block the user previewed; the fresh read must match exactly.
    public let expectedBaseline: [UInt8]
    public var exchanges: [HIDExchange] = []
    public var baseline: ReportRateSnapshot?
    public var plan: ReportRateWritePlan?
    public var writeRequestSent = false
    public var readback: ReportRateSnapshot?
    public var verified = false
    public var error: String?
    public var persistenceVerified = false
    public var scope = "Single explicit MT760 V0.1.4.4 report-rate write: fresh read, one write, one readback. No retries of any request; busy status only polls GetReport."

    public init(registryID: String, targetHz: Int, expectedBaseline: [UInt8]) {
        self.registryID = registryID; self.targetHz = targetHz; self.expectedBaseline = expectedBaseline
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Re-derives every claim from raw exchanges. Used by the App to reject inconsistent helper output.
    public func validateConsistency() throws {
        let steps = exchanges.map(\.step)
        guard steps.count <= 3, steps == Array(["readRate", "write", "readback"].prefix(steps.count)) else {
            throw DPIReadError.invalid(L("回报率写入记录的步骤顺序异常。", "Report-rate write record has steps in an unexpected order."))
        }
        let expectedRequests = [MT760ReportRateCommand.read, plan?.request, MT760ReportRateCommand.read]
        for (index, exchange) in exchanges.enumerated() where exchange.request != expectedRequests[index] {
            throw DPIReadError.invalid(L("回报率写入记录包含非预期请求。", "Report-rate write record contains unexpected requests."))
        }
        guard writeRequestSent == (exchanges.count >= 2) else {
            throw DPIReadError.invalid(L("写入发送标记与记录不一致。", "The write-sent flag does not match the record."))
        }
        if verified {
            guard error == nil, exchanges.count == 3, let plan, let readback,
                  exchanges.allSatisfy({ $0.outputIOReturn == 0 && $0.inputIOReturn == 0 && $0.inputActualLength == $0.response.count }),
                  try ReportRateSnapshot.decode(exchanges[0].response).block == expectedBaseline,
                  try ReportRateWritePlan.make(readResponse: exchanges[0].response, targetHz: targetHz) == plan,
                  exchanges[1].response.first == 1,
                  try plan.verify(readback: exchanges[2].response) == readback else {
                throw DPIReadError.invalid(L("回报率写入结果未通过完整性验证。", "Report-rate write result failed integrity verification."))
            }
        } else if error == nil {
            throw DPIReadError.invalid(L("未验证的写入结果缺少错误说明。", "Unverified write result has no error description."))
        }
    }
}
