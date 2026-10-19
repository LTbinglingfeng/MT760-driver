import Foundation
import Testing
@testable import MT760Core

struct DPIReadTests {
    struct Fixture: Decodable {
        let request: [UInt8]; let response: [UInt8]; let levels: [Int]
        let activeCount: Int; let currentGear: Int
    }
    func fixture() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "mt760-warm-read", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test func observedWarmReadDecodesWithoutStrippingID() throws {
        let f = try fixture()
        #expect(f.request == MT760WarmRead.request)
        let result = try DPISnapshot.decode(f.response)
        #expect(result.levels == f.levels) // Duplicates and non-sorted levels are valid.
        #expect(result.activeCount == f.activeCount)
        #expect(result.currentGear == f.currentGear)
        #expect(result.currentDPI == 4000)
    }

    @Test func rejectsOtherLengthsAndLeadingReportID() throws {
        let f = try fixture()
        for count in 0..<28 {
            #expect(throws: DPIReadError.self) { try DPISnapshot.decode(Array(f.response.prefix(count))) }
        }
        #expect(throws: DPIReadError.self) { try DPISnapshot.decode([0xBA] + f.response) }
        #expect(throws: DPIReadError.self) { try DPISnapshot.decode(f.response + [0,0,0,0]) }
    }

    @Test func rejectsBusyUnknownStatusAndBadGears() throws {
        let f = try fixture()
        for (index, value): (Int, UInt8) in [(0,0), (0,2), (0,0xBA), (18,7), (20,7), (20,255)] {
            var bytes = f.response; bytes[index] = value
            #expect(throws: DPIReadError.self) { try DPISnapshot.decode(bytes) }
        }
    }

    @Test func validatesActiveDPIAndPreservesUnknownBytes() throws {
        let f = try fixture()
        for units: UInt16 in [0,81,0xFFFF] {
            var bytes = f.response; bytes[4] = UInt8(truncatingIfNeeded: units); bytes[5] = UInt8(units >> 8)
            #expect(throws: DPIReadError.self) { try DPISnapshot.decode(bytes) }
        }
        var bytes = f.response
        bytes[19] = 0xFF; bytes[27] = 0x42
        #expect(try DPISnapshot.decode(bytes).levels == f.levels) // Unknown bytes are not reinterpreted.
        bytes[18] = 0; bytes[20] = 0; bytes[6] = 0
        #expect(try DPISnapshot.decode(bytes).activeCount == 1) // Inactive slots are retained, not normalized.
    }

    @Test func rejectsInvalidCodableModel() throws {
        let data = Data("{\"levels\":[800],\"activeCount\":7,\"currentGear\":0}".utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DPISnapshot.self, from: data) }
    }

    @Test func warmReadInterfacePolicyIsNarrow() {
        func device(pid: UInt32 = 0x4500, transport: String = "USB", iface: Int? = 1,
                    usage: UsagePair = .init(page: 1, usage: 6), reportID: UInt8 = 0xBA) -> DeviceInfo {
            let descriptor: [UInt8] = [0x85,reportID,0x75,8,0x95,31,0x81,2,0x91,2]
            return DeviceInfo(id: "fixture", product: "test", vendorID: 0x24AE, productID: pid,
                transport: transport, primaryUsage: usage, usages: [.init(page: 0xFF00, usage: 14)],
                maxInputBytes: 32, maxOutputBytes: 32, maxFeatureBytes: 0,
                descriptor: descriptor, summary: .parse(descriptor), usbInterfaceNumber: iface)
        }
        #expect(device().canAttemptDPIRead)
        #expect(!device(pid: 0x1870).canAttemptDPIRead)
        #expect(!device(transport: "Bluetooth Low Energy").canAttemptDPIRead)
        #expect(!device(iface: nil).canAttemptDPIRead)
        #expect(!device(iface: 2).canAttemptDPIRead)
        #expect(!device(usage: .init(page: 0xFFEF, usage: 0)).canAttemptDPIRead)
        #expect(!device(reportID: 5).canAttemptDPIRead)
    }

    @Test func outcomeRoundTripRetainsRawResponse() throws {
        let f = try fixture()
        var outcome = DPIReadOutcome(registryID: "fixture")
        outcome.response = f.response
        outcome.snapshot = try DPISnapshot.decode(f.response)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(DPIReadOutcome.self, from: outcome.encoded())
        #expect(copy.snapshot == outcome.snapshot)
        #expect(copy.response == f.response)
        #expect(!copy.configurationWritten && !copy.coldStartVerified)
    }
}
