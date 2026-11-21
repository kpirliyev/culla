import Foundation
import Synchronization

/// Lets at most a fixed number of jobs run at once. Waiting jobs start in the order they asked,
/// and a job whose task is cancelled while it waits never starts: it throws `CancellationError`.
/// Waiting suspends the task; it never blocks a thread.
public final class AsyncLimiter: Sendable {
    private struct State {
        var running = 0
        var waiters: [(id: UInt64, continuation: CheckedContinuation<Void, any Error>)] = []
        var nextID: UInt64 = 0
    }

    public let limit: Int
    private let state = Mutex(State())

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Waits for a free slot, runs `work`, and frees the slot.
    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await work()
    }

    private func acquire() async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if state.running < limit {
                        state.running += 1
                        return .success(())
                    }
                    state.waiters.append((id, continuation))
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    private func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, any Error>? in
            if state.waiters.isEmpty {
                state.running -= 1
                return nil
            }
            // The slot passes straight to the next waiter, so `running` stays the same.
            return state.waiters.removeFirst().continuation
        }
        next?.resume()
    }
}
