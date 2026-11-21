import CullaCore
import CullaPipeline
import Foundation
import Synchronization

let shootStart = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// A photo file that need not exist: the fake analyzer never opens it.
func fakeFile(_ id: String, size: Int64? = nil, modified: Date = shootStart, folder: URL = URL(fileURLWithPath: "/nonexistent/shoot")) -> PhotoFile {
    PhotoFile(
        id: id,
        url: folder.appendingPathComponent(id),
        fileSize: size ?? Int64(1000 + id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xFFFFFF }),
        modificationDate: modified,
        isRAW: false
    )
}

/// Jobs named p000, p001, ... one second apart in capture order.
func fakeJobs(_ count: Int, prefix: String = "p") -> [AnalysisJob] {
    (0..<count).map { index in
        AnalysisJob(file: fakeFile(String(format: "\(prefix)%03d", index), size: Int64(10_000 + index)),
                    sortDate: shootStart.addingTimeInterval(Double(index)))
    }
}

/// Scores whose blur score is `sharpness`, with an optional feature vector.
func fakeScores(sharpness: Double = 50, feature: [Float]? = nil, aesthetics: Double? = nil) -> PhotoScores {
    var scores = PhotoScores(analysedWidth: 100, analysedHeight: 80)
    scores.subjectSharpness = sharpness
    scores.frameSharpness = sharpness
    scores.featurePrint = feature.map(FeatureVector.encode)
    scores.aesthetics = aesthetics
    return scores
}

/// A deterministic stand-in for the real analysis, recording what it was asked to do.
final class FakeAnalyzer: Sendable {
    struct State {
        var started: [String] = []
        var finished: [String] = []
        var calls: [String: Int] = [:]
        var running = 0
        var maxRunning = 0
        /// Running count (including the new photo) at each start, in start order.
        var runningAtStart: [Int] = []
        var slotsInUse = Set<Int>()
        var slotClash = false
        var cancelled = 0
    }

    let state = Mutex(State())
    let delay: Duration
    let failing: Set<String>
    let scores: @Sendable (String) -> PhotoScores

    init(
        delay: Duration = .zero,
        failing: Set<String> = [],
        scores: @escaping @Sendable (String) -> PhotoScores = { _ in fakeScores() }
    ) {
        self.delay = delay
        self.failing = failing
        self.scores = scores
    }

    var function: PhotoAnalysisFunction {
        { [self] file, slot in await self.analyze(file, slot: slot) }
    }

    func analyze(_ file: PhotoFile, slot: Int) async -> AnalysisOutcome {
        state.withLock { state in
            state.started.append(file.id)
            state.calls[file.id, default: 0] += 1
            state.running += 1
            state.maxRunning = max(state.maxRunning, state.running)
            state.runningAtStart.append(state.running)
            if !state.slotsInUse.insert(slot).inserted { state.slotClash = true }
        }
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                state.withLock { $0.cancelled += 1 }
            }
        } else {
            await Task.yield()
        }
        state.withLock { state in
            state.running -= 1
            state.slotsInUse.remove(slot)
            state.finished.append(file.id)
        }
        if failing.contains(file.id) { return .unreadable("Cannot decode \(file.id)") }
        return .scores(scores(file.id))
    }

    var snapshot: State { state.withLock { $0 } }
}

/// Waits until `condition` holds, polling, or fails after `timeout`.
func eventually(timeout: Duration = .seconds(10), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
