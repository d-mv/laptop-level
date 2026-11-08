# `laptop-level` — macOS CLI Design Spec

## Overview

A Swift CLI tool that reads the MacBook's built-in accelerometer and **displays
its tilt** as two angles — left/right (L/R) and back/front (B/F). It does *not*
pronounce a verdict like "straight"; it reports the measurement and lets the
human read it (see [Fundamental sensing limits](#fundamental-sensing-limits) for
why a verdict would be dishonest). Targets Apple Silicon Macs. Single binary, no
third-party dependencies, public IOKit API only.

> **Hardware reality (verified on Mac14,5 / M2 Max, macOS 26.6):**
> Apple Silicon laptops expose an accelerometer + gyro through the **Sensor
> Processing Unit (SPU)** as IOKit HID devices. **CoreMotion is not an
> option** — its motion classes are `API_UNAVAILABLE(macos)`. The tool reads the
> accelerometer's raw HID input reports with the public `IOHIDManager` API.

---

## Sensor Access

### Why not CoreMotion

`import CoreMotion` compiles, but every motion class (`CMMotionManager`,
`CMDeviceMotion`, `CMAltimeter`, …) is marked `API_UNAVAILABLE(macos)`.
Separately, `CMAttitude` is rotation relative to where tracking *started*, not
tilt from horizontal. We want tilt relative to **gravity**, so we read the raw
gravity vector and derive the angles ourselves.

### The path: raw HID input reports via `IOHIDManager`

The SPU accelerometer is an `AppleSPUHIDDevice` with:

| Property | Value |
|---|---|
| `PrimaryUsagePage` | `0xff00` (vendor-defined) |
| `PrimaryUsage` | `0x03` |
| `Transport` | `"SPU"` (the internal keyboard/trackpad also uses usage 3, on `FIFO`) |
| `MaxInputReportSize` | `22` |

```
IOHIDManagerCreate
  → match { PrimaryUsagePage: 0xff00, PrimaryUsage: 3, Transport: "SPU" }
  → IOHIDManagerOpen → IOHIDDeviceRegisterInputReportCallback → schedule on run loop
  → each 22-byte report: x, y, z = little-endian Int32 at offsets 6, 10, 14
                         gravity (g) = value / 65536
```

- Reports arrive at ~100 Hz once the device is open; no root, no entitlement.
- If no report arrives within 300 ms, the tool sets
  `SensorPropertyReportingState = 1`, `SensorPropertyPowerState = 1` and
  `ReportInterval = 10000` on the usage-3 `AppleSPUHIDDriver`, then waits again.
  (It is not yet known whether a freshly booted Mac needs this; on the test
  machine reports flowed without it, but only after it had been set once in that
  boot.)
- Flat on a desk the sensor reads g ≈ (0.00, 0.01, −0.99): it lies flat in the
  **base**, with Z pointing down.

### ⚠️ History: the first sensor path read the wrong sensor

The original implementation used the private `IOHIDEventSystemClient` SPI and
asked services for HID event **type 12**, believing it was the accelerometer.
Type 12 is `AmbientLightSensor` (accelerometer is 13). The only service that
answered was `AppleSPUVD6286` — an ambient light / colour sensor — so the tool
was reporting light-sensor channels as x/y/z. That explains the old symptoms: a
constant "≈50° mounting offset", a "magnitude" that drifted with room light,
and readings that ignored both lid angle and physical tilt. No service answers
type 13 through that SPI, so it was dropped entirely.

Lesson: confirm a sensor by **moving the hardware**, not by getting stable
numbers back.

### Axis orientation (measured)

Measured on Mac14,5 by lifting edges while logging raw reports (2026-11-08):

| Pose | g (x, y, z) | L/R | B/F |
|---|---|---|---|
| Flat on desk | (+0.004, +0.015, −0.982) | +0.2° | +0.9° |
| Left edge lifted (right lower) | (+0.137, +0.016, −0.968) | **+8.0°** | +0.9° |
| Back edge lifted (front lower) | (+0.006, −0.315, −0.928) | +0.4° | **−18.7°** |

So **+X = right edge lower** and **+Y = back edge lower**, which matches the
CLI's labels directly (`L/R` `+` = right, `B/F` `+` = back). No axis remapping.

### Deriving pitch & roll from gravity

Given gravity `(gx, gy, gz)` (units cancel):

```
roll  = atan2(gx, hypot(gy, gz)) * 180/π    // L/R, + = right edge lower
pitch = atan2(gy, hypot(gx, gz)) * 180/π    // B/F, + = back edge lower
```

then subtract the per-model `(pitch₀, roll₀)` and wrap to (−180°, 180°]. Each
angle is measured against the other two components, so it stays accurate when
the laptop is tilted on both axes.

## Calibration / reference pose

**Decision: hard-coded per-model offset table.** No user calibration flag. The
tool looks up `hw.model` (via `sysctlbyname`) in a built-in table of
`(pitch₀, roll₀)` reference offsets and reports the deviation. Unrecognized
model → exit `2` (unsupported).

```swift
// ModelOffsets.swift — extend as models are measured on a known-level surface
let modelOffsets: [String: ReferenceOffset] = [
    "Mac14,5": ReferenceOffset(pitch0: 0, roll0: 0),   // NOT yet measured level
]
```

> ⚠️ Because the sensor lies flat in the base, the offset is only board
> mounting tolerance (expected well under 1°). `Mac14,5` is `(0, 0)` until it
> is measured on a surface verified with a real bubble level. On an ordinary
> desk it read about L/R +0.2°, B/F +0.9°, but that includes the desk's slope.

---

## Fundamental sensing limits

This is *why the tool only displays angles and never claims "straight."* A
resting accelerometer cannot answer "is the laptop standing perfectly straight
on the table." Two independent walls:

1. **Only 2 of 3 orientation DOF are observable.** At rest the accelerometer
   sees one thing: the **gravity vector**. That fixes **pitch and roll** (tilt)
   but reveals **nothing about yaw** — rotation about the vertical axis. Spin
   the laptop flat like a turntable and the reading is unchanged. So "straight"
   in the sense of *squared-up / not skewed to the desk* is invisible here.
   - The **gyro** can't fix this: it measures angular *rate* (≈0 at rest;
     integrating drifts without bound). It tracks change, never absolute heading.
   - A **magnetometer** would give heading — but **this Mac has none** (no
     magnetometer in the IORegistry). And even a compass gives north, not your
     desk edge. **Conclusion: yaw-straightness is unmeasurable on this hardware.**

2. **The measured tilt is relative to gravity, not the table.** `pitch=roll=0`
   means "level w.r.t. gravity," which equals "flat on the table" *only if the
   table is horizontal*. On a sloped desk, a flush laptop reads tilted. The
   sensor has no table reference.

The sensor is in the base, so the reading describes the base and does not
change with screen angle.

A physical bubble level shares both walls and nobody objects, because "level"
is understood as *relative to gravity*. So the honest design is: **report the
two gravity-relative angles, label their directions, and let the user judge.**
Hence no "Straight/Tilted" verdict in the default output.

---

## CLI Interface

### Basic usage

```
laptop-level
```

Single-shot read. Prints the two angles on one line and exits.

### Flags

| Flag | Description |
|---|---|
| `--watch` | Continuous mode — live in-place box at ~20 fps; JSONL / plain lines every 500 ms |
| `--format json` | Output as JSON. With `--watch`, emits one JSON object per line (JSONL) |
| `--color auto\|always\|never` | ANSI color for the watch bubble (default: `auto` — TTY only) |
| `--quiet` | No output; **the only** pass/fail path — exit by `--threshold` (for scripts) |
| `--threshold <deg>` | Tolerance for `--quiet` (default: `5`) |
| `--metric axis\|magnitude` | How `--quiet` applies the tolerance (default: `axis`) |
| `--help` | Usage |

> `--threshold`/`--metric` exist **only** to support the `--quiet` scripting
> gate. The default and `--watch` outputs never compare to a threshold — they
> just show the measurement.

### Flag interaction rules

- `--quiet` is **incompatible with `--watch`** → usage error, exit `64`.
- `--quiet` + `--format json` → usage error, exit `64` (`--quiet` means no stdout).
- `--format json --watch` is allowed and emits **JSONL** (one object per
  refresh), not the boxed renderer.
- Unknown flags / malformed `--threshold` value → usage error, exit `64`.

### Tolerance semantics (`--quiet` only)

For the scripting gate, "within tolerance" for a two-axis tilt is:

- `axis` (default): `|L/R| ≤ t` **and** `|B/F| ≤ t`.
- `magnitude`: `hypot(L/R, B/F) ≤ t` (combined tilt).

---

## Output Design

### Single-shot (default)

```
L/R   -0.018°   B/F   -0.524°
```

- Two signed angles, no verdict. Reported to 3 decimal places. `L/R` = roll (`+` = right), `B/F` = pitch
  (`+` = back). Direction labels/signs are pending the physical axis
  calibration (see Sensor Access).
- Fixed-width numeric columns (sign always printed, width-padded) — numbers
  never jump.
- Plain ASCII, one line, trailing newline (clean for shell capture).

### Watch mode (`--watch`)

Live **ASCII bubble level**, updated in-place via ANSI cursor moves
(cursor-up + erase line). No ncurses dependency.

```
┌───────────────────────────┐
│                           │
│                           │
│                           │
│                           │
│           · ● ·           │   ← bubble moves with tilt
│                           │
│                           │
│                           │
│                           │
└───────────────────────────┘
L/R   -0.157°   B/F   -0.327°
Press Ctrl+C to stop
```

- Bubble `●` moves within the box proportional to L/R and B/F; full deflection
  at `fullScaleDeg = 15°`. The `·` marks are the center target.
- **Color is a magnitude scale, not a verdict:** green near center → yellow →
  red toward the edge (thirds of full scale). It visualizes *how far off level*,
  not "good/bad".
- Box is 29×11 chars, redrawn in-place ~20 times per second (one write per
  frame, each line overwritten then its tail cleared, so no flicker). Resolution ≈ 1.15°/column
  (L/R) and 3.75°/row (B/F); the bubble leaves the center row at |B/F| ≥ ~1.9°.
- If stdout is **not a TTY**, `--watch` falls back to plain readout lines
  (one per refresh) instead of cursor manipulation.

### Color (`--color`, default `auto`)

Applies to the watch bubble only (the single-shot readout is plain).

- `auto`: color only when stdout is a TTY **and** `NO_COLOR` is unset.
- `always` / `never`: force on/off.
- ANSI: green `\u{001B}[32m`, yellow `\u{001B}[33m`, red `\u{001B}[31m`,
  reset `\u{001B}[0m`.

### JSON output (`--format json`)

Single-shot — one object (watch → JSONL, same shape per refresh):

```json
{
  "lr_deg": -0.026,
  "bf_deg": -0.494,
  "threshold_deg": 5,
  "metric": "axis",
  "straight": true
}
```

`lr_deg`/`bf_deg` are the measurement. `threshold_deg`/`metric`/`straight` are a
convenience for scripts that *do* want a pass/fail — `straight` is the same
tolerance check `--quiet` uses. Human-facing output never shows it.

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Read OK (default/JSON), or within tolerance under `--quiet` |
| `1` | `--quiet` only: tilt exceeded `--threshold` |
| `2` | No usable sensor (Intel/unsupported model, or SPU accel device absent/unopenable) |
| `3` | Sensor present but no stable reading within timeout (single-shot), or it stopped answering for 2 s (`--watch`) |
| `64` | Usage error (bad flags / incompatible flag combination) — `EX_USAGE` |

Without `--quiet`, a successful read always exits `0` — the tool reports the
measurement and does not judge. Exit `1` happens **only** under `--quiet`, the
opt-in scripting gate. Code `2` is the catch-all for "can't read the hardware";
a human-readable reason is written to **stderr**.

---

## Implementation Notes

### File structure

```
laptop-level/
├── Package.swift                 # SwiftPM manifest (macOS 12+, links IOKit)
├── Sources/laptop-level/
│   ├── main.swift                # Arg parsing, offset subtract, watch loop, exit codes
│   ├── SensorReader.swift        # SPU accel via IOHIDManager reports → gravity → tilt
│   ├── ModelOffsets.swift        # hw.model → reference offset table, angle wrapping
│   └── Renderer.swift            # ASCII bubble level, ANSI/color
└── Tests/laptop-levelTests/
    └── TiltTests.swift           # report decoding, tilt vs logged samples, wrap, renderer
```

**Status:** single-shot readout (plain + JSON), the `--quiet` gate and `--watch`
verified against live hardware with physical tilt on Mac14,5. Reference offset
still unmeasured (see above).

### Package.swift

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "laptop-level",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "laptop-level",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .testTarget(name: "laptop-levelTests", dependencies: ["laptop-level"]),
    ]
)
```

### SensorReader

- Open the SPU accel device with `IOHIDManager` (see Sensor Access) and register
  an input-report callback on the current run loop.
- `currentTilt()` drains queued reports, waits up to 250 ms for one more so
  the value is current, then returns the tilt of the **mean gravity vector over
  the last 25 reports (~250 ms)**. Averaging cut frame-to-frame jitter from
  ~±0.14° (single samples) to ~±0.01° on Mac14,5, for ~0.1 s of lag. Vectors
  are averaged, not angles, so it stays correct at any tilt. Decoding (`gravity(fromReport:)`) and angle math
  (`tilt(x:y:z:)`) are pure functions covered by tests. A non-finite or zero
  vector counts as "no sample", so NaN never reaches the output.
- Subtract the model offset with `ReferenceOffset.deviation(of:)`, which wraps
  both angles to (-180°, 180°].
- **Settle:** discard readings for the first 300 ms, in both single-shot and
  `--watch`. Single-shot then reports once two consecutive samples (50 ms
  apart) agree within 0.5°.
- **Timeout:** single-shot with no stable reading within 2 s → exit `3`;
  `--watch` with no sample for 2 s → restore cursor, exit `3`.
- Device missing or can't be opened → exit `2` with a stderr reason.

Tunables `MotionSensor.settleMs = 300`, `timeoutMs = 2000`, `windowSize = 25`,
and the watch intervals (50 ms box, 500 ms JSONL/plain) are fixed constants by
design (not flags).

### Renderer (watch mode)

- Detect TTY (`isatty(STDOUT_FILENO)`); non-TTY → plain line fallback.
- Hide the cursor on start; each later frame moves up `interiorHeight + 4`
  lines, then clears and redraws each line.
- `SIGINT`, `SIGTERM` and `SIGHUP` set a flag that ends the loop, so the cursor
  is always restored (exit `0`). `SIGPIPE` keeps its default action so a closed
  pipe ends the process.

### Arg parsing

No external lib. `parse()` in `main.swift` walks `CommandLine.arguments` once;
each value flag reads the next argument and is validated on the spot
(`--threshold` must be a number ≥ 0). Flag combinations are checked after the
walk; any error exits `64` with a message on stderr.

---

## Build & Install

```bash
# Build (the linker ad-hoc signs arm64 binaries; no extra codesign step needed)
swift build -c release

# Test
swift test

# Run
.build/release/laptop-level

# Install to PATH
cp .build/release/laptop-level /usr/local/bin/
```

---

## Scripting example

```bash
# Fail a script if the laptop is tilted
laptop-level --quiet || { echo "Please level the laptop first"; exit 1; }
```

---

## Bring-up checklist (new model)

1. Confirm the device: `ioreg -r -c AppleSPUHIDDevice -l | grep -E 'PrimaryUsage|MaxInputReportSize'`
   shows usage page `65280`, usage `3`, report size `22`.
2. **Move the hardware**: log raw reports while lifting the left edge and the
   back edge; confirm the axes and signs match the table above.
3. Measure the reference offset on a bubble-level-verified surface and add it
   to `modelOffsets`.

---

## Out of scope

- **Any "straight on the table" verdict** — unmeasurable (see
  [Fundamental sensing limits](#fundamental-sensing-limits)). The tool shows
  angles; the human judges.
- **Skew / yaw / squareness to the desk** — physically unobservable (no
  magnetometer; accelerometer is yaw-blind).
- **Table-slope compensation** — no table reference exists.
- Intel Mac support (different/likely-absent sensor path)
- GUI / menu bar app
- User-facing calibration (offsets are measured once per model, see above)
- Logging / history
- App Store distribution
