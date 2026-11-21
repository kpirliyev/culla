import CullaCore
import Foundation

/// What the scheduler reports, in order, on `AnalysisScheduler.events`.
public enum SchedulerEvent: Sendable {
    /// One photo is finished.
    case result(AnalysisResult)
    /// Nothing is waiting or in flight any more. Sent each time the queue drains, also when the
    /// work drained by being removed.
    case idle
}

/// Analyses photos several at a time, in the order that matters most right now.
///
/// - **Order.** Photos named by `setPriority(_:)` go first, in the order given; the rest follow
///   in capture order. Changing priorities costs as much as the list is long and applies to the
///   next photo started.
/// - **Concurrency** can be changed while running. Lowering it lets photos in flight finish and
///   starts no new one until fewer than the new limit are running.
/// - **Pause** starts nothing new; photos in flight finish and are reported. **Resume** carries on.
/// - **Cancel** starts nothing new, cancels the tasks in flight, throws their results away and
///   ends `events` at once.
/// - A photo that fails comes back `.unreadable` and the run goes on.
///
/// Every photo queued is analysed exactly once, unless it is removed or the run is cancelled
/// first. Queuing a photo that is waiting, in flight or already analysed does nothing; to
/// analyse one again, such as after its file changed, remove it first.
public actor AnalysisScheduler {
    /// The rule `culla-eval` uses: one photo per core, at least 2 and at most 8. Speed levels off
    /// above about 6 at once on an 8-core M2, where Vision's own processors are the limit.
    public static var defaultConcurrency: Int {
        min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Seconds of unpaused time the photos-per-second figure is measured over.
    public static let rateWindowSeconds = 20.0

    /// Every result, then `.idle` each time the queue drains. Ends when the scheduler is cancelled.
    /// Meant for one consumer.
    public nonisolated let events: AsyncStream<SchedulerEvent>
    private let continuation: AsyncStream<SchedulerEvent>.Continuation

    private let analyze: PhotoAnalysisFunction
    private let taskPriority: TaskPriority
    public private(set) var concurrency: Int
    public private(set) var isPaused = false
    public private(set) var isCancelled = false

    // Waiting jobs, and the two lists they are taken from. Both lists may hold ids that are no
    // longer waiting; they are skipped, so each id is looked at once per list.
    private var waiting: [String: AnalysisJob] = [:]
    private var order: [String] = []
    private var orderCursor = 0
    private var priority: [String] = []
    private var priorityCursor = 0

    private struct InFlight {
        var token: UInt64
        var slot: Int
        var task: Task<Void, Never>
        /// True once the photo was removed: its result is thrown away when it comes back, and
        /// its slot stays taken until then so the concurrency limit holds for real.
        var discarded = false
    }
    private var inFlight: [String: InFlight] = [:]
    /// Photos analysed, so queuing them again does nothing until they are removed.
    private var analysed = Set<String>()
    private var nextToken: UInt64 = 0
    private var busySlots = Set<Int>()

    private var done = 0
    private var unreadable = 0
    private var meter: ThroughputMeter
    private let clock = ContinuousClock()
    private let startedAt: ContinuousClock.Instant
    private var wasIdle = true

    /// - Parameters:
    ///   - concurrency: photos analysed at once, at least 1.
    ///   - priority: the priority of the tasks that analyse.
    ///   - analyze: analyses one photo; `StandardAnalysis.function()` for the real thing.
    public init(
        concurrency: Int = AnalysisScheduler.defaultConcurrency,
        priority: TaskPriority = .medium,
        analyze: @escaping PhotoAnalysisFunction
    ) {
        self.concurrency = max(1, concurrency)
        self.taskPriority = priority
        self.analyze = analyze
        (events, continuation) = AsyncStream.makeStream(of: SchedulerEvent.self, bufferingPolicy: .unbounded)
        startedAt = ContinuousClock.now
        meter = ThroughputMeter(windowSeconds: Self.rateWindowSeconds, now: 0)
    }

    // MARK: - Work

    /// Queues photos and starts as many as the limit allows. Photos waiting, in flight or already
    /// analysed are skipped. Photos are analysed in capture order unless a priority says otherwise.
    public func enqueue(_ jobs: [AnalysisJob]) {
        guard !isCancelled, !jobs.isEmpty else { return }
        var added = false
        for job in jobs where waiting[job.id] == nil && inFlight[job.id] == nil && !analysed.contains(job.id) {
            waiting[job.id] = job
            added = true
        }
        guard added else { return }
        // Rebuild the capture order from what is waiting: rare (opening a shoot, a rescan) and
        // linear in the waiting photos.
        order = waiting.values
            .sorted { $0.sortDate != $1.sortDate ? $0.sortDate < $1.sortDate : $0.id < $1.id }
            .map(\.id)
        orderCursor = 0
        priorityCursor = 0
        wasIdle = false
        fill()
    }

    /// Forgets photos: waiting ones are dropped, the results of ones in flight are thrown away,
    /// and analysed ones may be queued again. Unknown ids are ignored.
    public func remove(_ ids: some Sequence<String>) {
        guard !isCancelled else { return }
        for id in ids {
            waiting[id] = nil
            analysed.remove(id)
            if inFlight[id] != nil, !inFlight[id]!.discarded {
                inFlight[id]!.discarded = true
                inFlight[id]!.task.cancel()
            }
        }
        reportIdleIfDrained()
    }

    /// Names the photos that matter most right now, most important first, such as the visible
    /// ones and then the open group. Replaces the previous list. Applies to the next photo started.
    public func setPriority(_ ids: [String]) {
        priority = ids
        priorityCursor = 0
    }

    /// Changes how many photos are analysed at once (at least 1).
    public func setConcurrency(_ limit: Int) {
        concurrency = max(1, limit)
        fill()
    }

    public func pause() {
        guard !isPaused, !isCancelled else { return }
        isPaused = true
        meter.pause(now: now)
    }

    public func resume() {
        guard isPaused, !isCancelled else { return }
        isPaused = false
        meter.resume(now: now)
        fill()
    }

    /// Stops: nothing new starts, tasks in flight are cancelled and their results thrown away,
    /// and `events` ends. Returns at once; it does not wait for the tasks to wind down.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        waiting.removeAll()
        order.removeAll()
        for entry in inFlight.values { entry.task.cancel() }
        continuation.finish()
    }

    /// Where the run stands.
    public func progress() -> AnalysisProgress {
        let liveInFlight = inFlight.values.filter { !$0.discarded }.count
        let total = done + waiting.count + liveInFlight
        return AnalysisProgress(
            done: done,
            total: total,
            running: liveInFlight,
            unreadable: unreadable,
            isPaused: isPaused,
            photosPerSecond: meter.rate(now: now),
            secondsRemaining: meter.secondsRemaining(total - done, now: now)
        )
    }

    /// True when a photo is waiting or in flight.
    public func isPending(_ id: String) -> Bool {
        waiting[id] != nil || inFlight[id].map { !$0.discarded } ?? false
    }

    // MARK: - Running

    private var now: Double {
        let elapsed = clock.now - startedAt
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Starts photos until the limit is reached or nothing is waiting.
    private func fill() {
        guard !isCancelled, !isPaused else { return }
        while busySlots.count < concurrency, let job = takeNext() {
            start(job)
        }
    }

    private func takeNext() -> AnalysisJob? {
        while priorityCursor < priority.count {
            let id = priority[priorityCursor]
            priorityCursor += 1
            if let job = waiting.removeValue(forKey: id) { return job }
        }
        while orderCursor < order.count {
            let id = order[orderCursor]
            orderCursor += 1
            if let job = waiting.removeValue(forKey: id) { return job }
        }
        return nil
    }

    private func start(_ job: AnalysisJob) {
        var slot = 0
        while busySlots.contains(slot) { slot += 1 }
        busySlots.insert(slot)
        nextToken += 1
        let token = nextToken
        let analyze = self.analyze
        // Detached, so the analysis runs on the global executor rather than on this actor.
        let task = Task.detached(priority: taskPriority) { [weak self] in
            let outcome = await analyze(job.file, slot)
            await self?.finished(job, token: token, outcome: outcome)
        }
        inFlight[job.id] = InFlight(token: token, slot: slot, task: task)
    }

    private func finished(_ job: AnalysisJob, token: UInt64, outcome: AnalysisOutcome) {
        guard let entry = inFlight[job.id], entry.token == token else { return }
        inFlight[job.id] = nil
        busySlots.remove(entry.slot)
        guard !isCancelled else { return }
        if !entry.discarded {
            analysed.insert(job.id)
            done += 1
            if case .unreadable = outcome { unreadable += 1 }
            meter.record(done: done, now: now)
            continuation.yield(.result(AnalysisResult(file: job.file, outcome: outcome)))
        }
        fill()
        reportIdleIfDrained()
    }

    private func reportIdleIfDrained() {
        guard !wasIdle, waiting.isEmpty, inFlight.isEmpty, !isCancelled else { return }
        wasIdle = true
        continuation.yield(.idle)
    }
}
