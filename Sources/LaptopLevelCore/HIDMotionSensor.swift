import Foundation
import IOKit
import IOKit.hid

enum SensorError: Error {
    case unavailable  // no usable SPU accel device
}

struct Tilt: Equatable {
    let pitch: Double  // degrees, B/F: + = back edge lower (offset NOT yet removed)
    let roll: Double  // degrees, L/R: + = right edge lower
}

typealias Gravity = (x: Double, y: Double, z: Double)

// MARK: - Pure math (no hardware)

enum Accel {
    static let reportSize = 22
    static let windowSize = 25  // reports averaged per reading (~250 ms)

    /// Raw accel report → gravity in g, or nil if it's too short.
    /// x/y/z are little-endian Int32 at offsets 6/10/14, in 1/65536 g.
    static func gravity(fromReport r: UnsafeBufferPointer<UInt8>) -> Gravity? {
        guard r.count >= 18 else { return nil }
        func int32(_ o: Int) -> Double {
            let bits = UInt32(r[o]) | UInt32(r[o + 1]) << 8 | UInt32(r[o + 2]) << 16 | UInt32(r[o + 3]) << 24
            return Double(Int32(bitPattern: bits))
        }
        return (int32(6) / 65536, int32(10) / 65536, int32(14) / 65536)
    }

    /// Mean gravity vector. Averaging vectors (not angles) stays correct at
    /// any tilt.
    static func average(_ samples: [Gravity]) -> Gravity? {
        guard !samples.isEmpty else { return nil }
        let n = Double(samples.count)
        let sum = samples.reduce((x: 0.0, y: 0.0, z: 0.0)) { (x: $0.x + $1.x, y: $0.y + $1.y, z: $0.z + $1.z) }
        return (sum.x / n, sum.y / n, sum.z / n)
    }

    /// Gravity → tilt (degrees). The sensor lies flat in the base, so a level
    /// laptop reads g ≈ (0, 0, -1). Each angle is measured against the other
    /// two components, so it stays accurate for tilt on both axes. Nil for a
    /// non-finite or zero vector, so NaN never reaches output.
    static func tilt(_ g: Gravity) -> Tilt? {
        guard g.x.isFinite, g.y.isFinite, g.z.isFinite, g.x != 0 || g.y != 0 || g.z != 0 else { return nil }
        let roll = atan2(g.x, hypot(g.y, g.z)) * 180.0 / .pi
        let pitch = atan2(g.y, hypot(g.x, g.z)) * 180.0 / .pi
        return Tilt(pitch: pitch, roll: roll)
    }
}

// MARK: - Hardware

/// A live handle on the Apple Silicon SPU accelerometer.
///
/// Reads the raw HID input reports of the SPU accel device (usage page 0xFF00,
/// usage 3, transport "SPU") through the public IOHIDManager API, at ~100 Hz.
/// Reports are delivered on the current run loop, which `currentTilt()` pumps,
/// so use one instance from one thread. Each reading averages the last
/// `Accel.windowSize` reports (~250 ms): less jitter for ~0.1 s of lag.
final class HIDMotionSensor: TiltSource {
    static let accelMatching: [String: Any] = [
        kIOHIDPrimaryUsagePageKey: 0xFF00,
        kIOHIDPrimaryUsageKey: 3,
        kIOHIDTransportKey: "SPU",
    ]

    private let manager: IOHIDManager
    private let buffer: UnsafeMutablePointer<UInt8>
    private let readWait: TimeInterval
    private var window: [Gravity] = []
    private(set) var sampleCount = 0

    /// - Parameters:
    ///   - matching: device to open (overridable for tests).
    ///   - firstWait: how long to wait for the stream before asking the driver
    ///     to start reporting.
    ///   - readWait: how long `currentTilt()` waits for a fresh report.
    init(
        matching: [String: Any] = HIDMotionSensor.accelMatching,
        firstWait: TimeInterval = 0.3,
        readWait: TimeInterval = 0.25
    ) throws {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first else {
            throw SensorError.unavailable
        }

        self.manager = manager
        self.buffer = .allocate(capacity: Accel.reportSize)
        self.readWait = readWait
        // The context is always `self`, passed below.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, buffer, Accel.reportSize,
            { ctx, _, _, _, _, report, length in
                Unmanaged<HIDMotionSensor>.fromOpaque(ctx!).takeUnretainedValue()
                    .receive(UnsafeBufferPointer(start: report, count: length))
            }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // The stream normally runs once the device is open. If it stays silent,
        // ask the driver to power up and report, then wait once more.
        if !waitForSample(after: 0, seconds: firstWait) {
            Self.enableDriverReporting()
            _ = waitForSample(after: 0, seconds: 0.5)
        }
    }

    deinit {
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
    }

    /// Adds one report to the averaging window; ignores unusable reports.
    func receive(_ report: UnsafeBufferPointer<UInt8>) {
        guard let g = Accel.gravity(fromReport: report), Accel.tilt(g) != nil else { return }
        window.append(g)
        if window.count > Accel.windowSize { window.removeFirst(window.count - Accel.windowSize) }
        sampleCount += 1
    }

    /// Pump the run loop until a report newer than `count` arrives.
    private func waitForSample(after count: Int, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while sampleCount <= count && Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        return sampleCount > count
    }

    /// Current smoothed reading: drain queued reports, wait for one more so
    /// the window is current, then average it. Nil if none arrived in time.
    func currentTilt() -> Tilt? {
        while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        guard waitForSample(after: sampleCount, seconds: readWait), let g = Accel.average(window) else { return nil }
        return Accel.tilt(g)
    }

    /// Fallback: ask the SPU accel driver to power up and stream.
    static func enableDriverReporting() {
        var iterator: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator)
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let usage =
                IORegistryEntryCreateCFProperty(entry, "PrimaryUsage" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            guard usage == 3 else { continue }
            let props = [
                ("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 10_000),
            ]
            for (key, value) in props {
                IORegistryEntrySetCFProperty(entry, key as CFString, value as CFNumber)
            }
        }
    }
}
