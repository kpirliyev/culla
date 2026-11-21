import CoreGraphics
import Foundation

/// Turns an eye's outline into a single openness number.
public enum EyeGeometry {
    /// Height of the eye outline divided by its width.
    ///
    /// The width is the longest distance between any two outline points, which runs corner to
    /// corner. The height is measured at right angles to that line, so a tilted head gives the
    /// same result as an upright one. An open eye is roughly 0.3 and above; a shut eye is a
    /// thin sliver well below that.
    ///
    /// Points must be in pixels, not in coordinates normalised to a non-square box.
    public static func openness(of outline: [CGPoint]) -> Double? {
        guard outline.count >= 4 else { return nil }

        var width = 0.0
        var start = outline[0]
        var end = outline[0]
        for i in 0..<outline.count {
            for j in (i + 1)..<outline.count {
                let distance = hypot(Double(outline[i].x - outline[j].x), Double(outline[i].y - outline[j].y))
                if distance > width {
                    width = distance
                    start = outline[i]
                    end = outline[j]
                }
            }
        }
        guard width > 1e-6 else { return nil }

        let axisX = Double(end.x - start.x) / width
        let axisY = Double(end.y - start.y) / width
        var lowest = Double.infinity
        var highest = -Double.infinity
        for point in outline {
            let across = -Double(point.x - start.x) * axisY + Double(point.y - start.y) * axisX
            lowest = min(lowest, across)
            highest = max(highest, across)
        }
        return (highest - lowest) / width
    }
}
