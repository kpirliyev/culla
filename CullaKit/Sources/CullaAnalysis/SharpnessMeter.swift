import CullaCore
import Foundation

/// Sharpness of one region of an image.
public struct RegionSharpness: Sendable, Hashable {
    /// Contrast-normalised sharpness. Roughly 0 (smooth) to 100 and above (crisp fine detail).
    public var score: Double
    /// The same measurement without normalisation: plain edge strength in gray levels.
    public var edgeStrength: Double
    /// Centre of the sharpest tile in the region.
    public var peak: UnitPoint
}

/// Per-tile sharpness of a whole image, measured once and then queried for any region.
public struct SharpnessMap: Sendable {
    public let tileSize: Int
    public let columns: Int
    public let rows: Int
    public let imageWidth: Int
    public let imageHeight: Int
    /// Contrast-normalised sharpness per tile, row by row from the top.
    public let normalized: [Float]
    /// Edge strength per tile.
    public let raw: [Float]

    /// Sharpness of a region: the mean of its sharpest tenth of tiles.
    ///
    /// Taking the sharpest part rather than the average means a subject with a soft background,
    /// or a face whose cheeks are smooth, still reads as sharp when its detail is in focus.
    public func measure(in region: UnitRect) -> RegionSharpness {
        let area = region.clamped()
        let firstColumn = clampColumn(Int(area.x * Double(imageWidth)) / tileSize)
        let lastColumn = max(firstColumn, clampColumn((Int((area.maxX * Double(imageWidth)).rounded(.up)) - 1) / tileSize))
        let firstRow = clampRow(Int(area.y * Double(imageHeight)) / tileSize)
        let lastRow = max(firstRow, clampRow((Int((area.maxY * Double(imageHeight)).rounded(.up)) - 1) / tileSize))

        var indices: [Int] = []
        indices.reserveCapacity((lastRow - firstRow + 1) * (lastColumn - firstColumn + 1))
        for row in firstRow...lastRow {
            for column in firstColumn...lastColumn {
                indices.append(row * columns + column)
            }
        }

        let take = max(min(3, indices.count), indices.count / 10)
        let byScore = indices.sorted { normalized[$0] > normalized[$1] }.prefix(take)
        let byEdge = indices.map { raw[$0] }.sorted(by: >).prefix(take)
        let score = byScore.reduce(0.0) { $0 + Double(normalized[$1]) } / Double(take)
        let edge = byEdge.reduce(0.0) { $0 + Double($1) } / Double(take)

        let best = byScore.first ?? indices[0]
        let peak = UnitPoint(
            x: min(1, (Double(best % columns) + 0.5) * Double(tileSize) / Double(imageWidth)),
            y: min(1, (Double(best / columns) + 0.5) * Double(tileSize) / Double(imageHeight))
        )
        return RegionSharpness(score: score, edgeStrength: edge, peak: peak)
    }

    private func clampColumn(_ value: Int) -> Int { min(columns - 1, max(0, value)) }
    private func clampRow(_ value: Int) -> Int { min(rows - 1, max(0, value)) }
}

/// Measures how much fine detail an image holds, tile by tile.
///
/// Each tile gets the spread of its Laplacian (second derivative), which is large where edges
/// are crisp and small where they are soft. Dividing by the tile's own contrast makes a
/// low-contrast sharp texture and a high-contrast sharp edge score alike.
public enum SharpnessMeter {
    public static let tileSize = 32
    /// Tiles with less contrast than this (in gray levels) are treated as flat, so noise in
    /// skies and walls is not mistaken for detail.
    public static let contrastFloor = 10.0

    public static func map(of image: GrayImage) -> SharpnessMap {
        let smooth = image.smoothed()
        let width = smooth.width
        let height = smooth.height
        let tile = tileSize
        let columns = max(1, (width + tile - 1) / tile)
        let rows = max(1, (height + tile - 1) / tile)
        var normalized = [Float](repeating: 0, count: columns * rows)
        var raw = [Float](repeating: 0, count: columns * rows)
        let minimumPixels = tile * tile / 4

        smooth.pixels.withUnsafeBufferPointer { pixel in
            for row in 0..<rows {
                // The outermost pixel ring is skipped because the Laplacian needs all four neighbours.
                let y0 = max(1, row * tile)
                let y1 = min(height - 1, (row + 1) * tile)
                for column in 0..<columns {
                    let x0 = max(1, column * tile)
                    let x1 = min(width - 1, (column + 1) * tile)
                    guard y1 > y0, x1 > x0, (y1 - y0) * (x1 - x0) >= minimumPixels else { continue }

                    var sumLaplacian = 0
                    var sumLaplacianSquared = 0
                    var sumIntensity = 0
                    var sumIntensitySquared = 0
                    for y in y0..<y1 {
                        let offset = y * width
                        for x in x0..<x1 {
                            let index = offset + x
                            let centre = Int(pixel[index])
                            let laplacian = 4 * centre
                                - Int(pixel[index - 1]) - Int(pixel[index + 1])
                                - Int(pixel[index - width]) - Int(pixel[index + width])
                            sumLaplacian += laplacian
                            sumLaplacianSquared += laplacian * laplacian
                            sumIntensity += centre
                            sumIntensitySquared += centre * centre
                        }
                    }

                    let count = Double((y1 - y0) * (x1 - x0))
                    let meanLaplacian = Double(sumLaplacian) / count
                    let meanIntensity = Double(sumIntensity) / count
                    let edge = (Double(sumLaplacianSquared) / count - meanLaplacian * meanLaplacian).squareRoot0()
                    let contrast = (Double(sumIntensitySquared) / count - meanIntensity * meanIntensity).squareRoot0()

                    let index = row * columns + column
                    raw[index] = Float(edge)
                    normalized[index] = Float(100 * edge / max(contrast, contrastFloor))
                }
            }
        }

        return SharpnessMap(
            tileSize: tile,
            columns: columns,
            rows: rows,
            imageWidth: width,
            imageHeight: height,
            normalized: normalized,
            raw: raw
        )
    }
}

private extension Double {
    /// Square root that treats tiny negative rounding errors as zero.
    func squareRoot0() -> Double { self > 0 ? squareRoot() : 0 }
}
