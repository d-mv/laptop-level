import XCTest

@testable import LaptopLevelCore

final class ParseTests: XCTestCase {
    private func parse(_ args: String...) throws -> Command { try CLI.parse(args) }

    private func usageError(_ args: String..., file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            _ = try CLI.parse(args)
            XCTFail("expected usage error", file: file, line: line)
            return nil
        } catch {
            XCTAssertEqual(error.code, .usage, file: file, line: line)
            return error.message
        }
    }

    func testDefaults() throws {
        XCTAssertEqual(try parse(), .run(Options()))
    }

    func testHelp() throws {
        XCTAssertEqual(try parse("--help"), .help)
        XCTAssertEqual(try parse("--watch", "-h"), .help)
    }

    func testAllFlags() throws {
        var o = Options()
        o.watch = true
        o.json = true
        o.color = .always
        o.threshold = 2.5
        o.metric = .magnitude
        XCTAssertEqual(
            try parse(
                "--watch", "--format", "json", "--color", "always", "--threshold", "2.5", "--metric", "magnitude"),
            .run(o))
        XCTAssertEqual(try parse("--quiet"), .run(Options(quiet: true)))
    }

    func testBadValues() {
        XCTAssertEqual(usageError("--threshold"), "error: --threshold requires a value")
        XCTAssertEqual(usageError("--threshold", "abc"), "error: invalid --threshold")
        XCTAssertEqual(usageError("--threshold", "-1"), "error: invalid --threshold")
        XCTAssertEqual(usageError("--metric", "x"), "error: --metric must be axis|magnitude")
        XCTAssertEqual(usageError("--format", "yaml"), "error: --format only supports json")
        XCTAssertEqual(usageError("--color", "rainbow"), "error: --color must be auto|always|never")
        XCTAssertEqual(usageError("--bogus"), "error: unknown argument --bogus")
    }

    func testIncompatibleCombinations() {
        XCTAssertEqual(usageError("--quiet", "--watch"), "error: --quiet cannot be combined with --watch")
        XCTAssertEqual(
            usageError("--quiet", "--format", "json"), "error: --quiet cannot be combined with --format json")
    }
}

final class HelperTests: XCTestCase {
    func testDeviationMetrics() {
        let t = Tilt(pitch: 3, roll: -4)
        XCTAssertEqual(CLI.deviation(t, metric: .axis), 4)
        XCTAssertEqual(CLI.deviation(t, metric: .magnitude), 5)
    }

    func testResolveColor() {
        XCTAssertTrue(CLI.resolveColor(.always, isTTY: false, environment: [:]))
        XCTAssertFalse(CLI.resolveColor(.never, isTTY: true, environment: [:]))
        XCTAssertTrue(CLI.resolveColor(.auto, isTTY: true, environment: [:]))
        XCTAssertFalse(CLI.resolveColor(.auto, isTTY: false, environment: [:]))
        XCTAssertFalse(CLI.resolveColor(.auto, isTTY: true, environment: ["NO_COLOR": "1"]))
    }

    func testJSONLine() {
        let line = CLI.jsonLine(Tilt(pitch: -0.4944, roll: 1.5), Options(), within: true)
        XCTAssertEqual(line, #"{"lr_deg":1.500,"bf_deg":-0.494,"threshold_deg":5,"metric":"axis","straight":true}"#)
    }
}

final class SingleShotTests: XCTestCase {
    private let level = Tilt(pitch: 0.5, roll: -0.25)

    func testHelpPrintsUsage() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: ["--help"], deps: h.deps()), 0)
        XCTAssertTrue(h.out.hasPrefix("laptop-level — shows"))
    }

    func testUsageErrorGoesToStderr() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: ["--nope"], deps: h.deps()), 64)
        XCTAssertEqual(h.err, "error: unknown argument --nope\n")
        XCTAssertEqual(h.out, "")
    }

    func testUnsupportedModel() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: [], deps: h.deps(model: "Mac99,1")), 2)
        XCTAssertEqual(h.err, "error: model Mac99,1 has no calibration entry; unsupported\n")
        let unknown = Harness()
        XCTAssertEqual(CLI.run(arguments: [], deps: unknown.deps(model: "")), 2)
        XCTAssertTrue(unknown.err.contains("<unknown>"))
    }

    func testMissingSensor() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: [], deps: h.deps(sensor: nil)), 2)
        XCTAssertEqual(h.err, CLI.noSensorMessage + "\n")
    }

    func testPlainReadout() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: [], deps: h.deps(sensor: FakeSensor([level]))), 0)
        XCTAssertEqual(h.out, "L/R   -0.250°   B/F   +0.500°\n")
        XCTAssertGreaterThanOrEqual(h.time, Timing.settle, "waited out the warm-up")
    }

    func testJSON() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: ["--format", "json"], deps: h.deps(sensor: FakeSensor([level]))), 0)
        XCTAssertTrue(h.out.hasPrefix(#"{"lr_deg":-0.250,"bf_deg":0.500,"#))
        XCTAssertTrue(h.out.hasSuffix("\"straight\":true}\n"))
    }

    func testQuietGate() {
        let tilted = FakeSensor([Tilt(pitch: 6, roll: 0)])
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: ["--quiet"], deps: h.deps(sensor: tilted)), 1)
        XCTAssertEqual(CLI.run(arguments: ["--quiet", "--threshold", "7"], deps: h.deps(sensor: tilted)), 0)
        XCTAssertEqual(h.out, "")
    }

    func testTimeoutWhenReadingsNeverSettle() {
        // A gap, then steps that alternately move B/F and L/R by 5°: no two
        // consecutive samples are ever within 0.5° on both axes.
        let steps: [Tilt?] = (0..<200).map { (i: Int) -> Tilt? in
            let pitch = Double((i + 1) / 2) * 5
            let roll = Double(i / 2) * 5
            return Tilt(pitch: pitch, roll: roll)
        }
        let jumpy = FakeSensor([nil] + steps)
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: [], deps: h.deps(sensor: jumpy)), 3)
        XCTAssertEqual(h.err, "error: sensor present but no stable reading in time\n")
        XCTAssertGreaterThanOrEqual(h.time, Timing.timeout)
    }

    func testTimeoutWhenSensorSilent() {
        let h = Harness()
        XCTAssertEqual(CLI.run(arguments: [], deps: h.deps(sensor: FakeSensor([nil]))), 3)
    }
}

final class WatchTests: XCTestCase {
    private let tilt = Tilt(pitch: 1, roll: 2)

    override func tearDown() { interrupted = 0 }

    func testJSONLinesAtTwoPerSecond() {
        let h = Harness()
        h.stopWhen = { $0.outLines.count >= 3 }
        XCTAssertEqual(CLI.run(arguments: ["--watch", "--format", "json"], deps: h.deps(isTTY: true)), 0)
        XCTAssertEqual(h.outLines.count, 3)
        XCTAssertTrue(h.outLines.allSatisfy { $0.hasPrefix("{\"lr_deg\"") })
        XCTAssertFalse(h.out.contains(CLI.hideCursor), "JSONL never touches the cursor")
        XCTAssertEqual(h.signalInstalls, 1)
        XCTAssertGreaterThanOrEqual(h.flushes, 3)
        XCTAssertGreaterThanOrEqual(h.time, Timing.settle + 2 * Double(Timing.lineMicros) / 1e6)
    }

    func testPlainLinesWhenNotATerminal() {
        let h = Harness()
        h.stopWhen = { $0.outLines.count >= 2 }
        XCTAssertEqual(CLI.run(arguments: ["--watch"], deps: h.deps(sensor: FakeSensor([tilt]))), 0)
        XCTAssertEqual(h.outLines, ["L/R   +2.000°   B/F   +1.000°", "L/R   +2.000°   B/F   +1.000°"])
    }

    func testBoxRedrawsInPlaceAndRestoresCursor() {
        let h = Harness()
        h.stopWhen = { $0.out.components(separatedBy: "Press Ctrl+C").count > 2 }  // two frames
        let code = CLI.run(
            arguments: ["--watch", "--color", "never"], deps: h.deps(sensor: FakeSensor([tilt]), isTTY: true))
        XCTAssertEqual(code, 0)
        XCTAssertTrue(h.out.hasPrefix(CLI.hideCursor))
        XCTAssertTrue(h.out.hasSuffix(CLI.showCursor))
        XCTAssertEqual(
            h.out.components(separatedBy: "\u{001B}[\(Renderer.interiorHeight + 4)A").count, 2, "one move-up")
        XCTAssertTrue(h.out.contains("\r┌"))
    }

    func testTimeoutRestoresCursorAndExits3() {
        let h = Harness()
        // One good reading, then silence for longer than the timeout.
        let code = CLI.run(arguments: ["--watch"], deps: h.deps(sensor: FakeSensor([tilt, nil]), isTTY: true))
        XCTAssertEqual(code, 3)
        XCTAssertEqual(h.err, "error: sensor stopped answering\n")
        XCTAssertTrue(h.out.hasSuffix(CLI.showCursor))
    }
}
