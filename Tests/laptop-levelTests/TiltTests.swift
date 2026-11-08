import XCTest
@testable import laptop_level

/// Build a 22-byte SPU accel report with x/y/z (in g) at offsets 6/10/14.
private func report(_ x: Double, _ y: Double, _ z: Double) -> [UInt8] {
    var r = [UInt8](repeating: 0, count: MotionSensor.reportSize)
    for (i, v) in [x, y, z].enumerated() {
        let raw = UInt32(bitPattern: Int32((v * 65536).rounded()))
        for b in 0..<4 { r[6 + i * 4 + b] = UInt8((raw >> (8 * UInt32(b))) & 0xFF) }
    }
    return r
}

private func tiltFromReport(_ r: [UInt8]) throws -> Tilt {
    let g = try XCTUnwrap(r.withUnsafeBufferPointer { MotionSensor.gravity(fromReport: $0) })
    return try XCTUnwrap(MotionSensor.tilt(x: g.x, y: g.y, z: g.z))
}

final class ReportTests: XCTestCase {
    func testDecodesSignedLittleEndianFixedPoint() throws {
        let g = try XCTUnwrap(report(0.5, -0.25, -0.989).withUnsafeBufferPointer { MotionSensor.gravity(fromReport: $0) })
        XCTAssertEqual(g.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(g.y, -0.25, accuracy: 1e-4)
        XCTAssertEqual(g.z, -0.989, accuracy: 1e-4)
    }

    func testShortReportIsRejected() {
        let short = [UInt8](repeating: 0, count: 17)
        XCTAssertNil(short.withUnsafeBufferPointer { MotionSensor.gravity(fromReport: $0) })
    }
}

/// Samples logged on Mac14,5 (2026-11-08) while physically tilting the laptop.
final class TiltTests: XCTestCase {
    func testFlatOnDesk() throws {
        let t = try tiltFromReport(report(0.004, 0.015, -0.982))
        XCTAssertEqual(t.roll, 0.23, accuracy: 0.05)
        XCTAssertEqual(t.pitch, 0.88, accuracy: 0.05)
    }

    func testLeftEdgeLiftedReadsPositiveLR() throws {
        let t = try tiltFromReport(report(0.137, 0.016, -0.968))
        XCTAssertEqual(t.roll, 8.03, accuracy: 0.05)
        XCTAssertEqual(t.pitch, 0.94, accuracy: 0.1)
    }

    func testFrontDownReadsNegativeBF() throws {
        let t = try tiltFromReport(report(0.006, -0.315, -0.928))
        XCTAssertEqual(t.pitch, -18.72, accuracy: 0.05)
        XCTAssertEqual(t.roll, 0.37, accuracy: 0.05)
    }

    func testRawScaleCancels() throws {
        let a = try XCTUnwrap(MotionSensor.tilt(x: 0.137, y: 0.016, z: -0.968))
        let b = try XCTUnwrap(MotionSensor.tilt(x: 1.37, y: 0.16, z: -9.68))
        XCTAssertEqual(a.pitch, b.pitch, accuracy: 1e-12)
        XCTAssertEqual(a.roll, b.roll, accuracy: 1e-12)
    }

    func testUnusableVectorsAreRejected() {
        XCTAssertNil(MotionSensor.tilt(x: .nan, y: 1, z: 1))
        XCTAssertNil(MotionSensor.tilt(x: 0, y: .infinity, z: 1))
        XCTAssertNil(MotionSensor.tilt(x: 0, y: 0, z: 0))
    }
}

final class AverageTests: XCTestCase {
    func testAveragesVectorsComponentwise() throws {
        let g = try XCTUnwrap(MotionSensor.average([(0.1, 0.0, -1.0), (0.3, -0.2, -0.9)]))
        XCTAssertEqual(g.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(g.y, -0.1, accuracy: 1e-12)
        XCTAssertEqual(g.z, -0.95, accuracy: 1e-12)
    }

    func testEmptyWindowHasNoReading() {
        XCTAssertNil(MotionSensor.average([]))
    }

    func testAveragingCancelsSymmetricNoise() throws {
        let noisy: [MotionSensor.Gravity] = [(0.14, 0.02, -0.97), (0.12, 0.00, -0.97)]
        let g = try XCTUnwrap(MotionSensor.average(noisy))
        let t = try XCTUnwrap(MotionSensor.tilt(x: g.x, y: g.y, z: g.z))
        let mid = try XCTUnwrap(MotionSensor.tilt(x: 0.13, y: 0.01, z: -0.97))
        XCTAssertEqual(t.roll, mid.roll, accuracy: 1e-9)
        XCTAssertEqual(t.pitch, mid.pitch, accuracy: 1e-9)
    }
}

final class OffsetTests: XCTestCase {
    func testWrapDeg() {
        XCTAssertEqual(wrapDeg(0), 0)
        XCTAssertEqual(wrapDeg(190), -170, accuracy: 1e-12)
        XCTAssertEqual(wrapDeg(-190), 170, accuracy: 1e-12)
        XCTAssertEqual(wrapDeg(180), 180)
        XCTAssertEqual(wrapDeg(-180), 180)
        XCTAssertEqual(wrapDeg(725), 5, accuracy: 1e-12)
        XCTAssertEqual(wrapDeg(-0.0).sign, .plus)
    }

    func testDeviationWrapsAcrossSeam() {
        // Raw roll just past -180 while the reference sits near +180.
        let ref = ReferenceOffset(pitch0: 10, roll0: 179)
        let d = ref.deviation(of: Tilt(pitch: 12, roll: -179))
        XCTAssertEqual(d.roll, 2, accuracy: 1e-12)
        XCTAssertEqual(d.pitch, 2, accuracy: 1e-12)
    }
}

final class RendererTests: XCTestCase {
    private func bubbleRow(_ lines: [String]) -> Int? {
        lines.dropFirst().prefix(Renderer.interiorHeight).firstIndex { $0.contains("●") }
            .map { $0 - 1 }
    }

    func testFrameHeight() {
        XCTAssertEqual(Renderer.frame(pitch: 0, roll: 0, color: false).count, Renderer.interiorHeight + 4)
    }

    func testLevelBubbleIsCentered() {
        XCTAssertEqual(bubbleRow(Renderer.frame(pitch: 0, roll: 0, color: false)), Renderer.interiorHeight / 2)
    }

    func testSmallBackFrontTiltMovesBubble() {
        let center = Renderer.interiorHeight / 2
        XCTAssertNotEqual(bubbleRow(Renderer.frame(pitch: 2.5, roll: 0, color: false)), center)
        XCTAssertNotEqual(bubbleRow(Renderer.frame(pitch: -2.5, roll: 0, color: false)), center)
    }

    func testBubblePinsAtFullScale() {
        XCTAssertEqual(bubbleRow(Renderer.frame(pitch: 90, roll: 0, color: false)), Renderer.interiorHeight - 1)
        XCTAssertEqual(bubbleRow(Renderer.frame(pitch: -90, roll: 0, color: false)), 0)
    }
}
