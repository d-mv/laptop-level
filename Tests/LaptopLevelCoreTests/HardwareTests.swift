import XCTest

@testable import LaptopLevelCore

/// Runs against the real SPU accelerometer. Skipped on machines without one.
final class HardwareTests: XCTestCase {
    private func realSensor(firstWait: TimeInterval = 0.3, readWait: TimeInterval = 0.25) throws -> HIDMotionSensor {
        do {
            return try HIDMotionSensor(firstWait: firstWait, readWait: readWait)
        } catch {
            throw XCTSkip("no SPU accelerometer on this machine")
        }
    }

    func testReadsGravityAtRest() throws {
        let sensor = try realSensor()
        // Each read waits for a fresh report, so this overfills the window.
        for _ in 0..<Accel.windowSize { _ = sensor.currentTilt() }
        let t = try XCTUnwrap(sensor.currentTilt())
        XCTAssertLessThan(abs(t.roll), 90)
        XCTAssertLessThan(abs(t.pitch), 90)
        XCTAssertGreaterThan(sensor.sampleCount, Accel.windowSize, "window filled and trimmed")
    }

    func testDrainsReportsQueuedWhileIdle() throws {
        let sensor = try realSensor()
        _ = sensor.currentTilt()
        let before = sensor.sampleCount
        usleep(150_000)  // like the watch loop sleeping between frames
        XCTAssertNotNil(sensor.currentTilt())
        XCTAssertGreaterThan(sensor.sampleCount - before, 5, "caught up on the backlog")
    }

    func testFallbackEnablesDriverWhenStreamLooksSilent() throws {
        // firstWait 0 makes the first wait fail immediately → fallback path.
        let sensor = try realSensor(firstWait: 0)
        XCTAssertNotNil(sensor.currentTilt())
    }

    func testNoFreshReportWithinZeroWait() throws {
        XCTAssertNil(try realSensor(readWait: 0).currentTilt())
    }

    func testIgnoresUnusableReports() throws {
        let sensor = try realSensor(readWait: 0)
        let before = sensor.sampleCount
        [UInt8](repeating: 0, count: 10).withUnsafeBufferPointer { sensor.receive($0) }  // too short
        report(0, 0, 0).withUnsafeBufferPointer { sensor.receive($0) }  // zero vector
        XCTAssertEqual(sensor.sampleCount, before)
    }

    func testMissingDeviceThrows() {
        XCTAssertThrowsError(try HIDMotionSensor(matching: [kIOHIDPrimaryUsagePageKey: 0xDEAD]))
    }
}

/// Exercises the real process dependencies `main.swift` uses.
final class LiveDependencyTests: XCTestCase {
    func testLiveDependencies() throws {
        let live = Dependencies.live
        XCTAssertFalse(live.model().isEmpty)
        XCTAssertNotNil(live.environment["PATH"])
        _ = live.isTTY
        live.out("")
        live.err("")
        live.flush()
        let before = live.now()
        live.sleep(1_000)
        XCTAssertGreaterThan(live.now(), before)
        let sensor: TiltSource
        do {
            sensor = try live.makeSensor()
        } catch {
            throw XCTSkip("no SPU accelerometer on this machine")
        }
        XCTAssertNotNil(sensor.currentTilt())
    }

    func testSignalHandlersSetInterruptFlag() {
        Dependencies.live.installSignalHandlers()
        defer {
            for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig, SIG_DFL) }
            interrupted = 0
        }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            interrupted = 0
            raise(sig)
            XCTAssertEqual(interrupted, 1, "signal \(sig)")
        }
    }

    func testSysctlString() {
        XCTAssertEqual(sysctlString("hw.model"), Dependencies.live.model())
        XCTAssertEqual(sysctlString("no.such.key"), "")
    }
}
