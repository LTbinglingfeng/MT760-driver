import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MT760Core

struct ReadProcessFailure: Codable {
    let registryID: String
    var completedAt = Date()
    let error: String
    var kind = "helperProcessFailure"
}

/// Last verified DPI state: from a read, or from the readback of a verified write.
struct DPIState: Equatable {
    let registryID: String
    let snapshot: DPISnapshot
    /// Config data bytes 0–19; the only baseline a DPI / gear write may be matched against.
    let baseline: [UInt8]
    let time: Date
}

struct RateState: Equatable {
    let registryID: String
    let snapshot: ReportRateSnapshot
    let time: Date
}

struct KeyMappingState: Equatable {
    let registryID: String
    let snapshot: KeyMappingSnapshot
    let time: Date
    /// True when the slots come from a write readback rather than a plain read.
    let fromWrite: Bool
    var source: String { fromWrite ? L("写入读回", "write readback") : L("读取", "read") }
}

/// One helper transaction, kept with its raw JSON for export.
struct ActivityRecord: Identifiable {
    let id = UUID()
    let time = Date()
    let title: String
    let detail: String
    let succeeded: Bool
    let fileName: String
    let payload: Data
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let succeeded: Bool
    let text: String
}

enum Pane: String, CaseIterable, Identifiable, Hashable {
    case dpi, rate, keys, info
    var id: Self { self }
    var title: String {
        switch self {
        case .dpi: "DPI"
        case .rate: L("回报率", "Report Rate")
        case .keys: L("按键", "Buttons")
        case .info: L("设备信息", "Device Info")
        }
    }
    var symbol: String {
        switch self {
        case .dpi: "scope"
        case .rate: "waveform"
        case .keys: "computermouse"
        case .info: "info.circle"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: Enumeration — the 2 s scan never opens the device.

    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var lastScan: Date?
    private var scanning = false

    /// The MT760 configuration interface (USB 24AE:4500, interface 1). Other Rapoo interfaces are not used.
    var device: DeviceInfo? { devices.first(where: \.canAttemptDPIRead) }
    var hiddenInterfaceCount: Int { devices.count - (device == nil ? 0 : 1) }
    var hasNonUSBInterface: Bool { devices.contains { !$0.isUSB } }

    // MARK: Device state — read automatically, updated from verified readbacks.

    @Published private(set) var dpi: DPIState?
    @Published private(set) var rate: RateState?
    @Published private(set) var keys: KeyMappingState?
    @Published private(set) var dpiError: String?
    @Published private(set) var rateError: String?
    @Published private(set) var keyError: String?
    @Published private(set) var syncing = false
    @Published private(set) var lastSync: Date?

    /// Optimistic targets while a transaction is queued or running.
    @Published private(set) var pendingGear: Int?
    @Published private(set) var pendingDPI: Int?
    @Published private(set) var pendingRate: Int?
    @Published private(set) var pendingKeys: [Int: KeyFunction] = [:]

    @Published private(set) var operationCount = 0
    @Published private(set) var records: [ActivityRecord] = []
    @Published var toast: Toast?

    var busy: Bool { operationCount > 0 }
    var needsPermission: Bool { inputAccess != .granted && dpi == nil && rate == nil && keys == nil }

    private var queueTail: Task<Void, Never>?
    private var syncedID: String?
    private var queuedSyncIDs: Set<String> = []
    // Completion belongs to an operation, not a target value (500 → 250 → 500).
    private var pendingDPIToken: UUID?
    private var pendingGearToken: UUID?
    private var pendingRateToken: UUID?
    private var pendingKeyTokens: [Int: UUID] = [:]
    private let services: AppServices

    init(services: AppServices) {
        self.services = services
        inputAccess = services.inputAccess()
        // Property observers do not run in init; apply the stored choice before the first view is built.
        MT760Language.apply(languagePreference)
    }

    convenience init() { self.init(services: .live) }

    // MARK: Language

    private static let languageKey = "MT760LanguagePreference"

    /// UI language choice, stored in the App's own defaults. Switching needs no relaunch;
    /// texts already recorded (activity log, last error) stay in the language they were created in.
    @Published var languagePreference = MT760LanguagePreference(
        rawValue: UserDefaults.standard.string(forKey: AppModel.languageKey) ?? "") ?? .system {
        didSet {
            MT760Language.apply(languagePreference)
            UserDefaults.standard.set(languagePreference.rawValue, forKey: Self.languageKey)
        }
    }

    // MARK: Permission

    @Published private(set) var inputAccess: InputMonitoringAccess.Status
    private var requestedAccess = false

    /// Requests Input Monitoring once per launch when not yet granted (system prompt / registers the App in Settings).
    func ensureInputAccess() async {
        inputAccess = services.inputAccess()
        guard inputAccess != .granted, !requestedAccess else { return }
        requestedAccess = true
        await requestInputAccess()
    }

    func requestInputAccess() async {
        await services.requestInputAccess()
        inputAccess = services.inputAccess()
    }

    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(InputMonitoringAccess.settingsURL)
    }

    /// TCC answers are cached per process; a granted toggle takes effect only after relaunch.
    func relaunch() {
        guard !busy else { return }
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        do { try process.run() } catch { notify(false, L("无法重新打开：", "Could not reopen: ") + error.localizedDescription); return }
        NSApp.terminate(nil)
    }

    // MARK: Scan & sync

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        devices = await services.scan()
        inputAccess = services.inputAccess()
        lastScan = services.now()
        let id = device?.id
        guard id != syncedID else { return }
        // A new or re-enumerated interface (e.g. after replugging) gets a fresh read.
        syncedID = id
        dpi = nil; rate = nil; keys = nil
        dpiError = nil; rateError = nil; keyError = nil
        pendingGear = nil; pendingDPI = nil; pendingRate = nil; pendingKeys = [:]
        pendingGearToken = nil; pendingDPIToken = nil; pendingRateToken = nil; pendingKeyTokens = [:]
        lastSync = nil
        if id != nil { sync() }
    }

    /// Reads DPI, report rate and key mapping through the helper (read requests only).
    func sync() {
        // An obsolete queued read must not suppress a newly enumerated device's read.
        guard let id = device?.id, queuedSyncIDs.insert(id).inserted else { return }
        enqueue { [self] in
            queuedSyncIDs.remove(id)
            guard isCurrent(id) else { return }
            syncing = true
            await readDPI(id)
            await readRate(id)
            await readKeys(id)
            syncing = false
            if isCurrent(id) { lastSync = services.now() }
        }
    }

    /// The mouse's own DPI key changes the current gear; resync when the user returns.
    func appDidBecomeActive() {
        inputAccess = services.inputAccess()
        guard device != nil else { return }
        if let lastSync, services.now().timeIntervalSince(lastSync) < 5 { return }
        // Busy operations finish first; repeated activation requests coalesce in sync().
        sync()
    }

    var syncStatus: String {
        if device == nil { return L("未连接", "Not connected") }
        if syncing { return L("正在读取…", "Reading…") }
        if let lastSync { return L("已同步 ", "Synced ") + lastSync.formatted(date: .omitted, time: .standard) }
        return L("等待读取", "Waiting to read")
    }

    /// Device operations run strictly one after another; each one spawns at most one helper at a time.
    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = queueTail
        operationCount += 1
        // Unstructured on purpose: view lifetime must not cancel a helper transaction.
        queueTail = Task { @MainActor [weak self] in
            await previous?.value
            await operation()
            self?.operationCount -= 1
        }
    }

    private func isCurrent(_ id: String) -> Bool { device?.id == id }

    func helperURL() -> URL? {
        services.helperURL()
    }

    private static var missingHelper: String { L("缺少可执行的 mt760-read-helper，请重新运行 scripts/build-app.sh；不会回退到主进程访问设备。",
                                         "The mt760-read-helper executable is missing. Run scripts/build-app.sh again; the main process will not access the device as a fallback.") }

    // MARK: Reads

    private func readDPI(_ id: String) async {
        guard isCurrent(id) else { return }
        guard let helper = helperURL() else { dpi = nil; dpiError = Self.missingHelper; return }
        do {
            let outcome = try await services.readDPI(helper, id)
            if outcome.error == nil, let snapshot = outcome.snapshot,
               let baseline = try? DPIWritePlan.baselineData(fromConfigResponse: outcome.response) {
                log(L("读取 DPI", "Read DPI"), L("第 \(snapshot.currentGear) 档 · \(snapshot.currentDPI) DPI · 七槽 \(Self.levels(snapshot)) · 启用 \(snapshot.activeCount) 档",
                                                  "Level \(snapshot.currentGear) · \(snapshot.currentDPI) DPI · 7 slots \(Self.levels(snapshot)) · \(snapshot.activeCount) levels enabled"),
                    succeeded: true, file: "MT760-DPI-read", outcome)
                guard isCurrent(id) else { return }
                dpi = DPIState(registryID: id, snapshot: snapshot, baseline: baseline, time: outcome.completedAt)
                dpiError = nil
            } else {
                let message = outcome.error ?? L("未获得可解析的 DPI 数据。", "No parsable DPI data was received.")
                log(L("读取 DPI", "Read DPI"), message, succeeded: false, file: "MT760-DPI-read", outcome)
                guard isCurrent(id) else { return }
                dpi = nil; dpiError = message
            }
        } catch {
            let failure = ReadProcessFailure(registryID: id, error: Self.helperReadFailed(error))
            log(L("读取 DPI", "Read DPI"), failure.error, succeeded: false, file: "MT760-DPI-read", failure)
            guard isCurrent(id) else { return }
            dpi = nil; dpiError = failure.error
        }
    }

    private func readRate(_ id: String) async {
        guard isCurrent(id) else { return }
        guard let helper = helperURL() else { rate = nil; rateError = Self.missingHelper; return }
        do {
            let outcome = try await services.readRate(helper, id)
            if outcome.error == nil, let snapshot = outcome.snapshot {
                log(L("读取回报率", "Read report rate"), L("有线 \(snapshot.wiredHz) Hz · 无线字节 \(Self.wireless(snapshot)) · 原始块 \(hexBytes(snapshot.block))",
                                                          "Wired \(snapshot.wiredHz) Hz · wireless byte \(Self.wireless(snapshot)) · raw block \(hexBytes(snapshot.block))"),
                    succeeded: true, file: "MT760-report-rate-read", outcome)
                guard isCurrent(id) else { return }
                rate = RateState(registryID: id, snapshot: snapshot, time: outcome.completedAt)
                rateError = nil
            } else {
                let message = outcome.error ?? L("未获得可解析的回报率数据。", "No parsable report-rate data was received.")
                log(L("读取回报率", "Read report rate"), message, succeeded: false, file: "MT760-report-rate-read", outcome)
                guard isCurrent(id) else { return }
                rate = nil; rateError = message
            }
        } catch {
            let failure = ReadProcessFailure(registryID: id, error: Self.helperReadFailed(error))
            log(L("读取回报率", "Read report rate"), failure.error, succeeded: false, file: "MT760-report-rate-read", failure)
            guard isCurrent(id) else { return }
            rate = nil; rateError = failure.error
        }
    }

    private func readKeys(_ id: String) async {
        guard isCurrent(id) else { return }
        guard let helper = helperURL() else { keys = nil; keyError = Self.missingHelper; return }
        do {
            let outcome = try await services.readKeys(helper, id)
            if outcome.error == nil, let snapshot = outcome.snapshot {
                let changed = MT760Key.all.filter { snapshot.function(keyID: $0.id) != $0.defaultFunction }.count
                log(L("读取按键映射", "Read button mapping"), L("11 个按键 · \(changed) 个与默认不同", "11 buttons · \(changed) differ from default"), succeeded: true, file: "MT760-key-mapping-read", outcome)
                guard isCurrent(id) else { return }
                keys = KeyMappingState(registryID: id, snapshot: snapshot, time: outcome.completedAt, fromWrite: false)
                keyError = nil
            } else {
                let message = outcome.error ?? L("未获得可解析的按键数据。", "No parsable button data was received.")
                log(L("读取按键映射", "Read button mapping"), message, succeeded: false, file: "MT760-key-mapping-read", outcome)
                guard isCurrent(id) else { return }
                keys = nil; keyError = message
            }
        } catch {
            let failure = ReadProcessFailure(registryID: id, error: Self.helperReadFailed(error))
            log(L("读取按键映射", "Read button mapping"), failure.error, succeeded: false, file: "MT760-key-mapping-read", failure)
            guard isCurrent(id) else { return }
            keys = nil; keyError = failure.error
        }
    }

    // MARK: DPI value of the current gear

    func applyDPI(_ value: Int) {
        guard let state = dpi, isCurrent(state.registryID), MT760DPICommand.isValidTarget(value),
              value != (pendingDPI ?? state.snapshot.currentDPI) else { return }
        let id = state.registryID
        let gear = state.snapshot.currentGear
        let token = UUID()
        pendingDPI = value; pendingDPIToken = token
        enqueue { [self] in
            defer {
                if pendingDPIToken == token { pendingDPI = nil; pendingDPIToken = nil }
            }
            guard isCurrent(id), let state = dpi, state.registryID == id else { return }
            guard state.snapshot.currentGear == gear else {
                notify(false, L("当前档位已变为第 \(state.snapshot.currentGear) 档，未写入；请重新设置数值。",
                                "The current level changed to level \(state.snapshot.currentGear); nothing was written. Please set the value again."))
                return
            }
            guard value != state.snapshot.currentDPI else { return }
            guard let helper = helperURL() else { notify(false, Self.missingHelper); return }
            do {
                let outcome = try await services.writeDPI(helper, id, value, state.baseline)
                if outcome.verified, let readback = outcome.readback, outcome.exchanges.count == 4,
                   let baseline = try? DPIWritePlan.baselineData(fromConfigResponse: outcome.exchanges[3].response) {
                    log(L("修改 DPI", "Set DPI"), L("第 \(gear) 档 \(state.snapshot.currentDPI) → \(readback.currentDPI) DPI · 读回七槽 \(Self.levels(readback))",
                                                   "Level \(gear) \(state.snapshot.currentDPI) → \(readback.currentDPI) DPI · readback slots \(Self.levels(readback))"),
                        succeeded: true, file: "MT760-DPI-write", outcome)
                    if isCurrent(id) { dpi = DPIState(registryID: id, snapshot: readback, baseline: baseline, time: outcome.completedAt) }
                    notify(true, L("第 \(gear) 档已设为 \(readback.currentDPI) DPI", "Level \(gear) set to \(readback.currentDPI) DPI"))
                } else {
                    await writeFailed(L("修改 DPI", "Set DPI"), outcome.error, sent: outcome.writeRequestSent, file: "MT760-DPI-write", outcome) {
                        await self.readDPI(id)
                    }
                }
            } catch {
                await writeFailed(L("修改 DPI", "Set DPI"), error, id: id, file: "MT760-DPI-write") { await self.readDPI(id) }
            }
        }
    }

    // MARK: Current gear

    func switchGear(to gear: Int) {
        guard let state = dpi, isCurrent(state.registryID), (1...state.snapshot.activeCount).contains(gear),
              gear != (pendingGear ?? state.snapshot.currentGear) else { return }
        let id = state.registryID
        let token = UUID()
        pendingGear = gear; pendingGearToken = token
        enqueue { [self] in
            defer {
                if pendingGearToken == token { pendingGear = nil; pendingGearToken = nil }
            }
            guard isCurrent(id), let state = dpi, state.registryID == id, gear <= state.snapshot.activeCount,
                  gear != state.snapshot.currentGear else { return }
            guard let helper = helperURL() else { notify(false, Self.missingHelper); return }
            do {
                let outcome = try await services.switchGear(helper, id, gear, state.baseline)
                if outcome.verified, let plan = outcome.plan, let readback = outcome.readback, outcome.exchanges.count == 4,
                   let baseline = try? DPIWritePlan.baselineData(fromConfigResponse: outcome.exchanges[3].response) {
                    let swap = plan.swapsUnknownBytes
                        ? L(" · 0x648–0x64B：\(hexBytes(plan.auxiliaryData)) → \(hexBytes(plan.data))（官方字节交换）",
                            " · 0x648–0x64B: \(hexBytes(plan.auxiliaryData)) → \(hexBytes(plan.data)) (official byte swap)") : ""
                    log(L("切换档位", "Switch level"), L("第 \(plan.oldGear) 档 → 第 \(readback.currentGear) 档（\(readback.currentDPI) DPI）",
                                                     "Level \(plan.oldGear) → level \(readback.currentGear) (\(readback.currentDPI) DPI)") + swap,
                        succeeded: true, file: "MT760-DPI-gear-switch", outcome)
                    if isCurrent(id) { dpi = DPIState(registryID: id, snapshot: readback, baseline: baseline, time: outcome.completedAt) }
                } else {
                    await writeFailed(L("切换档位", "Switch level"), outcome.error, sent: outcome.writeRequestSent, file: "MT760-DPI-gear-switch", outcome) {
                        await self.readDPI(id)
                    }
                }
            } catch {
                await writeFailed(L("切换档位", "Switch level"), error, id: id, file: "MT760-DPI-gear-switch") { await self.readDPI(id) }
            }
        }
    }

    // MARK: Report rate

    func applyRate(_ hz: Int) {
        guard let state = rate, isCurrent(state.registryID), MT760ReportRateCommand.isValidTarget(hz),
              hz != (pendingRate ?? state.snapshot.wiredHz) else { return }
        let id = state.registryID
        let token = UUID()
        pendingRate = hz; pendingRateToken = token
        enqueue { [self] in
            defer {
                if pendingRateToken == token { pendingRate = nil; pendingRateToken = nil }
            }
            guard isCurrent(id), let state = rate, state.registryID == id, hz != state.snapshot.wiredHz else { return }
            guard let helper = helperURL() else { notify(false, Self.missingHelper); return }
            do {
                let outcome = try await services.writeRate(helper, id, hz, state.snapshot.block)
                if outcome.verified, let plan = outcome.plan, let readback = outcome.readback {
                    log(L("修改回报率", "Set report rate"), L("\(plan.oldHz) → \(readback.wiredHz) Hz · 有线与无线字节均为 \(hex(UInt32(plan.data[0])))（官方行为）",
                                                         "\(plan.oldHz) → \(readback.wiredHz) Hz · wired and wireless bytes both \(hex(UInt32(plan.data[0]))) (official behavior)"),
                        succeeded: true, file: "MT760-report-rate-write", outcome)
                    if isCurrent(id) { rate = RateState(registryID: id, snapshot: readback, time: outcome.completedAt) }
                    notify(true, L("回报率已设为 \(readback.wiredHz) Hz", "Report rate set to \(readback.wiredHz) Hz"))
                } else {
                    await writeFailed(L("修改回报率", "Set report rate"), outcome.error, sent: outcome.writeRequestSent, file: "MT760-report-rate-write", outcome) {
                        await self.readRate(id)
                    }
                }
            } catch {
                await writeFailed(L("修改回报率", "Set report rate"), error, id: id, file: "MT760-report-rate-write") { await self.readRate(id) }
            }
        }
    }

    // MARK: Key mapping

    func displayedFunction(keyID: Int) -> KeyFunction? {
        pendingKeys[keyID] ?? keys?.snapshot.function(keyID: keyID)
    }

    /// Long-lived editors supply their captured device ID; immediate menu actions use the current device.
    func canAssign(_ function: KeyFunction, to keyID: Int, expectedRegistryID: String? = nil) -> Bool {
        guard let state = keys, isCurrent(state.registryID),
              expectedRegistryID == nil || expectedRegistryID == state.registryID else { return false }
        return (try? KeyMappingRules.validate(keyID: keyID, function: function, slots: state.snapshot.slots)) != nil
    }

    func assign(_ function: KeyFunction, to keyID: Int, expectedRegistryID: String? = nil) {
        guard let state = keys, let key = MT760Key.key(keyID),
              canAssign(function, to: keyID, expectedRegistryID: expectedRegistryID),
              function != displayedFunction(keyID: keyID) else { return }
        let id = state.registryID
        let token = UUID()
        pendingKeys[keyID] = function; pendingKeyTokens[keyID] = token
        enqueue { [self] in
            defer {
                if pendingKeyTokens[keyID] == token { pendingKeys[keyID] = nil; pendingKeyTokens[keyID] = nil }
            }
            guard isCurrent(id), let state = keys, state.registryID == id, function.slot != state.snapshot.slots[keyID] else { return }
            do { try KeyMappingRules.validate(keyID: keyID, function: function, slots: state.snapshot.slots) }
            catch { notify(false, error.localizedDescription); return }
            guard let helper = helperURL() else { notify(false, Self.missingHelper); return }
            let oldSlot = state.snapshot.slots[keyID]
            let oldName = KeyFunction.decode(oldSlot)?.name ?? L("未识别 ", "Unrecognized ") + hexBytes(oldSlot)
            do {
                let outcome = try await services.writeKey(helper, id, keyID, function, state.snapshot)
                // Fresh reads of all keys in the same transaction + verified readback of the changed key.
                if outcome.verified, let baseline = outcome.baseline, let slot = outcome.readbackSlot {
                    var slots = baseline.slots
                    slots[keyID] = slot
                    log(L("修改按键", "Set button"), L("\(key.name)：\(oldName) → \(function.name) · 地址 \(hex(MT760KeyCommand.address(keyID: keyID)))：\(hexBytes(oldSlot)) → \(hexBytes(slot))",
                                                    "\(key.name): \(oldName) → \(function.name) · address \(hex(MT760KeyCommand.address(keyID: keyID))): \(hexBytes(oldSlot)) → \(hexBytes(slot))"),
                        succeeded: true, file: "MT760-key-write", outcome)
                    if isCurrent(id), let snapshot = try? KeyMappingSnapshot(slots: slots) {
                        keys = KeyMappingState(registryID: id, snapshot: snapshot, time: outcome.completedAt, fromWrite: true)
                    }
                    notify(true, L("\(key.name) 已设为 \(function.name)", "\(key.name) set to \(function.name)"))
                } else {
                    await writeFailed(L("修改按键", "Set button"), outcome.error, sent: outcome.writeRequestSent, file: "MT760-key-write", outcome) {
                        await self.readKeys(id)
                    }
                }
            } catch {
                await writeFailed(L("修改按键", "Set button"), error, id: id, file: "MT760-key-write") { await self.readKeys(id) }
            }
        }
    }

    // MARK: Failures, records, toasts

    /// A failed transaction is never resent; the affected section is re-read so the UI shows the real state.
    private func writeFailed<T: Encodable>(_ title: String, _ error: String?, sent: Bool, file: String, _ outcome: T,
                                           resync: () async -> Void) async {
        let message = error ?? L("写入未完成。", "The write did not complete.")
        log(title, message + (sent ? L("（写请求已发出，状态以重新读取为准）", " (write request was sent; the re-read result is authoritative)")
                                   : L("（未发出写请求）", " (no write request was sent)")),
            succeeded: false, file: file, outcome)
        notify(false, message + L(" 已重新读取设备。", " The device was re-read."))
        await resync()
    }

    private func writeFailed(_ title: String, _ error: Error, id: String, file: String, resync: () async -> Void) async {
        let failure = ReadProcessFailure(registryID: id, error: L("写入事务失败：\(error.localizedDescription) 设备状态以重新读取为准。",
                                                                         "Write transaction failed: \(error.localizedDescription) The re-read device state is authoritative."))
        log(title, failure.error, succeeded: false, file: file, failure)
        notify(false, failure.error)
        await resync()
    }

    private func log<T: Encodable>(_ title: String, _ detail: String, succeeded: Bool, file: String, _ value: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stamp = Self.fileStamp.string(from: Date())
        records.insert(ActivityRecord(title: title, detail: detail, succeeded: succeeded,
                                      fileName: "\(file)-\(stamp).json", payload: (try? encoder.encode(value)) ?? Data()), at: 0)
        if records.count > 60 { records.removeLast(records.count - 60) }
    }

    func notify(_ succeeded: Bool, _ text: String) {
        let toast = Toast(succeeded: succeeded, text: text)
        self.toast = toast
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: succeeded ? 2_400_000_000 : 6_000_000_000)
            if self?.toast?.id == toast.id { self?.toast = nil }
        }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func helperReadFailed(_ error: Error) -> String {
        L("辅助进程读取失败：", "Helper read failed: ") + error.localizedDescription
    }

    static func levels(_ snapshot: DPISnapshot) -> String { snapshot.levels.map(String.init).joined(separator: " / ") }

    static func wireless(_ snapshot: ReportRateSnapshot) -> String {
        hex(UInt32(snapshot.wirelessCode)) + (snapshot.wirelessHz.map { L("（\($0) Hz）", " (\($0) Hz)") } ?? L("（未知编码）", " (unknown code)"))
    }

    // MARK: Export

    func export(_ record: ActivityRecord) {
        save(record.payload, name: record.fileName, title: L("导出\(record.title)记录", "Export “\(record.title)” Record"),
             message: L("包含各步骤原始请求 / 响应 / IOReturn；进程失败时仅记录错误，不伪造设备响应。",
                        "Contains the raw request / response / IOReturn of each step. If the process failed, only the error is recorded; no device response is fabricated."))
    }

    func exportDiagnostics() {
        do {
            save(try DiagnosticSnapshot(devices: devices).encoded(), name: "MT760-diagnostics.json", title: L("导出设备诊断", "Export Device Diagnostics"),
                 message: L("包含全部 Rapoo 接口信息与 HID 描述符，不包含序列号、蓝牙地址或输入事件。",
                            "Contains all Rapoo interface information and HID descriptors; no serial numbers, Bluetooth addresses or input events."))
        } catch { notify(false, L("导出失败：", "Export failed: ") + error.localizedDescription) }
    }

    private func save(_ data: Data, name: String, title: String, message: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = name
        panel.title = title
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            notify(true, L("已保存到 ", "Saved to ") + url.lastPathComponent)
        } catch { notify(false, L("导出失败：", "Export failed: ") + error.localizedDescription) }
    }
}
