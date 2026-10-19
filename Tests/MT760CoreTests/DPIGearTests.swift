import Foundation
import Testing
@testable import MT760Core

/// Offline only: plans and validates gear-switch bytes, never opens HID devices.
struct DPIGearTests {
    func observed() throws -> [UInt8] {
        let url = try #require(Bundle.module.url(forResource: "mt760-warm-read", withExtension: "json", subdirectory: "Fixtures"))
        struct F: Decodable { let response: [UInt8] }
        return try JSONDecoder().decode(F.self, from: Data(contentsOf: url)).response
    }
    /// Observed sample with 0x64A == 0x64B so the official swap is a no-op (synthetic).
    func swapSafe() throws -> [UInt8] {
        var config = try observed(); config[22] = 0x03; config[23] = 0x03
        return config
    }
    /// Synthetic auxiliary response: status 01, unverified header, then 0x648… = config data 16…19.
    func aux(_ config: [UInt8]) -> [UInt8] { [0x01, 0x04, 0x04, 0x01] + Array(config[20...23]) + [0x10, 0x00, 0x14, 0x00] }

    @Test func writeHeaderMatchesStaticAnalysis() {
        #expect(MT760DPIGearCommand.writeHeader == [0xBA, 0xFF, 0xA5, 0x04, 0x48, 0x06, 0x00, 0x00])
    }

    @Test func plansOfficialGearWriteChangingOnlyGearByte() throws {
        let config = try swapSafe()
        let plan = try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 1)
        #expect(plan.oldGear == 3 && plan.newGear == 1 && plan.oldDPI == 4000 && plan.newDPI == 800)
        #expect(plan.request == [0xBA, 0xFF, 0xA5, 0x04, 0x48, 0x06, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03])
        let diff = (0..<20).filter { plan.expectedData[$0] != plan.baselineData[$0] }
        #expect(diff == [16])
        #expect(!plan.swapsUnknownBytes)
    }

    @Test func requestUsesOfficialSwappedOrder() throws {
        // B5 distinct from B6 == B7 still exercises the [g−1][B5][B7][B6] layout.
        var config = try swapSafe(); config[21] = 0x09
        let plan = try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 7)
        #expect(Array(plan.request[8...]) == [0x06, 0x09, 0x03, 0x03])
    }

    @Test func recordedSampleKeepsOfficialSwapOfUnknownBytes() throws {
        // The recorded hardware sample has 0x648… = 02 00 02 03; the official write flips the last two.
        let config = try observed()
        let plan = try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 1)
        #expect(plan.swapsUnknownBytes)
        #expect(plan.request == [0xBA, 0xFF, 0xA5, 0x04, 0x48, 0x06, 0x00, 0x00, 0x00, 0x00, 0x03, 0x02])
        #expect((0..<20).filter { plan.expectedData[$0] != plan.baselineData[$0] } == [16, 18, 19])
        var readback = config; readback[20] = 0; readback[22] = 0x03; readback[23] = 0x02
        #expect(try plan.verify(readback: readback).currentGear == 1)
        var unswapped = config; unswapped[20] = 0 // device ignored the swap: not what was written
        #expect(throws: DPIReadError.self) { try plan.verify(readback: unswapped) }
    }

    @Test func rejectsNoOpInactiveAndInvalidGears() throws {
        var config = try swapSafe()
        for gear in [3, 0, 8, -1] {
            #expect(throws: DPIReadError.self) {
                try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: gear)
            }
        }
        config[18] = 3 // only four gears enabled
        #expect(throws: DPIReadError.self) {
            try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 5)
        }
        #expect(try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 4).newGear == 4)
    }

    @Test func rejectsInconsistentAuxiliaryRead() throws {
        let config = try swapSafe()
        var bad = aux(config); bad[5] ^= 0xFF
        #expect(throws: DPIReadError.self) { try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: bad, targetGear: 1) }
        var busy = aux(config); busy[0] = 2
        #expect(throws: DPIReadError.self) { try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: busy, targetGear: 1) }
        #expect(throws: DPIReadError.self) { try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: Array(aux(config).prefix(7)), targetGear: 1) }
    }

    @Test func readbackMustChangeOnlyGearByte() throws {
        let config = try swapSafe()
        let plan = try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 1)
        var readback = config; readback[20] = 0
        #expect(try plan.verify(readback: readback).currentGear == 1)
        #expect(throws: DPIReadError.self) { try plan.verify(readback: config) } // unchanged device
        var levelChanged = readback; levelChanged[4] = 0x11
        #expect(throws: DPIReadError.self) { try plan.verify(readback: levelChanged) }
        var auxChanged = readback; auxChanged[23] ^= 1
        #expect(throws: DPIReadError.self) { try plan.verify(readback: auxChanged) }
    }

    func exchange(_ step: String, _ request: [UInt8], _ response: [UInt8]) -> HIDExchange {
        var e = HIDExchange(step: step, request: request)
        e.outputIOReturn = 0; e.inputIOReturn = 0; e.response = response; e.inputActualLength = response.count
        return e
    }

    func verifiedOutcome() throws -> DPIGearSwitchOutcome {
        let config = try swapSafe()
        let plan = try DPIGearSwitchPlan.make(configResponse: config, auxiliaryResponse: aux(config), targetGear: 1)
        var readback = config; readback[20] = 0
        var o = DPIGearSwitchOutcome(registryID: "1000ab9c7", targetGear: 1, expectedBaseline: plan.baselineData)
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
        let copy = try decoder.decode(DPIGearSwitchOutcome.self, from: o.encoded())
        try copy.validateConsistency()
        #expect(copy.readback?.currentGear == 1)
    }

    @Test func forgedOrInconsistentOutcomesAreRejected() throws {
        var badStatus = try verifiedOutcome(); badStatus.exchanges[2].response = [0x00]
        #expect(throws: DPIReadError.self) { try badStatus.validateConsistency() }
        var extraStep = try verifiedOutcome(); extraStep.exchanges.append(extraStep.exchanges[2])
        #expect(throws: DPIReadError.self) { try extraStep.validateConsistency() }
        var wrongRequest = try verifiedOutcome()
        wrongRequest.exchanges[2] = exchange("write", MT760DPIGearCommand.writeHeader + [0x00, 0x00, 0x02, 0x03], [1])
        #expect(throws: DPIReadError.self) { try wrongRequest.validateConsistency() }
        var hiddenSend = try verifiedOutcome(); hiddenSend.writeRequestSent = false
        #expect(throws: DPIReadError.self) { try hiddenSend.validateConsistency() }
        var silentFailure = try verifiedOutcome(); silentFailure.verified = false
        #expect(throws: DPIReadError.self) { try silentFailure.validateConsistency() }
    }

    @Test func missingHelperNeverFallsBackForGearSwitch() async throws {
        let baseline = try DPIWritePlan.baselineData(fromConfigResponse: swapSafe())
        do {
            _ = try await DPIGearClient.switchGear(helperURL: URL(fileURLWithPath: "/nonexistent/mt760-read-helper"),
                                                   registryID: "1000ab9c7", targetGear: 1, expectedBaseline: baseline)
            Issue.record("Expected missing helper error")
        } catch { #expect(error.localizedDescription.lowercased().contains(L("辅助程序", "helper not found"))) }
    }
}
