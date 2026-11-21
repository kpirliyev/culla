import Foundation

/// Measures how much of an image is clipped to white or black.
public enum ExposureMeter {
    public struct Clipping: Sendable, Hashable {
        /// Share of pixels at or above the highlight level.
        public var highlights: Double
        /// Share of pixels at or below the shadow level.
        public var shadows: Double
    }

    public static func measure(_ image: GrayImage, highlightLevel: UInt8 = 250, shadowLevel: UInt8 = 5) -> Clipping {
        var histogram = [Int](repeating: 0, count: 256)
        image.pixels.withUnsafeBufferPointer { pixels in
            histogram.withUnsafeMutableBufferPointer { bins in
                for value in pixels {
                    bins[Int(value)] += 1
                }
            }
        }
        let total = Double(max(image.pixels.count, 1))
        let bright = histogram[Int(highlightLevel)...].reduce(0, +)
        let dark = histogram[...Int(shadowLevel)].reduce(0, +)
        return Clipping(highlights: Double(bright) / total, shadows: Double(dark) / total)
    }
}
