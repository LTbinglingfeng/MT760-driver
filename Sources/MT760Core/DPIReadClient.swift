import Foundation
import Darwin

struct HelperOutput {
    let data: Data
    let status: Int32
}

/// The helper may block in IOKit; this supervisor never blocks the main/UI thread.
/// Temporary files avoid pipe-buffer deadlocks. Only the helper PID is terminated.
// All mutable state is initialized before publication, then confined to queue.
final class BoundedHelperProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.mt760.helper-supervisor")
    private let process = Process()
    private var timer: DispatchSourceTimer?
    private var completed = false
    private var timedOut = false
    private var continuation: CheckedContinuation<HelperOutput, Error>?
    private var directory: URL?
    private var output: FileHandle?
    private var errors: FileHandle?

    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> HelperOutput {
        try await withCheckedThrowingContinuation { continuation in
            let request = BoundedHelperProcess()
            request.continuation = continuation
            request.queue.async { request.start(executable: executable, arguments: arguments, timeout: timeout) }
        }
    }

    private func start(executable: URL, arguments: [String], timeout: TimeInterval) {
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MT760-read-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            directory = dir
            let out = dir.appendingPathComponent("stdout")
            let err = dir.appendingPathComponent("stderr")
            guard FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                  FileManager.default.createFile(atPath: err.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw DPIReadError.invalid(L("无法创建读取结果临时文件。", "Could not create the temporary read-result file."))
            }
            output = try FileHandle(forUpdating: out)
            errors = try FileHandle(forUpdating: err)
            process.executableURL = executable
            process.arguments = arguments
            // Helper messages are shown in the UI; keep them in the language selected at spawn time.
            var environment = ProcessInfo.processInfo.environment
            environment["MT760_LANG"] = MT760Language.current.code
            process.environment = environment
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [self] _ in queue.async { self.exited() } }
            try process.run()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [self] in
                guard !completed, process.isRunning else { return }
                timedOut = true
                kill(process.processIdentifier, SIGKILL)
                // If the OS cannot promptly reap the process, return without hanging the UI.
                // The helper's held lock prevents another helper from issuing a request.
                queue.asyncAfter(deadline: .now() + 0.5) { [self] in
                    finish(.failure(DPIReadError.invalid(L("读取超时，已请求终止辅助进程。设备可能已处理读请求；不自动重试。", "Read timed out; the helper was asked to terminate. The device may have processed the read request; no automatic retry."))))
                }
            }
            self.timer = timer
            timer.resume()
        } catch { finish(.failure(error)) }
    }

    private func exited() {
        guard !completed else { return }
        if timedOut || process.terminationStatus == 124 {
            finish(.failure(DPIReadError.invalid(L("读取超过时限，辅助进程已退出；设备是否完成请求未知。没有重试。", "The read exceeded its time limit and the helper exited; whether the device completed the request is unknown. Not retried."))))
            return
        }
        if process.terminationStatus == 125 {
            finish(.failure(DPIReadError.invalid(L("父进程结束，辅助读取已停止。", "Parent process ended; the helper read was stopped."))))
            return
        }
        do {
            try output?.seek(toOffset: 0)
            let data = try output?.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw DPIReadError.invalid(L("辅助进程输出超过上限。", "Helper output exceeds the size limit.")) }
            finish(.success(HelperOutput(data: data, status: process.terminationStatus)))
        } catch { finish(.failure(error)) }
    }

    private func finish(_ result: Result<HelperOutput, Error>) {
        guard !completed else { return }
        completed = true
        timer?.cancel(); timer = nil
        process.terminationHandler = nil
        try? output?.close(); try? errors?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        continuation?.resume(with: result)
        continuation = nil
    }
}

public enum DPIReadClient {
    /// Read-only transaction, run by the App's serialized device queue (on connection, ⌘R,
    /// activation, or to resync after a failed write).
    public static func read(helperURL: URL, registryID: String) async throws -> DPIReadOutcome {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw DPIReadError.invalid(L("找不到读取辅助程序，请重新运行 scripts/build-app.sh。不会退回主进程访问设备。", "Read helper not found; run scripts/build-app.sh again. The main process will not access the device as a fallback."))
        }
        guard registryID.count <= 16, !registryID.isEmpty, registryID.allSatisfy({ $0.isHexDigit }),
              let parsedID = UInt64(registryID, radix: 16) else {
            throw DPIReadError.invalid(L("设备 Registry ID 无效。", "Invalid device Registry ID."))
        }
        let canonicalID = String(parsedID, radix: 16)
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--read-dpi-warm", "--registry-id", canonicalID, "--confirm-mt760-v144"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: DPIReadOutcome
        do { result = try decoder.decode(DPIReadOutcome.self, from: output.data) }
        catch { throw DPIReadError.invalid(L("辅助进程未返回有效结果（退出码 \(output.status)）；不重试。", "The helper returned no valid result (exit code \(output.status)); not retried.")) }
        guard result.schemaVersion == 1, result.registryID == canonicalID,
              result.request == MT760WarmRead.request, !result.configurationWritten, !result.coldStartVerified else {
            throw DPIReadError.invalid(L("辅助进程返回的设备身份或协议范围不匹配。", "Device identity or protocol scope returned by the helper does not match."))
        }
        if result.error == nil {
            guard output.status == 0, result.outputIOReturn == 0, result.inputIOReturn == 0,
                  result.inputActualLength == result.response.count,
                  try DPISnapshot.decode(result.response) == result.snapshot else {
                throw DPIReadError.invalid(L("读取结果未通过完整性验证。", "Read result failed integrity verification."))
            }
        } else if result.snapshot != nil {
            throw DPIReadError.invalid(L("失败结果包含旧的 DPI 数据，已拒绝显示。", "The failed result contains stale DPI data; refused to display it."))
        }
        return result
    }
}

public enum DPIWriteClient {
    /// Run directly from the user's control change (no dialog). `expectedBaseline` comes from the latest
    /// verified read or readback shown in the UI; the helper aborts without writing if the device differs.
    public static func write(helperURL: URL, registryID: String, targetDPI: Int, expectedBaseline: [UInt8]) async throws -> DPIWriteOutcome {
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw DPIReadError.invalid(L("找不到辅助程序，请重新运行 scripts/build-app.sh。不会退回主进程访问设备。", "Helper not found; run scripts/build-app.sh again. The main process will not access the device as a fallback."))
        }
        guard registryID.count <= 16, !registryID.isEmpty, registryID.allSatisfy({ $0.isHexDigit }),
              let parsedID = UInt64(registryID, radix: 16) else {
            throw DPIReadError.invalid(L("设备 Registry ID 无效。", "Invalid device Registry ID."))
        }
        guard MT760DPICommand.isValidTarget(targetDPI) else {
            throw DPIReadError.invalid(L("目标 DPI 必须在 50–4000 之间且为 50 的倍数。", "Target DPI must be between 50 and 4000 and a multiple of 50."))
        }
        guard expectedBaseline.count == MT760DPICommand.configDataLength else {
            throw DPIReadError.invalid(L("缺少有效的读取基线；请先读取 DPI。", "No valid read baseline; read DPI first."))
        }
        let canonicalID = String(parsedID, radix: 16)
        let baselineHex = expectedBaseline.map { String(format: "%02x", $0) }.joined()
        // Write transaction has four exchanges; helper deadline 5 s, supervisor 8 s.
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--write-current-dpi", "--registry-id", canonicalID, "--target-dpi", String(targetDPI),
                        "--expect-config", baselineHex, "--confirm-mt760-v144-write"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: DPIWriteOutcome
        do { result = try decoder.decode(DPIWriteOutcome.self, from: output.data) }
        catch { throw DPIReadError.invalid(L("辅助进程未返回有效写入结果（退出码 \(output.status)）；设备状态可能不确定，请重新读取。不重试。", "The helper returned no valid write result (exit code \(output.status)); the device state may be uncertain, please read again. Not retried.")) }
        guard result.schemaVersion == 1, result.registryID == canonicalID, result.targetDPI == targetDPI,
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

public enum DPIGearClient {
    /// Run directly from the user's control change (no dialog). `expectedBaseline` comes from the latest
    /// verified read or readback shown in the UI; the helper aborts without writing if the device differs.
    public static func switchGear(helperURL: URL, registryID: String, targetGear: Int, expectedBaseline: [UInt8]) async throws -> DPIGearSwitchOutcome {
        try ReportRateClient.requireHelper(helperURL)
        let id = try ReportRateClient.canonicalID(registryID)
        guard MT760DPIGearCommand.isValidTarget(targetGear) else {
            throw DPIReadError.invalid(L("目标档位必须是 1–7。", "Target level must be 1–7."))
        }
        guard expectedBaseline.count == MT760DPICommand.configDataLength else {
            throw DPIReadError.invalid(L("缺少有效的读取基线；请先读取 DPI。", "No valid read baseline; read DPI first."))
        }
        let baselineHex = expectedBaseline.map { String(format: "%02x", $0) }.joined()
        let output = try await BoundedHelperProcess.run(executable: helperURL,
            arguments: ["--switch-dpi-gear", "--registry-id", id, "--target-gear", String(targetGear),
                        "--expect-config", baselineHex, "--confirm-mt760-v144-write"], timeout: 8)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result: DPIGearSwitchOutcome
        do { result = try decoder.decode(DPIGearSwitchOutcome.self, from: output.data) }
        catch { throw DPIReadError.invalid(L("辅助进程未返回有效切档结果（退出码 \(output.status)）；设备状态可能不确定，请重新读取。不重试。", "The helper returned no valid level-switch result (exit code \(output.status)); the device state may be uncertain, please read again. Not retried.")) }
        guard result.schemaVersion == 1, result.registryID == id, result.targetGear == targetGear,
              result.expectedBaseline == expectedBaseline, !result.persistenceVerified else {
            throw DPIReadError.invalid(L("辅助进程返回的设备身份或切档参数不匹配。", "Device identity or level-switch parameters returned by the helper do not match."))
        }
        try result.validateConsistency()
        if result.verified, output.status != 0 {
            throw DPIReadError.invalid(L("辅助进程退出码与切档结果不一致。", "Helper exit code does not match the level-switch result."))
        }
        return result
    }
}
