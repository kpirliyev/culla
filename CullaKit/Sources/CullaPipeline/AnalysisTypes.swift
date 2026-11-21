import CullaAnalysis
import CullaCore
import CullaFiles
import Foundation
import Synchronization

/// What analysing one photo gave: its scores, or why it could not be read.
public enum AnalysisOutcome: Sendable {
    case scores(PhotoScores)
    /// The file could not be opened or decoded. The reason is for showing to the user.
    case unreadable(String)
}

/// Analyses one photo. `slot` is the concurrent slot the scheduler runs it in, from 0 to the
/// concurrency limit minus one; no two photos in flight share a slot, so a function can keep one
/// analyzer per slot. Must not block a cooperative thread (see `BlockingQueue`), and should
/// return soon after its task is cancelled; whatever it returns then is thrown away.
public typealias PhotoAnalysisFunction = @Sendable (_ file: PhotoFile, _ slot: Int) async -> AnalysisOutcome

/// One photo waiting to be analysed.
public struct AnalysisJob: Sendable, Identifiable {
    public var file: PhotoFile
    /// Capture time, or modification time without one. Jobs nobody asked for first are analysed
    /// in this order, ties broken by id.
    public var sortDate: Date

    public init(file: PhotoFile, sortDate: Date) {
        self.file = file
        self.sortDate = sortDate
    }

    public var id: String { file.id }
}

/// One finished photo, as the scheduler hands it out.
public struct AnalysisResult: Sendable {
    /// The file as it was when the job was queued.
    public var file: PhotoFile
    public var outcome: AnalysisOutcome

    public var id: String { file.id }
}

/// How far analysis has got.
public struct AnalysisProgress: Sendable, Hashable {
    /// Photos analysed, or found unreadable, since the scheduler was created.
    public var done: Int
    /// `done` plus the photos waiting and in flight.
    public var total: Int
    /// Photos in flight right now.
    public var running: Int
    /// How many of `done` could not be read.
    public var unreadable: Int
    /// Photos whose scores came from the score cache instead. Not counted in `done` or `total`.
    /// Set by `ShootAnalysis`; always 0 from the scheduler itself.
    public var cached: Int
    public var isPaused: Bool
    /// Photos finished per second over the last `AnalysisScheduler.rateWindowSeconds` of
    /// unpaused time. Nil until a few photos are done.
    public var photosPerSecond: Double?
    /// Estimated seconds until `done` reaches `total`, smoothed so it does not jump around. Nil
    /// while the rate is unknown, and 0 when nothing is left.
    public var secondsRemaining: Double?

    public init(
        done: Int = 0,
        total: Int = 0,
        running: Int = 0,
        unreadable: Int = 0,
        cached: Int = 0,
        isPaused: Bool = false,
        photosPerSecond: Double? = nil,
        secondsRemaining: Double? = nil
    ) {
        self.done = done
        self.total = total
        self.running = running
        self.unreadable = unreadable
        self.cached = cached
        self.isPaused = isPaused
        self.photosPerSecond = photosPerSecond
        self.secondsRemaining = secondsRemaining
    }

    /// Photos waiting or in flight.
    public var remaining: Int { total - done }
    /// 0 to 1, for a progress bar. 1 when there is nothing to do.
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 1 }
    public var isComplete: Bool { done >= total }
}

/// The analysis the app and `culla-eval` run on a photo: `AnalysisImageLoader`, then one
/// `PhotoAnalyzer` per concurrent slot, as `culla-eval` does.
public enum StandardAnalysis {
    /// A function that loads each photo's analysis image at `maxPixelSize` and analyses it.
    /// Files that cannot be opened or decoded come back `.unreadable`.
    public static func function(maxPixelSize: Int = AnalysisImageLoader.defaultMaxPixelSize) -> PhotoAnalysisFunction {
        let pool = AnalyzerPool()
        return { file, slot in
            if Task.isCancelled { return .unreadable(localized("Cancelled")) }
            do {
                let loaded = try await AnalysisImageLoader.image(url: file.url, maxPixelSize: maxPixelSize)
                if Task.isCancelled { return .unreadable(localized("Cancelled")) }
                let analyzer = await pool.analyzer(for: slot)
                var scores = await analyzer.analyze(loaded.image)
                scores.timings.decode = loaded.decodeSeconds
                return .scores(scores)
            } catch {
                // The reason is shown in the inspector and the loupe, so in the person's language.
                return .unreadable((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }
    }
}

/// One `PhotoAnalyzer` per slot, made the first time a slot is used.
final class AnalyzerPool: Sendable {
    private let analyzers = Mutex([Int: PhotoAnalyzer]())

    func analyzer(for slot: Int) async -> PhotoAnalyzer {
        if let existing = analyzers.withLock({ $0[slot] }) { return existing }
        // Making one builds a Core Image face detector, which can block; keep it off the pool.
        let made = await BlockingQueue.shared.run { PhotoAnalyzer() }
        return analyzers.withLock { analyzers in
            if let existing = analyzers[slot] { return existing }
            analyzers[slot] = made
            return made
        }
    }
}
