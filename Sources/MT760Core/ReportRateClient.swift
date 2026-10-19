import Foundation

/// Supervises the helper for report-rate transactions; never touches HID in-process.
public enum ReportRateClient {
    static func canonicalID(_ registryID: String) throws -> String {
        guard registryID.count <= 16, !registryID.isEmpty, registryID.allSatisfy({ $0.isHexDigit }),
              let parsedID = UInt64(registryID, radix: 16) else {
            throw DPIReadError.invalid(L("设备 Registry ID 无效。", "Invalid device Registry ID."))
        }
        return String(parsedID, radix: 16)
    }

    static func requireHelper(_ helperURL: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw DPIReadError.invalid(L("找不到辅助程序，请重新运行 scripts/build-app.sh。不会退回主进程访问设备。", "Helper not found; run scripts/build-app.sh again. The main process will not access the device as a fallback."))
        }
    }

    /// Read-only transaction, run by the App's serialized device queue (on connection, ⌘R,
    /// activation, or to resync after a failed write).
    public static func read(helperURL: URL, registryID: String) async throws -> ReportRateReadOutcome {
        try requireHelper(helperURL)
        let id = try canonicalID(registryID)
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--read-report-rate", "--registry-id", id, "--confirm-mt760-v144"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: ReportRateReadOutcome
        do { result = try decoder.decode(ReportRateReadOutcome.self, from: output.data) }
        catch { throw DPIReadError.invalid(L("辅助进程未返回有效结果（退出码 \(output.status)）；不重试。", "The helper returned no valid result (exit code \(output.status)); not retried.")) }
        guard result.schemaVersion == 1, result.registryID == id else {
            throw DPIReadError.invalid(L("辅助进程返回的设备身份或协议范围不匹配。", "Device identity or protocol scope returned by the helper does not match."))
        }
        try result.validateConsistency()
        if result.error == nil, output.status != 0 {
            throw DPIReadError.invalid(L("辅助进程退出码与读取结果不一致。", "Helper exit code does not match the read result."))
        }
        return result
    }

    /// Run directly from the user's control change (no dialog). `expectedBaseline` comes from the latest
    /// verified read or readback shown in the UI; the helper aborts without writing if the device differs.
    public static func write(helperURL: URL, registryID: String, targetHz: Int, expectedBaseline: [UInt8]) async throws -> ReportRateWriteOutcome {
        try requireHelper(helperURL)
        let id = try canonicalID(registryID)
        guard MT760ReportRateCommand.isValidTarget(targetHz) else {
            throw DPIReadError.invalid(L("目标回报率必须是 125 / 250 / 500 / 1000 Hz。", "Target report rate must be 125 / 250 / 500 / 1000 Hz."))
        }
        guard expectedBaseline.count == MT760ReportRateCommand.blockLength else {
            throw DPIReadError.invalid(L("缺少有效的读取基线；请先读取回报率。", "No valid read baseline; read the report rate first."))
        }
        let baselineHex = expectedBaseline.map { String(format: "%02x", $0) }.joined()
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--write-report-rate", "--registry-id", id, "--target-hz", String(targetHz),
                        "--expect-rate-block", baselineHex, "--confirm-mt760-v144-write"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: ReportRateWriteOutcome
        do { result = try decoder.decode(ReportRateWriteOutcome.self, from: output.data) }
        catch { throw DPIReadError.invalid(L("辅助进程未返回有效写入结果（退出码 \(output.status)）；设备状态可能不确定，请重新读取。不重试。", "The helper returned no valid write result (exit code \(output.status)); the device state may be uncertain, please read again. Not retried.")) }
        guard result.schemaVersion == 1, result.registryID == id, result.targetHz == targetHz,
              result.expectedBaseline == expectedBaseline, !result.persistenceVerified else {
            throw DPIReadError.invalid(L("辅助进程返回的设备身份或写入参数不匹配。", "Device identity or write parameters returned by the helper do not match."))
        }
        try result.validateConsistency()
        if result.verified, output.status != 0 {
            throw DPIReadError.invalid(L("辅助进程退出码与写入结果不一致。", "Helper exit code does not match the write result."))
        }
        return result
    }
}
