import Foundation

/// Per-model reference pose. The SPU accelerometer carries a large constant
/// mounting offset, so "straight" is defined as deviation from these values.
///
/// Values are in the convention of `MotionSensor.tilt(x:y:z:)`.
///
/// ⚠️ Mac14,5 value comes from the spike's raw sample (x≈1000, y≈9600, z≈8080),
/// taken in an arbitrary pose — it is a PLACEHOLDER and must be re-measured on
/// a verified-level surface. See docs/design.md → "Calibration / reference pose".
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
    "Mac14,5": ReferenceOffset(pitch0: 49.9, roll0: 4.6),
]

/// Reads `hw.model` (e.g. "Mac14,5").
func currentModel() -> String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &buf, &size, nil, 0)
    return String(cString: buf)
}
