import AppKit
import CullaAnalysis
import CullaCore
import CullaFiles
import CullaSession

/// The face strip's crops: each face cut from the photo with room around it, at the strip's cell
/// size, from pixels at least that fine.
///
/// A crop comes in two steps:
/// 1. **At once**, from an image already in memory: the screen-size image if the loupe or a pane
///    decoded it, else the grid thumbnail. Cut on the main thread (well under a millisecond each),
///    so a new stack's strip never shows empty cells. From a thumbnail, a small face is soft.
/// 2. **Sharp**, from a decode just fine enough that the crop has at least as many pixels as
///    the cell: for a face that fills a tenth of the frame that is a reduced decode (ImageIO scales
///    JPEG while decoding, so it is quick); for small faces in a 24 MP frame it is the full image,
///    which is the "100% crop" of the Design. One decode serves every face of the frame, runs off
///    the main thread through `BlockingQueue`, at most two at a time, the frames in view first.
///    The decoded image is let go as soon as its faces are cut, so a 24 MP frame costs its 96 MB
///    only for the moment it is cut. Frames that left the strip before their turn are dropped.
///
/// Crops are kept, most recently used first, within `byteLimit` (about 320 crops).
@MainActor
final class FaceCropStore {
    struct Crop {
        let image: CGImage
        /// True when every pixel of the cell came from a real pixel of the photo: the source
        /// image held at least the cell's pixels across the crop.
        let sharp: Bool
    }

    /// One face to crop, as the strip asks for it.
    struct Request: Hashable {
        let photoID: String
        let file: PhotoFile
        let face: Int
        let box: UnitRect
        /// The photo's full size, for working out how fine a decode the crop needs.
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private struct Key: Hashable {
        let file: String
        let face: Int
    }

    private struct Entry {
        var crop: Crop
        var lastUse: UInt64
        var bytes: Int
    }

    private var entries: [Key: Entry] = [:]
    private var bytes = 0
    private var clock: UInt64 = 0
    /// Frames waiting for a sharp decode, most wanted first, and those decoding now.
    private var queue: [(key: String, requests: [Request], size: Int?)] = []
    private var running: Set<String> = []
    private var thumbnailLoads: Set<String> = []
    private let previews: ScreenPreviewCache
    private let thumbnails: ThumbnailCache
    private let activity: ActivityTracker

    /// The pixel size of a cell's crop: 72-point cells on a Retina display, with a little to spare.
    nonisolated static let cellPixels = 160
    static let byteLimit = 32 << 20
    static let concurrentDecodes = 2

    /// Called on the main thread when crops arrive.
    var onCrops: (() -> Void)?

    // Statistics, for the automation dump.
    private(set) var decodes = 0
    private(set) var fullSizeDecodes = 0
    private(set) var decodeMs: [Double] = []
    private(set) var peakDecodesInFlight = 0

    init(previews: ScreenPreviewCache, thumbnails: ThumbnailCache, activity: ActivityTracker) {
        self.previews = previews
        self.thumbnails = thumbnails
        self.activity = activity
    }

    private static func fileKey(_ file: PhotoFile) -> String {
        "\(file.url.path)|\(file.fileSize)|\(file.modificationDate.timeIntervalSinceReferenceDate)"
    }

    /// The best crop held for a face, if any.
    func crop(for request: Request) -> Crop? {
        let key = Key(file: Self.fileKey(request.file), face: request.face)
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key] = entry
        return entry.crop
    }

    /// The faces the strip shows, frames in view first. Crops that can be cut from an image in
    /// memory are cut now; sharp ones are queued; queued frames no longer asked for are dropped.
    func want(_ requests: [Request]) {
        var byFrame: [(String, [Request])] = []
        var index: [String: Int] = [:]
        for request in requests {
            let key = Self.fileKey(request.file)
            if let position = index[key] {
                byFrame[position].1.append(request)
            } else {
                index[key] = byFrame.count
                byFrame.append((key, [request]))
            }
        }
        var newQueue: [(key: String, requests: [Request], size: Int?)] = []
        for (key, frame) in byFrame {
            let missing = frame.filter { crop(for: $0) == nil }
            if !missing.isEmpty { cutFromMemory(missing) }
            let soft = frame.filter { crop(for: $0)?.sharp != true }
            guard !soft.isEmpty, !running.contains(key) else { continue }
            newQueue.append((key, soft, Self.decodeSize(for: soft)))
        }
        queue = newQueue
        startDecodes()
    }

    /// True while a sharp decode is running or waiting.
    var isBusy: Bool { !queue.isEmpty || !running.isEmpty || !thumbnailLoads.isEmpty }

    // MARK: Cutting

    /// The long side a decode needs so that each crop has at least `cellPixels` across; nil for
    /// the full image.
    static func decodeSize(for requests: [Request]) -> Int? {
        var needed = 0
        var fullLong = 0
        for request in requests {
            let long = max(request.pixelWidth, request.pixelHeight, 1)
            fullLong = max(fullLong, long)
            let crop = FaceCellCrop(face: request.box, imageWidth: request.pixelWidth, imageHeight: request.pixelHeight)
            let cropPixels = Double(min(crop.pixelWidth, crop.pixelHeight))
            // At the full size the crop is `cropPixels` across: scale the long side so it is
            // `cellPixels` across instead.
            needed = max(needed, Int((Double(long) * Double(cellPixels) / max(cropPixels, 1)).rounded(.up)))
        }
        // Rounded up to a step of 512, which ImageIO decodes as fast as any size near it.
        let stepped = (needed + 511) / 512 * 512
        return fullLong > 0 && stepped >= fullLong * 9 / 10 ? nil : stepped
    }

    /// Crops from the screen-size image or the thumbnail, whichever is in memory.
    private func cutFromMemory(_ requests: [Request]) {
        guard let first = requests.first else { return }
        let source = previews.cached(first.file) ?? thumbnails.cachedThumbnail(for: first.file)
        guard let source else {
            loadThumbnail(for: requests)
            return
        }
        for request in requests {
            guard let crop = Self.cut(request, from: source) else { continue }
            store(crop, for: request)
        }
    }

    private func loadThumbnail(for requests: [Request]) {
        guard let file = requests.first?.file else { return }
        let key = Self.fileKey(file)
        guard thumbnailLoads.insert(key).inserted else { return }
        let thumbnails = thumbnails
        Task {
            let image = try? await thumbnails.thumbnail(for: file)
            thumbnailLoads.remove(key)
            guard let image else { return }
            var added = false
            for request in requests where crop(for: request) == nil {
                if let crop = Self.cut(request, from: image) {
                    store(crop, for: request)
                    added = true
                }
            }
            if added { onCrops?() }
        }
    }

    /// Cuts one face from an image into a `cellPixels` square bitmap. Thread-safe.
    nonisolated static func cut(_ request: Request, from image: CGImage) -> Crop? {
        let crop = FaceCellCrop(face: request.box, imageWidth: image.width, imageHeight: image.height)
        let rect = CGRect(
            x: (crop.rect.x * Double(image.width)).rounded(), y: (crop.rect.y * Double(image.height)).rounded(),
            width: max(1, (crop.rect.width * Double(image.width)).rounded()), height: max(1, (crop.rect.height * Double(image.height)).rounded())
        )
        guard let region = image.cropping(to: rect) else { return nil }
        let side = cellPixels
        let aspect = rect.width / max(rect.height, 1)
        let width = aspect >= 1 ? side : max(1, Int((Double(side) * aspect).rounded()))
        let height = aspect >= 1 ? max(1, Int((Double(side) / aspect).rounded())) : side
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(region, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let output = context.makeImage() else { return nil }
        // Sharp when the source held at least the cell's pixels across the crop.
        return Crop(image: output, sharp: min(rect.width, rect.height) >= Double(side) * 0.98)
    }

    private func store(_ crop: Crop, for request: Request) {
        let key = Key(file: Self.fileKey(request.file), face: request.face)
        if let old = entries[key] {
            // A soft crop never replaces a sharp one.
            if old.crop.sharp, !crop.sharp { return }
            bytes -= old.bytes
        }
        clock += 1
        let size = crop.image.bytesPerRow * crop.image.height
        entries[key] = Entry(crop: crop, lastUse: clock, bytes: size)
        bytes += size
        while bytes > Self.byteLimit, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            bytes -= oldest.value.bytes
            entries[oldest.key] = nil
        }
    }

    // MARK: Sharp decodes

    private func startDecodes() {
        while running.count < Self.concurrentDecodes, !queue.isEmpty {
            let job = queue.removeFirst()
            running.insert(job.key)
            peakDecodesInFlight = max(peakDecodesInFlight, running.count)
            activity.begin(.preview)
            let requests = job.requests
            let size = job.size
            guard let url = requests.first?.file.url else { continue }
            Task {
                let started = CACurrentMediaTime()
                let crops: [(Request, Crop)] = await BlockingQueue.shared.run {
                    let preview = try? PreviewLoader.load(url, size: size.map { .screen(maxPixelSize: $0) } ?? .full)
                    guard let image = preview?.image else { return [] }
                    return requests.compactMap { request in Self.cut(request, from: image).map { (request, $0) } }
                }
                running.remove(job.key)
                activity.end(.preview)
                decodes += 1
                if size == nil { fullSizeDecodes += 1 }
                decodeMs.append((CACurrentMediaTime() - started) * 1000)
                if decodeMs.count > 50 { decodeMs.removeFirst() }
                for (request, crop) in crops {
                    // Marked sharp: the decode was chosen to be fine enough.
                    store(Crop(image: crop.image, sharp: true), for: request)
                }
                if !crops.isEmpty { onCrops?() }
                startDecodes()
            }
        }
    }

    /// Lets every crop go.
    func clear() {
        entries = [:]
        bytes = 0
        queue = []
    }

    var memoryBytes: Int { bytes }
    var count: Int { entries.count }
}
