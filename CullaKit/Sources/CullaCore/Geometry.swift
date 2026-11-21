import CoreGraphics
import Foundation

/// A point in 0...1 image coordinates, origin at the top-left corner.
public struct UnitPoint: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in 0...1 image coordinates, origin at the top-left corner.
public struct UnitRect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let full = UnitRect(x: 0, y: 0, width: 1, height: 1)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Builds a unit rectangle from a pixel rectangle whose origin is the top-left corner.
    public init(pixelRect: CGRect, imageWidth: Int, imageHeight: Int) {
        let w = Double(max(imageWidth, 1))
        let h = Double(max(imageHeight, 1))
        self.init(
            x: Double(pixelRect.minX) / w,
            y: Double(pixelRect.minY) / h,
            width: Double(pixelRect.width) / w,
            height: Double(pixelRect.height) / h
        )
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: UnitPoint { UnitPoint(x: x + width / 2, y: y + height / 2) }
    public var area: Double { max(0, width) * max(0, height) }

    /// The rectangle in pixels, origin at the top-left corner.
    public func pixelRect(imageWidth: Int, imageHeight: Int) -> CGRect {
        CGRect(
            x: x * Double(imageWidth),
            y: y * Double(imageHeight),
            width: width * Double(imageWidth),
            height: height * Double(imageHeight)
        )
    }

    /// The part of the rectangle that lies inside the image.
    public func clamped() -> UnitRect {
        let x0 = min(max(x, 0), 1)
        let y0 = min(max(y, 0), 1)
        let x1 = min(max(maxX, 0), 1)
        let y1 = min(max(maxY, 0), 1)
        return UnitRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    public func union(_ other: UnitRect) -> UnitRect {
        let x0 = min(x, other.x)
        let y0 = min(y, other.y)
        let x1 = max(maxX, other.maxX)
        let y1 = max(maxY, other.maxY)
        return UnitRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public func intersection(_ other: UnitRect) -> UnitRect? {
        let x0 = max(x, other.x)
        let y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX)
        let y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return UnitRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Overlap of two rectangles as a share of their combined area, 0 (apart) to 1 (identical).
    public func intersectionOverUnion(with other: UnitRect) -> Double {
        guard let overlap = intersection(other) else { return 0 }
        let combined = area + other.area - overlap.area
        return combined > 0 ? overlap.area / combined : 0
    }

    /// Shrinks (positive fraction) or grows (negative fraction) the rectangle around its centre.
    public func inset(byFraction fraction: Double) -> UnitRect {
        let dx = width * fraction
        let dy = height * fraction
        return UnitRect(x: x + dx, y: y + dy, width: width - 2 * dx, height: height - 2 * dy)
    }
}
