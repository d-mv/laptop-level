import XCTest

@testable import LaptopLevelCore

private func decode(_ r: [UInt8]) -> Gravity? {
    r.withUnsafeBufferPointer { Accel.gravity(fromReport: $0) }
}

final class ReportTests: XCTestCase {
    func testDecodesSignedLittleEndianFixedPoint() throws {
        let g = try XCTUnwrap(decode(report(0.5, -0.25, -0.989)))
        XCTAssertEqual(g.x, 0.5, accuracy: 1e-4)
        XCTAssertEqual(g.y, -0.25, accuracy: 1e-4)
        XCTAssertEqual(g.z, -0.989, accuracy: 1e-4)
    }

    func testShortReportIsRejected() {
        XCTAssertNil(decode([UInt8](repeating: 0, count: 17)))
    }
}

/// Samples logged on Mac14,5 (2026-11-08) while physically tilting the laptop.
final class TiltTests: XCTestCase {
    func testFlatOnDesk() throws {
        let t = try XCTUnwrap(Accel.tilt(decode(report(0.004, 0.015, -0.982))!))
        XCTAssertEqual(t.roll, 0.23, accuracy: 0.05)
        XCTAssertEqual(t.pitch, 0.88, accuracy: 0.05)
    }

    func testLeftEdgeLiftedReadsPositiveLR() throws {
        let t = try XCTUnwrap(Accel.tilt((0.137, 0.016, -0.968)))
        XCTAssertEqual(t.roll, 8.03, accuracy: 0.05)
        XCTAssertEqual(t.pitch, 0.94, accuracy: 0.1)
    }

    func testFrontDownReadsNegativeBF() throws {
        let t = try XCTUnwrap(Accel.tilt((0.006, -0.315, -0.928)))
        XCTAssertEqual(t.pitch, -18.72, accuracy: 0.05)
        XCTAssertEqual(t.roll, 0.37, accuracy: 0.05)
    }

    func testRawScaleCancels() throws {
        let a = try XCTUnwrap(Accel.tilt((0.137, 0.016, -0.968)))
        let b = try XCTUnwrap(Accel.tilt((1.37, 0.16, -9.68)))
        XCTAssertEqual(a.pitch, b.pitch, accuracy: 1e-12)
        XCTAssertEqual(a.roll, b.roll, accuracy: 1e-12)
    }

    func testUnusableVectorsAreRejected() {
        XCTAssertNil(Accel.tilt((.nan, 1, 1)))
        XCTAssertNil(Accel.tilt((0, .infinity, 1)))
        XCTAssertNil(Accel.tilt((0, 1, -.infinity)))
        XCTAssertNil(Accel.tilt((0, 0, 0)))
    }
}

final class AverageTests: XCTestCase {
    func testAveragesVectorsComponentwise() throws {
        let g = try XCTUnwrap(Accel.average([(0.1, 0.0, -1.0), (0.3, -0.2, -0.9)]))
        XCTAssertEqual(g.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(g.y, -0.1, accuracy: 1e-12)
        XCTAssertEqual(g.z, -0.95, accuracy: 1e-12)
    }

    func testEmptyWindowHasNoReading() {
        XCTAssertNil(Accel.average([]))
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
        let ref = ReferenceOffset(pitch0: 10, roll0: 179)
        let d = ref.deviation(of: Tilt(pitch: 12, roll: -179))
        XCTAssertEqual(d.roll, 2, accuracy: 1e-12)
        XCTAssertEqual(d.pitch, 2, accuracy: 1e-12)
    }

    func testMac14_5HasAnEntry() {
        XCTAssertNotNil(modelOffsets["Mac14,5"])
    }
}

final class RendererTests: XCTestCase {
    private func bubbleRow(_ lines: [String]) -> Int? {
        lines.dropFirst().prefix(Renderer.interiorHeight).firstIndex { $0.contains("●") }.map { $0 - 1 }
    }

    private func frame(_ pitch: Double, _ roll: Double, color: Bool = false) -> [String] {
        Renderer.frame(Tilt(pitch: pitch, roll: roll), color: color)
    }

    func testFrameHeight() {
        XCTAssertEqual(frame(0, 0).count, Renderer.interiorHeight + 4)
    }

    func testLevelBubbleIsCentered() {
        XCTAssertEqual(bubbleRow(frame(0, 0)), Renderer.interiorHeight / 2)
    }

    func testSmallBackFrontTiltMovesBubble() {
        let center = Renderer.interiorHeight / 2
        XCTAssertNotEqual(bubbleRow(frame(2.5, 0)), center)
        XCTAssertNotEqual(bubbleRow(frame(-2.5, 0)), center)
    }

    func testBubblePinsAtFullScale() {
        XCTAssertEqual(bubbleRow(frame(90, 0)), Renderer.interiorHeight - 1)
        XCTAssertEqual(bubbleRow(frame(-90, 0)), 0)
    }

    func testColorScalesWithMagnitude() {
        XCTAssertTrue(frame(0, 1, color: true).joined().contains("\u{001B}[32m"))  // green
        XCTAssertTrue(frame(0, 8, color: true).joined().contains("\u{001B}[33m"))  // yellow
        XCTAssertTrue(frame(0, 14, color: true).joined().contains("\u{001B}[31m"))  // red
        XCTAssertFalse(frame(0, 14).joined().contains("\u{001B}["))
    }

    func testReadoutIsFixedWidthAndSigned() {
        XCTAssertEqual(Renderer.readout(Tilt(pitch: -0.4944, roll: 0.0001)), "L/R   +0.000°   B/F   -0.494°")
    }

    func testTidyDegSquashesNegativeZero() {
        XCTAssertEqual(tidyDeg(-0.0001).sign, .plus)
        XCTAssertEqual(tidyDeg(1.23456), 1.235)
    }
}
