# laptop-level

A macOS CLI that reads the MacBook's built-in accelerometer and **shows its
tilt** as two angles — left/right and back/front. Apple Silicon only.

It deliberately does **not** claim the laptop is "straight": a resting
accelerometer can't sense skew/yaw or the table's own slope, so it reports the
measurement and lets you judge — like a bubble level. See
[`docs/design.md` → Fundamental sensing limits](docs/design.md).

> Reads the Sensor Processing Unit (SPU) accelerometer's raw HID reports through
> the public `IOHIDManager` API — CoreMotion is unavailable on macOS. No root
> needed. See [`docs/design.md`](docs/design.md) for the full design and the
> hardware investigation behind it.

## Build

```bash
swift build -c release
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
│                           │
│                           │
│                           │
│           · ● ·           │
│                           │
│                           │
│                           │
│                           │
└───────────────────────────┘
L/R   -0.157°   B/F   -0.327°
Press Ctrl+C to stop
```

Exit codes: `0` ok (or within tolerance under `--quiet`) · `1` over tolerance
(`--quiet` only) · `2` no/unsupported sensor · `3` read timeout · `64` usage error.

## Status

- ✅ Single-shot readout (`L/R`/`B/F`, plain / JSON), `--quiet` scripting gate,
  and `--watch` live bubble level on Mac14,5 (M2 Max). Sensor decoding and
  directions verified by physically tilting the laptop. Directions: `L/R +` =
  right edge lower, `B/F +` = back edge lower.
- ⚠️ Only `Mac14,5` has a calibration entry; other models exit `2`. Its offset
  is `(0, 0)` — not yet measured on a bubble-level-verified surface (expected
  error well under 1°).
- ℹ️ Versions before Nov 2026 read the ambient light sensor by mistake and did
  not measure tilt at all (see design doc → Sensor Access → History).

## Development

```bash
git config core.hooksPath .githooks   # once per clone: enable the git hooks
scripts/test-coverage.sh              # tests + 100% coverage gate
scripts/lint.sh                       # lint (swift format, ships with Swift 6)
scripts/check-format.sh               # format check
```

- `pre-commit`: format check, lint, tests with the 100% coverage gate.
- `pre-push`: release build.

All checks are local; there is no hosted CI. Details:
[`docs/design.md` → Development](docs/design.md#development).
