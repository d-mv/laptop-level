import Foundation

// MARK: - Exit codes (see docs/design.md → Exit Codes)
enum Exit: Int32 {
    case straight = 0
    case tilted = 1
    case noSensor = 2
    case timeout = 3
    case usage = 64
}

func die(_ code: Exit, _ message: String? = nil) -> Never {
    if let m = message { FileHandle.standardError.write(Data((m + "\n").utf8)) }
    exit(code.rawValue)
}

// MARK: - SIGINT flag (watch mode). Set only from the async-signal handler.
var interrupted: Int32 = 0

// MARK: - Options
enum ColorMode: String { case auto, always, never }

struct Options {
    var threshold = 5.0
    var metric = "axis"        // axis | magnitude
    var json = false
    var quiet = false
    var watch = false
    var color = ColorMode.auto
}

func parse(_ argv: [String]) -> Options {
    var o = Options()
    var i = 0
    func next(_ flag: String) -> String {
        i += 1
        guard i < argv.count else { die(.usage, "error: \(flag) requires a value") }
        return argv[i]
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "--help", "-h": printUsage(); exit(0)
        case "--watch": o.watch = true
        case "--quiet": o.quiet = true
        case "--threshold":
            guard let t = Double(next("--threshold")), t >= 0 else { die(.usage, "error: invalid --threshold") }
            o.threshold = t
        case "--metric":
            let m = next("--metric")
            guard m == "axis" || m == "magnitude" else { die(.usage, "error: --metric must be axis|magnitude") }
            o.metric = m
        case "--format":
            let f = next("--format")
            guard f == "json" else { die(.usage, "error: --format only supports json") }
            o.json = true
        case "--color":
            guard let c = ColorMode(rawValue: next("--color")) else {
                die(.usage, "error: --color must be auto|always|never")
            }
            o.color = c
        default:
            die(.usage, "error: unknown argument \(a)")
        }
        i += 1
    }
    // Interaction rules (docs/design.md → Flag interaction rules)
    if o.quiet && o.watch { die(.usage, "error: --quiet cannot be combined with --watch") }
    if o.quiet && o.json { die(.usage, "error: --quiet cannot be combined with --format json") }
    return o
}

func printUsage() {
    print("""
    laptop-level — shows your MacBook's tilt, relative to gravity.

    Reports two angles. It does NOT judge "straight": it can't sense skew/yaw
    or the table's own slope (see docs/design.md).

      L/R  left/right tilt (roll),  + = right
      B/F  back/front tilt (pitch), + = back

    USAGE:
      laptop-level [--watch] [--format json] [--color auto|always|never]
                   [--quiet [--threshold <deg>] [--metric axis|magnitude]]

      --watch     live ASCII bubble level (Ctrl+C to stop)
      --quiet     no output; exit 0 if within --threshold, else 1 (for scripts)

    EXIT CODES:
      0 ok / within tolerance   1 over tolerance (--quiet)
      2 no sensor   3 read timeout   64 usage error
    """)
}

// MARK: - Shared helpers

/// Combined tilt magnitude under the chosen metric.
func deviation(pitch: Double, roll: Double, metric: String) -> Double {
    metric == "magnitude" ? hypot(pitch, roll) : max(abs(pitch), abs(roll))
}

func resolveColor(_ mode: ColorMode) -> Bool {
    switch mode {
    case .always: return true
    case .never: return false
    case .auto: return isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    }
}

func jsonLine(pitch: Double, roll: Double, opts: Options, straight: Bool) -> String {
    let lr = String(format: "%.3f", tidyDeg(roll))     // left/right = roll
    let bf = String(format: "%.3f", tidyDeg(pitch))    // back/front = pitch
    let t = String(format: "%g", opts.threshold)
    // lr/bf are the measurement; threshold/straight are an opt-in convenience
    // for scripts (compared only via --quiet for humans).
    return "{\"lr_deg\":\(lr),\"bf_deg\":\(bf),\"threshold_deg\":\(t),\"metric\":\"\(opts.metric)\",\"straight\":\(straight)}"
}

// MARK: - Watch mode

func runWatch(_ opts: Options, _ offset: ReferenceOffset) -> Never {
    let isTTY = isatty(STDOUT_FILENO) != 0
    let color = resolveColor(opts.color)
    let sensor: MotionSensor
    do { sensor = try MotionSensor() }
    catch { die(.noSensor, "error: no readable motion sensor (unsupported hardware or blocked SPI)") }

    signal(SIGINT) { _ in interrupted = 1 }
    // Foundation ignores SIGPIPE, so a closed reader (e.g. `| head`) would spin
    // forever. Restore default disposition: exit when the pipe breaks.
    signal(SIGPIPE, SIG_DFL)
    let frameHeight = Renderer.interiorHeight + 4   // box(5) + status + hint = 7
    var first = true
    if isTTY && !opts.json { print("\u{001B}[?25l", terminator: "") }   // hide cursor

    while interrupted == 0 {
        guard let raw = sensor.currentTilt() else { usleep(200_000); continue }
        let pitch = (raw.pitch - offset.pitch0) + 0.0
        let roll = (raw.roll - offset.roll0) + 0.0

        if opts.json {
            let straight = deviation(pitch: pitch, roll: roll, metric: opts.metric) <= opts.threshold
            print(jsonLine(pitch: pitch, roll: roll, opts: opts, straight: straight))
        } else if isTTY {
            if !first { print("\u{001B}[\(frameHeight)A", terminator: "") }
            let lines = Renderer.frame(pitch: pitch, roll: roll, color: color)
            for line in lines { print("\r\u{001B}[2K" + line) }   // clear line, then content
            first = false
        } else {
            print(Renderer.readout(pitch: pitch, roll: roll))
        }
        // Flush each frame: piped stdout is block-buffered, which would both
        // delay output and defer the broken-pipe SIGPIPE until the buffer fills.
        fflush(stdout)
        usleep(500_000)
    }
    if isTTY && !opts.json { print("\u{001B}[?25h", terminator: "") }   // restore cursor
    exit(0)
}

// MARK: - Main

let opts = parse(Array(CommandLine.arguments.dropFirst()))

let model = currentModel()
guard let offset = modelOffsets[model] else {
    die(.noSensor, "error: model \(model.isEmpty ? "<unknown>" : model) has no calibration entry; unsupported")
}

if opts.watch { runWatch(opts, offset) }

// Single-shot
let raw: Tilt
do {
    raw = try MotionSensor.read()
} catch SensorError.unavailable {
    die(.noSensor, "error: no readable motion sensor (unsupported hardware or blocked SPI)")
} catch SensorError.timeout {
    die(.timeout, "error: sensor present but no stable reading in time")
} catch {
    die(.noSensor, "error: \(error)")
}

let pitch = (raw.pitch - offset.pitch0) + 0.0   // `+ 0.0` collapses -0.0 → 0.0
let roll = (raw.roll - offset.roll0) + 0.0

// --quiet is the only verdict path: silent, exit reflects the threshold. The
// default output just reports the measurement and exits 0.
if opts.quiet {
    let straight = deviation(pitch: pitch, roll: roll, metric: opts.metric) <= opts.threshold
    exit(straight ? Exit.straight.rawValue : Exit.tilted.rawValue)
}

if opts.json {
    let straight = deviation(pitch: pitch, roll: roll, metric: opts.metric) <= opts.threshold
    print(jsonLine(pitch: pitch, roll: roll, opts: opts, straight: straight))
} else {
    print(Renderer.readout(pitch: pitch, roll: roll))
}

exit(Exit.straight.rawValue)
