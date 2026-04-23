// Diagnostic tool — dump HID devices and highlight the SPU accelerometer / gyro.
// Build:  swiftc -framework IOKit -framework Foundation Tools/hid_probe.swift -o build/hid_probe
// Run:    ./build/hid_probe
import Foundation
import IOKit
import IOKit.hid

let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(mgr, nil) // match everything
IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))

guard let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else {
    print("No devices found")
    exit(1)
}

print("=== All HID Devices (\(devices.count)) ===\n")
let sorted = devices.sorted {
    let v0 = IOHIDDeviceGetProperty($0, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let v1 = IOHIDDeviceGetProperty($1, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    return v0 < v1
}

for d in sorted {
    let name    = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
    let vid     = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let pid     = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let page    = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
    let usage   = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
    let pairs   = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString)
    print(String(format: "  VID=0x%04X PID=0x%04X  page=0x%04X usage=0x%04X  name=\(name)", vid, pid, page, usage))
    if let pairs = pairs as? [[String:Any]] {
        for pair in pairs {
            let pp = pair[kIOHIDDeviceUsagePageKey as String] as? Int ?? -1
            let pu = pair[kIOHIDDeviceUsageKey as String] as? Int ?? -1
            print(String(format: "      -> usagePair page=0x%04X usage=0x%04X", pp, pu))
        }
    }
}

// Highlight likely motion-related devices.
print("\n=== Potential Motion Sensors (SPU accel/gyro or sensor-page motion) ===\n")
for d in sorted {
    let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? ""
    let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
    let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
    let reportSize = IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
    let transport = IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String ?? ""
    let usagePairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String:Any]] ?? []
    let isAppleSPU = transport == "SPU"
    let hasSensorPage = page == 0x20 || usagePairs.contains {
        ($0[kIOHIDDeviceUsagePageKey as String] as? Int ?? 0) == 0x20
    }
    let hasSPUAccel = isAppleSPU && ((page == 0xFF00 && usage == 0x03) || usagePairs.contains {
        ($0[kIOHIDDeviceUsagePageKey as String] as? Int ?? 0) == 0xFF00 &&
        ($0[kIOHIDDeviceUsageKey as String] as? Int ?? 0) == 0x03
    })
    let hasSPUGyro = isAppleSPU && ((page == 0xFF00 && usage == 0x09) || usagePairs.contains {
        ($0[kIOHIDDeviceUsagePageKey as String] as? Int ?? 0) == 0xFF00 &&
        ($0[kIOHIDDeviceUsageKey as String] as? Int ?? 0) == 0x09
    })
    let nameHit = name.localizedCaseInsensitiveContains("motion") ||
                  name.localizedCaseInsensitiveContains("accel") ||
                  name.localizedCaseInsensitiveContains("imu") ||
                  name.localizedCaseInsensitiveContains("spu") ||
                  name.localizedCaseInsensitiveContains("sensor")
    guard hasSensorPage || hasSPUAccel || hasSPUGyro || nameHit else { continue }
    let vid = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
    let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
    let label: String
    if hasSPUAccel {
        label = "SPU accelerometer"
    } else if hasSPUGyro {
        label = "SPU gyroscope"
    } else if hasSensorPage {
        label = "sensor-page motion/orientation"
    } else {
        label = "name match"
    }
    print(String(format: "  *** [%@] VID=0x%04X PID=0x%04X page=0x%04X usage=0x%04X report=%d name=%@",
                 label, vid, pid, page, usage, reportSize, name))
}
