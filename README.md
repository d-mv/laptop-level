# laptop-level

A macOS CLI that reads the MacBook's built-in accelerometer and **shows its
tilt** as two angles — left/right and back/front. Apple Silicon only.

It deliberately does **not** claim the laptop is "straight": a resting
accelerometer can't sense skew/yaw or the table's own slope, so it reports the
measurement and lets you judge — like a bubble level. See
[`docs/design.md` → Fundamental sensing limits](docs/design.md).

> Reads the Sensor Processing Unit (SPU) accelerometer via the **private**
> `IOHIDEventSystemClient` SPI — CoreMotion is unavailable on macOS. See
> [`docs/design.md`](docs/design.md) for the full design and the hardware
> investigation behind it.

## Build

```bash
swift build -c release
codesign -s - .build/release/laptop-level   # ad-hoc sign for local use
.build/release/laptop-level
```

## Usage

```bash
laptop-level                      # one-shot: L/R and B/F angles
laptop-level --watch              # live ASCII bubble level (Ctrl+C to stop)
laptop-level --format json        # machine-readable (JSONL under --watch)
laptop-level --color never        # watch bubble color: auto|always|never
laptop-level --quiet              # no output; exit 0/1 vs --threshold (scripts)
laptop-level --quiet --threshold 2 --metric magnitude
```

Default output (`L/R` = left/right tilt, `+` = right · `B/F` = back/front,
`+` = back):

```
L/R   -0.026°   B/F   -0.494°
```

`--watch`:

```
┌───────────────────────────┐
│                           │
│           · ● ·           │
│                           │
└───────────────────────────┘
L/R   -0.026°   B/F   -0.494°
Press Ctrl+C to stop
```

Exit codes: `0` ok (or within tolerance under `--quiet`) · `1` over tolerance
(`--quiet` only) · `2` no/unsupported sensor · `3` read timeout · `64` usage error.

## Status

- ✅ Single-shot readout (`L/R`/`B/F`, plain / JSON) + `--quiet` scripting gate,
  verified on Mac14,5 (M2 Max).
- ✅ `--watch` live ASCII bubble level: in-place TTY redraw, JSONL when piped,
  plain non-TTY fallback, clean SIGINT/SIGPIPE handling.
- ⚠️ Only `Mac14,5` has a calibration entry; other models exit `2`. The offset
  is a placeholder pending a verified-level measurement, and it's unconfirmed
  whether the sensor is base- or lid-mounted (see design doc).
