import CullaAnalysis
import CullaCore
import CullaFiles
import CullaSession
import CullaStore
import Foundation

/// What `ShootAnalysis` tells the app, in order, on `ShootAnalysis.events`. The app applies each
/// to its `SessionState`; nothing here holds or changes a decision.
public enum ShootAnalysisEvent: Sendable {
    /// Scores found in the score cache, delivered before any analysis starts. Apply with
    /// `SessionState.setScores(_:)`. Ids the session no longer has can be ignored.
    case cachedScores([String: PhotoScores])
    /// Photos analysed since the last batch: scores, unreadable photos and the progress so far.
    /// Sent at most once per `ShootAnalysis.Options.eventInterval`.
    case analysed(AnalysisBatch)
    /// Progress changed without new results, such as after a rescan queued more photos.
    case progress(AnalysisProgress)
    /// Stacks with their best picks, and duplicate sets, computed from the scores so far. Apply
    /// with `SessionState.applyGrouping(_:)`.
    case grouping(SessionGrouping)
    /// Analysis paused: results of photos that were in flight may still arrive.
    case paused(AnalysisProgress)
    case resumed(AnalysisProgress)
    /// Every queued photo is analysed, its scores saved and the final grouping sent before this.
    /// Sent again each time later work (a rescan) drains.
    case finished(AnalysisProgress)
}

/// One batch of analysis results.
public struct AnalysisBatch: Sendable {
    /// Scores by photo id. Apply with `SessionState.setScores(_:)`.
    public var scores: [String: PhotoScores]
    /// Why each photo could not be read, by photo id. Apply with `SessionState.markUnreadable`.
    public var unreadable: [String: String]
    public var progress: AnalysisProgress

    public init(scores: [String: PhotoScores] = [:], unreadable: [String: String] = [:], progress: AnalysisProgress) {
        self.scores = scores
        self.unreadable = unreadable
        self.progress = progress
    }
}

/// Analyses one open shoot in the background: the single object the app holds per open shoot.
///
/// It reads cached scores for every photo in one go and delivers them, analyses only the misses
/// through an `AnalysisScheduler`, saves new scores to the database in batches, and computes stacks,
/// best picks and duplicate sets off the calling thread as scores arrive. Everything it learns
/// goes out on `events`; the app applies the events to its `SessionState`, which stays the owner
/// of truth. This actor keeps only what it needs for grouping (files, metadata and scores) and
/// never a decision or rating.
///
/// Every method returns quickly: work they start runs in the background.
public actor ShootAnalysis {
    public struct Options: Sendable {
        /// Photos analysed at once at the start. Change it later with `setConcurrency(_:)`.
        public var concurrency = AnalysisScheduler.defaultConcurrency
        /// Priority of the analysis tasks.
        public var taskPriority: TaskPriority = .medium
        /// Results are gathered into one `.analysed` event at most this often.
        public var eventInterval: Duration = .milliseconds(250)
        /// New scores are saved at least this often while analysis runs, so a crash loses at most
        /// this much work...
        public var saveInterval: Duration = .seconds(2)
        /// ...or as soon as this many are waiting to be saved.
        public var saveBatchSize = 200
        /// While analysis runs, stacks and duplicate sets are recomputed at most this often, and
        /// only when new scores arrived. They are always recomputed when the queue drains.
        public var groupingInterval: Duration = .seconds(5)

        public init() {}
    }

    /// Events for the app. Meant for one consumer. Ends after `cancel()`.
    public nonisolated let events: AsyncStream<ShootAnalysisEvent>
    private let continuation: AsyncStream<ShootAnalysisEvent>.Continuation

    private let database: CullaDatabase?
    private let options: Options
    private let scheduler: AnalysisScheduler
    private var consumer: Task<Void, Never>?

    /// Files, metadata and scores of the shoot, for grouping. Its decisions are never used.
    private var model: SessionState
    private var manualPicks = Set<String>()
    private var hashes: [ScoreKey: String] = [:]
    private var cachedCount = 0
    /// Photos analysis found unreadable, which `update(photos:)` tries again when they are passed.
    private var failed = Set<String>()
    private var started = false
    private var isCancelled = false
    private var isRunning = false

    /// Lifecycle work (start, rescans) runs one after another.
    private var operations: Task<Void, Never>?

    // Results waiting to be sent and saved.
    private var outgoingScores: [String: PhotoScores] = [:]
    private var outgoingUnreadable: [String: String] = [:]
    private var unsaved: [ScoreKey: PhotoScores] = [:]
    private var saves: Task<Void, Never>?
    private var lastSave = ContinuousClock.now
    private var ticker: Task<Void, Never>?

    // Grouping.
    private var groupingTask: Task<Void, Never>?
    private var groupingAgain = false
    private var newScoresSinceGrouping = 0
    private var lastGrouping = ContinuousClock.now
    private var groupingWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - database: where scores are cached. Nil analyses everything and saves nothing.
    ///   - tuning: the settings grouping and best picks are computed with.
    ///   - analyze: analyses one photo; `StandardAnalysis.function()` for the real thing.
    public init(
        database: CullaDatabase?,
        tuning: Tuning = Tuning(),
        options: Options = Options(),
        analyze: @escaping PhotoAnalysisFunction = StandardAnalysis.function()
    ) {
        self.database = database
        self.options = options
        model = SessionState(tuning: tuning)
        scheduler = AnalysisScheduler(concurrency: options.concurrency, priority: options.taskPriority, analyze: analyze)
        (events, continuation) = AsyncStream.makeStream(of: ShootAnalysisEvent.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Lifecycle

    /// Starts on the session's photos. Cached scores are delivered first, then the misses are
    /// analysed. Photos that already carry scores of the current version are taken as they are.
    /// Only the first call does anything; use `update(photos:)` after a rescan.
    public func start(photos: [PhotoItem]) {
        guard !started, !isCancelled else { return }
        started = true
        let scheduler = self.scheduler
        consumer = Task { [weak self] in
            for await event in scheduler.events {
                await self?.handle(event)
            }
        }
        let items = photos.map { item in
            PhotoItem(
                file: item.file,
                metadata: item.metadata,
                scores: item.scores?.version == PhotoScores.currentVersion ? item.scores : nil
            )
        }
        enqueueOperation { analysis in
            await analysis.begin(with: items)
        }
    }

    /// Brings the shoot in line with a rescan: photos that are new, or whose file changed on disk,
    /// are looked up in the cache and analysed when missing; photos that are gone are forgotten.
    /// Pass the session's photos after `SessionState.merge(scanned:)`, leaving out the ones the
    /// app knows to be unreadable.
    ///
    /// Photos this engine found unreadable but that are passed here are tried again, even when
    /// their files did not change: the app passes them when it does not believe the failure,
    /// as for photos that failed while their folder could not be reached (a card pulled during
    /// analysis). Call it when the folder comes back.
    public func update(photos: [PhotoItem]) {
        guard started, !isCancelled else { return }
        let scanned = photos.map { ScannedPhoto(file: $0.file, metadata: $0.metadata) }
        enqueueOperation { analysis in
            await analysis.merge(scanned)
        }
    }

    /// The photos that matter most right now, most important first: the visible ones, then the
    /// open group. Applies to the next photo started.
    public func setPriority(_ ids: [String]) async {
        await scheduler.setPriority(ids)
    }

    /// Photos analysed at once; the app lowers it on battery.
    public func setConcurrency(_ limit: Int) async {
        await scheduler.setConcurrency(limit)
    }

    /// Starts no new photo until `resume()`. Results already received are sent and saved.
    public func pause() async {
        guard started, !isCancelled, !(await scheduler.isPaused) else { return }
        await scheduler.pause()
        stopTicker()
        let progress = await progress()
        flushEvents(progress: progress)
        saveUnsaved()
        continuation.yield(.paused(progress))
    }

    public func resume() async {
        guard started, !isCancelled, await scheduler.isPaused else { return }
        await scheduler.resume()
        if isRunning { startTicker() }
        continuation.yield(.resumed(await progress()))
    }

    /// Stops analysis. Photos in flight are abandoned; every result already received is saved
    /// before this returns, so nothing is half-written. `events` then ends.
    public func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        await scheduler.cancel()
        stopTicker()
        consumer?.cancel()
        operations?.cancel()
        saveUnsaved()
        await saves?.value
        resumeGroupingWaiters()
        continuation.finish()
    }

    /// Changes the settings grouping and best picks use. Nothing is analysed again: only the
    /// stacks, best picks and duplicate sets are recomputed and sent.
    public func setTuning(_ tuning: Tuning) {
        guard model.tuning != tuning else { return }
        model.tuning = tuning
        regroup()
    }

    /// The photos the user made best pick by hand. A stack holding one of them always keeps it as
    /// its pick, whatever the scores say. Regroups when the set changes.
    public func setManualBestPicks(_ ids: Set<String>) {
        guard ids != manualPicks else { return }
        manualPicks = ids
        regroup()
    }

    /// Recomputes and sends the grouping now, without waiting for the next interval.
    public func regroup() {
        guard started, !isCancelled else { return }
        startGrouping()
    }

    /// Where the run stands, including the photos found in the cache.
    public func progress() async -> AnalysisProgress {
        var progress = await scheduler.progress()
        progress.cached = cachedCount
        return progress
    }

    // MARK: - Operations

    private func enqueueOperation(_ work: @escaping @Sendable (ShootAnalysis) async -> Void) {
        let previous = operations
        operations = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await work(self)
        }
    }

    private func begin(with items: [PhotoItem]) async {
        model = SessionState(photos: items, tuning: model.tuning)
        let missing = model.photos.filter { $0.scores == nil }
        await lookUpAndQueue(missing)
    }

    private func merge(_ scanned: [ScannedPhoto]) async {
        let result = model.merge(scanned: scanned)
        // Failures the app does not believe, such as photos read while the card was out.
        let passed = Set(scanned.map(\.id))
        let retry = failed.intersection(passed).subtracting(result.modified)
        failed.subtract(retry)
        failed.subtract(result.removed)
        for id in retry { model.setScores(nil, for: id) }
        guard !result.isEmpty || !retry.isEmpty else { return }
        let gone = result.removed + result.modified
        // The scheduler counts retried photos as done; forgetting them lets them be queued again.
        await scheduler.remove(gone + retry.sorted())
        for id in gone {
            outgoingScores[id] = nil
            outgoingUnreadable[id] = nil
        }
        let changed = Set(result.added + result.modified).union(retry)
        await lookUpAndQueue(model.photos.filter { changed.contains($0.id) })
        if changed.isEmpty { startGrouping() }
    }

    /// Delivers cached scores for these photos and queues the rest for analysis.
    private func lookUpAndQueue(_ photos: [PhotoItem]) async {
        var cached: [String: PhotoScores] = [:]
        if let database, !photos.isEmpty {
            let keys = photos.map { ScoreKey(file: $0.file) }
            let found = (try? await database.scores(for: keys)) ?? [:]
            for (photo, key) in zip(photos, keys) {
                if let scores = found[key] { cached[photo.id] = scores }
            }
        }
        guard !isCancelled else { return }
        for (id, scores) in cached { model.setScores(scores, for: id) }
        cachedCount += cached.count
        if !cached.isEmpty { continuation.yield(.cachedScores(cached)) }

        let jobs = photos.filter { cached[$0.id] == nil }.map { AnalysisJob(file: $0.file, sortDate: $0.sortDate) }
        if jobs.isEmpty, !isRunning {
            // Nothing to analyse: group what is known and say so.
            await finishRun()
            return
        }
        // Cached scores can form stacks at once, so group them without waiting for analysis.
        if !cached.isEmpty { startGrouping() }
        guard !jobs.isEmpty else { return }
        isRunning = true
        if !(await scheduler.isPaused) { startTicker() }
        await scheduler.enqueue(jobs)
        continuation.yield(.progress(await progress()))
    }

    // MARK: - Results

    private func handle(_ event: SchedulerEvent) async {
        guard !isCancelled else { return }
        switch event {
        case .result(let result):
            // A result for a file that has changed or gone since it was queued is stale.
            guard let item = model.photo(result.id),
                  item.file.fileSize == result.file.fileSize,
                  item.file.modificationDate == result.file.modificationDate
            else { return }
            switch result.outcome {
            case .scores(let scores):
                failed.remove(result.id)
                model.setScores(scores, for: result.id)
                outgoingScores[result.id] = scores
                outgoingUnreadable[result.id] = nil
                unsaved[ScoreKey(file: item.file)] = scores
                newScoresSinceGrouping += 1
                if unsaved.count >= options.saveBatchSize { saveUnsaved() }
            case .unreadable(let reason):
                failed.insert(result.id)
                model.markUnreadable(result.id, reason: reason)
                outgoingUnreadable[result.id] = reason
                outgoingScores[result.id] = nil
            }
            // While paused the ticker is stopped; photos that were in flight still go out now.
            if ticker == nil {
                flushEvents(progress: await progress())
                saveUnsaved()
            }
        case .idle:
            await finishRun()
        }
    }

    /// The queue drained: send what is left, save it, regroup, then report.
    private func finishRun() async {
        isRunning = false
        stopTicker()
        flushEvents(progress: await progress())
        saveUnsaved()
        await saves?.value
        guard !isCancelled else { return }
        await groupAndWait()
        // A rescan may have queued more work meanwhile; its own drain reports then.
        guard !isCancelled, !isRunning else { return }
        continuation.yield(.finished(await progress()))
    }

    /// Runs every `eventInterval` while analysis runs: sends results, saves when due, and
    /// regroups when due.
    private func tick() async {
        guard !isCancelled else { return }
        flushEvents(progress: await progress())
        let now = ContinuousClock.now
        if !unsaved.isEmpty, now - lastSave >= options.saveInterval { saveUnsaved() }
        if newScoresSinceGrouping > 0, groupingTask == nil, now - lastGrouping >= options.groupingInterval {
            startGrouping()
        }
    }

    private func flushEvents(progress: AnalysisProgress) {
        guard !outgoingScores.isEmpty || !outgoingUnreadable.isEmpty else { return }
        let batch = AnalysisBatch(scores: outgoingScores, unreadable: outgoingUnreadable, progress: progress)
        outgoingScores = [:]
        outgoingUnreadable = [:]
        continuation.yield(.analysed(batch))
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let interval = options.eventInterval
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: - Saving

    /// Saves the waiting scores in one transaction, after any save still running.
    private func saveUnsaved() {
        lastSave = ContinuousClock.now
        guard let database, !unsaved.isEmpty else {
            unsaved = [:]
            return
        }
        let batch = unsaved
        unsaved = [:]
        let previous = saves
        saves = Task {
            await previous?.value
            // A failed save only costs analysing those photos again next time.
            try? await database.saveScores(batch)
        }
    }

    // MARK: - Grouping

    private func startGrouping() {
        guard !isCancelled else { return }
        guard groupingTask == nil else {
            groupingAgain = true
            return
        }
        newScoresSinceGrouping = 0
        lastGrouping = ContinuousClock.now
        let snapshot = model
        let known = hashes
        let picks = manualPicks
        groupingTask = Task { [weak self] in
            let (grouping, found) = await BlockingQueue.shared.run {
                Self.computeGrouping(snapshot, hashes: known, manualPicks: picks)
            }
            await self?.groupingFinished(grouping, hashes: found)
        }
    }

    private func groupingFinished(_ grouping: SessionGrouping, hashes found: [ScoreKey: String]) {
        groupingTask = nil
        hashes.merge(found) { _, new in new }
        guard !isCancelled else { return resumeGroupingWaiters() }
        continuation.yield(.grouping(grouping))
        if groupingAgain {
            groupingAgain = false
            startGrouping()
        } else {
            resumeGroupingWaiters()
        }
    }

    /// Regroups with everything known now and waits until that grouping is sent.
    private func groupAndWait() async {
        startGrouping()
        await withCheckedContinuation { continuation in
            if groupingTask == nil {
                continuation.resume()
            } else {
                groupingWaiters.append(continuation)
            }
        }
    }

    private func resumeGroupingWaiters() {
        let waiters = groupingWaiters
        groupingWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Stacks with best picks, and duplicate sets, for a snapshot of the shoot. Blocks: it may
    /// read files to hash them. Returns the hashes it computed, to keep for next time.
    static func computeGrouping(
        _ state: SessionState,
        hashes: [ScoreKey: String],
        manualPicks: Set<String>
    ) -> (SessionGrouping, [ScoreKey: String]) {
        var found: [ScoreKey: String] = [:]
        var grouping = state.computeGrouping { item in
            let key = ScoreKey(file: item.file)
            if let hash = hashes[key] ?? found[key] { return hash }
            guard let hash = try? FileHasher.sha256(of: item.file.url) else { return nil }
            found[key] = hash
            return hash
        }
        grouping.stacks = grouping.stacks.map { stack in
            var stack = stack
            stack.bestPick = bestPick(of: stack.members, in: state, manualPicks: manualPicks)
            return stack
        }
        return (grouping, found)
    }

    /// The pick for a stack: a member the user picked by hand, else the best by `BestPick`
    /// among the members with scores.
    static func bestPick(of members: [String], in state: SessionState, manualPicks: Set<String>) -> String? {
        if let manual = members.first(where: { manualPicks.contains($0) }) { return manual }
        let scored = members.compactMap { id in state.photo(id)?.scores.map { (id, $0) } }
        let candidates = scored.map { BestPickCandidate(scores: $0.1, tuning: state.tuning) }
        return BestPick.best(candidates, tuning: state.tuning).map { scored[$0].0 }
    }
}
