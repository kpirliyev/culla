import CoreGraphics
import CryptoKit
import CullaCore
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Grid thumbnails, kept in memory and on disk.
///
/// - A thumbnail is filed under the photo's path, file size and modification date, so a file that
///   changed gets a new thumbnail. Old ones stay on disk until `pruneDisk(toBytes:)` removes them.
/// - Concurrent requests for the same photo share one decode.
/// - At most `maxConcurrentDecodes` thumbnails are made at once. A request cancelled before its
///   turn comes never decodes anything; one already decoding finishes and is cached, since the
///   work is done.
/// - Disk reads, decoding and encoding run on `BlockingQueue.shared`, never on the main thread or
///   Swift's cooperative pool.
/// - The memory cache holds decoded images up to `memoryLimit` bytes and drops the least recently
///   used first. The disk cache counts a thumbnail as used when it is written or read, by setting
///   the file's modification date, and `pruneDisk(toBytes:)` removes the least recently used first.
public final class ThumbnailCache: Sendable {
    /// What a thumbnail is filed under.
    public struct Key: Hashable, Sendable {
        public var path: String
        public var fileSize: Int64
        public var modificationDate: Date

        public init(file: PhotoFile) {
            path = file.url.path
            fileSize = file.fileSize
            modificationDate = file.modificationDate
        }

        /// The thumbnail's file name in the disk cache.
        var fileName: String {
            let text = "\(path)|\(fileSize)|\(modificationDate.timeIntervalSinceReferenceDate.bitPattern)"
            return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined() + ".jpg"
        }
    }

    /// How requests were served, for tests and diagnostics.
    public struct Statistics: Sendable, Hashable {
        public var memoryHits = 0
        public var diskHits = 0
        /// Thumbnails made from the image file, from its embedded preview or by decoding.
        public var decodes = 0
        /// Of `decodes`, how many used the embedded preview.
        public var embeddedPreviews = 0
    }

    private struct MemoryEntry {
        var image: CGImage
        var cost: Int
        var lastUse: UInt64
    }

    private struct InFlight {
        var generation: UInt64
        var task: Task<Void, Never>
        var waiters: [UInt64: CheckedContinuation<CGImage, any Error>]
    }

    private struct State {
        var memory: [Key: MemoryEntry] = [:]
        var memoryBytes = 0
        var clock: UInt64 = 0
        var inFlight: [Key: InFlight] = [:]
        var statistics = Statistics()
    }

    private enum Outcome: Sendable {
        case disk(CGImage)
        case made(CGImage, embedded: Bool)
    }

    public let folder: URL
    public let maxPixelSize: Int
    public let memoryLimit: Int
    private let limiter: AsyncLimiter
    private let state = Mutex(State())

    /// - Parameters:
    ///   - folder: where thumbnails are stored. Created if needed. Never a shoot folder.
    ///   - maxPixelSize: the long side of a thumbnail.
    ///   - memoryLimit: bytes of decoded images kept in memory. A 512 px thumbnail takes about 0.7 MB.
    ///   - maxConcurrentDecodes: how many thumbnails are made at once.
    public init(
        folder: URL,
        maxPixelSize: Int = PreviewLoader.thumbnailPixelSize,
        memoryLimit: Int = 256 << 20,
        maxConcurrentDecodes: Int = ProcessInfo.processInfo.activeProcessorCount
    ) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.folder = folder
        self.maxPixelSize = maxPixelSize
        self.memoryLimit = memoryLimit
        limiter = AsyncLimiter(limit: maxConcurrentDecodes)
    }

    public var statistics: Statistics {
        state.withLock { $0.statistics }
    }

    /// The thumbnail if it is in memory, without waiting. Safe to call from the main thread, for
    /// example to fill a grid cell at once when it is already known.
    public func cachedThumbnail(for file: PhotoFile) -> CGImage? {
        let key = Key(file: file)
        return state.withLock { state in
            guard var entry = state.memory[key] else { return nil }
            state.clock += 1
            entry.lastUse = state.clock
            state.memory[key] = entry
            state.statistics.memoryHits += 1
            return entry.image
        }
    }

    /// The photo's thumbnail: from memory, else from disk, else made from the file and stored.
    /// Throws `CancellationError` when the calling task is cancelled before it arrives, and
    /// `ImageLoaderError` when the file cannot be read.
    public func thumbnail(for file: PhotoFile) async throws -> CGImage {
        if let image = cachedThumbnail(for: file) { return image }
        let key = Key(file: file)
        let waiter = state.withLock { state in
            state.clock += 1
            return state.clock
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, any Error>) in
                let immediate: Result<CGImage, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if let entry = state.memory[key] { return .success(entry.image) }
                    if state.inFlight[key] != nil {
                        state.inFlight[key]!.waiters[waiter] = continuation
                        return nil
                    }
                    state.clock += 1
                    let generation = state.clock
                    let task = Task.detached(priority: .userInitiated) { [self] in
                        let result: Result<Outcome, any Error>
                        do {
                            result = .success(try await limiter.run { [self] in
                                try await BlockingQueue.shared.run { [self] in try produce(file, key: key) }
                            })
                        } catch {
                            result = .failure(error)
                        }
                        finish(key, generation: generation, result: result)
                    }
                    state.inFlight[key] = InFlight(generation: generation, task: task, waiters: [waiter: continuation])
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<CGImage, any Error>? in
                guard var flight = state.inFlight[key], let continuation = flight.waiters.removeValue(forKey: waiter) else {
                    return nil
                }
                if flight.waiters.isEmpty {
                    // Nobody waits any more: stop the work if it has not started.
                    flight.task.cancel()
                    state.inFlight[key] = nil
                } else {
                    state.inFlight[key] = flight
                }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Hands a finished thumbnail to everyone waiting for it and keeps it in memory.
    private func finish(_ key: Key, generation: UInt64, result: Result<Outcome, any Error>) {
        let waiters = state.withLock { state -> [CheckedContinuation<CGImage, any Error>] in
            if case .success(let outcome) = result {
                switch outcome {
                case .disk(let image):
                    state.statistics.diskHits += 1
                    insert(image, for: key, into: &state)
                case .made(let image, let embedded):
                    state.statistics.decodes += 1
                    if embedded { state.statistics.embeddedPreviews += 1 }
                    insert(image, for: key, into: &state)
                }
            }
            guard let flight = state.inFlight[key], flight.generation == generation else { return [] }
            state.inFlight[key] = nil
            return Array(flight.waiters.values)
        }
        let delivered = result.map { outcome -> CGImage in
            switch outcome {
            case .disk(let image), .made(let image, _): image
            }
        }
        for waiter in waiters {
            waiter.resume(with: delivered)
        }
    }

    private func insert(_ image: CGImage, for key: Key, into state: inout State) {
        state.clock += 1
        let cost = image.bytesPerRow * image.height
        if let old = state.memory[key] { state.memoryBytes -= old.cost }
        state.memory[key] = MemoryEntry(image: image, cost: cost, lastUse: state.clock)
        state.memoryBytes += cost
        while state.memoryBytes > memoryLimit, state.memory.count > 1 {
            guard let oldest = state.memory.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            state.memory[oldest.key] = nil
            state.memoryBytes -= oldest.value.cost
        }
    }

    /// Reads the thumbnail from disk, or makes it from the file and writes it to disk. Blocks.
    private func produce(_ file: PhotoFile, key: Key) throws -> Outcome {
        let url = folder.appendingPathComponent(key.fileName, isDirectory: false)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return .disk(image)
        }
        let preview = try PreviewLoader.load(file.url, size: .thumbnail(maxPixelSize: maxPixelSize))
        // A failed write only costs a decode next time.
        try? Self.writeJPEG(preview.image, to: url)
        return .made(preview.image, embedded: preview.usedEmbeddedPreview)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageLoaderError.cannotWrite(url)
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageLoaderError.cannotWrite(url) }
        // Written whole under another name and moved into place, so a reader never sees half a file.
        try (data as Data).write(to: url, options: .atomic)
    }

    // MARK: - Memory and disk

    /// Drops every thumbnail from memory. The disk cache is untouched.
    public func clearMemory() {
        state.withLock { state in
            state.memory.removeAll()
            state.memoryBytes = 0
        }
    }

    /// Bytes of decoded thumbnails held in memory.
    public var memoryUsage: Int {
        state.withLock { $0.memoryBytes }
    }

    /// Bytes the disk cache takes.
    public func diskUsage() async throws -> Int64 {
        let folder = folder
        return try await BlockingQueue.shared.run {
            try Self.diskEntries(in: folder).reduce(0) { $0 + $1.size }
        }
    }

    /// Deletes thumbnails from disk, least recently used first, until the cache takes at most
    /// `limit` bytes. Returns how many files were deleted.
    @discardableResult
    public func pruneDisk(toBytes limit: Int64) async throws -> Int {
        let folder = folder
        return try await BlockingQueue.shared.run {
            var entries = try Self.diskEntries(in: folder)
            var total = entries.reduce(0) { $0 + $1.size }
            guard total > limit else { return 0 }
            entries.sort { $0.lastUse != $1.lastUse ? $0.lastUse < $1.lastUse : $0.url.path < $1.url.path }
            var deleted = 0
            for entry in entries where total > limit {
                try? FileManager.default.removeItem(at: entry.url)
                total -= entry.size
                deleted += 1
            }
            return deleted
        }
    }

    private static func diskEntries(in folder: URL) throws -> [(url: URL, size: Int64, lastUse: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "jpg", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
}
