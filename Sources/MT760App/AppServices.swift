import Foundation
import MT760Core

/// The App's external dependencies. Tests replace every entry, so queue regressions never
/// enumerate HID, request permission, or launch a hardware helper.
@MainActor
struct AppServices {
    var scan: () async -> [DeviceInfo]
    var inputAccess: () -> InputMonitoringAccess.Status
    var requestInputAccess: () async -> Void
    var helperURL: () -> URL?
    var now: () -> Date
    var readDPI: (URL, String) async throws -> DPIReadOutcome
    var readRate: (URL, String) async throws -> ReportRateReadOutcome
    var readKeys: (URL, String) async throws -> KeyMappingReadOutcome
    var writeDPI: (URL, String, Int, [UInt8]) async throws -> DPIWriteOutcome
    var switchGear: (URL, String, Int, [UInt8]) async throws -> DPIGearSwitchOutcome
    var writeRate: (URL, String, Int, [UInt8]) async throws -> ReportRateWriteOutcome
    var writeKey: (URL, String, Int, KeyFunction, KeyMappingSnapshot) async throws -> KeyWriteOutcome

    static var live: Self {
        Self(
            scan: { await Task.detached(priority: .utility) { HIDEnumerator.scan() }.value },
            inputAccess: { InputMonitoringAccess.status },
            requestInputAccess: {
                _ = await Task.detached(priority: .userInitiated) { InputMonitoringAccess.request() }.value
            },
            helperURL: {
                guard let url = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("mt760-read-helper"),
                      FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
                return url
            },
            now: { Date() },
            readDPI: { try await DPIReadClient.read(helperURL: $0, registryID: $1) },
            readRate: { try await ReportRateClient.read(helperURL: $0, registryID: $1) },
            readKeys: { try await KeyMappingClient.read(helperURL: $0, registryID: $1) },
            writeDPI: { try await DPIWriteClient.write(helperURL: $0, registryID: $1, targetDPI: $2, expectedBaseline: $3) },
            switchGear: { try await DPIGearClient.switchGear(helperURL: $0, registryID: $1, targetGear: $2, expectedBaseline: $3) },
            writeRate: { try await ReportRateClient.write(helperURL: $0, registryID: $1, targetHz: $2, expectedBaseline: $3) },
            writeKey: { try await KeyMappingClient.write(helperURL: $0, registryID: $1, keyID: $2, function: $3, baseline: $4) }
        )
    }
}
