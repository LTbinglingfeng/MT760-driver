import Foundation
import Testing
@testable import MT760Core

/// Offline only: synthetic responses (the 0x630 response has not been observed on hardware).
struct ReportRateTests {
    /// Status 01, unverified header bytes, then the 8-byte block at 0x630.
    func response(_ block: [UInt8]) -> [UInt8] { [0x01, 0x04, 0x04, 0x01] + block }
    let block1000: [UInt8] = [0x01, 0x01, 0x5A, 0xA5, 0x11, 0x22, 0x33, 0x44]

    @Test func commandBytesMatchStaticAnalysis() {
        #expect(MT760ReportRateCommand.read == [0xBA, 0xFF, 0xA4, 0x08, 0x30, 0x06, 0x00, 0x00])
        #expect(MT760ReportRateCommand.writeHeader == [0xBA, 0xFF, 0xA5, 0x04, 0x30, 0x06, 0x00, 0x00])
        #expect([125, 250, 500, 1000].map { MT760ReportRateCommand.code(forTarget: $0) } == [0x08, 0x04, 0x02, 0x01])
        // Higher codes decode but are never write targets for this chip type.
        #expect(MT760ReportRateCommand.hz(forCode: 0x84) == 2000)
        #expect(MT760ReportRateCommand.code(forTarget: 2000) == nil)
        #expect(MT760ReportRateCommand.code(forTarget: 8000) == nil)
    }

    @Test func decodesWiredAndWirelessCodes() throws {
        let snapshot = try ReportRateSnapshot.decode(response([0x02, 0x08] + Array(block1000[2...])))
        #expect(snapshot.wiredHz == 500 && snapshot.wirelessHz == 125 && snapshot.wirelessCode == 0x08)
        // Trailing bytes up to BA Input capacity are ignored, not reinterpreted.
        let padded = response(block1000) + [UInt8](repeating: 0xEE, count: 20)
        #expect(try ReportRateSnapshot.decode(padded).block == block1000)
    }

    @Test func rejectsMalformedResponses() {
        var busy = response(block1000); busy[0] = 2
        var unknownWired = block1000; unknownWired[0] = 0x03
        var highWired = block1000; highWired[0] = 0x84
        for bad in [Array(response(block1000).prefix(11)), response(block1000) + [UInt8](repeating: 0, count: 21),
                    busy, response(unknownWired), response(highWired)] {
            #expect(throws: DPIReadError.self) { try ReportRateSnapshot.decode(bad) }
        }
    }

    @Test func plansOfficialFourByteWrite() throws {
        let plan = try ReportRateWritePlan.make(readResponse: response(block1000), targetHz: 500)
        #expect(plan.oldHz == 1000 && plan.newHz == 500)
        #expect(plan.request == [0xBA, 0xFF, 0xA5, 0x04, 0x30, 0x06, 0x00, 0x00, 0x02, 0x02, 0x5A, 0xA5])
        #expect(plan.expectedBlock == [0x02, 0x02, 0x5A, 0xA5, 0x11, 0x22, 0x33, 0x44])
    }

    @Test func overwritesKnownWirelessCodeLikeOfficialSetter() throws {
        var block = block1000; block[1] = 0x08
        let plan = try ReportRateWritePlan.make(readResponse: response(block), targetHz: 250)
        #expect(Array(plan.data[0...1]) == [0x04, 0x04])
    }

    @Test func refusesNoOpInvalidTargetAndUnknownWirelessByte() {
        for target in [1000, 0, 2000, 4000, 8000, 300] {
            #expect(throws: DPIReadError.self) { try ReportRateWritePlan.make(readResponse: response(block1000), targetHz: target) }
        }
        var block = block1000; block[1] = 0x00
        #expect(throws: DPIReadError.self) { try ReportRateWritePlan.make(readResponse: response(block), targetHz: 500) }
    }

    @Test func readbackMustMatchWholeBlock() throws {
        let plan = try ReportRateWritePlan.make(readResponse: response(block1000), targetHz: 125)
        #expect(try plan.verify(readback: response(plan.expectedBlock)).wiredHz == 125)
        #expect(throws: DPIReadError.self) { try plan.verify(readback: response(block1000)) }
        var tail = plan.expectedBlock; tail[6] ^= 1 // unwritten bytes must not change
        #expect(throws: DPIReadError.self) { try plan.verify(readback: response(tail)) }
    }

    func exchange(_ step: String, _ request: [UInt8], _ response: [UInt8]) -> HIDExchange {
        var e = HIDExchange(step: step, request: request)
        e.outputIOReturn = 0; e.inputIOReturn = 0; e.response = response; e.inputActualLength = response.count
        return e
    }

    func verifiedOutcome() throws -> ReportRateWriteOutcome {
        let plan = try ReportRateWritePlan.make(readResponse: response(block1000), targetHz: 500)
        var o = ReportRateWriteOutcome(registryID: "1000ab9c7", targetHz: 500, expectedBaseline: block1000)
        o.exchanges = [exchange("readRate", MT760ReportRateCommand.read, response(block1000)),
                       exchange("write", plan.request, [0x01, 0, 0, 0]),
                       exchange("readback", MT760ReportRateCommand.read, response(plan.expectedBlock))]
        o.baseline = try ReportRateSnapshot.decode(response(block1000)); o.plan = plan; o.writeRequestSent = true
        o.readback = try plan.verify(readback: response(plan.expectedBlock)); o.verified = true
        return o
    }

    @Test func verifiedWriteOutcomeRoundTripsAndValidates() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(ReportRateWriteOutcome.self, from: verifiedOutcome().encoded())
        try copy.validateConsistency()
        #expect(copy.readback?.wiredHz == 500)
    }

    @Test func forgedWriteOutcomesAreRejected() throws {
        var badStatus = try verifiedOutcome(); badStatus.exchanges[1].response = [0x00]
        #expect(throws: DPIReadError.self) { try badStatus.validateConsistency() }
        var extra = try verifiedOutcome(); extra.exchanges.append(extra.exchanges[1])
        #expect(throws: DPIReadError.self) { try extra.validateConsistency() }
        var hidden = try verifiedOutcome(); hidden.writeRequestSent = false
        #expect(throws: DPIReadError.self) { try hidden.validateConsistency() }
        var other = try verifiedOutcome()
        other = ReportRateWriteOutcome(registryID: other.registryID, targetHz: 500, expectedBaseline: other.expectedBaseline)
        #expect(throws: DPIReadError.self) { try other.validateConsistency() }
        var stale = try verifiedOutcome()
        stale = ReportRateWriteOutcome(registryID: stale.registryID, targetHz: 500, expectedBaseline: [UInt8](repeating: 0, count: 8))
        stale.exchanges = try verifiedOutcome().exchanges; stale.writeRequestSent = true
        stale.plan = try verifiedOutcome().plan; stale.readback = try verifiedOutcome().readback; stale.verified = true
        #expect(throws: DPIReadError.self) { try stale.validateConsistency() } // baseline differs from preview
    }

    @Test func readOutcomeIsRederivedFromRawExchange() throws {
        var o = ReportRateReadOutcome(registryID: "1000ab9c7")
        o.exchange = exchange("readRate", MT760ReportRateCommand.read, response(block1000))
        o.snapshot = try ReportRateSnapshot.decode(response(block1000))
        try o.validateConsistency()
        var forged = o; forged.exchange?.response[4] = 0x08 // raw says 125 Hz, snapshot says 1000
        #expect(throws: DPIReadError.self) { try forged.validateConsistency() }
        var staleOnFailure = o; staleOnFailure.error = "x"
        #expect(throws: DPIReadError.self) { try staleOnFailure.validateConsistency() }
        var wrongRequest = o; wrongRequest.exchange = exchange("readRate", MT760DPICommand.readConfig, response(block1000))
        #expect(throws: DPIReadError.self) { try wrongRequest.validateConsistency() }
    }

    @Test func snapshotJSONMustMatchRawBlock() throws {
        let json = #"{"block":[1,1,0,0,0,0,0,0],"wiredHz":125,"wirelessCode":1,"wirelessHz":1000}"#
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ReportRateSnapshot.self, from: Data(json.utf8)) }
    }

    @Test func missingHelperNeverFallsBack() async {
        do {
            _ = try await ReportRateClient.write(helperURL: URL(fileURLWithPath: "/nonexistent/mt760-read-helper"),
                                                 registryID: "1000ab9c7", targetHz: 500, expectedBaseline: block1000)
            Issue.record("Expected missing helper error")
        } catch { #expect(error.localizedDescription.lowercased().contains(L("辅助程序", "helper not found"))) }
        do {
            _ = try await ReportRateClient.read(helperURL: URL(fileURLWithPath: "/bin/echo"), registryID: "not-an-id")
            Issue.record("Expected invalid ID error")
        } catch { #expect(error.localizedDescription.contains("Registry ID")) }
    }
}
