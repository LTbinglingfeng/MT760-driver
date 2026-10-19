import Foundation
import IOKit
import IOKit.hid

/// Report-rate transactions. Call ONLY inside mt760-read-helper with the matching flags.
///
/// Read: one fixed request `BA FF A4 08 30 06 00 00`, one synchronous GetReport, no busy polling.
/// Write, on one non-exclusive handle, mirroring MouseForTelink::setReturnRate:
/// 1. read 0x630 (fresh baseline; the 8-byte block must equal the bytes the user previewed)
/// 2. one write `BA FF A5 04 30 06 00 00 + code, code, B[2], B[3]`; success requires B[0] == 1
/// 3. one readback; the whole block must equal the plan (bytes 4…7 untouched)
/// No step is ever resent; busy status after the write/readback only polls GetReport.
/// Any failure after step 2 starts leaves the device state uncertain and is never auto-rolled back.
/// The device may re-initialise its USB link after a rate change; a readback failure is then
/// reported as uncertain, not as success.
public enum MT760ReportRateHardware {
    /// Shared with the gear-switch transaction (helper only).
    enum Opened {
        case device(IOHIDDevice)
        case failure(String)
    }

    static func openMatched(registryID: String) -> Opened {
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return .failure(L("请先退出 A HUB Office，避免同时通信。没有打开设备或发送请求。", "Please quit A HUB Office first to avoid concurrent communication. The device was not opened and no request was sent."))
        }
        let candidates = HIDEnumerator.devices().filter { HIDEnumerator.describe($0).id == registryID }
        guard candidates.count == 1, let device = candidates.first,
              HIDEnumerator.describe(device).canAttemptDPIRead else {
            return .failure(L("所选设备已移除或不符合 MT760 接口条件；没有发送请求。", "The selected device was removed or does not match the MT760 interface criteria; no request was sent."))
        }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            return .failure(MT760HardwareRead.openFailureMessage(opened))
        }
        return .device(device)
    }

    public static func readOnce(registryID: String) -> ReportRateReadOutcome {
        var result = ReportRateReadOutcome(registryID: registryID)
        func failure(_ message: String) -> ReportRateReadOutcome {
            result.error = message
            result.completedAt = Date()
            return result
        }
        let device: IOHIDDevice
        switch openMatched(registryID: registryID) {
        case .failure(let message): return failure(message)
        case .device(let opened): device = opened
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("检测到官方程序仍在运行，已关闭接口；没有发送请求。", "The official app is still running; the interface was closed and no request was sent."))
        }
        let exchange = MT760HardwareWrite.transact(device, step: "readRate", request: MT760ReportRateCommand.read, pollBusy: false)
        result.exchange = exchange
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error + L(" 不重试。", " Not retried.")) }
        do {
            result.snapshot = try ReportRateSnapshot.decode(exchange.response)
        } catch { return failure(error.localizedDescription) }
        result.completedAt = Date()
        return result
    }

    public static func writeOnce(registryID: String, targetHz: Int, expectedBaseline: [UInt8]) -> ReportRateWriteOutcome {
        var result = ReportRateWriteOutcome(registryID: registryID, targetHz: targetHz, expectedBaseline: expectedBaseline)
        func failure(_ message: String) -> ReportRateWriteOutcome {
            result.error = result.writeRequestSent ? message + L(" 写请求已发出，设备状态不确定；不自动重试或回滚，以重新读取的结果为准。", " The write request was sent and the device state is uncertain; no automatic retry or rollback. The re-read result is authoritative.") : message
            result.completedAt = Date()
            return result
        }
        guard MT760ReportRateCommand.isValidTarget(targetHz), expectedBaseline.count == MT760ReportRateCommand.blockLength else {
            return failure(L("目标回报率或预期基线参数无效；没有打开设备。", "Invalid target report rate or expected baseline; the device was not opened."))
        }
        let device: IOHIDDevice
        switch openMatched(registryID: registryID) {
        case .failure(let message): return failure(message)
        case .device(let opened): device = opened
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // 1. Fresh baseline (the official setter performs the same pre-read).
        var exchange = MT760HardwareWrite.transact(device, step: "readRate", request: MT760ReportRateCommand.read, pollBusy: false)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error + L(" 未写入。", " Nothing was written.")) }
        let plan: ReportRateWritePlan
        do {
            let snapshot = try ReportRateSnapshot.decode(exchange.response)
            result.baseline = snapshot
            guard snapshot.block == expectedBaseline else {
                return failure(L("设备当前回报率数据与界面所示不同（可能已被其他程序修改）；未写入。", "The device report-rate data differs from what is shown (possibly changed by another program); nothing was written."))
            }
            plan = try ReportRateWritePlan.make(readResponse: exchange.response, targetHz: targetHz)
            result.plan = plan
        } catch { return failure(L("基线无效：\(error.localizedDescription) 未写入。", "Baseline is invalid: \(error.localizedDescription) Nothing was written.")) }

        // Last gate before the only configuration write.
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("检测到官方程序启动；未写入。", "The official app was detected starting; nothing was written."))
        }

        // 2. The single write. Mark as sent before calling: SetReport may reach the device even on error.
        result.writeRequestSent = true
        exchange = MT760HardwareWrite.transact(device, step: "write", request: plan.request, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error) }
        guard exchange.response.first == 1 else {
            return failure(L("写入应答状态为 ", "Write acknowledgement status is ") + (exchange.response.first.map { hex(UInt32($0)) } ?? L("空", "empty"))
                           + L("，设备未确认成功。", "; the device did not confirm success."))
        }

        // 3. Readback.
        exchange = MT760HardwareWrite.transact(device, step: "readback", request: MT760ReportRateCommand.read, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) {
            return failure(L("设备已应答写入，但读回失败：", "The device acknowledged the write, but the readback failed: ") + error)
        }
        do {
            result.readback = try plan.verify(readback: exchange.response)
        } catch { return failure(L("读回校验失败：\(error.localizedDescription)", "Readback verification failed: \(error.localizedDescription)")) }
        result.verified = true
        result.completedAt = Date()
        return result
    }
}
