import Foundation

/// Per-model reference pose: what the sensor reads on a truly level surface.
/// Values are in the convention of `Accel.tilt(_:)`.
///
/// The accelerometer lies flat in the base, so offsets are small (board
/// mounting tolerance only).
///
/// ⚠️ Mac14,5 is set to (0, 0) — NOT yet measured on a verified-level surface.
/// On an ordinary desk it read about L/R +0.3°, B/F +0.8°, but that includes
/// the desk's own slope. See docs/design.md → "Calibration / reference pose".
struct ReferenceOffset {
    let pitch0: Double
    let roll0: Double

    /// Raw angles minus this reference, wrapped to (-180, 180].
    func deviation(of raw: Tilt) -> Tilt {
        Tilt(pitch: wrapDeg(raw.pitch - pitch0), roll: wrapDeg(raw.roll - roll0))
    }
}

/// Wrap an angle to (-180, 180]; also turns -0.0 into 0.0.
func wrapDeg(_ v: Double) -> Double {
    let w = v.truncatingRemainder(dividingBy: 360)
    let r = w > 180 ? w - 360 : (w <= -180 ? w + 360 : w)
    return r + 0.0
}

let modelOffsets: [String: ReferenceOffset] = [
    "Mac14,5": ReferenceOffset(pitch0: 0, roll0: 0)
]
