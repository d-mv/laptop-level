import Foundation

@testable import LaptopLevelCore

/// Sensor fake: returns the scripted readings in order, then repeats the last.
final class FakeSensor: TiltSource {
    private let readings: [Tilt?]
    private var index = 0

    init(_ readings: [Tilt?]) { self.readings = readings }

    func currentTilt() -> Tilt? {
        defer { index += 1 }
        return index < readings.count ? readings[index] : readings.last!
    }
}

/// Records everything the CLI does and drives a fake clock: each `sleep`
/// advances time, and `stopWhen` can end a watch loop.
final class Harness {
    var out = ""
    var err = ""
    var flushes = 0
    var signalInstalls = 0
    var time: TimeInterval = 0
    var stopWhen: (Harness) -> Bool = { _ in false }

    func deps(
        model: String = "Mac14,5",
        sensor: TiltSource? = FakeSensor([Tilt(pitch: 0, roll: 0)]),
        isTTY: Bool = false,
        environment: [String: String] = [:]
    ) -> Dependencies {
        Dependencies(
            model: { model },
            makeSensor: {
                guard let sensor else { throw SensorError.unavailable }
                return sensor
            },
            out: { self.out += $0 },
            err: { self.err += $0 },
            flush: { self.flushes += 1 },
            isTTY: isTTY,
            environment: environment,
            now: { Date(timeIntervalSinceReferenceDate: self.time) },
            sleep: {
                self.time += Double($0) / 1_000_000
                if self.stopWhen(self) { interrupted = 1 }
            },
            installSignalHandlers: { self.signalInstalls += 1 }
        )
    }

    var outLines: [Substring] { out.split(separator: "\n") }
}

/// A 22-byte SPU accel report with x/y/z (in g) at offsets 6/10/14.
func report(_ x: Double, _ y: Double, _ z: Double) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: Accel.reportSize)
    for (i, v) in [x, y, z].enumerated() {
        let raw = UInt32(bitPattern: Int32((v * 65536).rounded()))
        for b in 0..<4 { r[6 + i * 4 + b] = UInt8((raw >> (8 * UInt32(b))) & 0xFF) }
    }
    return r
}
