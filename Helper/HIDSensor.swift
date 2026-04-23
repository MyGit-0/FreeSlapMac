import Foundation
import IOKit
import IOKit.hid

/// Reads the Apple Silicon IMU accelerometer over IOKit HID.
///
/// Probe on this machine showed:
///   VID=0x05AC PID=0x8104 page=0xFF00 usage=0x0003  (Apple SPU accelerometer)
///   VID=0x05AC PID=0x8104 page=0x0020 usage=0x008A  (sensor-page motion/orientation device)
public final class HIDSensor {
    public typealias SampleHandler = (_ x: Double, _ y: Double, _ z: Double, _ tsNs: UInt64) -> Void

    private var manager: IOHIDManager?
    private let onSample: SampleHandler
    private let log: FSLog
    private(set) var running = false
    private var sampleCount = 0
    private var callbackCount = 0
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []

    private static let accelScalePerG: Double = 65536.0
    private var lastAxes: (x: Double?, y: Double?, z: Double?) = (nil, nil, nil)

    public init(log: FSLog, onSample: @escaping SampleHandler) {
        self.log = log
        self.onSample = onSample
    }

    deinit { stop() }

    public func start() throws {
        guard !running else { return }
        sampleCount = 0
        callbackCount = 0
        lastAxes = (nil, nil, nil)

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = mgr
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var lastOpenError: IOReturn = kIOReturnSuccess

        // Strategy 1: exact Apple SPU accelerometer (BMI286 IMU).
        let accelMatching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDProductIDKey as String: 0x8104,
            kIOHIDPrimaryUsagePageKey as String: 0xFF00,
            kIOHIDPrimaryUsageKey as String: 0x03,
        ]
        IOHIDManagerSetDeviceMatching(mgr, accelMatching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        var rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        lastOpenError = rc
        log.info("strategy 1 open (SPU accelerometer) returned 0x\(String(rc, radix: 16))")

        if let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devices.isEmpty {
            log.info("strategy 1: found \(devices.count) SPU accelerometer device(s)")
            logDevices(devices)
            registerSPUCallbacks(devices, context: ctx)
            running = true
            return
        }

        // Strategy 2: sensor-page motion device fallback.
        log.warn("strategy 1 empty; trying exact sensor-page motion device")
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let exactSensorMatching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_Sensor,
            kIOHIDPrimaryUsageKey as String: 0x008A,
        ]
        IOHIDManagerSetDeviceMatching(mgr, exactSensorMatching as CFDictionary)
        rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        lastOpenError = rc
        log.info("strategy 2 open (exact sensor-page) returned 0x\(String(rc, radix: 16))")
        if let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devices.isEmpty {
            log.info("strategy 2: found \(devices.count) exact sensor-page device(s)")
            logDevices(devices)
            logElements(devices)
            IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
                guard let ctx else { return }
                Unmanaged<HIDSensor>.fromOpaque(ctx).takeUnretainedValue().handleValue(value)
            }, ctx)
            running = true
            return
        }

        // Strategy 3: broader Apple sensor-page fallback for models that expose
        // the accelerometer under a different primary usage.
        log.warn("strategy 2 empty; trying broader Apple sensor-page match")
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        let broadSensorMatching: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x05AC,
            kIOHIDPrimaryUsagePageKey as String: kHIDPage_Sensor,
        ]
        IOHIDManagerSetDeviceMatching(mgr, broadSensorMatching as CFDictionary)
        rc = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        lastOpenError = rc
        log.info("strategy 3 open (broad sensor-page) returned 0x\(String(rc, radix: 16))")
        if let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>, !devices.isEmpty {
            log.info("strategy 3: found \(devices.count) broad sensor-page device(s)")
            logDevices(devices)
            logElements(devices)
            IOHIDManagerRegisterInputValueCallback(mgr, { ctx, _, _, value in
                guard let ctx else { return }
                Unmanaged<HIDSensor>.fromOpaque(ctx).takeUnretainedValue().handleValue(value)
            }, ctx)
            running = true
            return
        }

        log.error("no accelerometer found — neither sensor-page nor SPU device matched")
        manager = nil
        if lastOpenError != kIOReturnSuccess {
            throw HIDSensorError.openFailed(lastOpenError)
        }
        throw HIDSensorError.noSensorFound
    }

    public func stop() {
        guard running, let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        for buf in reportBuffers { buf.deallocate() }
        reportBuffers.removeAll()
        manager = nil
        running = false
        log.info("sensor stopped after \(sampleCount) samples")
    }

    // MARK: - Strategy 1: element value callback

    private func handleValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let elementUsage = IOHIDElementGetUsage(element)

        callbackCount += 1
        if callbackCount <= 5 {
            log.debug("handleValue called: page=0x\(String(usagePage, radix: 16)) usage=0x\(String(elementUsage, radix: 16))")
        }

        guard usagePage == UInt32(kHIDPage_Sensor) else { return }
        let usage = Int(elementUsage)
        let raw = Double(IOHIDValueGetIntegerValue(value))
        let logMin = Double(IOHIDElementGetLogicalMin(element))
        let logMax = Double(IOHIDElementGetLogicalMax(element))
        let phyMin = Double(IOHIDElementGetPhysicalMin(element))
        let phyMax = Double(IOHIDElementGetPhysicalMax(element))

        let g: Double
        if logMax > logMin, (phyMax != 0 || phyMin != 0) {
            g = phyMin + (raw - logMin) / (logMax - logMin) * (phyMax - phyMin)
        } else {
            g = raw / 1000.0
        }

        switch usage {
        case kHIDUsage_Snsr_Data_Motion_AccelerationAxisX, 0x0303: lastAxes.x = g
        case kHIDUsage_Snsr_Data_Motion_AccelerationAxisY, 0x0304, 0x0307: lastAxes.y = g
        case kHIDUsage_Snsr_Data_Motion_AccelerationAxisZ, 0x0305: lastAxes.z = g
        default: return
        }

        if let x = lastAxes.x, let y = lastAxes.y, let z = lastAxes.z {
            sampleCount += 1
            if sampleCount == 1 || sampleCount % 500 == 0 {
                log.debug("sample #\(sampleCount) x=\(x) y=\(y) z=\(z)")
            }
            onSample(x, y, z, DispatchTime.now().uptimeNanoseconds)
            lastAxes = (nil, nil, nil)
        }
    }

    // MARK: - Strategy 1: raw SPU 22-byte reports

    private func handleSPUReport(_ report: UnsafePointer<UInt8>, length: CFIndex) {
        guard length >= 18 else { return }
        let scale = Self.accelScalePerG
        let x = Double(int32LE(report, 6)) / scale
        let y = Double(int32LE(report, 10)) / scale
        let z = Double(int32LE(report, 14)) / scale
        sampleCount += 1
        if sampleCount == 1 || sampleCount % 500 == 0 {
            log.debug("SPU sample #\(sampleCount) x=\(x) y=\(y) z=\(z)")
        }
        onSample(x, y, z, DispatchTime.now().uptimeNanoseconds)
    }

    private func int32LE(_ p: UnsafePointer<UInt8>, _ offset: Int) -> Int32 {
        Int32(bitPattern:
            UInt32(p[offset]) |
            (UInt32(p[offset + 1]) << 8) |
            (UInt32(p[offset + 2]) << 16) |
            (UInt32(p[offset + 3]) << 24)
        )
    }

    private func registerSPUCallbacks(_ devices: Set<IOHIDDevice>, context ctx: UnsafeMutableRawPointer) {
        for d in devices {
            let reportSize = max(
                64,
                IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 64
            )
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: reportSize)
            reportBuffers.append(buf)
            IOHIDDeviceRegisterInputReportCallback(d, buf, reportSize, { ctx, _, _, _, _, report, length in
                guard let ctx else { return }
                Unmanaged<HIDSensor>.fromOpaque(ctx).takeUnretainedValue()
                    .handleSPUReport(report, length: length)
            }, ctx)
        }
    }

    private func logDevices(_ devices: Set<IOHIDDevice>) {
        for d in devices {
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
            let vid = IOHIDDeviceGetProperty(d, kIOHIDVendorIDKey as CFString) as? Int ?? 0
            let pid = IOHIDDeviceGetProperty(d, kIOHIDProductIDKey as CFString) as? Int ?? 0
            let page = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(d, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
            let reportSize = IOHIDDeviceGetProperty(d, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            log.info(String(
                format: "device=\"%@\" vid=0x%04X pid=0x%04X page=0x%04X usage=0x%04X report=%d",
                name, vid, pid, page, usage, reportSize
            ))
        }
    }

    private func logElements(_ devices: Set<IOHIDDevice>) {
        for d in devices {
            let name = IOHIDDeviceGetProperty(d, kIOHIDProductKey as CFString) as? String ?? "?"
            guard let elems = IOHIDDeviceCopyMatchingElements(d, nil, 0) as? [IOHIDElement] else { continue }
            let sensorElems = elems.filter { IOHIDElementGetUsagePage($0) == UInt32(kHIDPage_Sensor) }
            log.info("device=\"\(name)\" sensor-page elements=\(sensorElems.count)")
            for e in sensorElems.prefix(20) {
                let u = IOHIDElementGetUsage(e)
                log.info(String(format: "  elem usage=0x%04X type=%d", u, IOHIDElementGetType(e).rawValue))
            }
        }
    }
}

public enum HIDSensorError: Error {
    case openFailed(IOReturn)
    case noSensorFound
}
