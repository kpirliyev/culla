import CullaCore
import Dispatch
import Foundation
import Synchronization

/// How far `ShootLoader` has got.
public struct ShootLoadProgress: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// Listing the folder. `total` is not known yet and is 0.
        case scanning
        /// Reading capture data from the files' headers.
        case readingMetadata
        case finished
    }

    public var phase: Phase
    /// Photos whose metadata is ready, read or reused.
    public var done: Int
    /// Photos found.
    public var total: Int

    public init(phase: Phase, done: Int, total: Int) {
        self.phase = phase
        self.done = done
        self.total = total
    }

    /// 0 to 1, for a progress bar.
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Finds the photos of a shoot folder and reads their metadata, ready for a `SessionState`.
public enum ShootLoader {
    /// Photos read per step. Progress is reported and cancellation checked between steps.
    static let chunkSize = 256

    /// Scans `folder` (pairing RAW+JPEG, skipping videos and `_Rejected`) and reads every photo's
    /// metadata, many files at once, off the cooperative pool.
    ///
    /// - Parameters:
    ///   - known: photos whose metadata is already known, such as a saved session's. A file whose
    ///     id, size and modification date match a known photo is not read again.
    ///   - progress: called from a background thread as work advances, at most a few hundred
    ///     times however large the folder.
    /// - Returns: the photos, sorted by id. `SessionState` puts them in capture order.
    /// - Throws: when the folder cannot be read, or `CancellationError` when the task is cancelled.
    public static func load(
        folder: URL,
        includeSubfolders: Bool = true,
        pairRAWWithRendered: Bool = true,
        known: [ScannedPhoto] = [],
        progress: @escaping @Sendable (ShootLoadProgress) -> Void = { _ in }
    ) async throws -> [ScannedPhoto] {
        progress(ShootLoadProgress(phase: .scanning, done: 0, total: 0))
        let files = try await BlockingQueue.shared.run {
            try PhotoScanner.scan(folder: folder, includeSubfolders: includeSubfolders, pairRAWWithRendered: pairRAWWithRendered)
        }
        try Task.checkCancellation()

        let knownByID = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var results = [PhotoMetadata?](repeating: nil, count: files.count)
        var toRead: [Int] = []
        for (index, file) in files.enumerated() {
            if let match = knownByID[file.id],
               match.file.fileSize == file.fileSize,
               match.file.modificationDate == file.modificationDate {
                results[index] = match.metadata
            } else {
                toRead.append(index)
            }
        }

        var done = files.count - toRead.count
        progress(ShootLoadProgress(phase: .readingMetadata, done: done, total: files.count))
        var start = 0
        while start < toRead.count {
            try Task.checkCancellation()
            let chunk = Array(toRead[start..<min(start + chunkSize, toRead.count)])
            let urls = chunk.map { files[$0].url }
            let read = await BlockingQueue.shared.run { readConcurrently(urls) }
            for (index, metadata) in zip(chunk, read) {
                results[index] = metadata
            }
            start += chunk.count
            done += chunk.count
            progress(ShootLoadProgress(phase: .readingMetadata, done: done, total: files.count))
        }
        progress(ShootLoadProgress(phase: .finished, done: files.count, total: files.count))
        return zip(files, results).map { ScannedPhoto(file: $0, metadata: $1 ?? PhotoMetadata()) }
    }

    /// Reads the metadata of every file, spread over all cores. Blocks until done.
    private static func readConcurrently(_ urls: [URL]) -> [PhotoMetadata] {
        let results = Mutex([PhotoMetadata](repeating: PhotoMetadata(), count: urls.count))
        DispatchQueue.concurrentPerform(iterations: urls.count) { index in
            let metadata = MetadataReader.read(url: urls[index])
            results.withLock { $0[index] = metadata }
        }
        return results.withLock { $0 }
    }
}
