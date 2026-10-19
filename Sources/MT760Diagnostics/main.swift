import Foundation
import MT760Core

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] || args == ["-h"] {
    print(L("""
    用法：mt760-diagnostics [--json]
    仅枚举 Rapoo HID 设备及系统缓存的描述符；不打开设备，不发送命令。
    --json  输出诊断 JSON 到 stdout（可重定向保存）
    """, """
    Usage: mt760-diagnostics [--json]
    Enumerates only Rapoo HID devices and the descriptors cached by the system; does not open devices or send commands.
    --json  Write diagnostics JSON to stdout (redirect to save)
    """))
} else if args.isEmpty || args == ["--json"] {
    let devices = HIDEnumerator.scan()
    if args == ["--json"] {
        do {
            FileHandle.standardOutput.write(try DiagnosticSnapshot(devices: devices).encoded())
            print()
        } catch {
            FileHandle.standardError.write(Data(L("诊断导出失败：\(error)\n", "Diagnostics export failed: \(error)\n").utf8))
            exit(1)
        }
    } else {
        print(L("MT760 Control · 仅枚举模式 · 未向设备发送命令", "MT760 Control · enumeration only · no commands sent to the device"))
        if devices.isEmpty { print(L("未发现 Rapoo HID 设备。请使用 USB 数据线连接后重试。", "No Rapoo HID devices found. Connect with a USB data cable and try again.")) }
        for device in devices {
            print("\n\(device.product) [\(device.id)]")
            print("  VID/PID: \(hex(device.vendorID))/\(hex(device.productID)) · \(device.transport)")
            print("  Usage: \(hex(device.primaryUsage.page))/\(hex(device.primaryUsage.usage))")
            print("  \(device.status)")
            for report in device.summary.reports {
                let length = device.summary.lengthsAreReliable
                    ? "payload=\(report.payloadBytes)B wire=\(report.wireBytes)B"
                    : L("长度未确认（描述符有警告）", "length unconfirmed (descriptor has warnings)")
                print("  \(report.kind.rawValue) ID=\(hex(report.reportID)) \(length)")
            }
            for warning in device.summary.warnings { print(L("  注意：\(warning)", "  Note: \(warning)")) }
        }
    }
} else {
    FileHandle.standardError.write(Data(L("不支持的参数。使用 --help 查看用法。\n", "Unsupported argument. Use --help for usage.\n").utf8))
    exit(2)
}
