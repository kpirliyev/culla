import AppKit
import CoreGraphics
import CullaCore
import CullaFiles
import Foundation

/// Screen-size images for the loupe: decoded on demand off the main thread, a few kept in
/// memory so stepping back and forth is instant.
///
/// "Screen size" is the size the loupe's viewport needs, rounded up to a step of 512 pixels so
/// small window changes reuse what is decoded: about 2,560 pixels on the long side for a
/// 1280-point window on a Retina display. Decoding for the whole screen instead (5,120 pixels on
/// a 5K display) took 70 MB per image and 50 ms of the main thread to hand each one to Core
/// Animation.
@MainActor
final class ScreenPreviewCache {
    private struct Entry {
        var image: CGImage
        var lastUse: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<CGImage, any Error>] = [:]
    private var clock: UInt64 = 0
    private let activity: ActivityTracker
    let capacity = 5

    /// How many screen-size images are held.
    var count: Int { entries.count }

    init(activity: ActivityTracker) {
        self.activity = activity
    }

    /// The colour space of the window the loupe is in; images are prepared in it (`DisplayImage`).
    var colorSpace: CGColorSpace?

    /// The long side to decode at, in pixels. The loupe sets it from its viewport.
    private(set) var pixelSize = 2560

    /// Sets the decode size for a viewport of this many pixels on its long side. Returns true when
    /// it changed, so the photo in view should be decoded again.
    @discardableResult
    func setViewportLongSide(_ pixels: Int) -> Bool {
        let size = Self.bucket(pixels)
        guard size != pixelSize else { return false }
        pixelSize = size
        return true
    }

    static func bucket(_ pixels: Int) -> Int {
        let step = 512
        return min(8192, max(1024, (pixels + step - 1) / step * step))
    }

    func cached(_ file: PhotoFile) -> CGImage? {
        guard var entry = entries[key(file)] else { return nil }
        clock += 1
        entry.lastUse = clock
        entries[key(file)] = entry
        return entry.image
    }

    /// The photo at screen size. A decode that is no longer wanted still finishes and is kept,
    /// since stepping back to the photo is likely.
    func image(for file: PhotoFile) async throws -> CGImage {
        if let image = cached(file) { return image }
        let key = key(file)
        let task: Task<CGImage, any Error>
        if let running = inFlight[key] {
            task = running
        } else {
            let url = file.url
            let size = pixelSize
            let space = colorSpace
            activity.begin(.preview)
            task = Task.detached(priority: .userInitiated) {
                // Decoded and made ready for Core Animation off the main thread and the pool.
                try await BlockingQueue.shared.run {
                    DisplayImage.prepare(try PreviewLoader.load(url, size: .screen(maxPixelSize: size)).image, for: space)
                }
            }
            inFlight[key] = task
            Task { [weak self] in
                let result = await task.result
                guard let self else { return }
                self.inFlight[key] = nil
                self.activity.end(.preview)
                if case .success(let image) = result { self.insert(image, for: key) }
            }
        }
        return try await task.value
    }

    /// Starts decoding a photo the person is likely to look at next.
    func prefetch(_ file: PhotoFile) {
        guard cached(file) == nil, inFlight[key(file)] == nil else { return }
        Task { _ = try? await image(for: file) }
    }

    private func insert(_ image: CGImage, for key: String) {
        clock += 1
        entries[key] = Entry(image: image, lastUse: clock)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            entries[oldest.key] = nil
        }
    }

    private func key(_ file: PhotoFile) -> String {
        "\(file.url.path)|\(file.fileSize)|\(file.modificationDate.timeIntervalSinceReferenceDate)|\(pixelSize)"
    }
}
