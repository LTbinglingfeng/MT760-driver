import Foundation
import Testing
@testable import MT760Core

/// These tests spawn only system echo/sleep/false utilities, never the HID helper.
struct HelperProcessTests {
    @Test func successfulSubprocessIsCollected() async throws {
        let result = try await BoundedHelperProcess.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["fixture-only"], timeout: 2)
        #expect(result.status == 0)
        #expect(String(data: result.data, encoding: .utf8) == "fixture-only\n")
    }

    @Test func nonzeroExitIsNotHidden() async throws {
        let result = try await BoundedHelperProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [], timeout: 2)
        #expect(result.status != 0)
    }

    @Test func hangingSubprocessTimesOut() async {
        let start = Date()
        do {
            _ = try await BoundedHelperProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
            Issue.record("Expected timeout")
        } catch {
            #expect(Date().timeIntervalSince(start) < 3)
        }
    }

    @Test func missingHelperNeverFallsBackToHardware() async {
        do {
            _ = try await DPIReadClient.read(helperURL: URL(fileURLWithPath: "/nonexistent/mt760-read-helper"), registryID: "1000ab9c7")
            Issue.record("Expected missing helper error")
        } catch { #expect(error.localizedDescription.lowercased().contains(L("辅助程序", "helper not found"))) }
    }

    @Test func invalidIDRejectedBeforeLaunch() async {
        do {
            _ = try await DPIReadClient.read(helperURL: URL(fileURLWithPath: "/bin/echo"), registryID: "not-an-id")
            Issue.record("Expected ID rejection")
        } catch { #expect(error.localizedDescription.contains("Registry ID")) }
    }
}
