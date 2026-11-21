import Foundation

/// Photos per second over a recent window, and a time-left estimate that does not jump around.
///
/// Time is "active" time: the clock stops while analysis is paused, so a pause neither drags the
/// rate down nor makes the estimate grow. Pure logic with the time passed in, so it can be tested.
struct ThroughputMeter: Sendable {
    /// Seconds of active time the rate is measured over.
    var windowSeconds: Double
    /// How much of a fresh estimate is taken in per second of active time; the rest is the old
    /// estimate counted down. Lower is steadier.
    var smoothingPerSecond: Double = 0.15
    /// Photos that must finish after the first one before a rate is given...
    var minimumSamples = 3
    /// ...and seconds of active time that must pass after it.
    var minimumSeconds = 1.0

    /// Completions, oldest first. The rate is measured from the first photo that finished, not
    /// from the start: the first photos also pay for loading Vision's models, often seconds.
    private var samples: [(time: Double, done: Int)] = []
    private var activeBefore = 0.0
    private var resumedAt: Double?
    private var estimate: (time: Double, seconds: Double)?

    init(windowSeconds: Double, now: Double) {
        self.windowSeconds = windowSeconds
        resumedAt = now
    }

    func activeTime(now: Double) -> Double {
        activeBefore + (resumedAt.map { max(0, now - $0) } ?? 0)
    }

    mutating func pause(now: Double) {
        guard resumedAt != nil else { return }
        activeBefore = activeTime(now: now)
        resumedAt = nil
    }

    mutating func resume(now: Double) {
        guard resumedAt == nil else { return }
        resumedAt = now
    }

    /// Records that `done` photos are finished in all.
    mutating func record(done: Int, now: Double) {
        let time = activeTime(now: now)
        samples.append((time, done))
        // Keep one sample older than the window as its starting point.
        let cutoff = time - windowSeconds
        if let firstInside = samples.firstIndex(where: { $0.time >= cutoff }), firstInside > 1 {
            samples.removeFirst(firstInside - 1)
        }
    }

    /// Photos per second over the window, up to now. Nil until enough photos are done.
    func rate(now: Double) -> Double? {
        guard let first = samples.first, let last = samples.last, last.done - first.done >= minimumSamples else {
            return nil
        }
        let elapsed = activeTime(now: now) - first.time
        guard elapsed >= minimumSeconds else { return nil }
        return Double(last.done - first.done) / elapsed
    }

    /// Seconds left for `remaining` photos. The estimate counts down with active time and moves
    /// only part of the way towards each fresh estimate, so it neither jumps nor stalls.
    mutating func secondsRemaining(_ remaining: Int, now: Double) -> Double? {
        guard remaining > 0 else {
            estimate = nil
            return 0
        }
        guard let rate = rate(now: now), rate > 0 else { return estimate.map { max(0, $0.seconds) } }
        let time = activeTime(now: now)
        let fresh = Double(remaining) / rate
        guard let previous = estimate else {
            estimate = (time, fresh)
            return fresh
        }
        let elapsed = max(0, time - previous.time)
        let countedDown = max(0, previous.seconds - elapsed)
        let weight = min(1, smoothingPerSecond * max(elapsed, 0.05))
        let blended = countedDown + (fresh - countedDown) * weight
        estimate = (time, blended)
        return blended
    }
}
