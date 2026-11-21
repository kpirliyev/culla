import AppKit
import CullaCore
import CullaFiles

/// Full-size images for the loupe's zoom, and clipping masks for its overlay.
///
/// A full-size image is decoded only when the zoom shows more detail than the screen-size image
/// holds, off the main thread, one at a time, the photo in view first. The loupe says which
/// photos it wants (the one in view and the next one it is likely to show), and every other
/// full-size image is released at once: a 24 MP photo takes 96 MB decoded.
@MainActor
final class LoupeImageStore {
    private var full: [String: TiledImage] = [:]
    private var wanted: [(id: String, file: PhotoFile)] = []
    private var decoding: String?
    private let activity: ActivityTracker

    /// The colour space full-size images are prepared in: the window's.
    var colorSpace: CGColorSpace?

    /// Called on the main thread when a wanted full-size image is ready.
    var onFullImage: ((String) -> Void)?

    init(activity: ActivityTracker) {
        self.activity = activity
    }

    func fullImage(for id: String) -> TiledImage? { full[id] }

    /// True while a wanted full-size image is decoding or waiting to.
    var isBusy: Bool { decoding != nil || wanted.contains { full[$0.id] == nil } }

    /// Photos whose full-size image is decoded and kept, for the automation dump.
    var heldIDs: [String] { Array(full.keys).sorted() }

    /// The photos to hold full-size images for, most wanted first. The rest are released.
    func want(_ photos: [(id: String, file: PhotoFile)]) {
        wanted = photos
        let keep = Set(photos.map(\.id))
        let dropped = full.keys.filter { !keep.contains($0) }
        for id in dropped { full[id] = nil }
        startNext()
    }

    func releaseAll() {
        want([])
    }

    private func startNext() {
        guard decoding == nil, let next = wanted.first(where: { full[$0.id] == nil }) else { return }
        decoding = next.id
        activity.begin(.preview)
        let url = next.file.url
        let id = next.id
        let space = colorSpace
        Task {
            let image = try? await BlockingQueue.shared.run {
                DisplayImage.tiles(of: try PreviewLoader.load(url, size: .full).image, size: LoupeDocumentView.tileSize, overlap: 2, for: space)
            }
            decoding = nil
            activity.end(.preview)
            if let image, wanted.contains(where: { $0.id == id }) {
                full[id] = image
                onFullImage?(id)
            }
            startNext()
        }
    }

    // MARK: Clipping masks

    private var masks: [ObjectIdentifier: ClippingMask] = [:]
    private var maskOrder: [ObjectIdentifier] = []
    private var maskTasks: Set<ObjectIdentifier> = []

    /// The clipping mask of an image if it is made, else starts making it and calls `ready` on
    /// the main thread when it is.
    func clippingMask(for image: CGImage, ready: @escaping @MainActor () -> Void) -> ClippingMask? {
        let key = ObjectIdentifier(image)
        if let mask = masks[key] { return mask }
        guard !maskTasks.contains(key) else { return nil }
        maskTasks.insert(key)
        activity.begin(.preview)
        Task {
            let mask = await BlockingQueue.shared.run { ClippingMask.make(from: image) }
            maskTasks.remove(key)
            activity.end(.preview)
            if let mask {
                masks[key] = mask
                maskOrder.append(key)
                // A few masks: the photo in view and its neighbours.
                while maskOrder.count > 4 { masks[maskOrder.removeFirst()] = nil }
            }
            ready()
        }
        return nil
    }

    var isMakingMask: Bool { !maskTasks.isEmpty }
}

/// Where a photo is clipped: highlights at or above 250 and shadows at or below 5 on the same
/// 0-255 luminance scale `ExposureMeter` measures, drawn as a tint over the photo.
struct ClippingMask: @unchecked Sendable {
    let image: CGImage
    let highlights: Double
    let shadows: Double

    static let highlightLevel = 250
    static let shadowLevel = 5

    /// Made from the image at up to 2048 pixels on the long side, which is fine enough to see
    /// where clipping is and quick to make.
    nonisolated static func make(from source: CGImage, maxSide: Int = 2048) -> ClippingMask? {
        let scale = min(1, Double(maxSide) / Double(max(source.width, source.height)))
        let width = max(1, Int((Double(source.width) * scale).rounded()))
        let height = max(1, Int((Double(source.height) * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let input = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let output = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info),
              let source8 = input.data, let target8 = output.data
        else { return nil }
        input.interpolationQuality = .medium
        input.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = source8.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let mask = target8.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var bright = 0
        var dark = 0
        // Highlights in solid magenta, shadows in blue diagonal stripes, so neither reads as the
        // green, red and amber of decisions and flags, and the two differ by more than colour.
        // Premultiplied at 60% opacity, so the photo still shows through.
        let alpha: UInt8 = 153
        let stripe = max(3, width / 400)
        for index in 0 ..< width * height {
            let offset = index * 4
            let x = index % width, y = index / width
            let r = Int(pixels[offset]), g = Int(pixels[offset + 1]), b = Int(pixels[offset + 2])
            // Rec. 601 luma, as the analysis measures it.
            let luma = (299 * r + 587 * g + 114 * b) / 1000
            if luma >= highlightLevel {
                bright += 1
                mask[offset] = alpha; mask[offset + 1] = 0; mask[offset + 2] = alpha; mask[offset + 3] = alpha
            } else if luma <= shadowLevel {
                dark += 1
                if ((x + y) / stripe) % 2 == 0 {
                    mask[offset] = 0; mask[offset + 1] = 60; mask[offset + 2] = alpha; mask[offset + 3] = alpha
                } else {
                    mask[offset] = 0; mask[offset + 1] = 12; mask[offset + 2] = 40; mask[offset + 3] = 40
                }
            } else {
                mask[offset] = 0; mask[offset + 1] = 0; mask[offset + 2] = 0; mask[offset + 3] = 0
            }
        }
        guard let image = output.makeImage() else { return nil }
        let total = Double(width * height)
        return ClippingMask(image: image, highlights: Double(bright) / total, shadows: Double(dark) / total)
    }
}
