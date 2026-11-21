import CullaCore
@testable import CullaPipeline
import Foundation
import Testing

/// Collects a scheduler's results from its event stream.
private func results(
    of scheduler: AnalysisScheduler,
    count: Int,
    onEach: (Int, AnalysisResult) async -> Void = { _, _ in }
) async -> [AnalysisResult] {
    var collected: [AnalysisResult] = []
    for await event in scheduler.events {
        guard case .result(let result) = event else { continue }
        collected.append(result)
        await onEach(collected.count, result)
        if collected.count == count { break }
    }
    return collected
}

@Suite("AnalysisScheduler", .timeLimit(.minutes(1)))
struct SchedulerTests {
    @Test func priorityPhotosGoFirstThenCaptureOrder() async {
        let fake = FakeAnalyzer()
        let scheduler = AnalysisScheduler(concurrency: 1, analyze: fake.function)
        await scheduler.setPriority(["p007", "p003", "unknown"])
        // Queued out of order: capture order comes from the dates, not the order given.
        await scheduler.enqueue(fakeJobs(10).reversed())
        let done = await results(of: scheduler, count: 10)
        let expected = ["p007", "p003", "p000", "p001", "p002", "p004", "p005", "p006", "p008", "p009"]
        #expect(fake.snapshot.started == expected)
        #expect(done.map(\.id) == expected)
    }

    @Test func aPriorityChangeAppliesToTheNextPhotoStarted() async {
        let fake = FakeAnalyzer(delay: .milliseconds(50))
        let scheduler = AnalysisScheduler(concurrency: 1, analyze: fake.function)
        await scheduler.enqueue(fakeJobs(10))
        // When the second result arrives, the third photo has already started; it takes 50 ms,
        // long enough for the new priorities to arrive before the fourth starts.
        _ = await results(of: scheduler, count: 10) { count, _ in
            if count == 2 { await scheduler.setPriority(["p009", "p008", "p001"]) }
        }
        #expect(fake.snapshot.started == ["p000", "p001", "p002", "p009", "p008", "p003", "p004", "p005", "p006", "p007"])
    }

    @Test func theConcurrencyLimitHoldsAndCanChangeWhileRunning() async {
        let fake = FakeAnalyzer(delay: .milliseconds(3))
        let scheduler = AnalysisScheduler(concurrency: 3, analyze: fake.function)
        #expect(await scheduler.concurrency == 3)
        await scheduler.enqueue(fakeJobs(120))
        var startsBeforeRaise = 0
        var startsBeforeLower = 0
        _ = await results(of: scheduler, count: 120) { count, _ in
            if count == 20 {
                startsBeforeRaise = fake.snapshot.started.count
                await scheduler.setConcurrency(6)
            }
            if count == 70 {
                await scheduler.setConcurrency(1)
                // A task the scheduler started may begin a little later; wait until the photos
                // started under the old limit are done.
                _ = await eventually { await scheduler.progress().running <= 1 }
                startsBeforeLower = fake.snapshot.started.count
            }
        }
        let state = fake.snapshot
        let first = state.runningAtStart.prefix(startsBeforeRaise)
        let middle = state.runningAtStart[startsBeforeRaise..<startsBeforeLower]
        let last = state.runningAtStart.suffix(from: startsBeforeLower)
        #expect(first.max() == 3)
        #expect(middle.max() == 6)
        #expect(last.max() == 1, "once lowered, a photo only starts when nothing else runs")
        #expect(!state.slotClash, "no two photos in flight share a slot")
    }

    @Test func pauseStartsNothingNewAndResumeCarriesOn() async {
        let fake = FakeAnalyzer(delay: .milliseconds(5))
        let scheduler = AnalysisScheduler(concurrency: 2, analyze: fake.function)
        await scheduler.enqueue(fakeJobs(20))
        var iterator = scheduler.events.makeAsyncIterator()
        var received = 0
        while received < 4, let event = await iterator.next() {
            if case .result = event { received += 1 }
        }
        await scheduler.pause()
        #expect(await scheduler.progress().isPaused)
        // Photos in flight finish (a task the scheduler started may only now begin); nothing new starts.
        #expect(await eventually { await scheduler.progress().running == 0 })
        let startedAtPause = fake.snapshot.started.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(fake.snapshot.started.count == startedAtPause)
        #expect(startedAtPause < 20)

        await scheduler.resume()
        #expect(await !scheduler.progress().isPaused)
        while let event = await iterator.next() {
            if case .result = event { received += 1 }
            if case .idle = event { break }
        }
        #expect(received == 20)
        #expect(fake.snapshot.started.count == 20)
    }

    @Test func cancelStopsPromptlyAndEndsTheEvents() async {
        let fake = FakeAnalyzer(delay: .seconds(2))
        let scheduler = AnalysisScheduler(concurrency: 4, analyze: fake.function)
        await scheduler.enqueue(fakeJobs(50))
        #expect(await eventually { fake.snapshot.started.count == 4 })
        let clock = ContinuousClock()
        let start = clock.now
        await scheduler.cancel()
        var after = 0
        for await _ in scheduler.events { after += 1 }
        #expect(clock.now - start < .milliseconds(500), "the stream ends at once, not after the 2 s photos")
        #expect(after == 0)
        #expect(await eventually { fake.snapshot.cancelled == 4 }, "tasks in flight are cancelled")
        #expect(fake.snapshot.started.count == 4)
        // Nothing more is accepted.
        await scheduler.enqueue(fakeJobs(3, prefix: "late"))
        #expect(await scheduler.progress().total == 0)
    }

    @Test func aFailingPhotoDoesNotStopTheRun() async {
        let fake = FakeAnalyzer(failing: ["p002", "p005"])
        let scheduler = AnalysisScheduler(concurrency: 2, analyze: fake.function)
        await scheduler.enqueue(fakeJobs(8))
        let done = await results(of: scheduler, count: 8)
        let unreadable = done.filter { if case .unreadable = $0.outcome { true } else { false } }.map(\.id)
        #expect(Set(unreadable) == ["p002", "p005"])
        let progress = await scheduler.progress()
        #expect(progress.done == 8 && progress.unreadable == 2)
    }

    @Test func progressNumbersAreConsistent() async {
        let fake = FakeAnalyzer(delay: .milliseconds(1))
        let scheduler = AnalysisScheduler(concurrency: 4, analyze: fake.function)
        #expect(await scheduler.progress() == AnalysisProgress(secondsRemaining: 0))
        await scheduler.enqueue(fakeJobs(60))
        var previousDone = 0
        _ = await results(of: scheduler, count: 60) { count, _ in
            let progress = await scheduler.progress()
            #expect(progress.total == 60)
            #expect(progress.done >= count, "every result handed out is counted as done")
            #expect(progress.done >= previousDone)
            #expect(progress.running <= 4)
            #expect(progress.remaining == progress.total - progress.done)
            #expect(progress.fraction >= 0 && progress.fraction <= 1)
            if let rate = progress.photosPerSecond { #expect(rate > 0) }
            if let left = progress.secondsRemaining { #expect(left >= 0) }
            previousDone = progress.done
        }
        let final = await scheduler.progress()
        #expect(final.done == 60 && final.total == 60 && final.running == 0)
        #expect(final.isComplete && final.fraction == 1 && final.secondsRemaining == 0)
        // A rate needs a second of work after the first photo; this run is quicker than that.
        #expect(final.photosPerSecond.map { $0 > 0 } ?? true)
    }

    @Test func everyPhotoIsAnalysedExactlyOnce() async {
        let fake = FakeAnalyzer(delay: .microseconds(200))
        let scheduler = AnalysisScheduler(concurrency: 8, analyze: fake.function)
        let jobs = fakeJobs(300)
        await scheduler.enqueue(jobs)
        let done = await results(of: scheduler, count: 300) { count, _ in
            // Queuing again, and shuffling priorities, must never analyse a photo twice.
            if count % 50 == 0 {
                await scheduler.enqueue(Array(jobs.prefix(count + 20)))
                await scheduler.setPriority(jobs.shuffled().prefix(30).map(\.id))
            }
        }
        #expect(done.count == 300)
        #expect(Set(done.map(\.id)).count == 300)
        #expect(fake.snapshot.calls.values.allSatisfy { $0 == 1 })
        #expect(fake.snapshot.calls.count == 300)
    }

    @Test func removedPhotosAreNotAnalysedAndTheQueueStillDrains() async {
        let fake = FakeAnalyzer(delay: .milliseconds(20))
        let scheduler = AnalysisScheduler(concurrency: 1, analyze: fake.function)
        await scheduler.enqueue(fakeJobs(5))
        #expect(await eventually { fake.snapshot.started == ["p000"] })
        // p000 is in flight: its result is thrown away. p003 has not started.
        await scheduler.remove(["p000", "p003"])
        #expect(await !scheduler.isPending("p000"))
        var ids: [String] = []
        for await event in scheduler.events {
            if case .result(let result) = event { ids.append(result.id) }
            if case .idle = event { break }
        }
        #expect(ids == ["p001", "p002", "p004"])
        #expect(!fake.snapshot.started.contains("p003"))
        #expect(await scheduler.progress().total == 3)
    }

    @Test func idleIsReportedEachTimeTheQueueDrains() async {
        let scheduler = AnalysisScheduler(concurrency: 2, analyze: FakeAnalyzer().function)
        var iterator = scheduler.events.makeAsyncIterator()
        for round in 1...2 {
            await scheduler.enqueue(fakeJobs(3, prefix: "r\(round)-"))
            var results = 0
            while let event = await iterator.next() {
                if case .result = event { results += 1 }
                if case .idle = event { break }
            }
            #expect(results == 3)
        }
    }
}

@Suite("ThroughputMeter")
struct ThroughputMeterTests {
    @Test func theRateIsMeasuredFromTheFirstFinishedPhoto() {
        var meter = ThroughputMeter(windowSeconds: 20, now: 0)
        // A slow first photo, as when Vision loads its models, then 10 photos a second.
        meter.record(done: 1, now: 5)
        #expect(meter.rate(now: 5) == nil)
        for index in 1...20 { meter.record(done: 1 + index, now: 5 + Double(index) * 0.1) }
        let rate = meter.rate(now: 7)
        #expect(rate.map { abs($0 - 10) < 0.01 } == true)
    }

    @Test func pausedTimeDoesNotCount() {
        var meter = ThroughputMeter(windowSeconds: 20, now: 0)
        for index in 1...10 { meter.record(done: index, now: Double(index)) }
        meter.pause(now: 10)
        let before = meter.rate(now: 10)
        #expect(meter.rate(now: 100) == before, "a pause neither lowers the rate...")
        let left = meter.secondsRemaining(10, now: 10)
        #expect(meter.secondsRemaining(10, now: 100) == left, "...nor moves the estimate")
        meter.resume(now: 100)
        meter.record(done: 11, now: 101)
        #expect(meter.activeTime(now: 101) == 11)
    }

    @Test func theRateOnlyLooksAtTheRecentWindow() {
        var meter = ThroughputMeter(windowSeconds: 10, now: 0)
        // One photo a second for 30 s, then ten a second.
        for second in 1...30 { meter.record(done: second, now: Double(second)) }
        var done = 30
        for step in 1...150 {
            done += 1
            meter.record(done: done, now: 30 + Double(step) * 0.1)
        }
        let rate = meter.rate(now: 45) ?? 0
        #expect(rate > 9 && rate < 10.5)
    }

    @Test func theEstimateCountsDownSmoothly() {
        var meter = ThroughputMeter(windowSeconds: 20, now: 0)
        var done = 0
        var estimates: [Double] = []
        // Ten photos a second with a burst of jitter: 1 s gaps every so often.
        var time = 0.0
        for step in 0..<300 {
            time += step % 37 == 0 ? 1.0 : 0.1
            done += 1
            meter.record(done: done, now: time)
            if let left = meter.secondsRemaining(1000 - done, now: time) { estimates.append(left) }
        }
        #expect(estimates.count > 250)
        // Between two consecutive estimates the figure moves by little more than the time passed.
        let jumps = zip(estimates, estimates.dropFirst()).map { abs($1 - $0) }
        #expect(jumps.dropFirst(10).allSatisfy { $0 < 3 })
        #expect(meter.secondsRemaining(0, now: time) == 0)
    }
}
