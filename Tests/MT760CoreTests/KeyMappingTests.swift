import Foundation
import Testing
@testable import MT760Core

/// Offline only: synthetic responses (no key-mapping response has been observed on hardware).
struct KeyMappingTests {
    /// Official defaults, KeyID order 0…10.
    var defaultSlots: [[UInt8]] {
        (0...10).map { id in MT760Key.key(id)!.defaultFunction.slot }
    }

    /// Status 01, unverified header, then 16 data bytes starting at the key's slot.
    func response(keyID: Int, slots: [[UInt8]], tail: UInt8 = 0x5A) -> [UInt8] {
        let following = slots.dropFirst(keyID).prefix(4).flatMap { $0 }
        let data = following + [UInt8](repeating: tail, count: 16 - following.count)
        return [0x01, 0x04, 0x04, 0x01] + data
    }

    func reads(_ slots: [[UInt8]]) -> [HIDExchange] {
        MT760KeyCommand.officialReadOrder.map { id in
            var exchange = HIDExchange(step: "readKey\(id)", request: MT760KeyCommand.readRequest(keyID: id))
            exchange.outputIOReturn = 0; exchange.inputIOReturn = 0
            exchange.response = response(keyID: id, slots: slots)
            exchange.inputActualLength = exchange.response.count
            return exchange
        }
    }

    @Test func commandBytesMatchStaticAnalysis() {
        #expect(MT760KeyCommand.readRequest(keyID: 0) == [0xBA, 0xFF, 0xA4, 0x10, 0x00, 0x06, 0x00, 0x00])
        #expect(MT760KeyCommand.readRequest(keyID: 10) == [0xBA, 0xFF, 0xA4, 0x10, 0x28, 0x06, 0x00, 0x00])
        #expect(MT760KeyCommand.writeRequest(keyID: 5, slot: [0x03, 0x00, 0x08, 0x00])
                == [0xBA, 0xFF, 0xA5, 0x04, 0x14, 0x06, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00])
        #expect(MT760KeyCommand.officialReadOrder.sorted() == Array(0...10))
    }

    @Test func encodingsFollowOfficialSetKey() {
        #expect(KeyFunction.mouse(.left).slot == [0x03, 0x00, 0x01, 0x00])
        #expect(KeyFunction.mouse(.forward).slot == [0x03, 0x00, 0x10, 0x00])
        #expect(KeyFunction.fire.slot == [0x03, 0x00, 0x01, 0x01])
        #expect(KeyFunction.keyboard(0x04).slot == [0x01, 0x00, 0x04, 0x00])
        #expect(KeyFunction.combo(modifiers: 0x01, key: 0x06).slot == [0x02, 0x00, 0x01, 0x06])
        #expect(KeyFunction.multimedia(0x0192).slot == [0x04, 0x00, 0x01, 0x92])
        #expect(KeyFunction.disabled.slot == [0x07, 0x00, 0x00, 0x00])
        #expect(KeyFunction.dpi(.cyclePlus).slot == [0x08, 0x00, 0x03, 0x00])
        #expect(KeyFunction.sniper.slot == [0x09, 0x00, 0x01, 0x00])
        #expect(KeyFunction.reportRateSwitch.slot == [0x0A, 0x00, 0x00, 0x00])
        #expect(KeyFunction.verticalScroll(up: true).slot == [0x0B, 0x00, 0x01, 0x00])
        #expect(KeyFunction.verticalScroll(up: false).slot == [0x0B, 0x00, 0x02, 0x00])
        #expect(KeyFunction.horizontalScroll(right: true).slot == [0x0C, 0x00, 0x02, 0xFF])
        #expect(KeyFunction.horizontalScroll(right: false).slot == [0x0C, 0x00, 0x01, 0xFF])
    }

    @Test func decodeIsStrictRoundTrip() {
        let all: [KeyFunction] = MouseButton.allCases.map(KeyFunction.mouse) + DPIAction.allCases.map(KeyFunction.dpi)
            + [.fire, .sniper, .macroSwitch, .disabled, .reportRateSwitch, .lightModeSwitch, .configCycle, .dongleCycle,
               .keyboard(0x2C), .combo(modifiers: 0x08, key: 0x0F), .multimedia(0xE9), .macro(2),
               .verticalScroll(up: true), .verticalScroll(up: false), .horizontalScroll(right: true), .horizontalScroll(right: false)]
        for function in all { #expect(KeyFunction.decode(function.slot) == function) }
        // Unknown / ambiguous bytes stay raw.
        for bad: [UInt8] in [[0xFF, 0xFF, 0xFF, 0xFF], [0x03, 0x00, 0x03, 0x00], [0x03, 0x01, 0x01, 0x00],
                             [0x09, 0x00, 0x02, 0x00], [0x0B, 0x00, 0x03, 0x00], [0x0C, 0x00, 0x02, 0x00],
                             [0x01, 0x00, 0x04, 0x01], [0x06, 0x00, 0x00, 0x00], [0x00, 0x00, 0x00]] {
            #expect(KeyFunction.decode(bad) == nil)
        }
    }

    @Test func snapshotFromOfficialReads() throws {
        let snapshot = try KeyMappingSnapshot.fromReads(reads(defaultSlots))
        #expect(snapshot.slots == defaultSlots)
        #expect(snapshot.function(keyID: 3) == .dpi(.cycleMinus))
        #expect(snapshot.flattened.count == 44)
        #expect(try KeyMappingSnapshot.fromFlattened(snapshot.flattened) == snapshot)
    }

    @Test func rejectsMalformedReadResponses() {
        var busy = response(keyID: 0, slots: defaultSlots); busy[0] = 2
        for bad in [Array(response(keyID: 0, slots: defaultSlots).prefix(19)), busy,
                    response(keyID: 0, slots: defaultSlots) + [UInt8](repeating: 0, count: 13)] {
            #expect(throws: DPIReadError.self) { try MT760KeyCommand.readData(bad) }
        }
    }

    @Test func plansSingleSlotWritePreservingNeighbours() throws {
        let snapshot = try KeyMappingSnapshot(slots: defaultSlots)
        let read = response(keyID: 5, slots: defaultSlots)
        let plan = try KeyWritePlan.make(snapshot: snapshot, keyReadResponse: read, keyID: 5,
                                         newSlot: KeyFunction.multimedia(0xCD).slot)
        #expect(plan.request == [0xBA, 0xFF, 0xA5, 0x04, 0x14, 0x06, 0x00, 0x00, 0x04, 0x00, 0x00, 0xCD])
        #expect(Array(plan.expectedRead[4...]) == Array(read[8...]))
        var back = read; back.replaceSubrange(4..<8, with: plan.newSlot)
        #expect(try plan.verify(readback: back) == plan.newSlot)
        var neighbourChanged = back; neighbourChanged[9] ^= 1
        #expect(throws: DPIReadError.self) { try plan.verify(readback: neighbourChanged) }
        #expect(throws: DPIReadError.self) { try plan.verify(readback: read) }
    }

    @Test func enforcesOfficialRemapRules() throws {
        let slots = defaultSlots
        // Scroll only on wheel keys; wheel keys refuse DPI / DIY / sniper / fire.
        #expect(throws: DPIReadError.self) { try KeyMappingRules.validate(keyID: 1, function: .verticalScroll(up: true), slots: slots) }
        #expect(throws: DPIReadError.self) { try KeyMappingRules.validate(keyID: 9, function: .dpi(.plus), slots: slots) }
        #expect(throws: DPIReadError.self) { try KeyMappingRules.validate(keyID: 7, function: .fire, slots: slots) }
        try KeyMappingRules.validate(keyID: 9, function: .multimedia(0xE9), slots: slots)
        // Must keep a left button somewhere.
        #expect(throws: DPIReadError.self) { try KeyMappingRules.validate(keyID: 0, function: .disabled, slots: slots) }
        var moved = slots; moved[5] = KeyFunction.mouse(.left).slot
        try KeyMappingRules.validate(keyID: 0, function: .mouse(.right), slots: moved)
        // Excluded / unknown targets.
        for function: KeyFunction in [.macro(0), .configCycle, .macroSwitch, .keyboard(0x99), .multimedia(0x1234),
                                      .combo(modifiers: 0x03, key: 0x06), .combo(modifiers: 0x01, key: 0xE1)] {
            #expect(throws: DPIReadError.self) { try KeyMappingRules.validate(keyID: 2, function: function, slots: slots) }
        }
        for (_, shortcut) in MT760KeyTables.shortcuts { try KeyMappingRules.validate(keyID: 6, function: shortcut, slots: slots) }
    }

    @Test func refusesNoOpWrite() throws {
        let snapshot = try KeyMappingSnapshot(slots: defaultSlots)
        #expect(throws: DPIReadError.self) {
            try KeyWritePlan.make(snapshot: snapshot, keyReadResponse: response(keyID: 1, slots: defaultSlots),
                                  keyID: 1, newSlot: KeyFunction.mouse(.middle).slot)
        }
    }

    func verifiedWriteOutcome() throws -> KeyWriteOutcome {
        let keyID = 4, target = KeyFunction.reportRateSwitch.slot
        let snapshot = try KeyMappingSnapshot(slots: defaultSlots)
        var outcome = KeyWriteOutcome(registryID: "abc", keyID: keyID, targetSlot: target, expectedBaseline: snapshot.flattened)
        outcome.exchanges = reads(defaultSlots)
        outcome.baseline = snapshot
        let readIndex = MT760KeyCommand.officialReadOrder.firstIndex(of: keyID)!
        let plan = try KeyWritePlan.make(snapshot: snapshot, keyReadResponse: outcome.exchanges[readIndex].response,
                                         keyID: keyID, newSlot: target)
        outcome.plan = plan
        outcome.writeRequestSent = true
        var write = HIDExchange(step: "write", request: plan.request)
        write.outputIOReturn = 0; write.inputIOReturn = 0; write.response = [0x01] + [UInt8](repeating: 0, count: 11)
        write.inputActualLength = write.response.count
        var back = HIDExchange(step: "readback", request: MT760KeyCommand.readRequest(keyID: keyID))
        back.outputIOReturn = 0; back.inputIOReturn = 0
        var after = defaultSlots; after[keyID] = target
        back.response = response(keyID: keyID, slots: after); back.inputActualLength = back.response.count
        outcome.exchanges += [write, back]
        outcome.readbackSlot = target
        outcome.verified = true
        return outcome
    }

    @Test func writeOutcomeRevalidatesFromRawExchanges() throws {
        let outcome = try verifiedWriteOutcome()
        try outcome.validateConsistency()

        var tampered = outcome; tampered.readbackSlot = KeyFunction.disabled.slot
        #expect(throws: DPIReadError.self) { try tampered.validateConsistency() }
        var noFlag = outcome; noFlag.writeRequestSent = false
        #expect(throws: DPIReadError.self) { try noFlag.validateConsistency() }
        var unexplained = outcome; unexplained.verified = false
        #expect(throws: DPIReadError.self) { try unexplained.validateConsistency() }
    }

    @Test func verifiedWriteRequiresBaselineMatchingRawReads() throws {
        let outcome = try verifiedWriteOutcome()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        try outcome.validateConsistency()
        let decoded = try decoder.decode(KeyWriteOutcome.self, from: outcome.encoded())
        #expect(decoded.baseline == outcome.baseline)
        try decoded.validateConsistency()

        var missing = outcome
        missing.baseline = nil
        var targetChanged = defaultSlots
        targetChanged[outcome.keyID] = outcome.targetSlot
        var replaced = outcome
        replaced.baseline = try KeyMappingSnapshot(slots: targetChanged)
        // A different, unwritten key must also be bound to the original reads.
        var untouchedChanged = defaultSlots
        untouchedChanged[6] = KeyFunction.disabled.slot
        var neighbourChanged = outcome
        neighbourChanged.baseline = try KeyMappingSnapshot(slots: untouchedChanged)

        for invalid in [missing, replaced, neighbourChanged] {
            #expect(throws: DPIReadError.self) { try invalid.validateConsistency() }
            let roundTripped = try decoder.decode(KeyWriteOutcome.self, from: invalid.encoded())
            #expect(throws: DPIReadError.self) { try roundTripped.validateConsistency() }
        }
    }

    @Test func readOutcomeRejectsFailureWithData() throws {
        var outcome = KeyMappingReadOutcome(registryID: "abc")
        outcome.exchanges = reads(defaultSlots)
        outcome.snapshot = try KeyMappingSnapshot.fromReads(outcome.exchanges)
        try outcome.validateConsistency()
        outcome.error = "x"
        #expect(throws: DPIReadError.self) { try outcome.validateConsistency() }
        var wrongOrder = KeyMappingReadOutcome(registryID: "abc")
        wrongOrder.exchanges = Array(reads(defaultSlots).reversed())
        wrongOrder.error = "x"; wrongOrder.snapshot = nil
        #expect(throws: DPIReadError.self) { try wrongOrder.validateConsistency() }
    }

    @Test func outcomesRoundTripThroughJSON() throws {
        var outcome = KeyMappingReadOutcome(registryID: "abc")
        outcome.exchanges = reads(defaultSlots)
        outcome.snapshot = try KeyMappingSnapshot.fromReads(outcome.exchanges)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(KeyMappingReadOutcome.self, from: outcome.encoded())
        #expect(decoded.snapshot == outcome.snapshot)
        try decoded.validateConsistency()
    }
}
