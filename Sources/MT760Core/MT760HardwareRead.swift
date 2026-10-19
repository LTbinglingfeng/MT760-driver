import Foundation
import AppKit
import IOKit
import IOKit.hid

/// Synchronous, fixed-command transport. Call ONLY inside mt760-read-helper.
/// Main App/CLI enumeration never invokes this API. The helper owns the deadline.
public enum MT760HardwareRead {
    public static func officialAppIsRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.executableURL?.lastPathComponent == "A HUB Office" ||
            app.bundleURL?.lastPathComponent == "A HUB Office.app" ||
            app.localizedName == "A HUB Office"
        }
    }

    public static func readWarmOnce(registryID: String) -> DPIReadOutcome {
        var result = DPIReadOutcome(registryID: registryID)
        func failure(_ message: String) -> DPIReadOutcome {
            result.error = message
            result.completedAt = Date()
            return result
        }
        guard !officialAppIsRunning() else {
            return failure(L("请先退出 A HUB Office，避免同时通信。没有打开设备或发送请求。", "Please quit A HUB Office first to avoid concurrent communication. The device was not opened and no request was sent."))
        }
        let candidates = HIDEnumerator.devices().filter { HIDEnumerator.describe($0).id == registryID }
        guard candidates.count == 1, let device = candidates.first,
              HIDEnumerator.describe(device).canAttemptDPIRead else {
            return failure(L("所选设备已移除或不符合 MT760 温读取接口条件；没有发送请求。", "The selected device was removed or does not match the MT760 warm-read interface criteria; no request was sent."))
        }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            return failure(MT760HardwareRead.openFailureMessage(opened))
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard !officialAppIsRunning() else {
            return failure(L("检测到官方程序仍在运行，已关闭接口；没有发送请求。", "The official app is still running; the interface was closed and no request was sent."))
        }
        usleep(1000)
        // The observed nonzero-ID path includes BA both in the buffer and as the ID argument.
        let output = MT760WarmRead.request.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, MT760WarmRead.reportID, $0.baseAddress!, $0.count)
        }
        result.outputIOReturn = output
        guard output == kIOReturnSuccess else {
            return failure(L("读取请求发送失败：\(code(output))。不重试，不改变长度或 Report ID。", "Sending the read request failed: \(code(output)). Not retried; length and Report ID are not changed."))
        }
        usleep(1000)
        var buffer = [UInt8](repeating: 0, count: MT760WarmRead.inputCapacity)
        buffer[0] = UInt8(MT760WarmRead.reportID)
        var length = CFIndex(buffer.count)
        let input = buffer.withUnsafeMutableBufferPointer {
            IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, MT760WarmRead.reportID, $0.baseAddress!, &length)
        }
        result.inputIOReturn = input
        guard input == kIOReturnSuccess else {
            return failure(L("同步读取失败：\(code(input))。读取请求可能已被设备处理；不重试。", "Synchronous read failed: \(code(input)). The device may have processed the read request; not retried."))
        }
        result.inputActualLength = length
        guard (0...buffer.count).contains(length) else {
            return failure(L("IOKit 返回了超出容量的长度，停止解析。", "IOKit returned a length beyond capacity; parsing stopped."))
        }
        result.response = Array(buffer.prefix(length))
        do {
            result.snapshot = try DPISnapshot.decode(result.response)
        } catch {
            return failure(error.localizedDescription)
        }
        result.completedAt = Date()
        return result
    }

    /// Shared by read and write transactions.
    public static func openFailureMessage(_ value: IOReturn) -> String {
        if value == InputMonitoringAccess.notPermitted {
            return L("无法打开接口：\(code(value))（kIOReturnNotPermitted）。请在 系统设置 → 隐私与安全性 → 输入监控 中允许 “MT760 Control”，然后重新打开 App。未发送请求。", "Could not open the interface: \(code(value)) (kIOReturnNotPermitted). Allow “MT760 Control” in System Settings → Privacy & Security → Input Monitoring, then reopen the App. No request was sent.")
        }
        return L("无法非独占打开接口：\(code(value))。可能是设备被占用；未发送请求。", "Could not open the interface non-exclusively: \(code(value)). The device may be in use; no request was sent.")
    }

    private static func code(_ value: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}
