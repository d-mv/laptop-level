import Foundation

// MARK: - Exit codes (see docs/design.md → Exit Codes)

enum ExitCode: Int32 {
    case ok = 0
    case overThreshold = 1
    case noSensor = 2
    case timeout = 3
    case usage = 64
}

/// Ends the run with an exit code and an optional stderr message.
struct CLIExit: Error, Equatable {
    let code: ExitCode
    let message: String

    init(_ code: ExitCode, _ message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - Options

enum ColorMode: String { case auto, always, never }

enum Metric: String { case axis, magnitude }

struct Options: Equatable {
    var threshold = 5.0
    var metric = Metric.axis
    var json = false
    var quiet = false
    var watch = false
    var color = ColorMode.auto
}

enum Command: Equatable {
    case help
    case run(Options)
}

/// Set from the signal handler to end `--watch`. Plain global so a C signal
/// handler (which can't capture context) can write it.
var interrupted: sig_atomic_t = 0

public enum CLI {
    static let usage = """
        laptop-level — shows your MacBook's tilt, relative to gravity.

        Reports two angles. It does NOT judge "straight": it can't sense skew/yaw
        or the table's own slope (see docs/design.md).

          L/R  left/right tilt (roll),  + = right edge lower
          B/F  back/front tilt (pitch), + = back edge lower

        USAGE:
          laptop-level [--watch] [--format json] [--color auto|always|never]
                       [--quiet [--threshold <deg>] [--metric axis|magnitude]]

          --watch     live ASCII bubble level (Ctrl+C to stop)
          --quiet     no output; exit 0 if within --threshold, else 1 (for scripts)

        EXIT CODES:
          0 ok / within tolerance   1 over tolerance (--quiet)
          2 no sensor   3 read timeout   64 usage error

        """

    static let noSensorMessage = "error: no SPU accelerometer found (unsupported hardware)"

    /// Entry point: runs the tool and returns the process exit code.
    public static func run(arguments: [String], deps: Dependencies) -> Int32 {
        do {
            return try execute(arguments, deps).rawValue
        } catch {
            deps.err(error.message + "\n")
            return error.code.rawValue
        }
    }

    static func execute(_ arguments: [String], _ deps: Dependencies) throws(CLIExit) -> ExitCode {
        let opts: Options
        switch try parse(arguments) {
        case .help:
            deps.out(usage)
            return .ok
        case .run(let o):
            opts = o
        }

        let model = deps.model()
        guard let offset = modelOffsets[model] else {
            throw CLIExit(
                .noSensor, "error: model \(model.isEmpty ? "<unknown>" : model) has no calibration entry; unsupported")
        }

        let sensor = try openSensor(deps)
        if opts.watch { return try watch(opts, offset, sensor, deps) }

        guard let raw = stableReading(from: sensor, deps) else {
            throw CLIExit(.timeout, "error: sensor present but no stable reading in time")
        }
        let dev = offset.deviation(of: raw)
        let within = deviation(dev, metric: opts.metric) <= opts.threshold

        // --quiet is the only verdict path: silent, exit reflects the threshold.
        if opts.quiet { return within ? .ok : .overThreshold }
        deps.out((opts.json ? jsonLine(dev, opts, within: within) : Renderer.readout(dev)) + "\n")
        return .ok
    }

    // MARK: - Parsing

    static func parse(_ argv: [String]) throws(CLIExit) -> Command {
        var o = Options()
        var i = 0
        func value(_ flag: String) throws(CLIExit) -> String {
            i += 1
            guard i < argv.count else { throw CLIExit(.usage, "error: \(flag) requires a value") }
            return argv[i]
        }
        while i < argv.count {
            switch argv[i] {
            case "--help", "-h":
                return .help
            case "--watch":
                o.watch = true
            case "--quiet":
                o.quiet = true
            case "--threshold":
                guard let t = Double(try value("--threshold")), t >= 0 else {
                    throw CLIExit(.usage, "error: invalid --threshold")
                }
                o.threshold = t
            case "--metric":
                guard let m = Metric(rawValue: try value("--metric")) else {
                    throw CLIExit(.usage, "error: --metric must be axis|magnitude")
                }
                o.metric = m
            case "--format":
                guard try value("--format") == "json" else {
                    throw CLIExit(.usage, "error: --format only supports json")
                }
                o.json = true
            case "--color":
                guard let c = ColorMode(rawValue: try value("--color")) else {
                    throw CLIExit(.usage, "error: --color must be auto|always|never")
                }
                o.color = c
            default:
                throw CLIExit(.usage, "error: unknown argument \(argv[i])")
            }
            i += 1
        }
        // Interaction rules (docs/design.md → Flag interaction rules)
        if o.quiet && o.watch { throw CLIExit(.usage, "error: --quiet cannot be combined with --watch") }
        if o.quiet && o.json { throw CLIExit(.usage, "error: --quiet cannot be combined with --format json") }
        return .run(o)
    }

    // MARK: - Helpers

    /// Combined tilt under the chosen metric.
    static func deviation(_ t: Tilt, metric: Metric) -> Double {
        metric == .magnitude ? hypot(t.pitch, t.roll) : max(abs(t.pitch), abs(t.roll))
    }

    static func resolveColor(_ mode: ColorMode, isTTY: Bool, environment: [String: String]) -> Bool {
        switch mode {
        case .always: return true
        case .never: return false
        case .auto: return isTTY && environment["NO_COLOR"] == nil
        }
    }

    /// `lr`/`bf` are the measurement; `threshold`/`straight` are an opt-in
    /// convenience for scripts.
    static func jsonLine(_ t: Tilt, _ opts: Options, within: Bool) -> String {
        let lr = String(format: "%.3f", tidyDeg(t.roll))
        let bf = String(format: "%.3f", tidyDeg(t.pitch))
        let th = String(format: "%g", opts.threshold)
        return "{\"lr_deg\":\(lr),\"bf_deg\":\(bf),\"threshold_deg\":\(th),"
            + "\"metric\":\"\(opts.metric.rawValue)\",\"straight\":\(within)}"
    }

    static func openSensor(_ deps: Dependencies) throws(CLIExit) -> TiltSource {
        do {
            return try deps.makeSensor()
        } catch {
            throw CLIExit(.noSensor, noSensorMessage)
        }
    }

    /// Single-shot: discard warm-up samples, then require two consecutive close
    /// readings. Nil if none stabilize before the timeout.
    static func stableReading(from sensor: TiltSource, _ deps: Dependencies) -> Tilt? {
        let start = deps.now()
        let settleUntil = start.addingTimeInterval(Timing.settle)
        let deadline = start.addingTimeInterval(Timing.timeout)
        var last: Tilt?
        while deps.now() < deadline {
            if let t = sensor.currentTilt() {
                if deps.now() >= settleUntil, let prev = last,
                    abs(prev.pitch - t.pitch) < 0.5, abs(prev.roll - t.roll) < 0.5
                {
                    return t
                }
                last = t
            }
            deps.sleep(Timing.pollMicros)
        }
        return nil
    }

    // MARK: - Watch mode

    static let hideCursor = "\u{001B}[?25l"
    static let showCursor = "\u{001B}[?25h"

    static func watch(
        _ opts: Options, _ offset: ReferenceOffset, _ sensor: TiltSource, _ deps: Dependencies
    ) throws(CLIExit) -> ExitCode {
        interrupted = 0
        deps.installSignalHandlers()
        let color = resolveColor(opts.color, isTTY: deps.isTTY, environment: deps.environment)
        let drawsBox = deps.isTTY && !opts.json
        let frameHeight = Renderer.interiorHeight + 4  // box + status + hint
        var first = true
        if drawsBox { deps.out(hideCursor) }
        // Runs on Ctrl+C/kill and on timeout, so the cursor always comes back.
        defer {
            if drawsBox {
                deps.out(showCursor)
                deps.flush()
            }
        }

        let start = deps.now()
        let settleUntil = start.addingTimeInterval(Timing.settle)
        var lastSample = start

        while interrupted == 0 {
            guard let raw = sensor.currentTilt() else {
                if deps.now().timeIntervalSince(lastSample) > Timing.timeout {
                    throw CLIExit(.timeout, "error: sensor stopped answering")
                }
                deps.sleep(Timing.pollMicros)
                continue
            }
            lastSample = deps.now()
            if lastSample < settleUntil {
                deps.sleep(Timing.pollMicros)
                continue
            }
            let dev = offset.deviation(of: raw)

            if opts.json {
                let within = deviation(dev, metric: opts.metric) <= opts.threshold
                deps.out(jsonLine(dev, opts, within: within) + "\n")
            } else if drawsBox {
                // One write per frame: move up, then overwrite each line and
                // clear its tail. Avoids the flicker of clearing first.
                let up = first ? "" : "\u{001B}[\(frameHeight)A"
                let lines = Renderer.frame(dev, color: color)
                deps.out(up + lines.map { "\r" + $0 + "\u{001B}[K" }.joined(separator: "\n") + "\n")
                first = false
            } else {
                deps.out(Renderer.readout(dev) + "\n")
            }
            // Flush each frame: piped stdout is block-buffered, which would both
            // delay output and defer the broken-pipe SIGPIPE.
            deps.flush()
            // The box redraws at 20 fps; JSONL and plain lines stay at 2/s so
            // scripts and logs aren't flooded.
            deps.sleep(drawsBox ? Timing.frameMicros : Timing.lineMicros)
        }
        return .ok
    }
}

/// Fixed tunables (by design, not flags).
enum Timing {
    static let settle: TimeInterval = 0.3
    static let timeout: TimeInterval = 2.0
    static let pollMicros: UInt32 = 50_000
    static let frameMicros: UInt32 = 50_000
    static let lineMicros: UInt32 = 500_000
}
