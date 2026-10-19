import Foundation

/// Fixed current-gear (DPI level) switch command for ordinary MT760
/// (MouseForTelink, wired, firmware V0.1.4.4).
///
/// Derived from `MouseForTelink::setCurDPIGear(int)` @0x21bd60 (static analysis, not a captured
/// transaction; verified working on hardware by the author):
/// - pre-read getDeviceMemory `[08][LE32 0x648]` → `BA FF A4 08 48 06 00 00`, then keeps working
///   buffer B[5], B[6], B[7] (= response bytes 5…7, device 0x649…0x64B);
/// - setDeviceMemory `[04][LE32 0x648][gear−1][oldB5][oldB7][oldB6]` (9 caller bytes)
///   → 12-byte Output `BA FF A5 04 48 06 00 00 g−1 B5 B7 B6`.
/// The last two bytes are SWAPPED relative to the read (setDPIListInfo keeps the original order);
/// the reason is unknown. This tool sends the official bytes unchanged (user decision), so when
/// B6 ≠ B7 the write also exchanges 0x64A / 0x64B. The plan exposes that as `swapsUnknownBytes`
/// for the confirmation UI; nothing other than 0x648, 0x64A, 0x64B may differ.
public enum MT760DPIGearCommand {
    public static let writeHeader: [UInt8] = [0xBA, 0xFF, 0xA5, 0x04, 0x48, 0x06, 0x00, 0x00]
    public static let writeDataLength = 4
    /// Offset of 0x648 inside the 20-byte 0x638 configuration data.
    public static let gearDataOffset = 16
    public static let maxGear = 7

    public static func isValidTarget(_ gear: Int) -> Bool { (1...maxGear).contains(gear) }
}

/// A current-gear change built only from fresh device bytes.
public struct DPIGearSwitchPlan: Codable, Equatable {
    public let oldGear: Int
    public let newGear: Int
    public let oldDPI: Int
    public let newDPI: Int
    /// 0x638 configuration data 0–19 from the fresh read.
    public let baselineData: [UInt8]
    /// 0x648…0x64B as returned by the auxiliary read (response bytes 4…7).
    public let auxiliaryData: [UInt8]
    /// Written to 0x648…0x64B: gear−1, B5, B7, B6 (official order).
    public let data: [UInt8]
    public let request: [UInt8]
    /// Full configuration data expected on readback (byte 16, plus 18/19 when swapped).
    public let expectedData: [UInt8]
    /// True when the official write exchanges two differing unknown bytes (0x64A / 0x64B).
    public var swapsUnknownBytes: Bool { auxiliaryData[2] != auxiliaryData[3] }

    public static func make(configResponse: [UInt8], auxiliaryResponse aux: [UInt8], targetGear: Int) throws -> Self {
        let snapshot = try DPISnapshot.decode(configResponse)
        guard MT760DPIGearCommand.isValidTarget(targetGear) else {
            throw DPIReadError.invalid(L("目标档位 \(targetGear) 无效：MT760 最多 7 档。", "Target level \(targetGear) is invalid: MT760 has at most 7 levels."))
        }
        guard targetGear <= snapshot.activeCount else {
            throw DPIReadError.invalid(L("目标第 \(targetGear) 档未启用（当前启用 \(snapshot.activeCount) 档）；不切换到未启用的档位。", "Target level \(targetGear) is not enabled (\(snapshot.activeCount) levels enabled); not switching to a disabled level."))
        }
        guard targetGear != snapshot.currentGear else {
            throw DPIReadError.invalid(L("当前已经是第 \(targetGear) 档，不发送写入。", "Level \(targetGear) is already current; no write sent."))
        }
        let baseline = try DPIWritePlan.baselineData(fromConfigResponse: configResponse)
        guard (8...32).contains(aux.count) else {
            throw DPIReadError.invalid(L("辅助读取响应长度 \(aux.count) 不在预期范围；未写入。", "Auxiliary read response length \(aux.count) is outside the expected range; nothing was written."))
        }
        guard aux[0] == 1 else {
            throw DPIReadError.invalid(aux[0] == 2 ? L("辅助读取时设备忙；未写入，不重试。", "Device busy during the auxiliary read; nothing was written, not retried.") : L("辅助读取状态未知：\(hex(UInt32(aux[0])))；未写入。", "Unknown auxiliary read status: \(hex(UInt32(aux[0]))); nothing was written."))
        }
        let offset = MT760DPIGearCommand.gearDataOffset
        let auxData = Array(aux[4...7])
        guard auxData == Array(baseline[offset...(offset + 3)]) else {
            throw DPIReadError.invalid(L("辅助区域 0x648 与配置块 0x638 的重叠字节不一致；布局假设不成立，未写入。", "Overlapping bytes of auxiliary area 0x648 and config block 0x638 differ; the layout assumption does not hold, nothing was written."))
        }
        let data: [UInt8] = [UInt8(targetGear - 1), aux[5], aux[7], aux[6]] // official order (swap)
        var expected = baseline
        expected.replaceSubrange(offset...(offset + 3), with: data)
        let changed = (0..<expected.count).filter { expected[$0] != baseline[$0] }
        guard changed.contains(offset), Set(changed).isSubset(of: [offset, offset + 2, offset + 3]) else {
            throw DPIReadError.invalid(L("内部校验失败：差异超出当前档位字节。", "Internal check failed: differences extend beyond the current level bytes."))
        }
        return Self(oldGear: snapshot.currentGear, newGear: targetGear,
                    oldDPI: snapshot.currentDPI, newDPI: snapshot.levels[targetGear - 1],
                    baselineData: baseline, auxiliaryData: auxData, data: data,
                    request: MT760DPIGearCommand.writeHeader + data, expectedData: expected)
    }

    /// Readback of 0x638 must equal the planned data: baseline except the gear byte and the official swap.
    public func verify(readback response: [UInt8]) throws -> DPISnapshot {
        let snapshot = try DPISnapshot.decode(response)
        guard try DPIWritePlan.baselineData(fromConfigResponse: response) == expectedData else {
            throw DPIReadError.invalid(L("读回的配置字节与预期不一致。", "Readback configuration bytes do not match the expected value."))
        }
        guard snapshot.currentGear == newGear else {
            throw DPIReadError.invalid(L("读回的当前档位与计划不一致。", "Readback current level does not match the plan."))
        }
        return snapshot
    }
}

public struct DPIGearSwitchOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public let targetGear: Int
    /// Config bytes 0–19 the user previewed; the fresh baseline must match exactly.
    public let expectedBaseline: [UInt8]
    public var exchanges: [HIDExchange] = []
    public var baseline: DPISnapshot?
    public var plan: DPIGearSwitchPlan?
    public var writeRequestSent = false
    public var readback: DPISnapshot?
    public var verified = false
    public var error: String?
    public var persistenceVerified = false
    public var scope = "Single explicit MT760 V0.1.4.4 current-gear switch (setCurDPIGear bytes): fresh read, auxiliary read, one write to 0x648 (official bytes, including the 0x64A/0x64B swap), one readback. No retries of any request; busy status only polls GetReport."

    public init(registryID: String, targetGear: Int, expectedBaseline: [UInt8]) {
        self.registryID = registryID; self.targetGear = targetGear; self.expectedBaseline = expectedBaseline
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
            throw DPIReadError.invalid(L("切档记录的步骤顺序异常。", "Level-switch record has steps in an unexpected order."))
        }
        let expectedRequests = [MT760DPICommand.readConfig, MT760DPICommand.readAuxiliary, plan?.request, MT760DPICommand.readConfig]
        for (index, exchange) in exchanges.enumerated() where exchange.request != expectedRequests[index] {
            throw DPIReadError.invalid(L("切档记录包含非预期请求。", "Level-switch record contains unexpected requests."))
        }
        guard writeRequestSent == (exchanges.count >= 3) else {
            throw DPIReadError.invalid(L("写入发送标记与记录不一致。", "The write-sent flag does not match the record."))
        }
        if verified {
            guard error == nil, exchanges.count == 4, let plan, let readback,
                  exchanges.allSatisfy({ $0.outputIOReturn == 0 && $0.inputIOReturn == 0 && $0.inputActualLength == $0.response.count }),
                  try DPIWritePlan.baselineData(fromConfigResponse: exchanges[0].response) == expectedBaseline,
                  try DPIGearSwitchPlan.make(configResponse: exchanges[0].response, auxiliaryResponse: exchanges[1].response, targetGear: targetGear) == plan,
                  exchanges[2].response.first == 1,
                  try plan.verify(readback: exchanges[3].response) == readback else {
                throw DPIReadError.invalid(L("切档结果未通过完整性验证。", "Level-switch result failed integrity verification."))
            }
        } else if error == nil {
            throw DPIReadError.invalid(L("未验证的切档结果缺少错误说明。", "Unverified level-switch result has no error description."))
        }
    }
}
