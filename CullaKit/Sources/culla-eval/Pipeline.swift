import CoreGraphics
import CullaAnalysis
import CullaCore
import CullaFiles
import Foundation
import Synchronization

/// The scores of one run as saved to disk, so a later run can reuse them.
struct ScoreFile: Codable {
    /// Bumped whenever the choice of face or focus spot for the saved crops changes without a
    /// setting changing, such as a new main-face rule, so crops from an older run are not reused.
    /// Files written before this field existed fail to decode, which also means analysing again.
    static let currentPreviewVersion = 2

    var scoresVersion: Int
    var previewVersion: Int
    var maxPixelSize: Int
    /// The settings the saved crops were made with.
    var tuning: Tuning
    var records: [PhotoRecord]
}

struct AnalysisRun {
    var records: [PhotoRecord]
    var analysed: Int
    var reused: Int
    var wallSeconds: Double
    /// How many analysed photos came from each kind of source image.
    var sources: [AnalysisImageSource: Int] = [:]
}

/// Counts the source of each analysed image, from many tasks at once.
final class SourceCounter: Sendable {
    private let counts = Mutex([AnalysisImageSource: Int]())

    func add(_ source: AnalysisImageSource) {
        counts.withLock { $0[source, default: 0] += 1 }
    }

    var values: [AnalysisImageSource: Int] { counts.withLock { $0 } }
}

/// Analyses a list of photos, several at a time, reusing saved scores for files that have not changed.
enum Pipeline {
    private struct Outcome: Sendable {
        var slot: Int
        var index: Int
        var record: PhotoRecord
    }

    static func run(files: [PhotoFile], options: Options, layout: OutputLayout) async -> AnalysisRun {
        let clock = ContinuousClock()
        let start = clock.now

        let cached = options.useCache ? loadCache(options: options, layout: layout) : [:]
        var records = [PhotoRecord?](repeating: nil, count: files.count)
        var pending: [Int] = []
        for (index, file) in files.enumerated() {
            if let record = cached[file.id], isCurrent(record, for: file, layout: layout) {
                var record = record
                record.file = file
                records[index] = record
            } else {
                pending.append(index)
            }
        }
        let reused = files.count - pending.count

        // One analyzer per slot, so each concurrent photo has its own Core Image detector.
        let slots = max(1, min(options.jobs, pending.count))
        let analyzers = (0..<slots).map { _ in PhotoAnalyzer() }
        let progress = Progress(total: pending.count)
        let sources = SourceCounter()

        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            for slot in 0..<slots where next < pending.count {
                let index = pending[next]
                next += 1
                let file = files[index]
                let analyzer = analyzers[slot]
                group.addTask {
                    let record = await process(file, analyzer: analyzer, sources: sources, options: options, layout: layout)
                    return Outcome(slot: slot, index: index, record: record)
                }
            }
            for await outcome in group {
                records[outcome.index] = outcome.record
                progress.advance()
                guard next < pending.count else { continue }
                let index = pending[next]
                next += 1
                let file = files[index]
                let slot = outcome.slot
                let analyzer = analyzers[slot]
                group.addTask {
                    let record = await process(file, analyzer: analyzer, sources: sources, options: options, layout: layout)
                    return Outcome(slot: slot, index: index, record: record)
                }
            }
        }
        progress.finish()

        return AnalysisRun(
            records: records.compactMap { $0 },
            analysed: pending.count,
            reused: reused,
            wallSeconds: (clock.now - start).seconds,
            sources: sources.values
        )
    }

    // MARK: - One photo

    private static func process(
        _ file: PhotoFile,
        analyzer: PhotoAnalyzer,
        sources: SourceCounter,
        options: Options,
        layout: OutputLayout
    ) async -> PhotoRecord {
        // File reads, decoding and encoding block their thread, so they run on a Dispatch queue
        // and leave Swift's cooperative pool to the Vision requests (see `BlockingQueue`).
        let blocking = BlockingQueue.shared
        let metadata = await blocking.run { MetadataReader.read(url: file.url) }
        do {
            // The same loader the app analyses with, so both measure the same pixels. Timed where
            // the work happens, so waiting for a free thread is not counted.
            let loaded = try await AnalysisImageLoader.image(url: file.url, maxPixelSize: options.maxPixelSize)
            let image = loaded.image
            sources.add(loaded.source)

            var scores = await analyzer.analyze(image)
            scores.timings.decode = loaded.decodeSeconds
            let finished = scores
            try await blocking.run { () throws in
                try writeImages(for: file, image: image, scores: finished, options: options, layout: layout)
            }
            return PhotoRecord(file: file, metadata: metadata, scores: scores)
        } catch {
            return PhotoRecord(file: file, metadata: metadata, scores: nil, error: String(describing: error))
        }
    }

    /// Writes the thumbnail and the two crops the contact sheets show beside it, cut where
    /// `Previews` says, so the sheets can state each file's size without opening it.
    private static func writeImages(
        for file: PhotoFile,
        image: CGImage,
        scores: PhotoScores,
        options: Options,
        layout: OutputLayout
    ) throws {
        let key = FileHasher.shortKey(for: file.id)
        let previews = Previews(scores: scores, summary: scores.summary(tuning: options.tuning))

        if let thumb = ImageLoader.scaled(image, maxPixelSize: Previews.thumbnailPixels) {
            try ImageLoader.writeJPEG(thumb, to: layout.thumb(key), quality: 0.7)
        }
        if let face = previews.face, let crop = image.cropping(to: face.source),
           let small = ImageLoader.scaled(crop, maxPixelSize: Previews.thumbnailPixels) {
            try ImageLoader.writeJPEG(small, to: layout.faceCrop(key), quality: 0.8)
        }
        if let focus = previews.focus, let crop = image.cropping(to: focus.source) {
            try ImageLoader.writeJPEG(crop, to: layout.focusCrop(key), quality: 0.9)
        }
    }

    // MARK: - Saved scores

    static func save(_ records: [PhotoRecord], options: Options, layout: OutputLayout) throws {
        let file = ScoreFile(
            scoresVersion: PhotoScores.currentVersion,
            previewVersion: ScoreFile.currentPreviewVersion,
            maxPixelSize: options.maxPixelSize,
            tuning: options.tuning,
            records: records
        )
        try JSONEncoder().encode(file).write(to: layout.scoresJSON, options: .atomic)
    }

    private static func loadCache(options: Options, layout: OutputLayout) -> [String: PhotoRecord] {
        guard let data = try? Data(contentsOf: layout.scoresJSON),
              let file = try? JSONDecoder().decode(ScoreFile.self, from: data),
              file.scoresVersion == PhotoScores.currentVersion,
              file.previewVersion == ScoreFile.currentPreviewVersion,
              file.maxPixelSize == options.maxPixelSize,
              cropsMatch(file.tuning, options.tuning)
        else { return [:] }
        return Dictionary(file.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Saved crops show the face and focus spot chosen under the old settings, so a change to
    /// any setting that picks them means analysing again. The flag thresholds and the grouping
    /// settings only change what is flagged and how photos are grouped, so they are left out.
    private static func cropsMatch(_ a: Tuning, _ b: Tuning) -> Bool {
        a.minFaceFraction == b.minFaceFraction
            && a.backgroundFaceRatio == b.backgroundFaceRatio
            && a.maxYawDegrees == b.maxYawDegrees
            && a.countWinkAsClosed == b.countWinkAsClosed
            && a.facesTakePriority == b.facesTakePriority
    }

    private static func isCurrent(_ record: PhotoRecord, for file: PhotoFile, layout: OutputLayout) -> Bool {
        guard let scores = record.scores, scores.version == PhotoScores.currentVersion else { return false }
        return record.file.fileSize == file.fileSize
            && record.file.modificationDate == file.modificationDate
            && FileManager.default.fileExists(atPath: layout.thumb(FileHasher.shortKey(for: file.id)).path)
    }
}

/// Prints how many photos are done, on one updating line in a terminal.
private final class Progress {
    private let total: Int
    private var done = 0
    private let isTerminal = isatty(STDOUT_FILENO) == 1

    init(total: Int) {
        self.total = total
    }

    func advance() {
        done += 1
        if isTerminal {
            print("\r  analysed \(done) of \(total)", terminator: "")
            fflush(stdout)
        } else if done % 50 == 0 || done == total {
            print("  analysed \(done) of \(total)")
        }
    }

    func finish() {
        if isTerminal, total > 0 { print("") }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
