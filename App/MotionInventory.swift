import Foundation
import IOKit
import IOKit.hid

struct MotionDeviceInfo: Identifiable {
    let id = UUID()
    let name: String
    let vendorID: Int
    let productID: Int
    let usagePage: Int
    let usage: Int
    let transport: String
    let maxInputReportSize: Int
    let kind: String
}

enum MotionInventory {
    static func scan() -> [MotionDeviceInfo] {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, nil)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
            return []
        }

        return devices.compactMap { device in
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
            let reportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0

            let kind: String?
            if transport == "SPU", usagePage == 0xFF00, usage == 0x03 {
                kind = "SPU accelerometer"
            } else if transport == "SPU", usagePage == 0xFF00, usage == 0x09 {
                kind = "SPU gyroscope"
            } else if usagePage == 0x20, usage == 0x008A {
                kind = "Sensor-page motion/orientation"
            } else {
                kind = nil
            }

            guard let kind else { return nil }
            return MotionDeviceInfo(
                name: name,
                vendorID: vendorID,
                productID: productID,
                usagePage: usagePage,
                usage: usage,
                transport: transport,
                maxInputReportSize: reportSize,
                kind: kind
            )
        }
        .sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.usage < rhs.usage
        }
    }
}
