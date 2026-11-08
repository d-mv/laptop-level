import Foundation
import IOKit
import IOKit.hid

enum SensorError: Error {
    case unavailable        // exit 2: no usable sensor
    case timeout            // exit 3: present but no stable reading in time
}

struct Tilt {
    let pitch: Double       // degrees, B/F: + = back edge lower (offset NOT yet removed)
    let roll: Double        // degrees, L/R: + = right edge lower
}

/// A live handle on the Apple Silicon SPU accelerometer.
///
/// Reads the raw HID input reports of the SPU accel device (usage page 0xFF00,
/// usage 3, transport "SPU") through the public IOHIDManager API. Each 22-byte
/// report carries x/y/z as little-endian Int32 at offsets 6/10/14, in units of
/// 1/65536 g, at ~100 Hz. Reports are delivered on the current run loop, which
/// `currentTilt()` pumps — so use one instance from one thread.
final class MotionSensor {
    static let settleMs = 300
    static let timeoutMs = 2000

    private let manager: IOHIDManager
    private let buffer: UnsafeMutablePointer<UInt8>
    private var latest: Tilt?
    private var sampleCount = 0

    init() throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDPrimaryUsagePageKey: 0xFF00,
            kIOHIDPrimaryUsageKey: 3,
            kIOHIDTransportKey: "SPU",
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first
        else { throw SensorError.unavailable }

        self.manager = manager
        self.buffer = .allocate(capacity: Self.reportSize)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.reportSize, { ctx, _, _, _, _, report, length in
            guard let ctx else { return }
            let sensor = Unmanaged<MotionSensor>.fromOpaque(ctx).takeUnretainedValue()
            sensor.receive(UnsafeBufferPointer(start: report, count: length))
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // The stream normally runs once the device is open. If it stays silent,
        // ask the driver to power up and report, then wait once more.
        if !waitForSample(after: 0, seconds: 0.3) {
            Self.enableDriverReporting()
            _ = waitForSample(after: 0, seconds: 0.5)
        }
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    private func receive(_ report: UnsafeBufferPointer<UInt8>) {
        guard let g = Self.gravity(fromReport: report),
              let t = Self.tilt(x: g.x, y: g.y, z: g.z) else { return }
        latest = t
        sampleCount += 1
    }

    /// Pump the run loop until a report newer than `count` arrives.
    private func waitForSample(after count: Int, seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while sampleCount <= count && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        return sampleCount > count
    }

    /// Freshest sample: drain queued reports, then wait for one more so the
    /// value is current. Nil if the sensor stopped answering.
    func currentTilt() -> Tilt? {
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        return waitForSample(after: sampleCount, seconds: 0.25) ? latest : nil
    }

    // MARK: - Pure helpers (tested)

    static let reportSize = 22

    /// Raw accel report → gravity in g, or nil if it's too short.
    static func gravity(fromReport r: UnsafeBufferPointer<UInt8>) -> (x: Double, y: Double, z: Double)? {
        guard r.count >= 18 else { return nil }
        func int32(_ o: Int) -> Double {
            Double(Int32(bitPattern: UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24))
        }
        return (int32(6) / 65536, int32(10) / 65536, int32(14) / 65536)
    }

    /// Gravity vector → tilt (degrees). The sensor lies flat in the base, so a
    /// level laptop reads g ≈ (0, 0, -1). Each angle is measured against the
    /// other two components, so it stays accurate for tilt on both axes.
    /// Returns nil for a non-finite or zero vector, so NaN never reaches output.
    static func tilt(x: Double, y: Double, z: Double) -> Tilt? {
        guard x.isFinite, y.isFinite, z.isFinite, x != 0 || y != 0 || z != 0 else { return nil }
        let roll = atan2(x, hypot(y, z)) * 180.0 / .pi
        let pitch = atan2(y, hypot(x, z)) * 180.0 / .pi
        return Tilt(pitch: pitch, roll: roll)
    }

    /// Fallback: ask the SPU accel driver to power up and stream.
    private static func enableDriverReporting() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator)
                == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let usage = IORegistryEntryCreateCFProperty(entry, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            guard usage == 3 else { continue }
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 10_000)] {
                IORegistryEntrySetCFProperty(entry, key as CFString, value as CFNumber)
            }
        }
    }

    /// Single-shot: discard warm-up samples, then require two consecutive close
    /// readings before reporting. Throws `.timeout` if none stabilize in time.
    static func read(settleMs: Int = MotionSensor.settleMs, timeoutMs: Int = MotionSensor.timeoutMs) throws -> Tilt {
        let sensor = try MotionSensor()
        let start = Date()
        let settleUntil = start.addingTimeInterval(Double(settleMs) / 1000.0)
        let deadline = start.addingTimeInterval(Double(timeoutMs) / 1000.0)
        var last: Tilt?
        while Date() < deadline {
            if let t = sensor.currentTilt() {
                if Date() >= settleUntil, let prev = last,
                   abs(prev.pitch - t.pitch) < 0.5, abs(prev.roll - t.roll) < 0.5 {
                    return t
                }
                last = t
            }
            usleep(50_000)
        }
        throw SensorError.timeout
    }
}
