import CoreGraphics
import Dispatch
import Foundation

/// Images made ready for Core Animation off the main thread.
///
/// When an image is set as a layer's contents, Core Animation converts it to the window's colour
/// space and its own pixel layout on the main thread while the frame is committed: about 15 ms
/// for a 2,560-pixel screen image and 70 ms for a 24 MP photo (found with Instruments' Time
/// Profiler: `CA::Render::copy_image` → `create_image_by_rendering` → `vImageConvert_AnyToAny`).
/// Redrawing the image here, off the main thread, in the window's colour space and the 32-bit
/// premultiplied BGRA layout Core Animation uses, leaves it nothing to convert. The colour
/// matching is the same ColorSync conversion Core Animation would have made.
enum DisplayImage {
    /// The image in Core Animation's layout and the display's colour space. Blocks; call it off
    /// the main thread.
    nonisolated static func prepare(_ image: CGImage, for space: CGColorSpace?) -> CGImage {
        guard let context = context(width: image.width, height: image.height, space: space ?? image.colorSpace) else { return image }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// A full-size image cut into square tiles, each ready for Core Animation, made in parallel.
    /// Tiles run left to right, then top to bottom; each overlaps its right and lower neighbours
    /// by `overlap` pixels so no seam shows between them.
    nonisolated static func tiles(of image: CGImage, size: Int, overlap: Int, for space: CGColorSpace?) -> TiledImage {
        let columns = (image.width + size - 1) / size
        let rows = (image.height + size - 1) / size
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let count = columns * rows
        let results = TileResults(count: count)
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let column = index % columns
            let row = index / columns
            let rect = CGRect(x: column * size, y: row * size, width: size + overlap, height: size + overlap).intersection(bounds)
            guard let crop = image.cropping(to: rect) else { return }
            results.set(index, TiledImage.Tile(image: prepare(crop, for: space), rect: rect))
        }
        return TiledImage(width: image.width, height: image.height, columns: columns, rows: rows, tiles: results.values)
    }

    private nonisolated static func context(width: Int, height: Int, space: CGColorSpace?) -> CGContext? {
        let space = space.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }
}

/// A full-size image as tiles ready for Core Animation.
struct TiledImage: @unchecked Sendable {
    struct Tile {
        let image: CGImage
        /// Where the tile sits in the image, in pixels, origin at the top left.
        let rect: CGRect
    }

    let width: Int
    let height: Int
    let columns: Int
    let rows: Int
    /// Nil where a tile could not be made.
    let tiles: [Tile?]

    var bytes: Int { tiles.reduce(0) { $0 + ($1.map { $0.image.bytesPerRow * $0.image.height } ?? 0) } }
}

/// Collects the tiles made in parallel.
private final class TileResults: @unchecked Sendable {
    private var storage: [TiledImage.Tile?]
    private let lock = NSLock()

    init(count: Int) { storage = Array(repeating: nil, count: count) }

    func set(_ index: Int, _ tile: TiledImage.Tile) {
        lock.lock()
        storage[index] = tile
        lock.unlock()
    }

    var values: [TiledImage.Tile?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
