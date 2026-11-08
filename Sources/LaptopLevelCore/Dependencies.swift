import Foundation

/// A source of smoothed tilt readings (the real SPU sensor, or a test fake).
protocol TiltSource: AnyObject {
    /// Current reading, or nil if the sensor didn't answer in time.
    func currentTilt() -> Tilt?
}

/// Everything the CLI touches outside its own logic: hardware, terminal,
/// clock, and signals. Tests pass fakes; `main.swift` passes `.live`.
public struct Dependencies {
    var model: () -> String
    var makeSensor: () throws -> TiltSource
    var out: (String) -> Void
    var err: (String) -> Void
    var flush: () -> Void
    var isTTY: Bool
    var environment: [String: String]
    var now: () -> Date
    var sleep: (UInt32) -> Void
    var installSignalHandlers: () -> Void

    public static var live: Dependencies {
        Dependencies(
            model: { sysctlString("hw.model") },
            makeSensor: { try HIDMotionSensor() },
            out: { fputs($0, stdout) },
            err: { fputs($0, stderr) },
            flush: { fflush(stdout) },
            isTTY: isatty(STDOUT_FILENO) != 0,
            environment: ProcessInfo.processInfo.environment,
            now: { Date() },
            sleep: { usleep($0) },
            installSignalHandlers: {
                // Ctrl+C, `kill`, and a closed terminal all end the watch loop
                // cleanly, so the cursor is always restored.
                for sig in [SIGINT, SIGTERM, SIGHUP] { signal(sig) { _ in interrupted = 1 } }
                // Foundation ignores SIGPIPE, so a closed reader (`| head`)
                // would spin forever. Default action: exit when the pipe breaks.
                signal(SIGPIPE, SIG_DFL)
            }
        )
    }
}

/// Reads a string sysctl (e.g. `hw.model` → "Mac14,5"); "" if it doesn't exist.
func sysctlString(_ name: String) -> String {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}
