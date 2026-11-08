import XCTest
@testable import laptop_level

private func rad(_ d: Double) -> Double { d * .pi / 180 }

/// Gravity in the sensor frame for a sensor rotated `mount`° about its X axis,
/// with the base tilted by `lr`° (left/right) and `bf`° (back/front).
private func gravity(mount: Double, lr: Double, bf: Double) -> (Double, Double, Double) {
    // Base tilt: roll about base Y, then pitch about base X (X = hinge axis).
    let gx = sin(rad(lr))
    let gyz = cos(rad(lr))
    let a = rad(mount + bf)
    return (gx, gyz * sin(a), gyz * cos(a))
}

final class TiltTests: XCTestCase {
    func testDeviationMatchesTrueTiltWithMountingOffset() throws {
        let mount = 49.5
        let (x0, y0, z0) = gravity(mount: mount, lr: 0, bf: 0)
        let ref = try XCTUnwrap(MotionSensor.tilt(x: x0, y: y0, z: z0))
        for (lr, bf) in [(5.0, 0.0), (10.0, 0.0), (0.0, 5.0), (-3.0, 2.0), (5.0, 5.0)] {
            let (x, y, z) = gravity(mount: mount, lr: lr, bf: bf)
            let t = try XCTUnwrap(MotionSensor.tilt(x: x, y: y, z: z))
            XCTAssertEqual(t.roll - ref.roll, lr, accuracy: 1e-9, "L/R for (\(lr), \(bf))")
            XCTAssertEqual(t.pitch - ref.pitch, bf, accuracy: 1e-9, "B/F for (\(lr), \(bf))")
        }
    }

    func testRawUnitsCancel() throws {
        let a = try XCTUnwrap(MotionSensor.tilt(x: 139, y: 1368, z: 1164))
        let b = try XCTUnwrap(MotionSensor.tilt(x: 1390, y: 13680, z: 11640))
        XCTAssertEqual(a.pitch, b.pitch, accuracy: 1e-12)
        XCTAssertEqual(a.roll, b.roll, accuracy: 1e-12)
    }

    func testLiveSampleFromMac14_5() throws {
        // Sample logged on Mac14,5 on 2026-11-08, laptop resting on a desk.
        let t = try XCTUnwrap(MotionSensor.tilt(x: 139, y: 1368, z: 1164))
        XCTAssertEqual(t.pitch, 49.6, accuracy: 0.1)
        XCTAssertEqual(t.roll, 4.4, accuracy: 0.1)
    }

    func testUnusableVectorsAreRejected() {
        XCTAssertNil(MotionSensor.tilt(x: .nan, y: 1, z: 1))
        XCTAssertNil(MotionSensor.tilt(x: 0, y: .infinity, z: 1))
        XCTAssertNil(MotionSensor.tilt(x: 0, y: 0, z: 0))
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
