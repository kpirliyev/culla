import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation

// Runs the real analysis pipeline over a folder the way the app will, and reports how it went.
//
//   culla-pipeline-bench <folder> --db <file> [--runs <n>] [--jobs <n>]
//
// Each run opens a fresh `ShootAnalysis` on the same database, applies every event to a
// `SessionState` as the app would, and prints timings and event counts. The second run should
// find every score in the cache. The folder is only read.

struct BenchOptions {
    var folder: URL
    var database: URL
    var runs = 2
    var jobs = AnalysisScheduler.defaultConcurrency
}

func parse() -> BenchOptions? {
    var arguments = Array(CommandLine.arguments.dropFirst())[...]
    var folder: URL?
    var database: URL?
    var runs = 2
    var jobs = AnalysisScheduler.defaultConcurrency
    while let argument = arguments.popFirst() {
        switch argument {
        case "--db": database = arguments.popFirst().map { URL(fileURLWithPath: $0) }
        case "--runs": runs = arguments.popFirst().flatMap { Int($0) } ?? runs
        case "--jobs": jobs = arguments.popFirst().flatMap { Int($0) } ?? jobs
        default: folder = URL(fileURLWithPath: argument)
        }
    }
    guard let folder, let database else { return nil }
    return BenchOptions(folder: folder, database: database, runs: runs, jobs: jobs)
}

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

setvbuf(stdout, nil, _IOLBF, 0)

guard let options = parse() else {
    print("usage: culla-pipeline-bench <folder> --db <file> [--runs <n>] [--jobs <n>]")
    exit(2)
}

let clock = ContinuousClock()
let scanStart = clock.now
let scanned = try await ShootLoader.load(folder: options.folder)
print("Scanned \(scanned.count) photos in \(String(format: "%.2f", seconds(clock.now - scanStart))) s")
let database = try await CullaDatabase.open(at: options.database)

for run in 1...options.runs {
    var state = SessionState(scanned: scanned)
    var analysisOptions = ShootAnalysis.Options()
    analysisOptions.concurrency = options.jobs
    let analysis = ShootAnalysis(database: database, options: analysisOptions)

    let start = clock.now
    await analysis.start(photos: state.photos)

    var counts: [String: Int] = [:]
    var firstEvent: Double?
    var firstAnalysed: Double?
    var cached = 0
    var analysed = 0
    var unreadable = 0
    var groupings = 0
    var applySeconds = 0.0
    var finalProgress = AnalysisProgress()
    var rates: [Double] = []
    var estimates: [(at: Double, left: Double)] = []

    for await event in analysis.events {
        let at = seconds(clock.now - start)
        if firstEvent == nil { firstEvent = at }
        let applyStart = clock.now
        var finished = false
        switch event {
        case .cachedScores(let scores):
            counts["cachedScores", default: 0] += 1
            cached += scores.count
            state.setScores(scores)
        case .analysed(let batch):
            counts["analysed", default: 0] += 1
            if firstAnalysed == nil {
                firstAnalysed = at
                let names = (batch.scores.keys.sorted() + batch.unreadable.keys.sorted()).prefix(4)
                print(String(format: "  First batch at %.3f s: %d photos, such as %@", at, batch.scores.count + batch.unreadable.count,
                             names.joined(separator: ", ")))
            }
            analysed += batch.scores.count
            unreadable += batch.unreadable.count
            state.setScores(batch.scores)
            for (id, reason) in batch.unreadable { state.markUnreadable(id, reason: reason) }
            if let rate = batch.progress.photosPerSecond { rates.append(rate) }
            if let left = batch.progress.secondsRemaining { estimates.append((at, left)) }
        case .progress:
            counts["progress", default: 0] += 1
        case .grouping(let grouping):
            counts["grouping", default: 0] += 1
            groupings += 1
            state.applyGrouping(grouping)
        case .paused, .resumed:
            counts["pause/resume", default: 0] += 1
        case .finished(let progress):
            counts["finished", default: 0] += 1
            finalProgress = progress
            finished = true
        }
        applySeconds += seconds(clock.now - applyStart)
        if finished { break }
    }
    let total = seconds(clock.now - start)
    await analysis.cancel()

    print("")
    print("Run \(run)")
    print(String(format: "  Finished in %.2f s; %d from the cache, %d analysed, %d unreadable",
                 total, cached, analysed, unreadable))
    if analysed > 0 {
        print(String(format: "  Throughput: %.1f photos per second with %d at once", Double(analysed + unreadable) / total, options.jobs))
    }
    if let firstEvent { print(String(format: "  First event after %.3f s", firstEvent)) }
    if let firstAnalysed { print(String(format: "  First analysed batch after %.3f s", firstAnalysed)) }
    let eventTotal = counts.values.reduce(0, +)
    print("  Events: \(eventTotal) (" + counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + ")")
    print(String(format: "  Time applying events to SessionState: %.3f s", applySeconds))
    if !rates.isEmpty {
        print(String(format: "  Reported rate: first %.1f, last %.1f photos/s", rates.first!, rates.last!))
    }
    if estimates.count > 2 {
        // How much the time-left estimate moved between batches, beyond the time that passed.
        var worst = 0.0
        for (a, b) in zip(estimates, estimates.dropFirst()) {
            worst = max(worst, abs((b.left - a.left) + (b.at - a.at)))
        }
        print(String(format: "  Time-left estimate: first %.0f s, largest jump between batches %.1f s", estimates.first!.left, worst))
    }
    let picks = state.stacks.filter { $0.bestPick != nil }.count
    print("  Groupings sent: \(groupings); stacks \(state.stacks.count) (\(picks) with a best pick), duplicate sets \(state.duplicateSets.count)")
    print("  Progress at the end: done \(finalProgress.done) of \(finalProgress.total), cached \(finalProgress.cached)")
}
