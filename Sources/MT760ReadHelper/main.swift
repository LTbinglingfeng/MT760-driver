import Foundation
import Darwin
import MT760Core

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--help"] {
    print(L("""
    MT760 隔离硬件访问进程。只支持下列固定事务，不支持任意 HID 命令。
    读 DPI：  mt760-read-helper --read-dpi-warm --registry-id HEX --confirm-mt760-v144
    写 DPI：  mt760-read-helper --write-current-dpi --registry-id HEX --target-dpi N \\
                --expect-config 40HEX --confirm-mt760-v144-write
      仅修改当前档位的数值：现场读取并比对预期基线 → 辅助读取 → 写一次 → 读回校验。
    切档：    mt760-read-helper --switch-dpi-gear --registry-id HEX --target-gear 1-7 \\
                --expect-config 40HEX --confirm-mt760-v144-write
      仅修改当前档位 0x648：现场读取并比对预期基线 → 辅助读取 → 写一次 → 读回校验。
    读回报率：mt760-read-helper --read-report-rate --registry-id HEX --confirm-mt760-v144
    写回报率：mt760-read-helper --write-report-rate --registry-id HEX --target-hz 125|250|500|1000 \\
                --expect-rate-block 16HEX --confirm-mt760-v144-write
      现场读取 0x630 并比对预期基线 → 写一次 → 读回校验。
    读按键：  mt760-read-helper --read-key-mapping --registry-id HEX --confirm-mt760-v144
    写按键：  mt760-read-helper --write-key --registry-id HEX --key-id 0-10 --target-slot 8HEX \
                --expect-key-slots 88HEX --confirm-mt760-v144-write
      现场读取 11 个按键并比对预期基线 → 写一次（4 字节）→ 读回校验。
    仅限已确认普通 MT760 V0.1.4.4、USB 直连。任何请求均不重发；5 秒独立进程时限。
    请优先使用 App 界面。
    """, """
    MT760 isolated hardware-access process. Only the fixed transactions below are supported; arbitrary HID commands are not.
    Read DPI:          mt760-read-helper --read-dpi-warm --registry-id HEX --confirm-mt760-v144
    Write DPI:         mt760-read-helper --write-current-dpi --registry-id HEX --target-dpi N \\
                         --expect-config 40HEX --confirm-mt760-v144-write
      Changes only the current level's value: fresh read matched to the expected baseline → auxiliary read → one write → readback.
    Switch level:      mt760-read-helper --switch-dpi-gear --registry-id HEX --target-gear 1-7 \\
                         --expect-config 40HEX --confirm-mt760-v144-write
      Changes only the current level at 0x648: fresh read matched to the expected baseline → auxiliary read → one write → readback.
    Read report rate:  mt760-read-helper --read-report-rate --registry-id HEX --confirm-mt760-v144
    Write report rate: mt760-read-helper --write-report-rate --registry-id HEX --target-hz 125|250|500|1000 \\
                         --expect-rate-block 16HEX --confirm-mt760-v144-write
      Fresh read of 0x630 matched to the expected baseline → one write → readback.
    Read buttons:      mt760-read-helper --read-key-mapping --registry-id HEX --confirm-mt760-v144
    Write button:      mt760-read-helper --write-key --registry-id HEX --key-id 0-10 --target-slot 8HEX \\
                         --expect-key-slots 88HEX --confirm-mt760-v144-write
      Fresh read of all 11 buttons matched to the expected baseline → one write (4 bytes) → readback.
    Confirmed standard MT760 V0.1.4.4 over direct USB only. No request is ever resent; 5 s separate-process time limit.
    Prefer the App interface.
    """))
    exit(0)
}

func validID(_ value: String) -> String? {
    guard !value.isEmpty, value.count <= 16, value.allSatisfy({ $0.isHexDigit }),
          let parsed = UInt64(value, radix: 16) else { return nil }
    return String(parsed, radix: 16)
}

func parseHexBytes(_ value: String) -> [UInt8]? {
    guard value.count % 2 == 0, value.allSatisfy({ $0.isHexDigit }) else { return nil }
    var bytes: [UInt8] = []
    var index = value.startIndex
    while index < value.endIndex {
        let next = value.index(index, offsetBy: 2)
        guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
        bytes.append(byte); index = next
    }
    return bytes
}

enum Mode {
    case read(String)
    case write(String, Int, [UInt8])
    case readRate(String)
    case writeRate(String, Int, [UInt8])
    case switchGear(String, Int, [UInt8])
    case readKeys(String)
    case writeKey(String, Int, [UInt8], [UInt8])
}

func usageFailure() -> Never {
    FileHandle.standardError.write(Data(L("参数不合法；未访问设备。使用 --help 查看用法。\n", "Invalid arguments; the device was not accessed. Use --help for usage.\n").utf8))
    exit(2)
}

let mode: Mode
if args.count == 4, args[0] == "--read-dpi-warm", args[1] == "--registry-id",
   args[3] == "--confirm-mt760-v144", let id = validID(args[2]) {
    mode = .read(id)
} else if args.count == 8, args[0] == "--write-current-dpi", args[1] == "--registry-id",
          let id = validID(args[2]), args[3] == "--target-dpi", let dpi = Int(args[4]),
          MT760DPICommand.isValidTarget(dpi), args[5] == "--expect-config",
          let baseline = parseHexBytes(args[6]), baseline.count == MT760DPICommand.configDataLength,
          args[7] == "--confirm-mt760-v144-write" {
    mode = .write(id, dpi, baseline)
} else if args.count == 4, args[0] == "--read-report-rate", args[1] == "--registry-id",
          args[3] == "--confirm-mt760-v144", let id = validID(args[2]) {
    mode = .readRate(id)
} else if args.count == 8, args[0] == "--write-report-rate", args[1] == "--registry-id",
          let id = validID(args[2]), args[3] == "--target-hz", let hz = Int(args[4]),
          MT760ReportRateCommand.isValidTarget(hz), args[5] == "--expect-rate-block",
          let baseline = parseHexBytes(args[6]), baseline.count == MT760ReportRateCommand.blockLength,
          args[7] == "--confirm-mt760-v144-write" {
    mode = .writeRate(id, hz, baseline)
} else if args.count == 8, args[0] == "--switch-dpi-gear", args[1] == "--registry-id",
          let id = validID(args[2]), args[3] == "--target-gear", let gear = Int(args[4]),
          MT760DPIGearCommand.isValidTarget(gear), args[5] == "--expect-config",
          let baseline = parseHexBytes(args[6]), baseline.count == MT760DPICommand.configDataLength,
          args[7] == "--confirm-mt760-v144-write" {
    mode = .switchGear(id, gear, baseline)
} else if args.count == 4, args[0] == "--read-key-mapping", args[1] == "--registry-id",
          args[3] == "--confirm-mt760-v144", let id = validID(args[2]) {
    mode = .readKeys(id)
} else if args.count == 10, args[0] == "--write-key", args[1] == "--registry-id",
          let id = validID(args[2]), args[3] == "--key-id", let keyID = Int(args[4]),
          MT760KeyCommand.isValidKeyID(keyID), args[5] == "--target-slot",
          let slot = parseHexBytes(args[6]), KeyFunction.decode(slot) != nil, args[7] == "--expect-key-slots",
          let baseline = parseHexBytes(args[8]),
          baseline.count == MT760KeyCommand.slotLength * MT760KeyCommand.keyIDs.count,
          args[9] == "--confirm-mt760-v144-write" {
    mode = .writeKey(id, keyID, slot, baseline)
} else {
    usageFailure()
}

func emit(_ data: Data?, success: Bool) -> Never {
    if let data { FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10])) }
    else { FileHandle.standardError.write(Data(L("无法编码结果。\n", "Could not encode the result.\n").utf8)) }
    exit(success ? 0 : 1)
}

func emitFailure(_ message: String) -> Never {
    switch mode {
    case .read(let id):
        var outcome = DPIReadOutcome(registryID: id)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    case .write(let id, let dpi, let baseline):
        var outcome = DPIWriteOutcome(registryID: id, targetDPI: dpi, expectedBaseline: baseline)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    case .readRate(let id):
        var outcome = ReportRateReadOutcome(registryID: id)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    case .writeRate(let id, let hz, let baseline):
        var outcome = ReportRateWriteOutcome(registryID: id, targetHz: hz, expectedBaseline: baseline)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    case .switchGear(let id, let gear, let baseline):
        var outcome = DPIGearSwitchOutcome(registryID: id, targetGear: gear, expectedBaseline: baseline)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    case .readKeys(let id):
        var outcome = KeyMappingReadOutcome(registryID: id)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    case .writeKey(let id, let keyID, let slot, let baseline):
        var outcome = KeyWriteOutcome(registryID: id, keyID: keyID, targetSlot: slot, expectedBaseline: baseline)
        outcome.error = message
        emit(try? outcome.encoded(), success: false)
    }
}

// Per-user interprocess lock shared by read and write; keep the inode (no unlink race).
let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("local.mt760.control.read.lock").path
let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
guard descriptor >= 0 else { emitFailure(L("无法建立互斥锁；没有访问设备。", "Could not acquire the lock; the device was not accessed.")) }
var statInfo = stat()
guard fstat(descriptor, &statInfo) == 0, statInfo.st_uid == getuid(),
      (statInfo.st_mode & S_IFMT) == S_IFREG, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
    close(descriptor)
    emitFailure(L("另一设备任务仍在执行或互斥锁不可用；没有访问设备。", "Another device task is still running or the lock is unavailable; the device was not accessed."))
}

// A timeout terminates this helper, not the App, the official driver, or other processes.
// It is NOT proof that an in-flight IOKit request was cancelled on the device.
let originalParent = getppid()
let deadline = DispatchTime.now() + .seconds(5)
let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
watchdog.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
watchdog.setEventHandler {
    if getppid() != originalParent { _exit(125) }
    if DispatchTime.now() >= deadline { _exit(124) }
}
watchdog.resume()

let encoded: Data?
let succeeded: Bool
switch mode {
case .read(let id):
    let outcome = MT760HardwareRead.readWarmOnce(registryID: id)
    encoded = try? outcome.encoded(); succeeded = outcome.error == nil
case .write(let id, let dpi, let baseline):
    let outcome = MT760HardwareWrite.writeCurrentDPIOnce(registryID: id, targetDPI: dpi, expectedBaseline: baseline)
    encoded = try? outcome.encoded(); succeeded = outcome.verified
case .readRate(let id):
    let outcome = MT760ReportRateHardware.readOnce(registryID: id)
    encoded = try? outcome.encoded(); succeeded = outcome.error == nil
case .writeRate(let id, let hz, let baseline):
    let outcome = MT760ReportRateHardware.writeOnce(registryID: id, targetHz: hz, expectedBaseline: baseline)
    encoded = try? outcome.encoded(); succeeded = outcome.verified
case .switchGear(let id, let gear, let baseline):
    let outcome = MT760DPIGearHardware.switchGearOnce(registryID: id, targetGear: gear, expectedBaseline: baseline)
    encoded = try? outcome.encoded(); succeeded = outcome.verified
case .readKeys(let id):
    let outcome = MT760KeyMappingHardware.readOnce(registryID: id)
    encoded = try? outcome.encoded(); succeeded = outcome.error == nil
case .writeKey(let id, let keyID, let slot, let baseline):
    let outcome = MT760KeyMappingHardware.writeOnce(registryID: id, keyID: keyID, targetSlot: slot, expectedBaseline: baseline)
    encoded = try? outcome.encoded(); succeeded = outcome.verified
}
watchdog.cancel()
flock(descriptor, LOCK_UN)
close(descriptor)
emit(encoded, success: succeeded)
