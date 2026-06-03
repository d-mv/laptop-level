import Foundation

// MARK: - Color (purely a visual intensity of how far off level — not a verdict)

private let reset = "\u{001B}[0m"

/// Green near level → yellow → red as tilt approaches full scale.
private func colorForFraction(_ f: Double) -> String {
    if f < 1.0 / 3 { return "\u{001B}[32m" }        // green
    else if f < 2.0 / 3 { return "\u{001B}[33m" }   // yellow
    else { return "\u{001B}[31m" }                  // red
}

func colorize(_ s: String, fraction: Double, _ on: Bool) -> String {
    on ? colorForFraction(fraction) + s + reset : s
}

// MARK: - Renderer

enum Renderer {
    static let interiorWidth = 27    // → box is 29 wide incl. borders
    static let interiorHeight = 3    // → box is 5 tall incl. borders
    static let fullScaleDeg = 15.0   // bubble pins to the edge at this tilt

    /// The measurement readout — no verdict, just the two signed angles.
    /// `L/R` is roll (+ = right), `B/F` is pitch (+ = back).
    static func readout(pitch: Double, roll: Double) -> String {
        String(format: "L/R %+8.3f\u{00B0}   B/F %+8.3f\u{00B0}", tidyDeg(roll), tidyDeg(pitch))
    }

    /// Bubble-level frame: box + readout + hint, as individual lines.
    static func frame(pitch: Double, roll: Double, color: Bool) -> [String] {
        let cx = interiorWidth / 2          // 13
        let cy = interiorHeight / 2         // 1
        let bx = cx + Int((clamp(roll / fullScaleDeg) * Double(cx)).rounded())
        let by = cy + Int((clamp(pitch / fullScaleDeg) * Double(cy)).rounded())
        let mag = min(1.0, hypot(roll, pitch) / fullScaleDeg)

        var lines: [String] = []
        lines.append("┌" + String(repeating: "─", count: interiorWidth) + "┐")
        for row in 0..<interiorHeight {
            var cells = [String](repeating: " ", count: interiorWidth)
            if row == cy {                              // center target guides
                cells[cx - 2] = "·"
                cells[cx + 2] = "·"
            }
            if row == by {                              // the bubble (wins overlap)
                cells[bx] = colorize("●", fraction: mag, color)
            }
            lines.append("│" + cells.joined() + "│")
        }
        lines.append("└" + String(repeating: "─", count: interiorWidth) + "┘")
        lines.append(readout(pitch: pitch, roll: roll))
        lines.append("Press Ctrl+C to stop")
        return lines
    }

    private static func clamp(_ v: Double) -> Double { max(-1.0, min(1.0, v)) }
}

/// Round to 3 decimals, squashing negative zero (shared with main).
func tidyDeg(_ v: Double) -> Double {
    let r = (v * 1000).rounded() / 1000
    return r == 0 ? 0 : r
}
