import CullaAnalysis
import CullaCore
import CullaCommands
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Observation

/// Runs the background analysis of one open shoot and hands what it learns to the session model.
///
/// One `ShootAnalysis` per open shoot. It starts when the shoot opens, without being asked, and
/// never blocks culling: its events are applied to `SessionState` a few times a second at most,
/// and every view works with whatever scores exist so far. The photos the person is looking at go
/// first (`setPriority`), and how many are analysed at once follows the Mac's memory, its power
/// source and memory pressure (`AnalysisConcurrency`).
@MainActor
@Observable
final class AnalysisController {
    enum Phase: String {
        /// Created, reading cached scores.
        case starting
        case running
        case paused
        /// Everything queued is analysed and the final grouping applied.
        case finished
        /// Stopped because the shoot closed.
        case cancelled
    }

    private(set) var phase = Phase.starting {
        didSet { if phase != oldValue { updateActivity() } }
    }
    /// Progress as the engine reported it last. `done` and `total` count only photos analysed in
    /// this open; `cached` the photos whose scores came from the cache.
    private(set) var progress = AnalysisProgress()
    /// Photos analysed at once now, and why.
    private(set) var concurrency: Int
    private(set) var concurrencyReason = ""
    /// Photos analysed (or found unreadable) since the shoot opened, as opposed to read from
    /// the cache.
    private(set) var analysedThisOpen = 0
    /// Photos given new scores (not found unreadable) since the shoot opened.
    private(set) var scoredThisOpen = 0
    private(set) var cachedCount = 0
    private(set) var groupingsApplied = 0

    // Timings, in seconds since the open started, for diagnostics and the automation dump.
    @ObservationIgnored private(set) var openStartedAt: Date
    @ObservationIgnored private(set) var startedAt: Date?
    @ObservationIgnored private(set) var cachedAppliedAt: Date?
    @ObservationIgnored private(set) var firstResultAt: Date?
    @ObservationIgnored private(set) var firstGroupCountAt: Date?
    @ObservationIgnored private(set) var firstGroupingAt: Date?
    @ObservationIgnored private(set) var finishedAt: Date?
    /// Events received, by kind, for the automation dump.
    @ObservationIgnored private(set) var eventCounts: [String: Int] = [:]

    @ObservationIgnored private let analysis: ShootAnalysis
    @ObservationIgnored private weak var model: SessionModel?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let power: PowerMonitor
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var priorityTask: Task<Void, Never>?
    @ObservationIgnored private var concurrencyObservation: ObservationToken?
    @ObservationIgnored private var lastPriority: [String] = []
    @ObservationIgnored private var sentTuning: Tuning
    /// The hand-chosen best picks the engine was given, so it never replaces them.
    @ObservationIgnored private var sentManualPicks: Set<String>
    /// A mirror of `ShootAnalysis`'s own grouping state once analysis has finished: whether a
    /// grouping is being computed and whether another was asked for meanwhile. Each tuning
    /// change asks for one; each grouping event ends one.
    @ObservationIgnored private var groupingInFlight = false
    @ObservationIgnored private var groupingAgain = false
    /// Held while analysis runs, so macOS does not throttle it (App Nap) when the window is
    /// behind others. Analysis is work the person started by opening the shoot.
    @ObservationIgnored private var activity: (any NSObjectProtocol)?

    init(model: SessionModel, database: CullaDatabase, settings: AppSettings, power: PowerMonitor, openStartedAt: Date) {
        self.model = model
        self.settings = settings
        self.power = power
        self.openStartedAt = openStartedAt
        sentTuning = model.state.tuning
        sentManualPicks = model.state.handPickedBestPicks
        let limit = Self.limit(settings: settings, power: power)
        concurrency = limit
        concurrencyReason = Self.reason(settings: settings, power: power)
        var options = ShootAnalysis.Options()
        options.concurrency = limit
        // Below the interface, which must never wait for analysis.
        options.taskPriority = .utility
        analysis = ShootAnalysis(database: database, tuning: model.state.tuning, options: options)
    }

    /// Starts analysing the session's photos: cached scores first, then the misses.
    func start() {
        guard eventTask == nil, let model else { return }
        startedAt = Date()
        updateActivity()
        let analysis = analysis
        eventTask = Task { [weak self] in
            for await event in analysis.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        // Files already known to be unreadable are not tried again on every open.
        let photos = model.state.photos.filter { !$0.isUnreadable }
        let picks = sentManualPicks
        Task {
            // The picks chosen by hand in an earlier open, before the first grouping.
            await analysis.setManualBestPicks(picks)
            await analysis.start(photos: photos)
        }
        concurrencyObservation = observeChanges { [weak self] in self?.followPower() }
    }

    /// Stops analysis and waits until every result already received is saved.
    func cancel() async {
        guard phase != .cancelled else { return }
        phase = .cancelled
        priorityTask?.cancel()
        concurrencyObservation?.cancel()
        await analysis.cancel()
        eventTask?.cancel()
    }

    /// After a rescan, an apply or an undo: photos that are new or changed are looked up in the
    /// cache and analysed when missing; photos that are gone are forgotten.
    func update(photos: [PhotoItem]) {
        guard phase != .cancelled, eventTask != nil else { return }
        let photos = photos.filter { !$0.isUnreadable }
        let analysis = analysis
        Task { await analysis.update(photos: photos) }
    }

    var isRunning: Bool { phase == .running || phase == .starting }
    var isPaused: Bool { phase == .paused }
    var isFinished: Bool { phase == .finished }

    /// True until the final grouping after analysis, or after the last tuning change, has been
    /// applied: stacks and duplicate sets may still change.
    var groupingPending: Bool {
        phase == .starting || phase == .running || groupingInFlight
    }

    private func updateActivity() {
        let working = phase == .starting || phase == .running
        if working, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep], reason: "Analysing the photos of a shoot"
            )
        } else if !working, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    // MARK: - Control

    func pause() {
        guard phase == .running || phase == .starting else { return }
        Task { await analysis.pause() }
    }

    func resume() {
        guard phase == .paused else { return }
        Task { await analysis.resume() }
    }

    func togglePause() {
        isPaused ? resume() : pause()
    }

    /// Hands a new tuning to the engine, which recomputes stacks, best picks and duplicate sets
    /// from the stored scores. Nothing is analysed again.
    func setTuning(_ tuning: Tuning) {
        guard tuning != sentTuning, phase != .cancelled else { return }
        sentTuning = tuning
        if !isRunning {
            if groupingInFlight { groupingAgain = true } else { groupingInFlight = true }
        }
        Task { await analysis.setTuning(tuning) }
    }

    /// Hands the engine the best picks chosen by hand: it regroups, and automatic grouping never
    /// replaces them.
    func setManualBestPicks(_ picks: Set<String>) {
        guard picks != sentManualPicks, phase != .cancelled else { return }
        sentManualPicks = picks
        if !isRunning {
            if groupingInFlight { groupingAgain = true } else { groupingInFlight = true }
        }
        let analysis = analysis
        Task { await analysis.setManualBestPicks(picks) }
    }

    /// The photos that matter most right now, most important first. Debounced, so scrolling and
    /// stepping do not flood the engine.
    func prioritize(_ ids: [String]) {
        guard phase == .running || phase == .starting || phase == .paused else { return }
        guard ids != lastPriority else { return }
        lastPriority = ids
        priorityTask?.cancel()
        let analysis = analysis
        priorityTask = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await analysis.setPriority(ids)
        }
    }

    // MARK: - Concurrency

    private static func limit(settings: AppSettings, power: PowerMonitor) -> Int {
        AnalysisConcurrency.limit(
            engineDefault: AnalysisScheduler.defaultConcurrency,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            onBattery: power.onBattery,
            reduceOnBattery: settings.reduceAnalysisOnBattery,
            memoryPressure: power.memoryPressure
        )
    }

    private static func reason(settings: AppSettings, power: PowerMonitor) -> String {
        AnalysisConcurrency.reason(
            engineDefault: AnalysisScheduler.defaultConcurrency,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            onBattery: power.onBattery,
            reduceOnBattery: settings.reduceAnalysisOnBattery,
            memoryPressure: power.memoryPressure
        )
    }

    /// Follows the power source, memory pressure and the setting.
    private func followPower() {
        let limit = Self.limit(settings: settings, power: power)
        let reason = Self.reason(settings: settings, power: power)
        if reason != concurrencyReason { concurrencyReason = reason }
        guard limit != concurrency else { return }
        concurrency = limit
        let analysis = analysis
        Task { await analysis.setConcurrency(limit) }
    }

    // MARK: - Events

    private func handle(_ event: ShootAnalysisEvent) {
        guard phase != .cancelled, let model else { return }
        switch event {
        case .cachedScores(let scores):
            count("cachedScores")
            cachedCount += scores.count
            model.applyAnalysis(scores: scores, unreadable: [:])
            if cachedAppliedAt == nil { cachedAppliedAt = Date() }
            noteGroupCounts(model)
        case .analysed(let batch):
            count("analysed")
            // Work after a rescan runs again after the first finish.
            if phase == .starting || (phase == .finished && !batch.progress.isComplete) { phase = .running }
            if firstResultAt == nil { firstResultAt = Date() }
            analysedThisOpen += batch.scores.count + batch.unreadable.count
            scoredThisOpen += batch.scores.count
            progress = withCached(batch.progress)
            model.applyAnalysis(scores: batch.scores, unreadable: batch.unreadable)
            noteGroupCounts(model)
        case .progress(let progress):
            count("progress")
            if phase == .starting, !progress.isComplete { phase = progress.isPaused ? .paused : .running }
            self.progress = withCached(progress)
        case .grouping(let grouping):
            count("grouping")
            model.applyGrouping(grouping)
            groupingsApplied += 1
            if firstGroupingAt == nil { firstGroupingAt = Date() }
            noteGroupCounts(model)
            if groupingAgain {
                groupingAgain = false
            } else {
                groupingInFlight = false
            }
        case .paused(let progress):
            count("paused")
            self.progress = withCached(progress)
            phase = .paused
        case .resumed(let progress):
            count("resumed")
            self.progress = withCached(progress)
            phase = progress.isComplete ? phase : .running
        case .finished(let progress):
            count("finished")
            self.progress = withCached(progress)
            phase = .finished
            finishedAt = Date()
            groupingInFlight = false
            groupingAgain = false
            model.analysisFinished(analysedSomething: scoredThisOpen > 0)
        }
    }

    private func withCached(_ progress: AnalysisProgress) -> AnalysisProgress {
        var progress = progress
        progress.cached = max(progress.cached, cachedCount)
        return progress
    }

    private func count(_ kind: String) {
        eventCounts[kind, default: 0] += 1
    }

    private func noteGroupCounts(_ model: SessionModel) {
        guard firstGroupCountAt == nil else { return }
        let state = model.state
        if GroupID.allCases.contains(where: { $0.needsAnalysis && state.count(of: $0).total > 0 }) {
            firstGroupCountAt = Date()
        }
    }

    // MARK: - Words

    /// The toolbar's line, or nil when it should show nothing.
    var statusText: String {
        switch phase {
        case .starting: return localized("analysis.starting", default: "Analysing…")
        case .running:
            return AnalysisText.running(done: progress.done, total: progress.total, secondsRemaining: progress.secondsRemaining)
        case .paused: return AnalysisText.paused(done: progress.done, total: progress.total)
        case .finished: return localized("analysis.finished", default: "Analysed")
        case .cancelled: return ""
        }
    }

    /// Photos with scores or found unreadable, of the photos in the session: how far the groups
    /// can be trusted.
    var checkedFraction: Double {
        progress.total > 0 ? Double(progress.done) / Double(progress.total) : (isFinished ? 1 : 0)
    }

    /// Seconds since the open started, rounded to milliseconds, for the dump.
    func seconds(_ date: Date?) -> Double? {
        date.map { ($0.timeIntervalSince(openStartedAt) * 1000).rounded() / 1000 }
    }
}
