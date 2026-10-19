import Foundation
import IOKit
import IOKit.hid

/// Single current-gear switch. Call ONLY inside mt760-read-helper with the matching flags.
///
/// Sequence on one non-exclusive handle, mirroring MouseForTelink::setCurDPIGear:
/// 1. read config 0x638 (fresh baseline; must equal the bytes the user previewed)
/// 2. read auxiliary 0x648 (official pre-read; must agree with overlapping config bytes)
/// 3. one write `BA FF A5 04 48 06 00 00 g−1 B5 B7 B6` (official swap kept); success requires B[0] == 1
/// 4. one config readback; must equal the plan (gear byte and swapped 0x64A/0x64B only)
/// No step is ever resent; busy status after the write/readback only polls GetReport.
/// Any failure after step 3 starts leaves the device state uncertain and is never auto-rolled back.
public enum MT760DPIGearHardware {
    public static func switchGearOnce(registryID: String, targetGear: Int, expectedBaseline: [UInt8]) -> DPIGearSwitchOutcome {
        var result = DPIGearSwitchOutcome(registryID: registryID, targetGear: targetGear, expectedBaseline: expectedBaseline)
        func failure(_ message: String) -> DPIGearSwitchOutcome {
            result.error = result.writeRequestSent ? message + L(" 写请求已发出，设备状态不确定；不自动重试或回滚，以重新读取的结果为准。", " The write request was sent and the device state is uncertain; no automatic retry or rollback. The re-read result is authoritative.") : message
            result.completedAt = Date()
            return result
        }
        guard MT760DPIGearCommand.isValidTarget(targetGear), expectedBaseline.count == MT760DPICommand.configDataLength else {
            return failure(L("目标档位或预期基线参数无效；没有打开设备。", "Invalid target level or expected baseline; the device was not opened."))
        }
        let device: IOHIDDevice
        switch MT760ReportRateHardware.openMatched(registryID: registryID) {
        case .failure(let message): return failure(message)
        case .device(let opened): device = opened
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // 1. Fresh baseline.
        var exchange = MT760HardwareWrite.transact(device, step: "readConfig", request: MT760DPICommand.readConfig, pollBusy: false)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error + L(" 未写入。", " Nothing was written.")) }
        do {
            result.baseline = try DPISnapshot.decode(exchange.response)
            guard try DPIWritePlan.baselineData(fromConfigResponse: exchange.response) == expectedBaseline else {
                return failure(L("设备当前配置与界面所示不同（可能已按键切档或被其他程序修改）；未写入。", "The device configuration differs from what is shown (the level may have been switched with the mouse button or changed by another program); nothing was written."))
            }
        } catch { return failure(L("基线读取无效：\(error.localizedDescription) 未写入。", "Baseline read is invalid: \(error.localizedDescription) Nothing was written.")) }

        // 2. Auxiliary pre-read, as the official setter does.
        exchange = MT760HardwareWrite.transact(device, step: "readAuxiliary", request: MT760DPICommand.readAuxiliary, pollBusy: false)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error + L(" 未写入。", " Nothing was written.")) }
        let plan: DPIGearSwitchPlan
        do {
            plan = try DPIGearSwitchPlan.make(configResponse: result.exchanges[0].response,
                                              auxiliaryResponse: exchange.response, targetGear: targetGear)
            result.plan = plan
        } catch { return failure(error.localizedDescription) }

        // Last gate before the only configuration write.
        guard !MT760HardwareRead.officialAppIsRunning() else {
            return failure(L("检测到官方程序启动；未写入。", "The official app was detected starting; nothing was written."))
        }

        // 3. The single write. Mark as sent before calling: SetReport may reach the device even on error.
        result.writeRequestSent = true
        exchange = MT760HardwareWrite.transact(device, step: "write", request: plan.request, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(error) }
        guard exchange.response.first == 1 else {
            return failure(L("写入应答状态为 ", "Write acknowledgement status is ") + (exchange.response.first.map { hex(UInt32($0)) } ?? L("空", "empty"))
                           + L("，设备未确认成功。", "; the device did not confirm success."))
        }

        // 4. Readback.
        exchange = MT760HardwareWrite.transact(device, step: "readback", request: MT760DPICommand.readConfig, pollBusy: true)
        result.exchanges.append(exchange)
        if let error = MT760HardwareWrite.transportError(exchange) { return failure(L("读回失败：", "Readback failed: ") + error) }
        do {
            result.readback = try plan.verify(readback: exchange.response)
        } catch { return failure(L("读回校验失败：\(error.localizedDescription)", "Readback verification failed: \(error.localizedDescription)")) }
        result.verified = true
        result.completedAt = Date()
        return result
    }
}
