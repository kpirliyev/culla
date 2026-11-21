#if DEBUG
import Darwin
import Dispatch
import Foundation
import QuartzCore
import Synchronization

/// Measures how late the main thread answers, so "no visible stall" becomes a number.
///
/// A background timer pings the main queue every few milliseconds; the time a ping waits before
/// the main thread runs it is the stall. Only one ping is in flight at a time, so a long stall
/// is measured once, in full.
final class StallMonitor: Sendable {
    static let shared = StallMonitor()

    struct Snapshot: Sendable {
        /// The longest stall since launch, in milliseconds.
        var longestMs: Double
        /// The longest stall since the last `resetWindow()`.
        var windowLongestMs: Double
        /// Stalls over 50 ms and over 100 ms since the last `resetWindow()`.
        var windowOver50: Int
        var windowOver100: Int
        var samples: Int
        /// Stalls over 50 ms: when (milliseconds since the monitor started) and how long.
        var events: [(atMs: Double, ms: Double)]
    }

    private struct State {
        var longest: Double = 0
        var windowLongest: Double = 0
        var windowOver50 = 0
        var windowOver100 = 0
        var samples = 0
        var outstanding = false
        var sentAt: UInt64 = 0
        var running = false
        var startedAt: UInt64 = 0
        var events: [(atMs: Double, ms: Double)] = []
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "Culla.stall-monitor", qos: .userInteractive)
    private let timer: DispatchSourceTimer

    private init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
    }

    func start() {
        let alreadyRunning = state.withLock { state in
            defer { state.running = true }
            if !state.running { state.startedAt = DispatchTime.now().uptimeNanoseconds }
            return state.running
        }
        guard !alreadyRunning else { return }
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [self] in tick() }
        timer.resume()
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let send = state.withLock { state -> Bool in
            guard !state.outstanding else { return false }
            state.outstanding = true
            state.sentAt = now
            return true
        }
        guard send else { return }
        DispatchQueue.main.async { [self] in
            let answered = DispatchTime.now().uptimeNanoseconds
            state.withLock { state in
                let ms = Double(answered &- state.sentAt) / 1_000_000
                state.outstanding = false
                state.samples += 1
                state.longest = max(state.longest, ms)
                state.windowLongest = max(state.windowLongest, ms)
                if ms > 50 {
                    state.windowOver50 += 1
                    let at = Double(state.sentAt &- state.startedAt) / 1_000_000
                    if state.events.count < 200 { state.events.append((at, ms)) }
                }
                if ms > 100 { state.windowOver100 += 1 }
            }
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { state in
            Snapshot(
                longestMs: state.longest, windowLongestMs: state.windowLongest,
                windowOver50: state.windowOver50, windowOver100: state.windowOver100, samples: state.samples,
                events: state.events
            )
        }
    }

    /// When the monitor started, in `CACurrentMediaTime` seconds (the same clock as mach time).
    var startedAtMediaTime: Double {
        let start = state.withLock { $0.startedAt }
        let now = DispatchTime.now().uptimeNanoseconds
        return CACurrentMediaTime() - Double(now &- start) / 1_000_000_000
    }

    /// Milliseconds since the monitor started, to line stalls up with script steps.
    func now() -> Double {
        let start = state.withLock { $0.startedAt }
        return Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
    }

    /// Starts a new measuring window, such as before scrolling.
    func resetWindow() {
        state.withLock { state in
            state.windowLongest = 0
            state.windowOver50 = 0
            state.windowOver100 = 0
        }
    }
}

/// The process's memory use.
enum MemoryUsage {
    struct Snapshot: Sendable {
        var residentBytes: UInt64
        var footprintBytes: UInt64
        /// The highest footprint since the process started.
        var peakFootprintBytes: UInt64 = 0
    }

    static func current() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Snapshot(residentBytes: 0, footprintBytes: 0) }
        return Snapshot(residentBytes: info.resident_size, footprintBytes: info.phys_footprint, peakFootprintBytes: UInt64(info.ledger_phys_footprint_peak))
    }
}
#endif
