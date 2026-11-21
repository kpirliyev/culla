import CullaAnalysis
import CullaCore
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Synchronization
import Testing

/// Reads a coordinator's events in order, keeping every one.
final class EventReader {
    private var iterator: AsyncStream<ShootAnalysisEvent>.Iterator
    private(set) var all: [ShootAnalysisEvent] = []

    init(_ analysis: ShootAnalysis) {
        iterator = analysis.events.makeAsyncIterator()
    }

    /// Reads until an event matches and returns the events read, that one included. Stops early
    /// when the stream ends.
    @discardableResult
    func read(until match: (ShootAnalysisEvent) -> Bool) async -> [ShootAnalysisEvent] {
        var read: [ShootAnalysisEvent] = []
        while let event = await iterator.next() {
            read.append(event)
            all.append(event)
            if match(event) { break }
        }
        return read
    }

    @discardableResult
    func untilFinished() async -> [ShootAnalysisEvent] {
        await read { if case .finished = $0 { true } else { false } }
    }

    /// Reads until the stream ends.
    @discardableResult
    func toEnd() async -> [ShootAnalysisEvent] {
        await read { _ in false }
    }
}

extension Array where Element == ShootAnalysisEvent {
    var cachedScores: [String: PhotoScores] {
        reduce(into: [:]) { result, event in
            if case .cachedScores(let scores) = event { result.merge(scores) { _, new in new } }
        }
    }

    /// Ids of analysed photos, in the order the batches came, one entry per delivery.
    var analysedIDs: [String] {
        flatMap { event -> [String] in
            if case .analysed(let batch) = event { return batch.scores.keys.sorted() }
            return []
        }
    }

    var unreadableIDs: [String] {
        flatMap { event -> [String] in
            if case .analysed(let batch) = event { return batch.unreadable.keys.sorted() }
            return []
        }
    }

    var groupings: [SessionGrouping] {
        compactMap { if case .grouping(let grouping) = $0 { grouping } else { nil } }
    }

    var finished: AnalysisProgress? {
        compactMap { if case .finished(let progress) = $0 { progress } else { nil } }.last
    }
}

/// Photos named p000, p001, ... one second apart.
private func items(_ count: Int, prefix: String = "p") -> [PhotoItem] {
    fakeJobs(count, prefix: prefix).map { job in
        PhotoItem(file: job.file, metadata: PhotoMetadata(captureDate: job.sortDate))
    }
}

private func keys(_ items: [PhotoItem]) -> [ScoreKey] {
    items.map { ScoreKey(file: $0.file) }
}

private func options(_ change: (inout ShootAnalysis.Options) -> Void = { _ in }) -> ShootAnalysis.Options {
    var options = ShootAnalysis.Options()
    options.eventInterval = .milliseconds(20)
    change(&options)
    return options
}

@Suite("ShootAnalysis", .timeLimit(.minutes(1)))
struct ShootAnalysisTests {
    @Test func cachedScoresAreDeliveredWithoutAnalysis() async throws {
        let database = try CullaDatabase.inMemory()
        let photos = items(10)
        try await database.saveScores(Dictionary(uniqueKeysWithValues: keys(photos).map { ($0, fakeScores(sharpness: 70)) }))
        let fake = FakeAnalyzer()
        let analysis = ShootAnalysis(database: database, options: options(), analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.start(photos: photos)
        let events = await reader.untilFinished()

        guard case .cachedScores(let cached) = events.first else {
            Issue.record("cached scores come first")
            return
        }
        #expect(cached.count == 10)
        #expect(cached["p004"]?.subjectSharpness == 70)
        #expect(fake.snapshot.calls.isEmpty)
        #expect(events.finished?.cached == 10)
        #expect(events.finished?.total == 0)
        await analysis.cancel()
    }

    @Test func onlyMissesAreAnalysedAndEverythingIsSaved() async throws {
        let database = try CullaDatabase.inMemory()
        let photos = items(20)
        let cachedKeys = keys(Array(photos.prefix(8)))
        try await database.saveScores(Dictionary(uniqueKeysWithValues: cachedKeys.map { ($0, fakeScores()) }))
        let fake = FakeAnalyzer()
        let analysis = ShootAnalysis(database: database, options: options(), analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.start(photos: photos)
        let events = await reader.untilFinished()

        #expect(Set(fake.snapshot.calls.keys) == Set(photos.dropFirst(8).map(\.id)))
        #expect(fake.snapshot.calls.values.allSatisfy { $0 == 1 })
        #expect(events.cachedScores.count == 8)
        #expect(Set(events.analysedIDs) == Set(photos.dropFirst(8).map(\.id)))
        // The cache comes before any analysed photo.
        let firstCached = events.firstIndex { if case .cachedScores = $0 { true } else { false } }
        let firstAnalysed = events.firstIndex { if case .analysed = $0 { true } else { false } }
        #expect(firstCached! < firstAnalysed!)
        #expect(try await database.scores(for: keys(photos)).count == 20)
        #expect(events.finished?.done == 12 && events.finished?.total == 12 && events.finished?.cached == 8)
        await analysis.cancel()
    }

    @Test func resultsAreSavedInBatches() async throws {
        let database = try CullaDatabase.inMemory()
        let photos = items(45)
        let analysis = ShootAnalysis(
            database: database,
            options: options {
                $0.concurrency = 1
                $0.saveBatchSize = 10
                $0.saveInterval = .seconds(60)
            },
            analyze: FakeAnalyzer(delay: .milliseconds(10)).function
        )
        let reader = EventReader(analysis)
        await analysis.start(photos: photos)
        // Look at the store each time a batch of results arrives.
        var savedWhileRunning: [Int] = []
        while true {
            let events = await reader.read { event in
                switch event {
                case .analysed, .finished: true
                default: false
                }
            }
            guard let last = events.last else { break }
            if case .finished = last { break }
            savedWhileRunning.append(try await database.cachedScoreCount())
        }
        #expect(!savedWhileRunning.isEmpty)
        // Every save is one batch of 10; only the final save at the end of the run is smaller.
        #expect(savedWhileRunning.allSatisfy { $0 % 10 == 0 || $0 == 45 }, "\(savedWhileRunning)")
        #expect(savedWhileRunning.contains { $0 > 0 && $0 < 45 }, "batches are saved while analysis runs")
        #expect(try await database.cachedScoreCount() == 45, "the last, partial batch is saved before finishing")
        await analysis.cancel()
    }

    @Test func aSecondCoordinatorOnTheSameDatabaseAnalysesNothing() async throws {
        let database = try CullaDatabase.inMemory()
        let photos = items(20)
        let first = ShootAnalysis(database: database, options: options(), analyze: FakeAnalyzer().function)
        let firstReader = EventReader(first)
        await first.start(photos: photos)
        await firstReader.untilFinished()
        await first.cancel()

        let fake = FakeAnalyzer()
        let second = ShootAnalysis(database: database, options: options(), analyze: fake.function)
        let reader = EventReader(second)
        await second.start(photos: photos)
        let events = await reader.untilFinished()
        #expect(fake.snapshot.calls.isEmpty)
        #expect(events.cachedScores.count == 20)
        #expect(events.analysedIDs.isEmpty)
        await second.cancel()
    }

    @Test func aFileThatChangedOnDiskIsAnalysedAgain() async throws {
        let database = try CullaDatabase.inMemory()
        var photos = items(10)
        let first = ShootAnalysis(database: database, options: options(), analyze: FakeAnalyzer().function)
        let firstReader = EventReader(first)
        await first.start(photos: photos)
        await firstReader.untilFinished()
        await first.cancel()

        photos[3].file.modificationDate = shootStart.addingTimeInterval(3600)
        photos[3].file.fileSize += 1
        let fake = FakeAnalyzer()
        let second = ShootAnalysis(database: database, options: options(), analyze: fake.function)
        let reader = EventReader(second)
        await second.start(photos: photos)
        let events = await reader.untilFinished()
        #expect(fake.snapshot.started == ["p003"])
        #expect(events.cachedScores.count == 9)
        #expect(events.analysedIDs == ["p003"])
        // The new entry replaced the old one.
        #expect(try await database.cachedScoreCount() == 10)
        await second.cancel()
    }

    @Test func aRescanAnalysesNewAndChangedPhotosAndForgetsGoneOnes() async throws {
        let database = try CullaDatabase.inMemory()
        // Every frame looks alike and they are a second apart, so they form one stack.
        let fake = FakeAnalyzer(delay: .milliseconds(2)) { _ in fakeScores(feature: [0, 0, 0]) }
        let analysis = ShootAnalysis(database: database, options: options(), analyze: fake.function)
        let reader = EventReader(analysis)
        var session = SessionState(photos: items(6))
        await analysis.start(photos: session.photos)
        let firstRun = await reader.untilFinished()
        #expect(firstRun.groupings.last?.stacks.first?.members.count == 6)

        // A rescan: p001 is gone, p002 changed, p100 is new.
        var scanned = session.photos.filter { $0.id != "p001" }.map { ScannedPhoto(file: $0.file, metadata: $0.metadata) }
        scanned[1].file.modificationDate = shootStart.addingTimeInterval(99)
        scanned.append(ScannedPhoto(
            file: fakeFile("p100", size: 99_999),
            metadata: PhotoMetadata(captureDate: shootStart.addingTimeInterval(6))
        ))
        let merge = session.merge(scanned: scanned)
        #expect(merge.removed == ["p001"] && merge.modified == ["p002"] && merge.added == ["p100"])
        await analysis.update(photos: session.photos)
        let secondRun = await reader.untilFinished()

        #expect(Set(secondRun.analysedIDs) == ["p002", "p100"])
        let calls = fake.snapshot.calls
        #expect(calls["p002"] == 2 && calls["p100"] == 1 && calls["p000"] == 1)
        let stack = try #require(secondRun.groupings.last?.stacks.first)
        #expect(!stack.members.contains("p001"))
        #expect(stack.members.contains("p100"))
        await analysis.cancel()
    }

    @Test func groupingHasTheExpectedStacksDuplicateSetsAndBestPicks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CullaPipelineTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two byte-identical files: an exact duplicate set.
        let copy = Data(repeating: 7, count: 4096)
        try copy.write(to: folder.appendingPathComponent("C1"))
        try copy.write(to: folder.appendingPathComponent("C2"))

        func item(_ id: String, at seconds: Double, size: Int64? = nil) -> PhotoItem {
            PhotoItem(
                file: fakeFile(id, size: size, folder: folder),
                metadata: PhotoMetadata(captureDate: shootStart.addingTimeInterval(seconds))
            )
        }
        let photos = [
            item("A1", at: 0), item("A2", at: 1), item("A3", at: 2),
            item("B1", at: 100),
            item("C1", at: 200, size: 4096), item("C2", at: 300, size: 4096),
            item("D1", at: 400), item("D2", at: 400),
        ]
        let closedEyes = FaceScores(
            box: UnitRect(x: 0.3, y: 0.3, width: 0.3, height: 0.3), sizeFraction: 0.3,
            leftEyeOpenness: 0.1, rightEyeOpenness: 0.1, sharpness: 90
        )
        let fake = FakeAnalyzer { id in
            switch id {
            case "A1": return fakeScores(sharpness: 30, feature: [0, 0, 0])
            case "A2":
                var scores = fakeScores(sharpness: 90, feature: [0.1, 0, 0])
                scores.faces = [closedEyes]
                return scores
            case "A3": return fakeScores(sharpness: 80, feature: [0.2, 0, 0])
            case "B1": return fakeScores(feature: [5, 5, 5])
            case "D1", "D2": return fakeScores(feature: id == "D1" ? [9, 0, 0] : [9.05, 0, 0])
            default: return fakeScores()
            }
        }
        let analysis = ShootAnalysis(database: try CullaDatabase.inMemory(), options: options(), analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.start(photos: photos)
        let events = await reader.untilFinished()
        let grouping = try #require(events.groupings.last)
        // The final grouping comes before Finished.
        let lastGrouping = events.lastIndex { if case .grouping = $0 { true } else { false } }
        #expect(lastGrouping == events.count - 2)

        #expect(grouping.stacks == [
            PhotoStack(members: ["A1", "A2", "A3"], bestPick: "A3"),
            PhotoStack(members: ["D1", "D2"], bestPick: "D1"),
        ])
        #expect(grouping.duplicateSets == [
            PhotoDuplicateSet(kind: .exact, members: ["C1", "C2"]),
            PhotoDuplicateSet(kind: .near, members: ["D1", "D2"]),
        ])

        // The app applies it as it is.
        var session = SessionState(photos: photos)
        for (id, scores) in events.reduce(into: [String: PhotoScores](), { result, event in
            if case .analysed(let batch) = event { result.merge(batch.scores) { _, new in new } }
        }) {
            session.setScores(scores, for: id)
        }
        session.applyGrouping(grouping)
        #expect(session.stack(containing: "A2")?.bestPick == "A3")

        // A pick made by hand is kept, and survives a tuning change that regroups.
        await analysis.setManualBestPicks(["A1"])
        let manual = await reader.read { if case .grouping = $0 { true } else { false } }
        #expect(manual.groupings.last?.stacks.first == PhotoStack(members: ["A1", "A2", "A3"], bestPick: "A1"))

        var tuning = Tuning()
        tuning.bestPickSharpnessMargin = 100
        await analysis.setTuning(tuning)
        let retuned = await reader.read { if case .grouping = $0 { true } else { false } }
        #expect(retuned.groupings.last?.stacks.first?.bestPick == "A1")

        // Without the hand pick, a wide sharpness margin and no face ratings leave A1 and A3
        // tied, so the earlier frame wins.
        await analysis.setManualBestPicks([])
        let tied = await reader.read { if case .grouping = $0 { true } else { false } }
        #expect(tied.groupings.last?.stacks.first?.bestPick == "A1")

        // Tighter similarity splits the stack; nothing is analysed again.
        let callsBefore = fake.snapshot.calls
        tuning.stackDistance = 0.07
        await analysis.setTuning(tuning)
        let split = await reader.read { if case .grouping = $0 { true } else { false } }
        #expect(split.groupings.last?.stacks == [PhotoStack(members: ["D1", "D2"], bestPick: "D1")])
        #expect(fake.snapshot.calls == callsBefore)
        await analysis.cancel()
    }

    @Test func groupsFillInWhileAnalysisRuns() async throws {
        let fake = FakeAnalyzer(delay: .milliseconds(5)) { _ in fakeScores(feature: [0, 0, 0]) }
        let analysis = ShootAnalysis(
            database: nil,
            options: options {
                $0.concurrency = 2
                $0.groupingInterval = .milliseconds(50)
            },
            analyze: fake.function
        )
        let reader = EventReader(analysis)
        await analysis.start(photos: items(80))
        let events = await reader.untilFinished()
        let sizes = events.groupings.map { $0.stacks.map(\.members.count).reduce(0, +) }
        #expect(sizes.count >= 3, "groupings were sent while analysis ran: \(sizes)")
        #expect(sizes.last == 80)
        #expect(zip(sizes, sizes.dropFirst()).allSatisfy { $0 <= $1 })
        await analysis.cancel()
    }

    @Test func pauseAndResumeAreReported() async throws {
        let fake = FakeAnalyzer(delay: .milliseconds(10))
        let analysis = ShootAnalysis(database: nil, options: options { $0.concurrency = 2 }, analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.start(photos: items(30))
        await reader.read { if case .analysed = $0 { true } else { false } }
        await analysis.pause()
        let paused = await reader.read { if case .paused = $0 { true } else { false } }
        #expect(paused.last.map { if case .paused(let progress) = $0 { progress.isPaused } else { false } } == true)
        // Photos the scheduler started before the pause may only now begin; let them finish.
        #expect(await eventually { await analysis.progress().running == 0 })
        let startedAtPause = fake.snapshot.started.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.snapshot.started.count == startedAtPause)
        #expect(startedAtPause < 30)

        await analysis.resume()
        let rest = await reader.untilFinished()
        guard case .resumed = rest.first(where: { if case .analysed = $0 { false } else { true } }) else {
            Issue.record("resumed is reported")
            return
        }
        #expect(Set(reader.all.analysedIDs).count == 30)
        #expect(fake.snapshot.calls.count == 30)
        await analysis.cancel()
    }

    @Test func cancelEndsTheEventsAndSavesWhatArrived() async throws {
        let database = try CullaDatabase.inMemory()
        let fake = FakeAnalyzer(delay: .milliseconds(30))
        let analysis = ShootAnalysis(database: database, options: options { $0.concurrency = 2 }, analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.start(photos: items(100))
        await reader.read { if case .analysed = $0 { true } else { false } }
        let clock = ContinuousClock()
        let start = clock.now
        await analysis.cancel()
        await reader.toEnd()
        // Cancelling does not wait for the queue: no photo starts afterwards, and most never
        // started. Counted rather than timed, so a busy machine cannot fail it; the time limit
        // only catches a cancel that hangs (the whole queue takes 1.5 s on an idle machine).
        let startedAtCancel = fake.snapshot.started.count
        #expect(clock.now - start < .seconds(10))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.snapshot.started.count == startedAtCancel)
        #expect(startedAtCancel < 100)
        let delivered = Set(reader.all.analysedIDs)
        let saved = try await database.cachedScoreCount()
        #expect(saved >= delivered.count, "everything delivered is saved")
        #expect(saved < 100)
        // Calls after cancelling do nothing.
        await analysis.update(photos: items(3, prefix: "late"))
        await analysis.regroup()
        #expect(try await database.cachedScoreCount() == saved)
    }

    @Test func unreadablePhotosAreReportedAndTheRunGoesOn() async throws {
        let database = try CullaDatabase.inMemory()
        let fake = FakeAnalyzer(failing: ["p001", "p004"])
        let analysis = ShootAnalysis(database: database, options: options(), analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.start(photos: items(6))
        let events = await reader.untilFinished()
        #expect(Set(events.unreadableIDs) == ["p001", "p004"])
        #expect(events.analysedIDs.count == 4)
        #expect(events.finished?.unreadable == 2)
        // Only scores are cached; unreadable files are tried again next time.
        #expect(try await database.cachedScoreCount() == 4)
        await analysis.cancel()
    }

    /// Photos that failed while their folder could not be reached (a card pulled mid-analysis) are
    /// analysed again once the app passes them back, though their files never changed; photos the
    /// app knows to be unreadable are left out by the app and not tried again.
    @Test func photosThatFailedWhileDisconnectedAreAnalysedWhenTheFolderReturns() async throws {
        let database = try CullaDatabase.inMemory()
        let disconnected = Mutex(true)
        let calls = Mutex([String: Int]())
        let analyze: PhotoAnalysisFunction = { file, _ in
            calls.withLock { $0[file.id, default: 0] += 1 }
            await Task.yield()
            if file.id == "p005" { return .unreadable("Damaged") }
            let away = disconnected.withLock { $0 }
            return away && ["p002", "p003"].contains(file.id) ? .unreadable("The folder cannot be read") : .scores(fakeScores())
        }
        let analysis = ShootAnalysis(database: database, options: options(), analyze: analyze)
        let reader = EventReader(analysis)
        let session = SessionState(photos: items(6))
        await analysis.start(photos: session.photos)
        let firstRun = await reader.untilFinished()
        #expect(Set(firstRun.unreadableIDs) == ["p002", "p003", "p005"])

        // The folder is back; nothing changed on disk. The app believes p005's failure only.
        disconnected.withLock { $0 = false }
        await analysis.update(photos: session.photos.filter { $0.id != "p005" })
        let secondRun = await reader.untilFinished()
        #expect(Set(secondRun.analysedIDs) == ["p002", "p003"])
        #expect(secondRun.unreadableIDs.isEmpty)
        let counted = calls.withLock { $0 }
        #expect(counted["p002"] == 2 && counted["p003"] == 2 && counted["p005"] == 1 && counted["p000"] == 1)
        #expect(try await database.cachedScoreCount() == 5)

        // Nothing left to retry: a further update with nothing changed analyses nothing.
        await analysis.update(photos: session.photos.filter { $0.id != "p005" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.withLock { $0.values.reduce(0, +) } == 8)
        await analysis.cancel()
    }

    @Test func prioritiesReachTheScheduler() async throws {
        let fake = FakeAnalyzer(delay: .milliseconds(20))
        let analysis = ShootAnalysis(database: nil, options: options { $0.concurrency = 1 }, analyze: fake.function)
        let reader = EventReader(analysis)
        await analysis.setPriority(["p009", "p008"])
        await analysis.start(photos: items(10))
        await reader.untilFinished()
        #expect(fake.snapshot.started.prefix(2) == ["p009", "p008"])
        await analysis.setConcurrency(3)
        await analysis.cancel()
    }
}
