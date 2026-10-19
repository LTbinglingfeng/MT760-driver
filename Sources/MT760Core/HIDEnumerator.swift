import Foundation
import IOKit
import IOKit.hid

/// Enumeration only. No IOHIDDeviceOpen, GetReport, SetReport, or input callbacks.
/// A fresh manager per scan makes device removal observable without retaining stale devices.
public enum HIDEnumerator {
    public static func scan() -> [DeviceInfo] {
        devices().map(describe).sorted { $0.id < $1.id }
    }

    static func devices() -> Set<IOHIDDevice> {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x24AE] as CFDictionary)
        return IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
    }

    static func describe(_ device: IOHIDDevice) -> DeviceInfo {
        func property(_ key: String) -> AnyObject? { IOHIDDeviceGetProperty(device, key as CFString) }
        func number(_ key: String) -> UInt32 { (property(key) as? NSNumber)?.uint32Value ?? 0 }
        func text(_ key: String) -> String { property(key) as? String ?? L("未知", "Unknown") }
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &registryID)
        let primary = UsagePair(page: number(kIOHIDPrimaryUsagePageKey), usage: number(kIOHIDPrimaryUsageKey))
        let pairs = (property(kIOHIDDeviceUsagePairsKey) as? [[String: Any]] ?? []).map {
            UsagePair(page: ($0[kIOHIDDeviceUsagePageKey] as? NSNumber)?.uint32Value ?? 0,
                      usage: ($0[kIOHIDDeviceUsageKey] as? NSNumber)?.uint32Value ?? 0)
        }
        let descriptor = [UInt8](property(kIOHIDReportDescriptorKey) as? Data ?? Data())
        return DeviceInfo(
            id: String(registryID, radix: 16), product: text(kIOHIDProductKey),
            vendorID: number(kIOHIDVendorIDKey), productID: number(kIOHIDProductIDKey),
            transport: text(kIOHIDTransportKey), primaryUsage: primary, usages: pairs,
            maxInputBytes: Int(number(kIOHIDMaxInputReportSizeKey)),
            maxOutputBytes: Int(number(kIOHIDMaxOutputReportSizeKey)),
            maxFeatureBytes: Int(number(kIOHIDMaxFeatureReportSizeKey)),
            descriptor: descriptor, summary: .parse(descriptor),
            usbInterfaceNumber: interfaceNumber(service: IOHIDDeviceGetService(device))
        )
    }

    private static func interfaceNumber(service: io_service_t) -> Int? {
        guard service != 0, IOObjectRetain(service) == KERN_SUCCESS else { return nil }
        var current = service
        defer { IOObjectRelease(current) }
        for _ in 0..<24 {
            if IOObjectConformsTo(current, "IOUSBHostInterface") != 0,
               let value = IORegistryEntryCreateCFProperty(current, "bInterfaceNumber" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber {
                return value.intValue
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }
}
