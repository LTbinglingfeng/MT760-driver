import Foundation
import IOKit
import IOKit.hid

/// Single DPI write transaction. Call ONLY inside mt760-read-helper with the write flag.
///
/// Sequence on one non-exclusive handle, mirroring MouseForTelink::setDPIListInfo:
/// 1. read config 0x638 (fresh baseline; must equal the bytes the user previewed)
/// 2. read auxiliary 0x648 (official pre-read; must agree with overlapping config bytes)
/// 3. one write `BA FF A5 14 38 06 00 00 + 20 B`; success requires response B[0] == 1
/// 4. one config readback; must reproduce the written bytes exactly
/// No step is ever resent. Busy status (B[0] == 2) after the write/readback only polls
/// GetReport, bounded far below the official 250 polls. Any failure after step 3 starts
/// leaves the device state uncertain and is reported as such, never auto-rolled back.
public enum MT760HardwareWrite {
    static let busyPollLimit = 50
    static let busyPollInterval: useconds_t = 2000
    static let stepDelay: useconds_t = 2000

    public static func writeCurrentDPIOnce(registryID: String, targetDPI: Int, expectedBaseline: [UInt8]) -> DPIWriteOutcome {
        var result = DPIWriteOutcome(registryID: registryID, targetDPI: targetDPI, expectedBaseline: expectedBaseline)
        func failure(_ message: String) -> DPIWriteOutcome {
            result.error = result.writeRequestSent ? message + L(" 写请求已发出，设备状态不确定；不自动重试或回滚，以重新读取的结果为准。", " The write request was sent and the device state is uncertain; no automatic retry or rollback. The re-read result is authoritative.") : message
            result.completedAt = Date()
            return result
        }
        guard MT760DPICommand.isValidTarget(targetDPI), expectedBaseline.count == MT760DPICommand.configDataLength else {
            return failure(L("目标 DPI 或预期基线参数无效；没有打开设备。", "Invalid target DPI or expected baseline; the device was not opened."))
        }
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("请先退出 A HUB Office，避免同时通信。没有打开设备或发送请求。", "Please quit A HUB Office first to avoid concurrent communication. The device was not opened and no request was sent."))
        }
        let candidates = HIDEnumerator.devices().filter { HIDEnumerator.describe($0).id == registryID }
        guard candidates.count == 1, let device = candidates.first,
              HIDEnumerator.describe(device).canAttemptDPIRead else {
            return failure(L("所选设备已移除或不符合 MT760 接口条件；没有发送请求。", "The selected device was removed or does not match the MT760 interface criteria; no request was sent."))
        }
        let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard opened == kIOReturnSuccess else {
            return failure(MT760HardwareRead.openFailureMessage(opened))
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // 1. Fresh baseline.
        var exchange = transact(device, step: "readConfig", request: MT760DPICommand.readConfig, pollBusy: false)
        result.exchanges.append(exchange)
        if let error = transportError(exchange) { return failure(error) }
        do {
            let snapshot = try DPISnapshot.decode(exchange.response)
            result.baseline = snapshot
            guard try DPIWritePlan.baselineData(fromConfigResponse: exchange.response) == expectedBaseline else {
                return failure(L("设备当前配置与界面所示不同（可能已切档或被其他程序修改）；未写入。", "The device configuration differs from what is shown (the level may have been switched or changed by another program); nothing was written."))
            }
        } catch { return failure(L("基线读取无效：\(error.localizedDescription) 未写入。", "Baseline read is invalid: \(error.localizedDescription) Nothing was written.")) }

        // 2. Auxiliary pre-read, as the official setter does.
        exchange = transact(device, step: "readAuxiliary", request: MT760DPICommand.readAuxiliary, pollBusy: false)
        result.exchanges.append(exchange)
        if let error = transportError(exchange) { return failure(error + L(" 未写入。", " Nothing was written.")) }
        let plan: DPIWritePlan
        do {
            plan = try DPIWritePlan.make(configResponse: result.exchanges[0].response,
                                         auxiliaryResponse: exchange.response, targetDPI: targetDPI)
            result.plan = plan
        } catch { return failure(error.localizedDescription) }

        // Last gate before the only configuration write.
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("检测到官方程序启动；未写入。", "The official app was detected starting; nothing was written."))
        }

        // 3. The single write. Mark as sent before calling: SetReport may reach the device even on error.
        result.writeRequestSent = true
        exchange = transact(device, step: "write", request: plan.request, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = transportError(exchange) { return failure(error) }
        guard exchange.response.first == 1 else {
            return failure(L("写入应答状态为 ", "Write acknowledgement status is ") + (exchange.response.first.map { hex(UInt32($0)) } ?? L("空", "empty"))
                           + L("，设备未确认成功。", "; the device did not confirm success."))
        }

        // 4. Readback.
        exchange = transact(device, step: "readback", request: MT760DPICommand.readConfig, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = transportError(exchange) { return failure(L("读回失败：", "Readback failed: ") + error) }
        do {
            result.readback = try plan.verify(readback: exchange.response)
        } catch { return failure(L("读回校验失败：\(error.localizedDescription)", "Readback verification failed: \(error.localizedDescription)")) }
        result.verified = true
        result.completedAt = Date()
        return result
    }

    /// Shared by the DPI and report-rate transactions (helper only).
    static func transact(_ device: IOHIDDevice, step: String, request: [UInt8], pollBusy: Bool) -> HIDExchange {
        var exchange = HIDExchange(step: step, request: request)
        usleep(stepDelay)
        let output = request.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, MT760WarmRead.reportID, $0.baseAddress!, $0.count)
        }
        exchange.outputIOReturn = output
        guard output == kIOReturnSuccess else { return exchange }
        usleep(stepDelay)
        while true {
            var buffer = [UInt8](repeating: 0, count: MT760WarmRead.inputCapacity)
            buffer[0] = UInt8(MT760WarmRead.reportID)
            var length = CFIndex(buffer.count)
            let input = buffer.withUnsafeMutableBufferPointer {
                IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, MT760WarmRead.reportID, $0.baseAddress!, &length)
            }
            exchange.inputIOReturn = input
            guard input == kIOReturnSuccess, (0...buffer.count).contains(length) else {
                exchange.inputActualLength = length
                return exchange
            }
            exchange.inputActualLength = length
            exchange.response = Array(buffer.prefix(length))
            guard pollBusy, exchange.response.first == 2, exchange.busyPolls < busyPollLimit else { return exchange }
            exchange.busyPolls += 1
            usleep(busyPollInterval)
        }
    }

    static func transportError(_ exchange: HIDExchange) -> String? {
        if let output = exchange.outputIOReturn, output != kIOReturnSuccess {
            return L("\(exchange.step) 请求发送失败：\(code(output))。", "\(exchange.step): sending the request failed: \(code(output)).")
        }
        if let input = exchange.inputIOReturn, input != kIOReturnSuccess {
            return L("\(exchange.step) 同步读取失败：\(code(input))。", "\(exchange.step): synchronous read failed: \(code(input)).")
        }
        if exchange.inputActualLength != exchange.response.count {
            return L("\(exchange.step) 返回长度超出容量。", "\(exchange.step): returned length exceeds capacity.")
        }
        if exchange.response.first == 2 {
            return L("\(exchange.step) 设备持续忙（已轮询 \(exchange.busyPolls) 次 GetReport）。", "\(exchange.step): device stayed busy (polled GetReport \(exchange.busyPolls) times).")
        }
        return nil
    }

    private static func code(_ value: IOReturn) -> String {
        String(format: "0x%08X", UInt32(bitPattern: value))
    }
}
