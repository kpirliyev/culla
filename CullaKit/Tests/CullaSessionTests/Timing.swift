import Darwin

/// Timing for speed tests that must pass on a busy machine.
///
/// Wall-clock time is the wrong measure there: other processes take the CPU away and the same
/// work takes several times as long. These helpers measure the CPU time of the calling thread
/// instead (`CLOCK_THREAD_CPUTIME_ID`), which counts only the time the work itself ran, and take
/// the best of a few runs. Load can still slow the work somewhat (it may run on an efficiency
/// core, or share caches), so costly operations are also compared with a baseline pass over the
/// same photos measured right beside them: both slow down together, and the ratio says whether
/// the operation's cost has grown out of proportion, which is the regression worth catching.
enum Timing {
    /// CPU seconds this thread spent on `work`. The work must be synchronous.
    static func cpuSeconds(_ work: () -> Void) -> Double {
        var start = timespec()
        var end = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
        work()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
        return Double(end.tv_sec - start.tv_sec) + Double(end.tv_nsec - start.tv_nsec) / 1e9
    }

    /// The least CPU time of `runs` runs of `work`.
    static func best(of runs: Int = 5, _ work: () -> Void) -> Double {
        (0..<runs).map { _ in cpuSeconds(work) }.min()!
    }

    /// The least CPU time of `work` and of `baseline` over `runs` alternating runs of each, so
    /// both are measured under the same conditions.
    static func bestBeside(baseline: () -> Void, runs: Int = 5, _ work: () -> Void) -> (work: Double, baseline: Double) {
        var bestWork = Double.infinity
        var bestBaseline = Double.infinity
        for _ in 0..<runs {
            bestBaseline = min(bestBaseline, cpuSeconds(baseline))
            bestWork = min(bestWork, cpuSeconds(work))
        }
        return (bestWork, bestBaseline)
    }
}
