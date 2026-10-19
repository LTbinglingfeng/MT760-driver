import Foundation
import IOKit
import IOKit.hid

/// Key-mapping transactions. Call ONLY inside mt760-read-helper with the matching flags.
///
/// Read: the 11 official per-key reads `BA FF A4 10 <0x600+4·KeyID>` in official order,
/// one GetReport each, no busy polling, stop at the first failure.
/// Write, on one non-exclusive handle, mirroring MouseForTelink::setKey:
/// 1. the same 11 reads; the 44 slot bytes must equal the bytes the user previewed
/// 2. one write `BA FF A5 04 <addr> d0 d1 d2 d3`; success requires B[0] == 1
/// 3. one readback of that key; all 16 bytes must equal the plan (neighbours untouched)
/// No step is ever resent; any failure after step 2 starts leaves the state uncertain.
public enum MT760KeyMappingHardware {
    /// Shared read sequence; returns an error message on the first failing step.
    static func readAll(_ device: IOHIDDevice, into exchanges: inout [HIDExchange]) -> String? {
        for id in MT760KeyCommand.officialReadOrder {
            let exchange = MT760HardwareWrite.transact(device, step: "readKey\(id)",
                                                       request: MT760KeyCommand.readRequest(keyID: id), pollBusy: false)
            exchanges.append(exchange)
            if let error = MT760HardwareWrite.transportError(exchange) { return error + L(" 不重试。", " Not retried.") }
            do { _ = try MT760KeyCommand.readData(exchange.response) }
            catch { return "KeyID \(id)：\(error.localizedDescription)" }
        }
        return nil
    }

    public static func readOnce(registryID: String) -> KeyMappingReadOutcome {
        var result = KeyMappingReadOutcome(registryID: registryID)
        func failure(_ message: String) -> KeyMappingReadOutcome {
            result.error = message
            result.completedAt = Date()
            return result
        }
        let device: IOHIDDevice
        switch MT760ReportRateHardware.openMatched(registryID: registryID) {
        case .failure(let message): return failure(message)
        case .device(let opened): device = opened
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("检测到官方程序仍在运行，已关闭接口；没有发送请求。", "The official app is still running; the interface was closed and no request was sent."))
        }
        if let error = readAll(device, into: &result.exchanges) { return failure(error) }
        do { result.snapshot = try KeyMappingSnapshot.fromReads(result.exchanges) }
        catch { return failure(error.localizedDescription) }
        result.completedAt = Date()
        return result
    }

    public static func writeOnce(registryID: String, keyID: Int, targetSlot: [UInt8], expectedBaseline: [UInt8]) -> KeyWriteOutcome {
        var result = KeyWriteOutcome(registryID: registryID, keyID: keyID, targetSlot: targetSlot, expectedBaseline: expectedBaseline)
        func failure(_ message: String) -> KeyWriteOutcome {
            result.error = result.writeRequestSent ? message + L(" 写请求已发出，设备状态不确定；不自动重试或回滚，以重新读取的结果为准。", " The write request was sent and the device state is uncertain; no automatic retry or rollback. The re-read result is authoritative.") : message
            result.completedAt = Date()
            return result
        }
        guard MT760KeyCommand.isValidKeyID(keyID), KeyFunction.decode(targetSlot) != nil,
              expectedBaseline.count == MT760KeyCommand.slotLength * MT760KeyCommand.keyIDs.count else {
            return failure(L("KeyID、目标功能或预期基线参数无效；没有打开设备。", "Invalid KeyID, target function or expected baseline; the device was not opened."))
        }
        let device: IOHIDDevice
        switch MT760ReportRateHardware.openMatched(registryID: registryID) {
        case .failure(let message): return failure(message)
        case .device(let opened): device = opened
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // 1. Fresh baseline of every key (needed for the "keep one left button" rule).
        if let error = readAll(device, into: &result.exchanges) { return failure(error + L(" 未写入。", " Nothing was written.")) }
        let plan: KeyWritePlan
        do {
            let snapshot = try KeyMappingSnapshot.fromReads(result.exchanges)
            result.baseline = snapshot
            guard snapshot.flattened == expectedBaseline else {
                return failure(L("设备当前按键映射与界面所示不同（可能已被其他程序修改）；未写入。", "The device button mapping differs from what is shown (possibly changed by another program); nothing was written."))
            }
            let readIndex = MT760KeyCommand.officialReadOrder.firstIndex(of: keyID)!
            plan = try KeyWritePlan.make(snapshot: snapshot, keyReadResponse: result.exchanges[readIndex].response,
                                         keyID: keyID, newSlot: targetSlot)
            result.plan = plan
        } catch { return failure(L("基线无效：\(error.localizedDescription) 未写入。", "Baseline is invalid: \(error.localizedDescription) Nothing was written.")) }

        // Last gate before the only configuration write.
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("检测到官方程序启动；未写入。", "The official app was detected starting; nothing was written."))
        }

        // 2. The single write. Mark as sent before calling: SetReport may reach the device even on error.
        result.writeRequestSent = true
        var exchange = MT760HardwareWrite.transact(device, step: "write", request: plan.request, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error) }
        guard exchange.response.first == 1 else {
            return failure(L("写入应答状态为 ", "Write acknowledgement status is ") + (exchange.response.first.map { hex(UInt32($0)) } ?? L("空", "empty"))
                           + L("，设备未确认成功。", "; the device did not confirm success."))
        }

        // 3. Readback of the same key.
        exchange = MT760HardwareWrite.transact(device, step: "readback", request: MT760KeyCommand.readRequest(keyID: keyID), pollBusy: true)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(L("读回失败：", "Readback failed: ") + error) }
        do { result.readbackSlot = try plan.verify(readback: exchange.response) }
        catch { return failure(L("读回校验失败：\(error.localizedDescription)", "Readback verification failed: \(error.localizedDescription)")) }
        result.verified = true
        result.completedAt = Date()
        return result
    }
}
