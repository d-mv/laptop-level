# `laptop-level` — macOS CLI Design Spec

## Overview

A Swift CLI tool that reads the MacBook's built-in accelerometer and **displays
its tilt** as two angles — left/right (L/R) and back/front (B/F). It does *not*
pronounce a verdict like "straight"; it reports the measurement and lets the
human read it (see [Fundamental sensing limits](#fundamental-sensing-limits) for
why a verdict would be dishonest). Targets Apple Silicon Macs. Single binary, no
third-party dependencies — but it links private system SPI (see
[Sensor Access](#sensor-access)).

> **Hardware reality (verified on Mac14,5 / M2 Max, macOS 26.4 SDK):**
> Apple Silicon laptops expose an accelerometer + gyro through the **Sensor
> Processing Unit (SPU)** as IOKit HID interfaces (`accel`, `gyro`,
> `devmotion6` under `AppleSPUHIDInterface`). **CoreMotion is not an option** —
> `CMMotionManager` and `CMAltimeter` are `API_UNAVAILABLE(macos)` and will not
> compile. The only way to read this sensor is the private `IOHIDEventSystemClient`
> SPI. This is undocumented, version-fragile, and requires a signed binary.
>
> **Spike status (proven, not theoretical):** a C spike against the private SPI
> reads live, stable 3-axis data and exits 0 — even unsigned in an interactive
> terminal. See [Spike results](#spike-results-proven) for the exact constants
> and the calibration consequence.

---

## Sensor Access

### Why not CoreMotion

`import CoreMotion` compiles, but every motion class (`CMMotionManager`,
`CMDeviceMotion`, `CMAltimeter`, …) is marked `API_UNAVAILABLE(macos)`. Using
`attitude.pitch`/`attitude.roll` is impossible on macOS — verified by a failed
build against the current SDK. The original design assumed an iOS API surface
that does not exist here.

Separately, `attitude` would have been the *wrong* quantity anyway: `CMAttitude`
is rotation relative to the reference frame captured when tracking *started*, not
absolute tilt from horizontal. We want tilt relative to **gravity**, so we read
the raw gravity vector and derive the angles ourselves.

### The viable path: `IOHIDEventSystemClient` SPI

The SPU accelerometer is enumerated as an `AppleSPUHIDInterface` with:

| Property | Value |
|---|---|
| `device_type` | `"accel"` |
| `device-usage-page` | `0xff00` (vendor-defined) |
| `device-usage` | `0x03` |

Read sequence (all symbols are **private SPI** — declared by hand, see below):

```
IOHIDEventSystemClientCreate(kCFAllocatorDefault)
  → set matching dict { PrimaryUsagePage: 0xff00, PrimaryUsage: 0x03 }   // the accel service
  → IOHIDEventSystemClientCopyServices() → pick the accel IOHIDServiceClientRef
  → IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeAccelerometer, 0, 0)
  → IOHIDEventGetFloatValue(event, field)   // field = (kIOHIDEventTypeAccelerometer << 16) + axis
```

Constants (`kIOHIDEventTypeAccelerometer = 12`; axes X=0, Y=1, Z=2) are not in
any public header. **These are now confirmed** on Mac14,5 by the spike (below) —
but re-verify on any untested OS/model before trusting them.

### Spike results (proven)

A standalone C spike (declared the six SPI symbols, linked `IOKit` +
`CoreFoundation`) produced:

- `IOHIDEventSystemClientCopyServices` returned 182 services; exactly one
  answered an accelerometer event.
- That service reports `PrimaryUsagePage = 0xff00`, **`PrimaryUsage = 0x04`**
  (note: the HID *event service* reports usage `0x04`, whereas the raw `accel`
  IORegistry node showed `device-usage 0x03` — match the **event** value `0x04`,
  or simply probe every service for an accel event and keep the one that
  answers).
- Live read: `raw(x≈1000, y≈9600, z≈8080)`, vector magnitude **≈ 12,500**
  (raw units, **not** normalized to 1 g — irrelevant for `atan2`, which uses
  ratios).
- ⚠️ **The raw scale is not stable.** A later read (2026-11-08) gave a
  magnitude of ≈ 1,700, drifting ±5% over a few seconds while the laptop sat
  still, with the angles steady to ~0.05°. Use the vector only for ratios —
  never treat its magnitude as g or use it for motion/sanity checks.
- Five samples over 1 s agreed to within ~0.1° (sensor is low-noise), while
  magnitude crept 12527 → 12594 — **confirming the warm-up settle delay is real
  and necessary.**
- Worked **unsigned** from an interactive terminal. Signing may still be needed
  for non-interactive/daemon contexts — keep the codesign step.

### Calibration consequence (decision needed)

At physical rest the sensor reads **pitch ≈ +49.9°, roll ≈ +4.6°** (current
formulas), not `(0, 0)`. The sensor carries a large constant **mounting
offset**: it sits in the **base**, rotated ~50° about its X axis (see
[Sensor location](#sensor-location-resolved-base-mounted)). Therefore
"straight" **cannot** be defined as raw `(0, 0)`; the tool must subtract a
**reference pose** `(pitch₀, roll₀)` captured when the machine is known-level,
and test the *deviation* `(pitch − pitch₀, roll − roll₀)` against the threshold.

## Calibration / reference pose

**Decision: hard-coded per-model offset table.** No user calibration flag. The
tool looks up `hw.model` (via `sysctlbyname`) in a built-in table of
`(pitch₀, roll₀)` reference offsets and reports the deviation. Unrecognized
model → exit `2` (unsupported), with a stderr hint to contribute a measurement.

```swift
// ModelOffsets.swift — extend as models are measured on a known-level surface
let modelOffsets: [String: ReferenceOffset] = [
    "Mac14,5": ReferenceOffset(pitch0: 49.9, roll0: 4.6),   // PLACEHOLDER, re-measure level
]
```

> ⚠️ The `Mac14,5` value above comes from the spike's raw sample, taken in an
> *arbitrary* pose, not a verified-level one. Re-measure on a known-flat
> surface (real bubble level) before trusting it. Offsets are only valid for
> the formulas in [Deriving pitch & roll](#deriving-pitch--roll-from-gravity);
> re-capture them if those formulas change.

### Sensor location (resolved: base-mounted)

The ~50° rest pitch first suggested a lid-mounted sensor, which would have made
a fixed offset useless. Tested on Mac14,5 (2026-11-08) by logging the
lid-angle sensor (HID usage page `0x20`, usage `0x8A`, feature report 1,
angle = little-endian bytes 1–2) next to the accelerometer while moving the
lid:

| Lid angle | B/F (pitch) |
|---|---|
| 112° | 49.5° |
| 54° | 49.5° |
| 7° | 48.0° |
| 99° | 49.8° |
| 110° | 49.7° |

A ~105° lid sweep moved pitch by ≤ 2° (the dip near closed is consistent with
hand pressure on the base). **The accelerometer is in the base**; the ~50° is a
fixed mounting rotation, so a per-model constant offset is valid.

### Axis orientation is undocumented → one-time calibration

The SPU does not document which physical axis is X/Y/Z or their sign. Bring-up
includes a manual mapping step: lay the laptop flat (gravity should read ≈ `1g`
on one axis, ≈ `0` on the other two), then tip it nose-down and right-side-down
to fix the sign of pitch and roll. Bake the resulting mapping in as constants.
This is *not* user-facing calibration (still out of scope) — it's a build-time
constant determined once.

### Deriving pitch & roll from gravity

Given the raw gravity vector `(gx, gy, gz)` (units cancel):

```
pitch = atan2(gy, gz) * 180/π               // back/front tilt (B/F)
roll  = atan2(gx, hypot(gy, gz)) * 180/π    // left/right tilt (L/R)
```

then subtract the per-model `(pitch₀, roll₀)`.

Why these and not `roll = atan2(gx, gz)`, `pitch = atan2(gy, hypot(gx, gz))`:
the sensor is rotated ~50° about X, so at rest gravity is split between Y and Z.
With `atan2(gx, gz)`, Z carries only cos 50° ≈ 0.65 of gravity, so roll was
inflated ~1.5× (a true 5° read as ~7.6°) and pitch leaked into roll; subtracting
angle offsets did not cancel that. Measuring pitch inside the Y–Z plane and
roll against the full Y–Z component makes the subtraction exact for a mounting
rotation about X (covered by `Tests/laptop-levelTests/TiltTests.swift`).

Sign conventions (`+` = right / back) are still pending the physical axis
calibration step above.

### Distribution constraints (consequences of using SPI)

- **Codesigning required.** Unsigned binaries may fail to attach to the HID
  service. Sign with a Developer ID (ad-hoc for local use).
- **Not App Store distributable** — uses private API.
- **Version-fragile** — the SPI and constants can change between macOS releases.
  Treat a clean failure (exit `2`) as expected on unverified OS versions.
- **No sandbox.** The tool cannot be sandboxed and reach the sensor.

---

## Fundamental sensing limits

This is *why the tool only displays angles and never claims "straight."* A
resting accelerometer (the only signal available — see below) cannot answer
"is the laptop standing perfectly straight on the table." Three independent
walls:

1. **Only 2 of 3 orientation DOF are observable.** At rest the accelerometer
   sees one thing: the **gravity vector**. That fixes **pitch and roll** (tilt)
   but reveals **nothing about yaw** — rotation about the vertical axis. Spin
   the laptop flat like a turntable and the reading is unchanged. So "straight"
   in the sense of *squared-up / not skewed to the desk* is mathematically
   invisible here.
   - The **gyro** can't fix this: it measures angular *rate* (≈0 at rest;
     integrating drifts without bound). It tracks change, never absolute heading.
   - A **magnetometer** would give heading — but **this Mac has none** (verified:
     no magnetometer in the IORegistry). And even a compass gives north, not
     your physical desk edge. True squareness needs vision. **Conclusion:
     yaw-straightness is unmeasurable on this hardware.**

2. **The measured tilt is relative to gravity, not the table.** `pitch=roll=0`
   means "level w.r.t. gravity," which equals "flat on the table" *only if the
   table is horizontal*. On a sloped desk, a flush laptop reads tilted and a
   "level" laptop isn't flush. The sensor has no table reference.

3. ~~The sensor is lid-mounted~~ — **disproved**: the sensor is in the base
   (see [Sensor location](#sensor-location-resolved-base-mounted)), so the tilt
   describes the base and does not change with screen angle.

A physical bubble level shares both remaining walls and nobody objects, because
"level" is understood as *relative to gravity*. So the honest design is: **report
the two gravity-relative angles, label their directions, and let the user judge.**
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
| `--watch` | Continuous mode — refresh every 500 ms, live in-place output |
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
- Box is 29×11 chars, redrawn in-place each frame. Resolution ≈ 1.15°/column
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
| `2` | No usable sensor (Intel/unsupported, SPU accel absent, or SPI/signing blocked attach) |
| `3` | Sensor present but no stable reading within timeout |
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
├── Package.swift          # SwiftPM manifest
└── Sources/
    ├── CHIDSPI/                  # C interop module exposing the private SPI
    │   ├── include/CHIDSPI.h         # hand-declared IOHIDEventSystemClient symbols
    │   └── shim.c                    # empty TU (SwiftPM needs ≥1 source)
    └── laptop-level/
        ├── main.swift            # Arg parsing, offset subtract, exit-code dispatch  ✅ built
        ├── SensorReader.swift    # SPU accel via IOHIDEventSystemClient, gravity→pitch/roll  ✅ built
        ├── ModelOffsets.swift    # hw.model → reference offset table  ✅ built
        └── Renderer.swift        # ASCII bubble level, ANSI/color, TTY  ✅ built
Tests/
└── laptop-levelTests/
    └── TiltTests.swift           # tilt math vs mounting offset, renderer geometry (`swift test`)
```

The private HID symbols cannot be imported from a public framework, so they are
re-declared in a small C interop module (`CHIDSPI`). It's a plain `.target`
(not `.systemLibrary`) — SwiftPM auto-generates the module map from the umbrella
header; the extern symbols resolve against the linked `IOKit` framework.

**Status:** fully implemented and verified against live hardware — single-shot
readout (`L/R`/`B/F`, plain + JSON), the `--quiet` scripting gate, **and**
`--watch` (live ASCII bubble level over a pty, JSONL when piped, plain non-TTY
fallback, SIGINT/SIGPIPE-clean).

### Package.swift

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "laptop-level",
    targets: [
        .target(name: "CHIDSPI"),   // Sources/CHIDSPI/{include/CHIDSPI.h, shim.c}
        .executableTarget(
            name: "laptop-level",
            dependencies: ["CHIDSPI"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
```

> Do **not** use `swiftSettings: [.unsafeFlags(["-framework", ...])]` — SwiftPM
> rejects `unsafeFlags` for consumable packages and it's the wrong mechanism.
> Link via `linkerSettings.linkedFramework`. CoreMotion is **not** linked.

### SensorReader

- Create `IOHIDEventSystemClient`, match the SPU accel service (usage page
  `0xff00`, usage `0x03`).
- Poll `IOHIDServiceClientCopyEvent` for `kIOHIDEventTypeAccelerometer`; read
  X/Y/Z float values; apply the calibrated axis mapping.
- **Settle:** discard readings for the first ~300 ms (sensor warm-up / debounce);
  require N consecutive samples within a small delta before reporting.
- **Timeout:** if no stable reading within 2 s → exit `3`.
- If the service can't be created/matched → exit `2` with a stderr reason.

Tunables `SETTLE_MS = 300`, `WATCH_INTERVAL_MS = 500`, `TIMEOUT_MS = 2000` are
fixed constants by design (not flags).

### Renderer (watch mode)

- Detect TTY (`isatty(STDOUT_FILENO)`); non-TTY → plain line fallback.
- Save cursor on first frame; subsequent frames move up N lines, erase, redraw.
- Trap `SIGINT` to restore the cursor and exit cleanly (exit `0`).

### Arg parsing

No external lib. Simple `CommandLine.arguments` walk; validate combinations up
front and exit `64` on any conflict:

```swift
// --threshold <value>
if let i = args.firstIndex(of: "--threshold"), args.indices.contains(i + 1) {
    guard let t = Double(args[i + 1]) else { usageError("invalid --threshold") }
    threshold = t
}
```

---

## Build, Sign & Install

```bash
# Build
swift build -c release

# Sign (required to attach to the HID sensor service; ad-hoc for local use)
codesign -s - .build/release/laptop-level

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

## Bring-up checklist (do this first)

1. Confirm `accel` exists: `ioreg -n accel -r -d 1` shows `device_type = "accel"`.
2. Spike the SPI read in isolation — print raw X/Y/Z; confirm `kIOHIDEventTypeAccelerometer`
   and field constants actually return live data.
3. Calibrate axis mapping + signs (flat, nose-down, right-down).
4. Only then build the CLI/renderer on top.

If step 2 fails on the target OS, the whole tool degrades to a clean exit `2`.

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
- User-facing calibration (build-time axis mapping is internal, see above)
- Logging / history
- App Store distribution (precluded by private SPI)
