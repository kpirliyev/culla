import CullaCore
import Foundation
import Testing

@Suite("BlockingQueue")
struct BlockingQueueTests {
    private struct Failure: Error, Equatable {}

    @Test func returnsTheResult() async {
        let value = await BlockingQueue.shared.run { 6 * 7 }
        #expect(value == 42)
    }

    @Test func rethrowsTheError() async {
        await #expect(throws: Failure.self) {
            try await BlockingQueue.shared.run { () throws(Failure) -> Int in throw Failure() }
        }
    }

    @Test func serialQueueRunsInOrderWithoutOverlap() async {
        let queue = BlockingQueue(label: "test.serial", concurrent: false)
        let log = Log()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    await queue.run {
                        log.enter(index)
                        Thread.sleep(forTimeInterval: 0.001)
                        log.leave()
                    }
                }
            }
        }
        #expect(log.maximumOverlap == 1)
        #expect(log.entered.count == 20)
    }

    /// Many items that block until all of them are running at once. On a pool with one thread per
    /// core this can never finish; on the Dispatch queue every item gets a thread of its own.
    @Test func blockedItemsDoNotWaitForEachOther() async {
        let count = max(24, ProcessInfo.processInfo.activeProcessorCount * 3)
        let gate = Gate(count: count)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0..<count {
                group.addTask { await BlockingQueue.shared.run { gate.arriveAndWait(timeout: 20) } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.count == count)
        #expect(results.allSatisfy { $0 })
    }
}

/// Records which items are inside a critical section, to check that a serial queue never overlaps.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private(set) var maximumOverlap = 0
    private(set) var entered: [Int] = []

    func enter(_ index: Int) {
        lock.withLock {
            inside += 1
            maximumOverlap = max(maximumOverlap, inside)
            entered.append(index)
        }
    }

    func leave() {
        lock.withLock { inside -= 1 }
    }
}

/// Lets each caller through only once `count` callers are waiting at the same time.
private final class Gate: @unchecked Sendable {
    private let condition = NSCondition()
    private let count: Int
    private var arrived = 0

    init(count: Int) {
        self.count = count
    }

    /// True when everyone arrived within the timeout.
    func arriveAndWait(timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        arrived += 1
        condition.broadcast()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while arrived < count {
            if !condition.wait(until: deadline) { return arrived >= count }
        }
        return true
    }
}
