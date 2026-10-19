import Foundation

/// Fixed key-mapping memory commands for ordinary MT760 (MouseForTelink, wired, firmware V0.1.4.4).
///
/// Derived from the official library (static analysis, not a captured transaction):
/// - Base address: MouseForTelink ctor writes qword index 0x70 = 0x0000060400000600, so object
///   member +0x380 = 0x600. Slot address = 0x600 + KeyID × 4 (4 bytes per key).
/// - `MouseForTelink::getKeyInfoList` @0x220060: per key getDeviceMemory `[10][LE32 addr]`
///   → `BA FF A4 10 <addr LE32>` (16 bytes = this slot and the next three). Working buffer
///   +0xe4 (= response B[4], data byte 0) is the device function byte, +0xe5… the parameters
///   handed to `bufTOFunc`; the remaining 12 bytes are ignored by the official code.
/// - `MouseForTelink::setKey` @0x21dfd0: clears the buffer, then setDeviceMemory
///   `[04][LE32 addr][d0 d1 d2 d3]` → 12-byte Output `BA FF A5 04 <addr LE32> d0 d1 d2 d3`.
///   Unset data bytes stay 0 (buffer cleared first).
/// - Device function byte d0 ↔ app KeyType (setKey switch / bufTOFunc switch):
///   01 keyboard (d2 = HID usage) · 02 combination (d2 = modifier bitmask E0…E7 → bit 0…7,
///   d3 = HID usage) · 03 mouse button (d2 = bitmask F0…F4 → bit 0…4); `03 00 01 01` = Fire ·
///   04 consumer (d2 d3 = big-endian 16-bit usage) · 05 macro (d2 = id) · 07 disable ·
///   08 DPI function (KeyType 0x32) · 09 Sniper / Macro switch (0x33) · 0A DIY etc. (0x34) ·
///   0B vertical wheel (d2 1 = up, 2 = down) · 0C horizontal wheel (d2 2 = right, 1 = left, d3 FF).
///   KeyType 0x35 writes `FF FF FF FF`; bufTOFunc maps d1 == 1 to 0x35 and d0 == FF to a
///   KeyID-dependent default whose extra argument was not recovered — such slots are shown raw.
/// - Key layout `:/DeviceProfile/Device/MT760.json` (11 keys), read order [0,1,2,5,6,4,3,9,10,7,8];
///   modifier / mouse bit tables from the BaseDevice ctor (+0x121 E0…E7, +0x138 F0…F4).
public enum MT760KeyCommand {
    public static let baseAddress: UInt32 = 0x600
    public static let slotLength = 4
    /// Official per-key read length (0x10).
    public static let readLength = 16
    public static let responseDataOffset = 4
    public static let keyIDs = Array(0...10)
    /// Order in which the official remap page passes KeyIDs to getKeyInfoList.
    public static let officialReadOrder = [0, 1, 2, 5, 6, 4, 3, 9, 10, 7, 8]

    public static func address(keyID: Int) -> UInt32 { baseAddress + UInt32(keyID * slotLength) }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    public static func readRequest(keyID: Int) -> [UInt8] {
        [0xBA, 0xFF, 0xA4, UInt8(readLength)] + le32(address(keyID: keyID))
    }

    public static func writeRequest(keyID: Int, slot: [UInt8]) -> [UInt8] {
        [0xBA, 0xFF, 0xA5, UInt8(slotLength)] + le32(address(keyID: keyID)) + slot
    }

    public static func isValidKeyID(_ id: Int) -> Bool { keyIDs.contains(id) }

    /// One key read response → the 16 data bytes (status 01 required). Length unobserved:
    /// accept 20…32 (BA Input capacity), use only bytes 4…19.
    public static func readData(_ response: [UInt8]) throws -> [UInt8] {
        let end = responseDataOffset + readLength
        guard (end...MT760WarmRead.inputCapacity).contains(response.count) else {
            throw DPIReadError.invalid(L("按键读取响应长度为 \(response.count)，不在预期的 \(end)–\(MT760WarmRead.inputCapacity) 字节；未尝试剥头或补零。",
                                         "Button read response is \(response.count) bytes, outside the expected \(end)–\(MT760WarmRead.inputCapacity) bytes; no header stripping or zero padding was attempted."))
        }
        guard response[0] == 1 else {
            throw DPIReadError.invalid(response[0] == 2 ? L("设备忙；本版不重发请求。", "Device busy; this version does not resend requests.")
                                                        : L("响应状态未知：", "Unknown response status: ") + hex(UInt32(response[0])) + L("。", "."))
        }
        return Array(response[responseDataOffset..<end])
    }
}

public enum MouseButton: UInt8, Codable, CaseIterable, Sendable {
    case left = 0xF0, right = 0xF1, middle = 0xF2, back = 0xF3, forward = 0xF4
    var bit: UInt8 { rawValue - 0xF0 }
    public var name: String {
        switch self {
        case .left: L("左键", "Left"); case .right: L("右键", "Right"); case .middle: L("中键", "Middle")
        case .back: L("后退", "Back"); case .forward: L("前进", "Forward")
        }
    }
}

/// KeyType 0x32 KeyCodes (keycode.json).
public enum DPIAction: UInt8, Codable, CaseIterable, Sendable {
    case cyclePlus = 3, cycleMinus = 4, plus = 5, minus = 6
    public var name: String {
        switch self {
        case .cyclePlus: L("DPI 循环+", "DPI Cycle+"); case .cycleMinus: L("DPI 循环−", "DPI Cycle−"); case .plus: "DPI+"; case .minus: "DPI−"
        }
    }
}

/// A key function with an exact 4-byte encoding taken from MouseForTelink::setKey.
public enum KeyFunction: Codable, Equatable, Hashable, Sendable {
    case mouse(MouseButton)
    case keyboard(UInt8)
    /// Modifier bitmask (bit n = HID usage E0+n) and one HID usage.
    case combo(modifiers: UInt8, key: UInt8)
    case multimedia(UInt16)
    case macro(UInt8)
    case disabled
    case dpi(DPIAction)
    case sniper
    case fire
    case macroSwitch
    /// "DIY": keycode.json notes DIY 等同于回报率切换.
    case reportRateSwitch
    case lightModeSwitch
    case configCycle
    case dongleCycle
    case verticalScroll(up: Bool)
    case horizontalScroll(right: Bool)

    public var slot: [UInt8] {
        switch self {
        case .mouse(let button): [0x03, 0x00, 1 << button.bit, 0x00]
        case .keyboard(let code): [0x01, 0x00, code, 0x00]
        case .combo(let modifiers, let key): [0x02, 0x00, modifiers, key]
        case .multimedia(let usage): [0x04, 0x00, UInt8(usage >> 8), UInt8(truncatingIfNeeded: usage)]
        case .macro(let id): [0x05, 0x00, id, 0x00]
        case .disabled: [0x07, 0x00, 0x00, 0x00]
        case .dpi(let action): [0x08, 0x00, action.rawValue, 0x00]
        case .sniper: [0x09, 0x00, 0x01, 0x00]
        case .fire: [0x03, 0x00, 0x01, 0x01] // setKey 0x33 code 2 special case (u32 0x01010003)
        case .macroSwitch: [0x09, 0x00, 0x03, 0x00]
        case .reportRateSwitch: [0x0A, 0x00, 0x00, 0x00]
        case .lightModeSwitch: [0x0A, 0x00, 0x01, 0x00]
        case .configCycle: [0x0A, 0x00, 0x02, 0x00]
        case .dongleCycle: [0x0A, 0x00, 0x03, 0x00]
        case .verticalScroll(let up): [0x0B, 0x00, up ? 0x01 : 0x02, 0x00]
        case .horizontalScroll(let right): [0x0C, 0x00, right ? 0x02 : 0x01, 0xFF]
        }
    }

    /// Strict decode: only slots that this encoder reproduces byte-for-byte are recognised.
    /// Anything else (including the official FF FF FF FF "default" state) returns nil and is shown raw.
    public static func decode(_ slot: [UInt8]) -> KeyFunction? {
        guard slot.count == MT760KeyCommand.slotLength else { return nil }
        let candidate: KeyFunction?
        switch slot[0] {
        case 0x01: candidate = .keyboard(slot[2])
        case 0x02: candidate = .combo(modifiers: slot[2], key: slot[3])
        case 0x03:
            if slot == KeyFunction.fire.slot { candidate = .fire }
            else { candidate = MouseButton.allCases.first { 1 << $0.bit == slot[2] }.map(KeyFunction.mouse) }
        case 0x04: candidate = .multimedia(UInt16(slot[2]) << 8 | UInt16(slot[3]))
        case 0x05: candidate = .macro(slot[2])
        case 0x07: candidate = .disabled
        case 0x08: candidate = DPIAction(rawValue: slot[2]).map(KeyFunction.dpi)
        case 0x09: candidate = [1: .sniper, 3: .macroSwitch][slot[2]]
        case 0x0A: candidate = [0: .reportRateSwitch, 1: .lightModeSwitch, 2: .configCycle, 3: .dongleCycle][slot[2]]
        case 0x0B: candidate = [1: .verticalScroll(up: true), 2: .verticalScroll(up: false)][slot[2]]
        case 0x0C: candidate = [2: .horizontalScroll(right: true), 1: .horizontalScroll(right: false)][slot[2]]
        default: candidate = nil
        }
        guard let candidate, candidate.slot == slot else { return nil }
        return candidate
    }

    public var isScroll: Bool {
        switch self { case .verticalScroll, .horizontalScroll: true; default: false }
    }

    public var name: String {
        switch self {
        case .mouse(let button): L("鼠标 · ", "Mouse · ") + button.name
        case .keyboard(let code): L("键盘 · ", "Key · ") + MT760KeyTables.keyName(code)
        case .combo(let modifiers, let key):
            L("组合键 · ", "Combo · ") + (MT760KeyTables.modifierNames(modifiers) + [MT760KeyTables.keyName(key)]).joined(separator: "+")
        case .multimedia(let usage): L("多媒体 · ", "Media · ") + MT760KeyTables.multimediaName(usage)
        case .macro(let id): L("宏 #", "Macro #") + String(id)
        case .disabled: L("禁用", "Disabled")
        case .dpi(let action): action.name
        case .sniper: L("狙击键", "Sniper")
        case .fire: L("连发键", "Rapid Fire")
        case .macroSwitch: L("宏开关", "Macro Toggle")
        case .reportRateSwitch: L("回报率切换（DIY）", "Report Rate Switch (DIY)")
        case .lightModeSwitch: L("灯效切换", "Lighting Mode Switch")
        case .configCycle: L("配置循环", "Profile Cycle")
        case .dongleCycle: L("接收器循环", "Receiver Cycle")
        case .verticalScroll(let up): up ? L("滚轮 · 上滚", "Wheel · Scroll Up") : L("滚轮 · 下滚", "Wheel · Scroll Down")
        case .horizontalScroll(let right): right ? L("滚轮 · 右滚", "Wheel · Scroll Right") : L("滚轮 · 左滚", "Wheel · Scroll Left")
        }
    }
}

/// Display / write-target tables. Write targets are limited to these known values.
public enum MT760KeyTables {
    // Tables are computed rather than stored so their names follow a runtime language switch.

    /// Mouse "Extended" palette (kb_common.json mouseMultimedia, type 2).
    public static var multimedia: [(usage: UInt16, name: String)] { [
        (0xB6, L("上一曲", "Previous Track")), (0xCD, L("播放/暂停", "Play/Pause")), (0xB5, L("下一曲", "Next Track")), (0xB7, L("停止", "Stop")),
        (0xE2, L("静音", "Mute")), (0xE9, L("音量+", "Volume+")), (0xEA, L("音量−", "Volume−")),
        (0x183, L("媒体播放器", "Media Player")), (0x18A, L("邮件", "Mail")), (0x192, L("计算器", "Calculator")),
        (0x194, L("我的电脑", "My Computer")), (0x221, L("搜索", "Search")),
    ] }

    public static var modifiers: [String] { ["Ctrl", "Shift", "Alt", "Win/⌘"].map { L("左 ", "Left ") + $0 }
        + ["Ctrl", "Shift", "Alt", "Win/⌘"].map { L("右 ", "Right ") + $0 } }

    /// HID keyboard usages offered as single keys / combination keys.
    public static var keys: [(code: UInt8, name: String)] {
        var list: [(UInt8, String)] = []
        for (index, scalar) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { list.append((UInt8(0x04 + index), String(scalar))) }
        for (index, digit) in ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"].enumerated() { list.append((UInt8(0x1E + index), digit)) }
        list += [(0x28, "Enter"), (0x29, "Esc"), (0x2A, "Backspace"), (0x2B, "Tab"), (0x2C, "Space"),
                 (0x2D, "-"), (0x2E, "="), (0x2F, "["), (0x30, "]"), (0x31, "\\"), (0x33, ";"), (0x34, "'"),
                 (0x35, "`"), (0x36, ","), (0x37, "."), (0x38, "/"), (0x39, "Caps Lock")]
        for index in 0..<12 { list.append((UInt8(0x3A + index), "F\(index + 1)")) }
        list += [(0x46, "Print Screen"), (0x47, "Scroll Lock"), (0x48, "Pause"), (0x49, "Insert"), (0x4A, "Home"),
                 (0x4B, "Page Up"), (0x4C, "Delete"), (0x4D, "End"), (0x4E, "Page Down"),
                 (0x4F, "→"), (0x50, "←"), (0x51, "↓"), (0x52, "↑")]
        for index in 0..<8 { list.append((UInt8(0xE0 + index), modifiers[index])) }
        return list
    }

    /// Official mouse "Extended" shortcuts (type 0xF, one modifier + one key).
    public static var shortcuts: [(name: String, function: KeyFunction)] { [
        (L("关闭窗口", "Close Window") + " Alt+F4", .combo(modifiers: 1 << 2, key: 0x3D)),
        (L("锁定电脑", "Lock Computer") + " Win+L", .combo(modifiers: 1 << 3, key: 0x0F)),
        (L("运行", "Run") + " Win+R", .combo(modifiers: 1 << 3, key: 0x15)),
        (L("显示桌面", "Show Desktop") + " Win+D", .combo(modifiers: 1 << 3, key: 0x07)),
        (L("放大", "Zoom In") + " Win+=", .combo(modifiers: 1 << 3, key: 0x57)),
        (L("缩小", "Zoom Out") + " Win+−", .combo(modifiers: 1 << 3, key: 0x2D)),
        (L("复制", "Copy") + " Ctrl+C", .combo(modifiers: 1 << 0, key: 0x06)),
        (L("粘贴", "Paste") + " Ctrl+V", .combo(modifiers: 1 << 0, key: 0x19)),
        (L("剪切", "Cut") + " Ctrl+X", .combo(modifiers: 1 << 0, key: 0x1B)),
        (L("全选", "Select All") + " Ctrl+A", .combo(modifiers: 1 << 0, key: 0x04)),
    ] }

    public static func keyName(_ code: UInt8) -> String {
        keys.first { $0.code == code }?.name ?? (code == 0x57 ? "Keypad +" : hex(UInt32(code)))
    }

    public static func modifierNames(_ mask: UInt8) -> [String] {
        (0..<8).filter { mask & (1 << $0) != 0 }.map { modifiers[$0] }
    }

    public static func multimediaName(_ usage: UInt16) -> String {
        multimedia.first { $0.usage == usage }?.name ?? hex(UInt32(usage))
    }
}

/// The 11 MT760 keys (MT760.json layout) with their official defaults.
public struct MT760Key: Sendable {
    public let id: Int
    public let name: String
    public let defaultFunction: KeyFunction
    /// KeyIDs 7…10 are wheel directions; only they accept wheel functions.
    public var isRoller: Bool { (7...10).contains(id) }

    public static var all: [MT760Key] { [
        MT760Key(id: 0, name: L("左键", "Left Button"), defaultFunction: .mouse(.left)),
        MT760Key(id: 1, name: L("中键", "Middle Button"), defaultFunction: .mouse(.middle)),
        MT760Key(id: 2, name: L("右键", "Right Button"), defaultFunction: .mouse(.right)),
        MT760Key(id: 5, name: L("侧键（默认前进）", "Side Button (default Forward)"), defaultFunction: .mouse(.forward)),
        MT760Key(id: 6, name: L("侧键（默认后退）", "Side Button (default Back)"), defaultFunction: .mouse(.back)),
        MT760Key(id: 4, name: L("DPI 键", "DPI Button"), defaultFunction: .dpi(.cyclePlus)),
        // MT760.json says DIY (0x34/0) but restoreKey overrides MT models to DPI cycle−.
        MT760Key(id: 3, name: L("DIY 键", "DIY Button"), defaultFunction: .dpi(.cycleMinus)),
        MT760Key(id: 9, name: L("滚轮上", "Wheel Up"), defaultFunction: .verticalScroll(up: true)),
        MT760Key(id: 10, name: L("滚轮下", "Wheel Down"), defaultFunction: .verticalScroll(up: false)),
        MT760Key(id: 7, name: L("滚轮左", "Wheel Left"), defaultFunction: .horizontalScroll(right: false)),
        MT760Key(id: 8, name: L("滚轮右", "Wheel Right"), defaultFunction: .horizontalScroll(right: true)),
    ] }

    public static func key(_ id: Int) -> MT760Key? { all.first { $0.id == id } }
}

public enum KeyMappingRules {
    /// Functions this tool may write. Macros, macro switch, light mode, config / dongle cycle are
    /// excluded (need other device state or are not offered for the wired MT760).
    public static func isWriteTarget(_ function: KeyFunction) -> Bool {
        switch function {
        case .mouse, .disabled, .dpi, .sniper, .fire, .reportRateSwitch, .verticalScroll, .horizontalScroll: true
        case .keyboard(let code): MT760KeyTables.keys.contains { $0.code == code }
        case .multimedia(let usage): MT760KeyTables.multimedia.contains { $0.usage == usage }
        case .combo(let modifiers, let key):
            // MT760: MaxModifyNum 1, MaxCodeNum 1; chip 7 rejects empty modifier or key lists.
            modifiers.nonzeroBitCount == 1 && !(0xE0...0xE7).contains(key)
                && (MT760KeyTables.keys.contains { $0.code == key } || key == 0x57)
        case .macro, .macroSwitch, .lightModeSwitch, .configCycle, .dongleCycle: false
        }
    }

    /// Mirrors MSRemapManager::setKeyInfo checks. `slots` is the full current mapping (KeyID 0…10).
    public static func validate(keyID: Int, function: KeyFunction, slots: [[UInt8]]) throws {
        guard let key = MT760Key.key(keyID) else { throw DPIReadError.invalid(L("KeyID \(keyID) 无效。", "Invalid KeyID \(keyID).")) }
        guard isWriteTarget(function) else {
            throw DPIReadError.invalid(L("“\(function.name)”不是本工具支持写入的功能。", "“\(function.name)” is not a function this tool can write."))
        }
        if function.isScroll, !key.isRoller {
            throw DPIReadError.invalid(L("只有滚轮方向键支持滚轮功能（官方限制）。", "Only scroll-wheel directions support scroll functions (official restriction)."))
        }
        if key.isRoller {
            switch function {
            case .dpi, .reportRateSwitch, .sniper, .fire:
                throw DPIReadError.invalid(L("滚轮方向键不能设置 DPI、DIY、狙击或连发功能（官方限制）。",
                                             "Scroll-wheel directions cannot be set to DPI, DIY, sniper or rapid-fire functions (official restriction)."))
            default: break
            }
        }
        guard slots.count == MT760KeyCommand.keyIDs.count else { throw DPIReadError.invalid(L("按键快照不完整。", "Button snapshot is incomplete.")) }
        let leftSlot = KeyFunction.mouse(.left).slot
        let keepsLeft = slots.indices.contains { $0 == keyID ? function.slot == leftSlot : slots[$0] == leftSlot }
        guard keepsLeft else {
            throw DPIReadError.invalid(L("至少需要保留一个按键为“鼠标左键”（官方限制）。", "At least one button must remain the left mouse button (official restriction)."))
        }
    }
}

public struct KeyMappingSnapshot: Codable, Equatable, Sendable {
    /// Index = KeyID 0…10; 4 bytes each (data bytes 0…3 of that key's read).
    public let slots: [[UInt8]]

    public init(slots: [[UInt8]]) throws {
        guard slots.count == MT760KeyCommand.keyIDs.count, slots.allSatisfy({ $0.count == MT760KeyCommand.slotLength }) else {
            throw DPIReadError.invalid(L("按键快照长度无效。", "Invalid button snapshot length."))
        }
        self.slots = slots
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(slots: values.decode([[UInt8]].self, forKey: .slots))
    }

    public func function(keyID: Int) -> KeyFunction? { KeyFunction.decode(slots[keyID]) }
    /// Flattened 44 bytes (KeyID order), used as the previewed baseline.
    public var flattened: [UInt8] { slots.flatMap { $0 } }

    public static func fromFlattened(_ bytes: [UInt8]) throws -> Self {
        let n = MT760KeyCommand.slotLength
        guard bytes.count == n * MT760KeyCommand.keyIDs.count else { throw DPIReadError.invalid(L("按键基线长度无效。", "Invalid button baseline length.")) }
        return try Self(slots: stride(from: 0, to: bytes.count, by: n).map { Array(bytes[$0..<($0 + n)]) })
    }

    /// Exchanges must be the official reads in official order; returns the snapshot.
    static func fromReads(_ exchanges: [HIDExchange]) throws -> Self {
        guard exchanges.count == MT760KeyCommand.officialReadOrder.count else { throw DPIReadError.invalid(L("按键读取记录数量异常。", "Unexpected number of button read records.")) }
        var slots = [[UInt8]](repeating: [], count: MT760KeyCommand.keyIDs.count)
        for (exchange, id) in zip(exchanges, MT760KeyCommand.officialReadOrder) {
            guard exchange.request == MT760KeyCommand.readRequest(keyID: id) else {
                throw DPIReadError.invalid(L("按键读取记录包含非预期请求。", "Button read record contains unexpected requests."))
            }
            slots[id] = Array(try MT760KeyCommand.readData(exchange.response).prefix(MT760KeyCommand.slotLength))
        }
        return try Self(slots: slots)
    }
}

/// One-key change built only from fresh device bytes.
public struct KeyWritePlan: Codable, Equatable {
    public let keyID: Int
    public let oldSlot: [UInt8]
    public let newSlot: [UInt8]
    public let request: [UInt8]
    /// Fresh 16-byte read of this key before the write.
    public let baselineRead: [UInt8]
    /// Readback must equal this: new slot followed by the 12 untouched neighbouring bytes.
    public let expectedRead: [UInt8]

    public static func make(snapshot: KeyMappingSnapshot, keyReadResponse: [UInt8], keyID: Int, newSlot: [UInt8]) throws -> Self {
        guard let function = KeyFunction.decode(newSlot) else {
            throw DPIReadError.invalid(L("目标字节 \(hexBytes(newSlot)) 不是已知的按键功能编码。", "Target bytes \(hexBytes(newSlot)) are not a known button function encoding."))
        }
        try KeyMappingRules.validate(keyID: keyID, function: function, slots: snapshot.slots)
        let baseline = try MT760KeyCommand.readData(keyReadResponse)
        guard Array(baseline.prefix(MT760KeyCommand.slotLength)) == snapshot.slots[keyID] else {
            throw DPIReadError.invalid(L("内部校验失败：按键读取与快照不一致。", "Internal check failed: button read does not match the snapshot."))
        }
        guard newSlot != snapshot.slots[keyID] else {
            throw DPIReadError.invalid(L("该按键已经是“\(function.name)”，不发送写入。", "This button is already “\(function.name)”; no write sent."))
        }
        var expected = baseline
        expected.replaceSubrange(0..<MT760KeyCommand.slotLength, with: newSlot)
        return Self(keyID: keyID, oldSlot: snapshot.slots[keyID], newSlot: newSlot,
                    request: MT760KeyCommand.writeRequest(keyID: keyID, slot: newSlot),
                    baselineRead: baseline, expectedRead: expected)
    }

    public func verify(readback response: [UInt8]) throws -> [UInt8] {
        let data = try MT760KeyCommand.readData(response)
        guard data == expectedRead else {
            throw DPIReadError.invalid(L("读回的按键数据与预期不一致（\(hexBytes(Array(data.prefix(4)))) ≠ \(hexBytes(newSlot))）。", "Readback button data does not match the expected value (\(hexBytes(Array(data.prefix(4)))) ≠ \(hexBytes(newSlot)))."))
        }
        return Array(data.prefix(MT760KeyCommand.slotLength))
    }
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

public struct KeyMappingReadOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public var exchanges: [HIDExchange] = []
    public var snapshot: KeyMappingSnapshot?
    public var error: String?
    public var configurationWritten = false
    public var scope = "Explicit MT760 V0.1.4.4 key-mapping read: the 11 official per-key reads of 0x600+4·KeyID (16 bytes each); no configuration writes, retries, or automatic initialization."

    public init(registryID: String) { self.registryID = registryID }
    public func encoded() throws -> Data { try encodeJSON(self) }

    public func validateConsistency() throws {
        guard !configurationWritten else { throw DPIReadError.invalid(L("读取结果声称写入了配置。", "Read result claims that configuration was written.")) }
        guard exchanges.count <= MT760KeyCommand.officialReadOrder.count else { throw DPIReadError.invalid(L("按键读取记录数量异常。", "Unexpected number of button read records.")) }
        for (exchange, id) in zip(exchanges, MT760KeyCommand.officialReadOrder)
        where exchange.step != "readKey\(id)" || exchange.request != MT760KeyCommand.readRequest(keyID: id) {
            throw DPIReadError.invalid(L("按键读取记录包含非预期请求。", "Button read record contains unexpected requests."))
        }
        if error == nil {
            guard let snapshot,
                  exchanges.allSatisfy({ $0.outputIOReturn == 0 && $0.inputIOReturn == 0 && $0.inputActualLength == $0.response.count }),
                  try KeyMappingSnapshot.fromReads(exchanges) == snapshot else {
                throw DPIReadError.invalid(L("按键读取结果未通过完整性验证。", "Button read result failed integrity verification."))
            }
        } else if snapshot != nil {
            throw DPIReadError.invalid(L("失败结果包含旧的按键数据，已拒绝显示。", "The failed result contains stale button data; refused to display it."))
        }
    }
}

public struct KeyWriteOutcome: Codable {
    public var schemaVersion = 1
    public var completedAt = Date()
    public let registryID: String
    public let keyID: Int
    public let targetSlot: [UInt8]
    /// 44 bytes (11 slots, KeyID order) the user previewed; the fresh reads must match exactly.
    public let expectedBaseline: [UInt8]
    public var exchanges: [HIDExchange] = []
    public var baseline: KeyMappingSnapshot?
    public var plan: KeyWritePlan?
    public var writeRequestSent = false
    public var readbackSlot: [UInt8]?
    public var verified = false
    public var error: String?
    public var persistenceVerified = false
    public var scope = "Single explicit MT760 V0.1.4.4 key-mapping write (setKey bytes): 11 fresh reads matched to the preview, one 4-byte write to 0x600+4·KeyID, one readback of that key. No retries of any request; busy status only polls GetReport."

    public init(registryID: String, keyID: Int, targetSlot: [UInt8], expectedBaseline: [UInt8]) {
        self.registryID = registryID; self.keyID = keyID; self.targetSlot = targetSlot; self.expectedBaseline = expectedBaseline
    }
    public func encoded() throws -> Data { try encodeJSON(self) }

    var expectedSteps: [String] {
        MT760KeyCommand.officialReadOrder.map { "readKey\($0)" } + ["write", "readback"]
    }

    public func validateConsistency() throws {
        let reads = MT760KeyCommand.officialReadOrder.count
        let steps = exchanges.map(\.step)
        guard steps.count <= reads + 2, steps == Array(expectedSteps.prefix(steps.count)) else {
            throw DPIReadError.invalid(L("按键写入记录的步骤顺序异常。", "Button write record has steps in an unexpected order."))
        }
        let expectedRequests: [[UInt8]?] = MT760KeyCommand.officialReadOrder.map { MT760KeyCommand.readRequest(keyID: $0) }
            + [plan?.request, MT760KeyCommand.readRequest(keyID: keyID)]
        for (index, exchange) in exchanges.enumerated() where exchange.request != expectedRequests[index] {
            throw DPIReadError.invalid(L("按键写入记录包含非预期请求。", "Button write record contains unexpected requests."))
        }
        guard writeRequestSent == (exchanges.count > reads) else {
            throw DPIReadError.invalid(L("写入发送标记与记录不一致。", "The write-sent flag does not match the record."))
        }
        if verified {
            guard error == nil, exchanges.count == reads + 2, let baseline, let plan, let readbackSlot,
                  exchanges.allSatisfy({ $0.outputIOReturn == 0 && $0.inputIOReturn == 0 && $0.inputActualLength == $0.response.count }),
                  let readIndex = MT760KeyCommand.officialReadOrder.firstIndex(of: keyID) else {
                throw DPIReadError.invalid(L("按键写入结果未通过完整性验证。", "Button write result failed integrity verification."))
            }
            let snapshot = try KeyMappingSnapshot.fromReads(Array(exchanges.prefix(reads)))
            guard baseline == snapshot, snapshot.flattened == expectedBaseline,
                  try KeyWritePlan.make(snapshot: snapshot, keyReadResponse: exchanges[readIndex].response,
                                        keyID: keyID, newSlot: targetSlot) == plan,
                  exchanges[reads].response.first == 1,
                  try plan.verify(readback: exchanges[reads + 1].response) == readbackSlot else {
                throw DPIReadError.invalid(L("按键写入结果未通过完整性验证。", "Button write result failed integrity verification."))
            }
        } else if error == nil {
            throw DPIReadError.invalid(L("未验证的写入结果缺少错误说明。", "Unverified write result has no error description."))
        }
    }
}
