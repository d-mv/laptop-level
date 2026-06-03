import Foundation

/// Per-model reference pose. The SPU accelerometer carries a large constant
/// mounting offset, so "straight" is defined as deviation from these values.
///
/// ⚠️ Mac14,5 value captured in an arbitrary pose during the SPI spike — it is a
/// PLACEHOLDER and must be re-measured on a verified-level surface. See
/// docs/design.md → "Calibration / reference pose".
struct ReferenceOffset {
    let pitch0: Double
    let roll0: Double
}

let modelOffsets: [String: ReferenceOffset] = [
    "Mac14,5": ReferenceOffset(pitch0: 49.7, roll0: 7.1),
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
