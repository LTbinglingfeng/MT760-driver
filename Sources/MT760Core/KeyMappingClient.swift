import Foundation

/// Supervises the helper for key-mapping transactions; never touches HID in-process.
public enum KeyMappingClient {
    /// Read-only transaction, run by the App's serialized device queue (on connection, ⌘R,
    /// activation, or to resync after a failed write).
    public static func read(helperURL: URL, registryID: String) async throws -> KeyMappingReadOutcome {
        try ReportRateClient.requireHelper(helperURL)
        let id = try ReportRateClient.canonicalID(registryID)
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--read-key-mapping", "--registry-id", id, "--confirm-mt760-v144"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: KeyMappingReadOutcome
        do { result = try decoder.decode(KeyMappingReadOutcome.self, from: output.data) }
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
    public static func write(helperURL: URL, registryID: String, keyID: Int, function: KeyFunction,
                             baseline: KeyMappingSnapshot) async throws -> KeyWriteOutcome {
        try ReportRateClient.requireHelper(helperURL)
        let id = try ReportRateClient.canonicalID(registryID)
        try KeyMappingRules.validate(keyID: keyID, function: function, slots: baseline.slots)
        let slot = function.slot
        let expected = baseline.flattened
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--write-key", "--registry-id", id, "--key-id", String(keyID),
                        "--target-slot", slot.map { String(format: "%02x", $0) }.joined(),
                        "--expect-key-slots", expected.map { String(format: "%02x", $0) }.joined(),
                        "--confirm-mt760-v144-write"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: KeyWriteOutcome
        do { result = try decoder.decode(KeyWriteOutcome.self, from: output.data) }
        catch { throw DPIReadError.invalid(L("辅助进程未返回有效写入结果（退出码 \(output.status)）；设备状态可能不确定，请重新读取。不重试。", "The helper returned no valid write result (exit code \(output.status)); the device state may be uncertain, please read again. Not retried.")) }
        guard result.schemaVersion == 1, result.registryID == id, result.keyID == keyID,
              result.targetSlot == slot, result.expectedBaseline == expected, !result.persistenceVerified else {
            throw DPIReadError.invalid(L("辅助进程返回的设备身份或写入参数不匹配。", "Device identity or write parameters returned by the helper do not match."))
        }
        try result.validateConsistency()
        if result.verified, output.status != 0 {
            throw DPIReadError.invalid(L("辅助进程退出码与写入结果不一致。", "Helper exit code does not match the write result."))
        }
        return result
    }
}
