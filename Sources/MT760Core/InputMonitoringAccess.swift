import Foundation
import IOKit
import IOKit.hidsystem

/// macOS "Input Monitoring" (TCC ListenEvent) gate for IOHIDDeviceOpen.
///
/// MT760 interface 1 has primary usage 0001/0006 (keyboard), so opening it requires this
/// permission; without it IOHIDDeviceOpen returns kIOReturnNotPermitted (0xE00002E2).
/// The helper is launched by the App, so TCC attributes access to the App bundle.
/// Ad-hoc signatures change on every rebuild; macOS may then require re-granting.
public enum InputMonitoringAccess {
    public enum Status: String, Codable {
        case granted, denied, unknown
    }

    public static var status: Status {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .unknown
        }
    }

    /// Shows the system prompt when the state is undetermined; otherwise returns the current answer.
    /// May block briefly, so call off the main thread.
    @discardableResult
    public static func request() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!

    public static let notPermitted: Int32 = Int32(bitPattern: 0xE00002E2)
}
