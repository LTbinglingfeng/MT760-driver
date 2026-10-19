import Foundation
import Testing
@testable import MT760Core

/// Offline only: plans and validates bytes, never opens HID devices.
struct DPIWriteTests {
    func observed() throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "mt760-warm-read", withExtension: "json", subdirectory: "Fixtures"))
        struct F: Decodable { let response: [UInt8] }
        return try JSONDecoder().decode(F.self, from: Data(contentsOf: url)).response
    }
    /// Synthetic auxiliary response: status 01, unverified header, then 0x648… = config data 16…19.
    func aux(_ config: [UInt8]) -> [UInt8] { [0x01, 0x04, 0x04, 0x01] + Array(config[20...23]) + [0x10, 0x00, 0x14, 0x00] }

    @Test func normalizationClampsExtremeValuesAndBounds() {
        for (value, expected) in [(Int.min, 50), (-50, 50), (0, 50), (49, 50),
                                  (50, 50), (51, 50), (3999, 4000), (4000, 4000),
                                  (4001, 4000), (Int.max, 4000)] {
            #expect(MT760DPICommand.normalizedTarget(value) == expected)
        }
    }

    @Test func normalizationRoundsNonMultiplesAndHalfStepsUp() {
        for (value, expected) in [(74, 50), (75, 100), (76, 100), (123, 100),
                                  (124, 100), (125, 150), (126, 150), (801, 800),
                                  (824, 800), (825, 850), (826, 850),
                                  (3974, 3950), (3975, 4000), (3976, 4000)] {
            #expect(MT760DPICommand.normalizedTarget(value) == expected)
        }
    }

    @Test func normalizationIsValidAndIdempotent() {
        for value in [Int.min, Int.max] + Array(-100...4100) {
            let normalized = MT760DPICommand.normalizedTarget(value)
            #expect(MT760DPICommand.isValidTarget(normalized))
            #expect(MT760DPICommand.normalizedTarget(normalized) == normalized)
            if MT760DPICommand.isValidTarget(value) {
                #expect(normalized == value)
            }
        }
    }

    @Test func commandBytesMatchStaticAnalysis() {
        #expect(MT760DPICommand.readConfig == [0xBA, 0xFF, 0xA4, 0x18, 0x38, 0x06, 0x00, 0x00])
        #expect(MT760DPICommand.readAuxiliary == [0xBA, 0xFF, 0xA4, 0x08, 0x48, 0x06, 0x00, 0x00])
        #expect(MT760DPICommand.writeHeader == [0xBA, 0xFF, 0xA5, 0x14, 0x38, 0x06, 0x00, 0x00])
    }

    @Test func plansCurrentSlotChangeOnly() throws {
        let config = try observed()
        let plan = try DPIWritePlan.make(configResponse: config, auxiliaryResponse: aux(config), targetDPI: 1600)
        #expect(plan.gear == 3 && plan.oldDPI == 4000 && plan.newDPI == 1600)
        #expect(plan.request.count == 28)
        #expect(plan.request == [0xBA, 0xFF, 0xA5, 0x14, 0x38, 0x06, 0x00, 0x00,
                                 0x10, 0x00, 0x14, 0x00, 0x20, 0x00, 0x20, 0x00, 0x30, 0x00, 0x40, 0x00,
                                 0x50, 0x00, 0x06, 0x00, 0x02, 0x00, 0x02, 0x03])
        // Slot 7 also holds 4000; the plan uses the protocol gear byte, not a value search.
        #expect(plan.expectedLevels == [800, 1000, 1600, 1600, 2400, 3200, 4000])
        let diff = (0..<20).filter { plan.data[$0] != plan.baselineData[$0] }
        #expect(diff == [4])
    }

    @Test func encodesTargetAsLE16Units() throws {
        let config = try observed()
        // Max 4000 DPI = 80 units, so the high byte stays 0 for every valid target.
        let plan = try DPIWritePlan.make(configResponse: config, auxiliaryResponse: aux(config), targetDPI: 50)
        #expect(Array(plan.data[4...5]) == [0x01, 0x00])
    }

    @Test func rejectsNoOpAndInvalidTargets() throws {
        let config = try observed()
        for target in [4000, 0, 49, 75, 4050, -50] {
            #expect(throws: DPIReadError.self) {
                try DPIWritePlan.make(configResponse: config, auxiliaryResponse: aux(config), targetDPI: target)
            }
        }
    }

    @Test func rejectsInconsistentAuxiliaryRead() throws {
        let config = try observed()
        var bad = aux(config); bad[5] ^= 0xFF
        #expect(throws: DPIReadError.self) { try DPIWritePlan.make(configResponse: config, auxiliaryResponse: bad, targetDPI: 1600) }
        var busy = aux(config); busy[0] = 2
        #expect(throws: DPIReadError.self) { try DPIWritePlan.make(configResponse: config, auxiliaryResponse: busy, targetDPI: 1600) }
        #expect(throws: DPIReadError.self) { try DPIWritePlan.make(configResponse: config, auxiliaryResponse: Array(aux(config).prefix(7)), targetDPI: 1600) }
    }

    @Test func refusesToClearUnknownByte15() throws {
        var config = try observed(); config[19] = 0x01
        #expect(throws: DPIReadError.self) { try DPIWritePlan.make(configResponse: config, auxiliaryResponse: aux(config), targetDPI: 1600) }
    }

    @Test func readbackMustMatchWrittenBytes() throws {
        let config = try observed()
        let plan = try DPIWritePlan.make(configResponse: config, auxiliaryResponse: aux(config), targetDPI: 1600)
        var readback = config
        readback.replaceSubrange(4..<24, with: plan.data)
        #expect(try plan.verify(readback: readback).currentDPI == 1600)
        #expect(throws: DPIReadError.self) { try plan.verify(readback: config) } // unchanged device
        var gearMoved = readback; gearMoved[20] = 6
        #expect(throws: DPIReadError.self) { try plan.verify(readback: gearMoved) }
        var auxChanged = readback; auxChanged[23] ^= 1
        #expect(throws: DPIReadError.self) { try plan.verify(readback: auxChanged) }
    }

    func exchange(_ step: String, _ request: [UInt8], _ response: [UInt8]) -> HIDExchange {
        var e = HIDExchange(step: step, request: request)
        e.outputIOReturn = 0; e.inputIOReturn = 0; e.response = response; e.inputActualLength = response.count
        return e
    }

    func verifiedOutcome() throws -> DPIWriteOutcome {
        let config = try observed()
        let plan = try DPIWritePlan.make(configResponse: config, auxiliaryResponse: aux(config), targetDPI: 1600)
        var readback = config; readback.replaceSubrange(4..<24, with: plan.data)
        var o = DPIWriteOutcome(registryID: "1000ab9c7", targetDPI: 1600, expectedBaseline: plan.baselineData)
        o.exchanges = [exchange("readConfig", MT760DPICommand.readConfig, config),
                       exchange("readAuxiliary", MT760DPICommand.readAuxiliary, aux(config)),
                       exchange("write", plan.request, [0x01, 0, 0, 0]),
                       exchange("readback", MT760DPICommand.readConfig, readback)]
        o.baseline = try DPISnapshot.decode(config); o.plan = plan; o.writeRequestSent = true
        o.readback = try plan.verify(readback: readback); o.verified = true
        return o
    }

    @Test func verifiedOutcomeRoundTripsAndValidates() throws {
        let o = try verifiedOutcome()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(DPIWriteOutcome.self, from: o.encoded())
        try copy.validateConsistency()
        #expect(copy.readback?.currentDPI == 1600)
    }

    @Test func forgedOrInconsistentOutcomesAreRejected() throws {
        var badStatus = try verifiedOutcome(); badStatus.exchanges[2].response = [0x00]
        #expect(throws: DPIReadError.self) { try badStatus.validateConsistency() }
        var extraStep = try verifiedOutcome(); extraStep.exchanges.append(extraStep.exchanges[2])
        #expect(throws: DPIReadError.self) { try extraStep.validateConsistency() }
        var wrongRequest = try verifiedOutcome(); wrongRequest.exchanges[1] = exchange("readAuxiliary", [0xBA, 0xFF, 0xA5], [1])
        #expect(throws: DPIReadError.self) { try wrongRequest.validateConsistency() }
        var hiddenSend = try verifiedOutcome(); hiddenSend.writeRequestSent = false
        #expect(throws: DPIReadError.self) { try hiddenSend.validateConsistency() }
        var silentFailure = try verifiedOutcome(); silentFailure.verified = false
        #expect(throws: DPIReadError.self) { try silentFailure.validateConsistency() }
        var otherBaseline = try verifiedOutcome()
        otherBaseline = DPIWriteOutcome(registryID: otherBaseline.registryID, targetDPI: 1600,
                                        expectedBaseline: [UInt8](repeating: 0, count: 20))
        #expect(throws: DPIReadError.self) { try otherBaseline.validateConsistency() } // error == nil, not verified
    }

    @Test func missingHelperNeverFallsBackForWrites() async throws {
        let baseline = try DPIWritePlan.baselineData(fromConfigResponse: observed())
        do {
            _ = try await DPIWriteClient.write(helperURL: URL(fileURLWithPath: "/nonexistent/mt760-read-helper"),
                                               registryID: "1000ab9c7", targetDPI: 1600, expectedBaseline: baseline)
            Issue.record("Expected missing helper error")
        } catch { #expect(error.localizedDescription.lowercased().contains(L("辅助程序", "helper not found"))) }
    }
}
