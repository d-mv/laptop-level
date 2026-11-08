import CHIDSPI
import CoreFoundation
import Foundation

enum SensorError: Error {
    case unavailable        // exit 2: no usable sensor / SPI blocked
    case timeout            // exit 3: present but no stable reading in time
}

struct Tilt {
    let pitch: Double       // degrees, raw (mounting offset NOT yet removed)
    let roll: Double
}

/// A live handle on the SPU accelerometer via the private IOHIDEventSystemClient
/// SPI. Opens the client + locates the accel service once, then samples on
/// demand — suitable for both single-shot and the watch loop.
final class MotionSensor {
    // Held for lifetime: `services` (CFArray) keeps the service pointers valid;
    // `client` is kept so it isn't torn down underneath them.
    private let client: IOHIDEventSystemClientRef
    private let services: CFArray
    private let service: IOHIDServiceClientRef

    init() throws {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            throw SensorError.unavailable
        }
        guard let services = IOHIDEventSystemClientCopyServices(client) else {
            throw SensorError.unavailable
        }
        var found: IOHIDServiceClientRef?
        for i in 0..<CFArrayGetCount(services) {
            let s = unsafeBitCast(CFArrayGetValueAtIndex(services, i), to: IOHIDServiceClientRef.self)
            if let ev = IOHIDServiceClientCopyEvent(s, Int64(kIOHIDEventTypeAccelerometer), 0, 0) {
                HIDEventRelease(ev)
                found = s
                break
            }
        }
        guard let service = found else { throw SensorError.unavailable }
        self.client = client
        self.services = services
        self.service = service
    }

    /// One raw gravity sample → pitch/roll, or nil if the event didn't arrive
    /// or carried no usable vector.
    func currentTilt() -> Tilt? {
        guard let ev = IOHIDServiceClientCopyEvent(service, Int64(kIOHIDEventTypeAccelerometer), 0, 0) else {
            return nil
        }
        defer { HIDEventRelease(ev) }
        return Self.tilt(x: IOHIDEventGetFloatValue(ev, HIDAccelField(0)),
                         y: IOHIDEventGetFloatValue(ev, HIDAccelField(1)),
                         z: IOHIDEventGetFloatValue(ev, HIDAccelField(2)))
    }

    /// Gravity vector → raw pitch/roll (degrees). Raw units cancel in atan2.
    ///
    /// The sensor sits in the base but is rotated ~50° about its X axis, so
    /// gravity is split between Y and Z. Pitch is therefore the angle within the
    /// Y–Z plane, and roll is measured against the full Y–Z component. Using
    /// `atan2(x, z)` for roll instead would inflate it by 1/cos(pitch) (~1.5×)
    /// and leak pitch into roll.
    ///
    /// Returns nil for a non-finite or zero vector (no gravity data), so NaN
    /// never reaches the output.
    static func tilt(x: Double, y: Double, z: Double) -> Tilt? {
        guard x.isFinite, y.isFinite, z.isFinite, x != 0 || y != 0 || z != 0 else { return nil }
        let yz = hypot(y, z)
        let pitch = atan2(y, z) * 180.0 / .pi
        let roll = atan2(x, yz) * 180.0 / .pi
        return Tilt(pitch: pitch, roll: roll)
    }

    /// Single-shot: discard warm-up samples, then require two consecutive close
    /// readings before reporting. Throws `.timeout` if none stabilize in time.
    static let settleMs = 300
    static let timeoutMs = 2000

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
