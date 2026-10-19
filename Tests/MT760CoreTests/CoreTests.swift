import Foundation
import Testing
@testable import MT760Core

struct CoreTests {
    @Test func numberedReportsAndPadding() throws {
        let parsed = DescriptorSummary.parse([
            0x06, 0x0B, 0xFF, 0x09, 0x04, 0xA1, 0x01,
            0x85, 0x05, 0x75, 0x08, 0x95, 0x3F, 0x91, 0x02,
            0x85, 0x02, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
            0x95, 0x05, 0x81, 0x03, 0xC0
        ])
        #expect(parsed.warnings.isEmpty)
        let output = try #require(parsed.reports.first { $0.kind == .output })
        #expect(output.reportID == 5)
        #expect(output.payloadBytes == 63)
        #expect(output.wireBytes == 64)
        let input = try #require(parsed.reports.first { $0.kind == .input })
        #expect(input.bitCount == 8) // Includes constant padding fields.
        #expect(input.wireBytes == 2)
    }

    @Test func unnumberedFeatureAndRounding() throws {
        let parsed = DescriptorSummary.parse([0x75, 0x01, 0x95, 0x09, 0xB1, 0x02])
        let feature = try #require(parsed.reports.first)
        #expect(feature.kind == .feature)
        #expect(feature.payloadBytes == 2)
        #expect(feature.wireBytes == 2)
    }

    @Test func pushPopRestoresAllGlobals() {
        let parsed = DescriptorSummary.parse([
            0x85, 0x05, 0x75, 0x08, 0x95, 0x02,
            0xA4, 0x85, 0x06, 0x95, 0x03, 0x91, 0x02,
            0xB4, 0x91, 0x02
        ])
        #expect(parsed.warnings.isEmpty)
        #expect(parsed.reports.map(\.reportID) == [5, 6])
        #expect(parsed.reports.map(\.payloadBytes) == [2, 3])
    }

    @Test func fourByteCountAndFeatureBoundary() {
        let parsed = DescriptorSummary.parse([0x85, 1, 0x75, 8, 0x97, 248, 0, 0, 0, 0xB1, 2])
        #expect(parsed.reports.first?.wireBytes == 249)
        #expect(parsed.warnings.isEmpty)
    }

    @Test func malformedDescriptorsAreDiagnosed() {
        let samples: [[UInt8]] = [[], [0xFE], [0xFE, 2, 1, 0], [0x77, 1], [0xB4],
                                 [0x85, 0], [0x86, 0, 1], [0xA4], [0xA1, 1], [0xC0],
                                 [0x75, 0, 0x95, 1, 0x81, 2],
                                 [0x77, 255, 255, 255, 255, 0x97, 255, 255, 255, 255, 0x81, 2]]
        for bytes in samples { #expect(!DescriptorSummary.parse(bytes).warnings.isEmpty) }
    }

    @Test func oversizedFieldsInvalidatePartialLengths() {
        let parsed = DescriptorSummary.parse([
            0x75, 8, 0x95, 1, 0x81, 2,
            0x77, 255, 255, 255, 255, 0x81, 2
        ])
        #expect(parsed.reports.first?.payloadBytes == 1) // Partial sum, never a reliable length.
        #expect(!parsed.lengthsAreReliable)
        #expect(!parsed.warnings.isEmpty)
        #expect(DescriptorSummary.parse([0x75, 8, 0x95, 1, 0x81, 2]).lengthsAreReliable)
    }

    @Test func longItemsSkippedAndMixedIDsWarned() {
        let parsed = DescriptorSummary.parse([0xFE, 1, 0, 0xFF, 0x75, 8, 0x95, 1, 0x81, 2, 0x85, 1, 0x91, 2])
        #expect(parsed.reports.count == 2)
        #expect(parsed.warnings.count == 2)
    }

    @Test func candidatePolicyDoesNotTrustBluetoothOrStandardMouse() {
        #expect(!device(transport: "Bluetooth Low Energy", page: 0xFF0B).isVendorCandidate)
        #expect(!device(page: 1).isVendorCandidate)
        #expect(!device(vendor: 0x1234).isVendorCandidate)
        #expect(device().isVendorCandidate)
        #expect(device().matchesDocumentHint)
        #expect(device(page: 0xFF01).isVendorCandidate)
        #expect(!device(page: 0xFF01).matchesDocumentHint)
        #expect(device(page: 1, usages: [.init(page: 0xFF0B, usage: 0x0104)]).matchesDocumentHint)
        #expect(!device(page: 0x10000).isVendorCandidate)
    }

    @Test func snapshotRoundTripAndPrivacy() throws {
        let snapshot = DiagnosticSnapshot(devices: [device()])
        let data = try snapshot.encoded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticSnapshot.self, from: data)
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.devices == snapshot.devices)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let devices = try #require(json["devices"] as? [[String: Any]])
        #expect(devices[0]["serialNumber"] == nil)
        #expect(devices[0]["address"] == nil)
        #expect(decoded.mode == snapshot.mode)
    }

    @Test func parserHandlesDeterministicNoise() {
        var state: UInt64 = 1234
        for count in 0..<512 {
            let bytes = (0..<count).map { _ -> UInt8 in
                state = state &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: state >> 32)
            }
            let parsed = DescriptorSummary.parse(bytes)
            #expect(parsed.reports.allSatisfy { $0.payloadBytes <= 1_048_576 })
        }
    }

    private func device(transport: String = "USB", vendor: UInt32 = 0x24AE,
                        page: UInt32 = 0xFF0B, usages: [UsagePair] = []) -> DeviceInfo {
        DeviceInfo(id: "test", product: "Test fixture, not real hardware", vendorID: vendor,
                   productID: 0x1234, transport: transport,
                   primaryUsage: .init(page: page, usage: 0x0104), usages: usages,
                   maxInputBytes: 64, maxOutputBytes: 64, maxFeatureBytes: 249,
                   descriptor: [], summary: .parse([]))
    }
}
