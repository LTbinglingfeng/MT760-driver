import Foundation
import Testing
@testable import MT760App
@testable import MT760Core

private func device(_ id: String) throws -> DeviceInfo {
    let json = """
    {"id":"\(id)","product":"OFFLINE MOCK","vendorID":9390,"productID":17664,"transport":"USB","primaryUsage":{"page":1,"usage":6},"usages":[{"page":65280,"usage":14}],"maxInputBytes":32,"maxOutputBytes":32,"maxFeatureBytes":0,"descriptor":[],"usbInterfaceNumber":1,"summary":{"reports":[{"kind":"input","reportID":186,"bitCount":248},{"kind":"output","reportID":186,"bitCount":248}],"warnings":[],"lengthsAreReliable":true}}
    """
    let d = try JSONDecoder().decode(DeviceInfo.self, from: Data(json.utf8))
    precondition(d.canAttemptDPIRead)
    return d
}
private func dpiResponse(_ value: Int) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: 28); r[0] = 1
    for i in 0..<7 { r[4+i*2] = UInt8(value/50) }
    r[18] = 6; r[20] = 0
    return r
}
private func exchange(_ step: String, _ request: [UInt8], _ response: [UInt8]) -> HIDExchange {
    var e = HIDExchange(step: step, request: request)
    e.outputIOReturn = 0; e.inputIOReturn = 0; e.response = response; e.inputActualLength = response.count
    return e
}

private enum FakeError: Error { case timeout, injectedFailure }

/// Each write has its own bounded continuation; a failed assertion cannot strand the queue forever.
private actor WriteGate {
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
    func pause(_ number: Int) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiters[number] = continuation
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self.expire(number)
            }
        }
    }
    private func expire(_ number: Int) {
        waiters.removeValue(forKey: number)?.resume(throwing: FakeError.timeout)
    }
    func contains(_ number: Int) -> Bool { waiters[number] != nil }
    func release(_ number: Int) throws {
        guard let continuation = waiters.removeValue(forKey: number) else { throw FakeError.timeout }
        continuation.resume()
    }
}

@MainActor
private final class FakeIO {
    var devices: [DeviceInfo] = []
    var now = Date(timeIntervalSince1970: 1_000)
    var reads: [String] = []
    var writes: [String] = []
    var baselines: [[UInt8]] = []
    var failNextWrite = false
    let gate = WriteGate()
    private var configs: [String: [UInt8]] = [:]
    private var rates: [String: [UInt8]] = [:]
    private var mappings: [String: [[UInt8]]] = [:]

    func config(_ id: String) -> [UInt8] { configs[id] ?? dpiResponse(800) }
    func rateBlock(_ id: String) -> [UInt8] {
        let code = MT760ReportRateCommand.code(forTarget: 1000)!
        return rates[id] ?? [code, code, 0, 0, 0, 0, 0, 0]
    }
    func slots(_ id: String) -> [[UInt8]] {
        // MT760Key.all is presentation order, NOT wire KeyID order.
        mappings[id] ?? (0...10).map { MT760Key.key($0)!.defaultFunction.slot }
    }
    func keyResponse(_ key: Int, _ slots: [[UInt8]]) -> [UInt8] {
        let bytes = slots.dropFirst(key).prefix(4).flatMap { $0 }
        return [1, 4, 4, 1] + bytes + Array(repeating: 0, count: 16 - bytes.count)
    }
    func keyReads(_ slots: [[UInt8]]) -> [HIDExchange] {
        MT760KeyCommand.officialReadOrder.map {
            exchange("readKey\($0)", MT760KeyCommand.readRequest(keyID: $0), keyResponse($0, slots))
        }
    }
    var services: AppServices {
        AppServices(
            scan: { self.devices }, inputAccess: { .granted }, requestInputAccess: {},
            helperURL: { URL(fileURLWithPath: "/offline-only/never-executed") }, now: { self.now },
            readDPI: { _, id in try self.readDPI(id) },
            readRate: { _, id in try self.readRate(id) },
            readKeys: { _, id in try self.readKeys(id) },
            writeDPI: { _, id, target, baseline in try await self.writeDPI(id, target, baseline) },
            switchGear: { _, id, target, baseline in try await self.switchGear(id, target, baseline) },
            writeRate: { _, id, target, baseline in try await self.writeRate(id, target, baseline) },
            writeKey: { _, id, key, function, baseline in try await self.writeKey(id, key, function, baseline) }
        )
    }
    func readDPI(_ id: String) throws -> DPIReadOutcome {
        reads.append("\(id):dpi")
        var o = DPIReadOutcome(registryID: id)
        o.response = config(id); o.snapshot = try DPISnapshot.decode(o.response)
        o.outputIOReturn = 0; o.inputIOReturn = 0; o.inputActualLength = o.response.count
        // DPIReadOutcome has no validateConsistency; decode raw bytes just as its client does.
        return o
    }
    func readRate(_ id: String) throws -> ReportRateReadOutcome {
        reads.append("\(id):rate")
        var o = ReportRateReadOutcome(registryID: id)
        let response: [UInt8] = [1, 0, 0, 0] + rateBlock(id)
        o.snapshot = try ReportRateSnapshot.decode(response)
        o.exchange = exchange("readRate", MT760ReportRateCommand.read, response)
        try o.validateConsistency(); return o
    }
    func readKeys(_ id: String) throws -> KeyMappingReadOutcome {
        reads.append("\(id):keys")
        var o = KeyMappingReadOutcome(registryID: id)
        o.exchanges = keyReads(slots(id)); o.snapshot = try KeyMappingSnapshot.fromReads(o.exchanges)
        try o.validateConsistency(); return o
    }
    func pause(_ label: String, _ baseline: [UInt8]) async throws {
        writes.append(label); baselines.append(baseline)
        try await gate.pause(writes.count)
        if failNextWrite { failNextWrite = false; throw FakeError.injectedFailure }
    }
    func writeDPI(_ id: String, _ target: Int, _ baseline: [UInt8]) async throws -> DPIWriteOutcome {
        try await pause("\(id):dpi=\(target)", baseline)
        let before = config(id)
        #expect(try DPIWritePlan.baselineData(fromConfigResponse: before) == baseline)
        let aux: [UInt8] = [1, 0, 0, 0] + Array(before[20...23])
        let plan = try DPIWritePlan.make(configResponse: before, auxiliaryResponse: aux, targetDPI: target)
        let after: [UInt8] = [1, 0, 0, 0] + plan.data + [0, 0, 0, 0]
        var o = DPIWriteOutcome(registryID: id, targetDPI: target, expectedBaseline: baseline)
        o.baseline = try DPISnapshot.decode(before); o.plan = plan
        o.readback = try plan.verify(readback: after); o.verified = true; o.writeRequestSent = true
        o.exchanges = [exchange("readConfig", MT760DPICommand.readConfig, before),
                       exchange("readAuxiliary", MT760DPICommand.readAuxiliary, aux),
                       exchange("write", plan.request, [1, 0, 0, 0]),
                       exchange("readback", MT760DPICommand.readConfig, after)]
        try o.validateConsistency(); configs[id] = after; return o
    }
    func switchGear(_ id: String, _ target: Int, _ baseline: [UInt8]) async throws -> DPIGearSwitchOutcome {
        try await pause("\(id):gear=\(target)", baseline)
        let before = config(id)
        #expect(try DPIWritePlan.baselineData(fromConfigResponse: before) == baseline)
        let aux: [UInt8] = [1, 0, 0, 0] + Array(before[20...23])
        let plan = try DPIGearSwitchPlan.make(configResponse: before, auxiliaryResponse: aux, targetGear: target)
        let after: [UInt8] = [1, 0, 0, 0] + plan.expectedData + [0, 0, 0, 0]
        var o = DPIGearSwitchOutcome(registryID: id, targetGear: target, expectedBaseline: baseline)
        o.baseline = try DPISnapshot.decode(before); o.plan = plan
        o.readback = try plan.verify(readback: after); o.verified = true; o.writeRequestSent = true
        o.exchanges = [exchange("readConfig", MT760DPICommand.readConfig, before),
                       exchange("readAuxiliary", MT760DPICommand.readAuxiliary, aux),
                       exchange("write", plan.request, [1, 0, 0, 0]),
                       exchange("readback", MT760DPICommand.readConfig, after)]
        try o.validateConsistency(); configs[id] = after; return o
    }
    func writeRate(_ id: String, _ target: Int, _ baseline: [UInt8]) async throws -> ReportRateWriteOutcome {
        try await pause("\(id):rate=\(target)", baseline)
        #expect(baseline == rateBlock(id))
        let before: [UInt8] = [1, 0, 0, 0] + rateBlock(id)
        let plan = try ReportRateWritePlan.make(readResponse: before, targetHz: target)
        let after: [UInt8] = [1, 0, 0, 0] + plan.expectedBlock
        var o = ReportRateWriteOutcome(registryID: id, targetHz: target, expectedBaseline: baseline)
        o.baseline = try ReportRateSnapshot.decode(before); o.plan = plan
        o.readback = try plan.verify(readback: after); o.verified = true; o.writeRequestSent = true
        o.exchanges = [exchange("readRate", MT760ReportRateCommand.read, before),
                       exchange("write", plan.request, [1, 0, 0, 0]),
                       exchange("readback", MT760ReportRateCommand.read, after)]
        try o.validateConsistency(); rates[id] = plan.expectedBlock; return o
    }
    func writeKey(_ id: String, _ key: Int, _ function: KeyFunction, _ baseline: KeyMappingSnapshot) async throws -> KeyWriteOutcome {
        try await pause("\(id):key=\(function.name)", baseline.flattened)
        #expect(baseline.slots == slots(id))
        var o = KeyWriteOutcome(registryID: id, keyID: key, targetSlot: function.slot, expectedBaseline: baseline.flattened)
        o.baseline = baseline; o.exchanges = keyReads(slots(id))
        let plan = try KeyWritePlan.make(snapshot: baseline, keyReadResponse: keyResponse(key, slots(id)), keyID: key, newSlot: function.slot)
        var after = slots(id); after[key] = function.slot
        o.plan = plan; o.writeRequestSent = true; o.verified = true; o.readbackSlot = function.slot
        o.exchanges += [exchange("write", plan.request, [1, 0, 0, 0]),
                        exchange("readback", MT760KeyCommand.readRequest(keyID: key), keyResponse(key, after))]
        try o.validateConsistency(); mappings[id] = after; return o
    }
}

@MainActor
private func waitUntil(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !(await predicate()) {
        guard ContinuousClock.now < deadline else { throw FakeError.timeout }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
private func fresh(_ io: FakeIO) async throws -> AppModel {
    io.devices = [try device("a")]
    let model = AppModel(services: io.services)
    await model.refresh()
    try await waitUntil { !model.busy }
    #expect(model.dpi?.snapshot.currentDPI == 800)
    #expect(model.rate?.snapshot.wiredHz == 1000)
    #expect(model.keys?.snapshot.slots == io.slots("a"))
    return model
}

struct AppModelTests {
    @Test @MainActor func staleEditorCannotWriteNewDeviceButNewEditorCan() async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        io.devices = [try device("b")]; await model.refresh()
        try await waitUntil { !model.busy }
        #expect(!model.canAssign(.reportRateSwitch, to: 4, expectedRegistryID: "a"))
        model.assign(.reportRateSwitch, to: 4, expectedRegistryID: "a")
        #expect(!model.busy && io.writes.isEmpty && model.pendingKeys.isEmpty)
        #expect(model.canAssign(.reportRateSwitch, to: 4, expectedRegistryID: "b"))
        model.assign(.reportRateSwitch, to: 4, expectedRegistryID: "b")
        try await waitUntil { await io.gate.contains(1) }
        try await io.gate.release(1)
        try await waitUntil { !model.busy }
        #expect(io.writes.count == 1 && io.writes[0].hasPrefix("b:key="))
        #expect(model.keys?.snapshot.function(keyID: 4) == .reportRateSwitch)
    }

    @Test @MainActor func obsoleteQueuedSyncDoesNotSuppressNewDeviceSync() async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        model.applyRate(500)
        try await waitUntil { await io.gate.contains(1) }
        model.sync()
        io.devices = [try device("b")]; await model.refresh()
        try await io.gate.release(1)
        try await waitUntil { !model.busy }
        #expect(io.reads == ["a:dpi", "a:rate", "a:keys", "b:dpi", "b:rate", "b:keys"])
        #expect(model.dpi?.registryID == "b" && model.rate?.registryID == "b" && model.keys?.registryID == "b")
        #expect(model.lastSync != nil)
        await model.refresh(); await model.refresh()
        #expect(!model.busy && io.reads.count == 6)
    }

    @Test @MainActor func returnToOriginalDPIUsesLatestReadbackBaseline() async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        let initial = try #require(model.dpi?.baseline)
        model.applyDPI(1600)
        try await waitUntil { await io.gate.contains(1) }
        model.applyDPI(800)
        #expect(model.operationCount == 2 && model.pendingDPI == 800)
        try await io.gate.release(1)
        try await waitUntil { await io.gate.contains(2) }
        #expect(model.dpi?.snapshot.currentDPI == 1600)
        #expect(io.baselines[0] == initial && io.baselines[1] == model.dpi?.baseline)
        #expect(io.baselines[1] != initial && model.pendingDPI == 800)
        try await io.gate.release(2)
        try await waitUntil { !model.busy }
        #expect(io.writes == ["a:dpi=1600", "a:dpi=800"])
        #expect(model.dpi?.snapshot.currentDPI == 800 && model.pendingDPI == nil)
    }

    @Test @MainActor func busyActivationCoalescesOneDeferredSync() async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        let old = model.lastSync
        io.now += 60
        model.applyRate(500)
        try await waitUntil { await io.gate.contains(1) }
        for _ in 0..<5 { model.appDidBecomeActive() }
        #expect(model.operationCount == 2 && io.reads.count == 3)
        try await io.gate.release(1)
        try await waitUntil { !model.busy }
        #expect(io.reads == ["a:dpi", "a:rate", "a:keys", "a:dpi", "a:rate", "a:keys"])
        #expect(model.lastSync == io.now && model.lastSync != old)
        #expect(model.rate?.snapshot.wiredHz == 500)
        model.appDidBecomeActive()
        #expect(!model.busy && io.reads.count == 6)
    }

    @Test(arguments: ["dpi", "gear", "rate", "key"])
    @MainActor func repeatedTargetKeepsPendingUntilItsOwnCompletion(kind: String) async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        func apply(_ first: Bool) {
            switch kind {
            case "dpi": model.applyDPI(first ? 1600 : 1200)
            case "gear": model.switchGear(to: first ? 2 : 3)
            case "rate": model.applyRate(first ? 500 : 250)
            default: model.assign(first ? .reportRateSwitch : .disabled, to: 4, expectedRegistryID: "a")
            }
        }
        func pendingIsFirst() -> Bool {
            switch kind {
            case "dpi": model.pendingDPI == 1600
            case "gear": model.pendingGear == 2
            case "rate": model.pendingRate == 500
            default: model.pendingKeys[4] == .reportRateSwitch
            }
        }
        apply(true)
        try await waitUntil { await io.gate.contains(1) }
        apply(false); apply(true)
        #expect(model.operationCount == 3 && pendingIsFirst())
        for number in 1...3 {
            #expect(pendingIsFirst())
            try await io.gate.release(number)
            if number < 3 {
                try await waitUntil { await io.gate.contains(number + 1) }
                #expect(pendingIsFirst())
                #expect(model.operationCount == 3 - number)
            }
        }
        try await waitUntil { !model.busy }
        #expect(io.writes.count == 3 && io.writes[0] == io.writes[2] && io.writes[0] != io.writes[1])
        #expect(model.pendingDPI == nil && model.pendingGear == nil && model.pendingRate == nil && model.pendingKeys.isEmpty)
        switch kind {
        case "dpi": #expect(model.dpi?.snapshot.currentDPI == 1600)
        case "gear": #expect(model.dpi?.snapshot.currentGear == 2)
        case "rate": #expect(model.rate?.snapshot.wiredHz == 500)
        default: #expect(model.keys?.snapshot.function(keyID: 4) == .reportRateSwitch)
        }
    }

    @Test(arguments: [false, true])
    @MainActor func removalOrSwitchDropsOldQueuedWrites(switchDevice: Bool) async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        model.applyRate(500)
        try await waitUntil { await io.gate.contains(1) }
        model.applyDPI(1600); model.switchGear(to: 2); model.applyRate(250)
        model.assign(.reportRateSwitch, to: 4, expectedRegistryID: "a")
        io.devices = switchDevice ? [try device("b")] : []
        await model.refresh()
        #expect(model.pendingDPI == nil && model.pendingGear == nil && model.pendingRate == nil && model.pendingKeys.isEmpty)
        try await io.gate.release(1)
        try await waitUntil { !model.busy }
        #expect(io.writes == ["a:rate=500"])
        if switchDevice {
            #expect(model.dpi?.registryID == "b" && model.rate?.snapshot.wiredHz == 1000 && model.keys?.registryID == "b")
            #expect(io.reads.count == 6)
        } else {
            #expect(model.device == nil && model.dpi == nil && model.rate == nil && model.keys == nil)
            #expect(io.reads.count == 3)
        }
    }

    @Test(arguments: ["dpi", "gear", "rate", "key"])
    @MainActor func failedWriteOnlyRereadsAndNeverRetries(kind: String) async throws {
        let io = FakeIO()
        let model = try await fresh(io)
        io.failNextWrite = true
        switch kind {
        case "dpi": model.applyDPI(1600)
        case "gear": model.switchGear(to: 2)
        case "rate": model.applyRate(500)
        default: model.assign(.reportRateSwitch, to: 4, expectedRegistryID: "a")
        }
        try await waitUntil { await io.gate.contains(1) }
        try await io.gate.release(1)
        try await waitUntil { !model.busy }
        #expect(io.writes.count == 1)
        let section = kind == "gear" ? "dpi" : (kind == "key" ? "keys" : kind)
        #expect(io.reads == ["a:dpi", "a:rate", "a:keys", "a:\(section)"])
        #expect(model.dpi?.snapshot.currentDPI == 800 && model.dpi?.snapshot.currentGear == 1)
        #expect(model.rate?.snapshot.wiredHz == 1000 && model.keys?.snapshot.slots == io.slots("a"))
        #expect(model.pendingDPI == nil && model.pendingGear == nil && model.pendingRate == nil && model.pendingKeys.isEmpty)
        #expect(model.records.filter { !$0.succeeded }.count == 1)
    }
}
