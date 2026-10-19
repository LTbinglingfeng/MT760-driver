import Foundation

/// Fixed memory commands for ordinary MT760 (MouseForTelink, wired, firmware V0.1.4.4).
///
/// Derived from the official library (static analysis, not a captured write transaction):
/// - Message table 0x7D4 (getDeviceMemory) prefix `BA FF A4`; 0x7D5 (setDeviceMemory) prefix `BA FF A5`.
/// - Caller parameters are `[length][LE32 address][data…]`.
/// - DPI configuration block: address 0x638 (object member +0x3b4), 20 bytes written.
/// - Auxiliary read: address 0x648 (member +0x3bc), 8 bytes; 0x648 = 0x638 + 16, so it
///   overlaps data offsets 16…19 of the DPI block (current gear and three unknown bytes).
public enum MT760DPICommand {
    public static let readConfig: [UInt8] = MT760WarmRead.request // BA FF A4 18 38 06 00 00
    public static let readAuxiliary: [UInt8] = [0xBA, 0xFF, 0xA4, 0x08, 0x48, 0x06, 0x00, 0x00]
    public static let writeHeader: [UInt8] = [0xBA, 0xFF, 0xA5, 0x14, 0x38, 0x06, 0x00, 0x00]
    public static let configDataLength = 20
    /// Response offset of data byte 0 in the observed 28-byte read (4-byte status header).
    public static let responseDataOffset = 4
    /// MouseForTelink::getDPISupportInfo: MinValue 50, MaxValue 4000, StepValue 50, MaxGear 7.
    public static let dpiRange = 50...4000
    public static let dpiStep = 50

    /// Clamp before arithmetic so even Int.min/max are safe; positive half-steps round up.
    public static func normalizedTarget(_ value: Int) -> Int {
        let clamped = min(max(value, dpiRange.lowerBound), dpiRange.upperBound)
        return ((clamped + dpiStep / 2) / dpiStep) * dpiStep
    }

    public static func isValidTarget(_ dpi: Int) -> Bool { dpiRange.contains(dpi) && dpi % dpiStep == 0 }
}

/// A single-slot DPI change, built only from fresh device bytes.
///
/// 20-byte data layout (setDPIListInfo, non-BLE branch):
/// 0–13 seven LE16 (DPI/50) · 14 Size−1 · 15 zero · 16 CurDpiGear−1 · 17–19 auxiliary B[5…7].
/// The plan preserves every baseline byte except the current slot's two bytes; it refuses
/// rather than normalize when an unknown field would have to change.
public struct DPIWritePlan: Codable, Equatable {
    public let gear: Int
    public let oldDPI: Int
    public let newDPI: Int
    public let baselineData: [UInt8]
    public let data: [UInt8]
    public let request: [UInt8]
    public let expectedLevels: [Int]
    public let activeCount: Int

    public static func baselineData(fromConfigResponse response: [UInt8]) throws -> [UInt8] {
        _ = try DPISnapshot.decode(response)
        let start = MT760DPICommand.responseDataOffset
        return Array(response[start..<(start + MT760DPICommand.configDataLength)])
    }

    public static func make(configResponse: [UInt8], auxiliaryResponse aux: [UInt8], targetDPI: Int) throws -> Self {
        let snapshot = try DPISnapshot.decode(configResponse)
        guard MT760DPICommand.isValidTarget(targetDPI) else {
            throw DPIReadError.invalid(L("目标 DPI \(targetDPI) 无效：MT760 仅支持 50–4000、步进 50。", "Target DPI \(targetDPI) is invalid: MT760 supports only 50–4000 in steps of 50."))
        }
        guard targetDPI != snapshot.currentDPI else {
            throw DPIReadError.invalid(L("当前档位已经是 \(targetDPI) DPI，不发送写入。", "The current level is already \(targetDPI) DPI; no write sent."))
        }
        var data = try baselineData(fromConfigResponse: configResponse)
        guard data[15] == 0 else {
            throw DPIReadError.invalid(L("配置数据第 15 字节为 \(hex(UInt32(data[15])))，官方写入会将其清零；语义未知，拒绝写入。", "Config data byte 15 is \(hex(UInt32(data[15]))); the official write would clear it. Its meaning is unknown, so the write is refused."))
        }
        // Auxiliary response must carry the same status header and overlap the config block.
        guard (8...32).contains(aux.count) else {
            throw DPIReadError.invalid(L("辅助读取响应长度 \(aux.count) 不在预期范围；未写入。", "Auxiliary read response length \(aux.count) is outside the expected range; nothing was written."))
        }
        guard aux[0] == 1 else {
            throw DPIReadError.invalid(aux[0] == 2 ? L("辅助读取时设备忙；未写入，不重试。", "Device busy during the auxiliary read; nothing was written, not retried.") : L("辅助读取状态未知：\(hex(UInt32(aux[0])))；未写入。", "Unknown auxiliary read status: \(hex(UInt32(aux[0]))); nothing was written."))
        }
        guard Array(aux[4...7]) == Array(data[16...19]) else {
            throw DPIReadError.invalid(L("辅助区域 0x648 与配置块 0x638 的重叠字节不一致；布局假设不成立，未写入。", "Overlapping bytes of auxiliary area 0x648 and config block 0x638 differ; the layout assumption does not hold, nothing was written."))
        }
        let slot = snapshot.currentGear - 1
        let units = UInt16(targetDPI / MT760DPICommand.dpiStep)
        let baseline = data
        data[slot * 2] = UInt8(truncatingIfNeeded: units)
        data[slot * 2 + 1] = UInt8(units >> 8)
        data[17] = aux[5]; data[18] = aux[6]; data[19] = aux[7] // official order (no swap)
        let changed = (0..<data.count).filter { data[$0] != baseline[$0] }
        guard Set(changed).isSubset(of: [slot * 2, slot * 2 + 1]), !changed.isEmpty else {
            throw DPIReadError.invalid(L("内部校验失败：差异超出当前档位字节。", "Internal check failed: differences extend beyond the current level bytes."))
        }
        var levels = snapshot.levels
        levels[slot] = targetDPI
        return Self(gear: snapshot.currentGear, oldDPI: snapshot.currentDPI, newDPI: targetDPI,
                    baselineData: baseline, data: data, request: MT760DPICommand.writeHeader + data,
                    expectedLevels: levels, activeCount: snapshot.activeCount)
    }

    /// Readback must reproduce exactly the written 20 bytes and decode to the planned model.
    public func verify(readback response: [UInt8]) throws -> DPISnapshot {
        let snapshot = try DPISnapshot.decode(response)
        let start = MT760DPICommand.responseDataOffset
        guard Array(response[start..<(start + MT760DPICommand.configDataLength)]) == data else {
            throw DPIReadError.invalid(L("读回的配置字节与写入数据不一致。", "Readback configuration bytes do not match the written data."))
        }
        guard snapshot.levels == expectedLevels, snapshot.activeCount == activeCount, snapshot.currentGear == gear else {
            throw DPIReadError.invalid(L("读回的 DPI 模型与计划不一致。", "Readback DPI model does not match the plan."))
        }
        return snapshot
    }
}

/// One SetReport(Output) followed by synchronous GetReport(Input) on the same handle.
public struct HIDExchange: Codable, Equatable {
    public let step: String
    public let request: [UInt8]
    public var outputIOReturn: Int32?
    public var inputIOReturn: Int32?
    public var inputActualLength: Int?
    public var response: [UInt8] = []
    /// Extra GetReport calls while status byte was 2 (busy). The request is never resent.
    public var busyPolls = 0

    public init(step: String, request: [UInt8]) { self.step = step; self.request = request }
}

public struct DPIWriteOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public let targetDPI: Int
    /// Config bytes 0–19 the user previewed; the fresh baseline must match exactly.
    public let expectedBaseline: [UInt8]
    public var exchanges: [HIDExchange] = []
    public var baseline: DPISnapshot?
    public var plan: DPIWritePlan?
    public var writeRequestSent = false
    public var readback: DPISnapshot?
    public var verified = false
    public var error: String?
    public var persistenceVerified = false
    public var scope = "Single explicit MT760 V0.1.4.4 current-slot DPI write: fresh read, auxiliary read, one write, one readback. No retries of any request; busy status only polls GetReport."

    public init(registryID: String, targetDPI: Int, expectedBaseline: [UInt8]) {
        self.registryID = registryID; self.targetDPI = targetDPI; self.expectedBaseline = expectedBaseline
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
        guard steps.count <= 4, steps == Array(["readConfig", "readAuxiliary", "write", "readback"].prefix(steps.count)) else {
            throw DPIReadError.invalid(L("写入记录的步骤顺序异常。", "Write record has steps in an unexpected order."))
        }
        let expectedRequests = [MT760DPICommand.readConfig, MT760DPICommand.readAuxiliary, plan?.request, MT760DPICommand.readConfig]
        for (index, exchange) in exchanges.enumerated() where exchange.request != expectedRequests[index] {
            throw DPIReadError.invalid(L("写入记录包含非预期请求。", "Write record contains unexpected requests."))
        }
        guard writeRequestSent == (exchanges.count >= 3) else {
            throw DPIReadError.invalid(L("写入发送标记与记录不一致。", "The write-sent flag does not match the record."))
        }
        if verified {
            guard error == nil, exchanges.count == 4, let plan, let readback,
                  exchanges.allSatisfy({ $0.outputIOReturn == 0 && $0.inputIOReturn == 0 && $0.inputActualLength == $0.response.count }),
                  try DPIWritePlan.baselineData(fromConfigResponse: exchanges[0].response) == expectedBaseline,
                  try DPIWritePlan.make(configResponse: exchanges[0].response, auxiliaryResponse: exchanges[1].response, targetDPI: targetDPI) == plan,
                  exchanges[2].response.first == 1,
                  try plan.verify(readback: exchanges[3].response) == readback else {
                throw DPIReadError.invalid(L("写入结果未通过完整性验证。", "Write result failed integrity verification."))
            }
        } else if error == nil {
            throw DPIReadError.invalid(L("未验证的写入结果缺少错误说明。", "Unverified write result has no error description."))
        }
    }
}
