import Dispatch

/// Runs synchronous work on a Dispatch queue and suspends the calling task until it is done.
///
/// Swift's cooperative thread pool has only one thread per core and assumes that a task never
/// blocks its thread. Several things in the per-photo path break that assumption: ImageIO decoding
/// and encoding, the pixel loops, and above all Core Image's face detector, which is built on
/// Vision and waits synchronously for Vision's own queue. Done on the pool, enough photos in
/// flight park every pool thread in such a wait, while the work they wait for needs a pool thread
/// to finish, and the whole run stops. Done here, a blocked call holds a Dispatch thread, Dispatch
/// adds threads as needed, and the pool stays free to move async work along.
public struct BlockingQueue: Sendable {
    /// Shared by decoding, pixel measurements and image writing. Concurrent, because the number of
    /// items in flight is already bounded by how many photos the caller analyses at once.
    public static let shared = BlockingQueue(label: "Culla.blocking", concurrent: true)

    private let queue: DispatchQueue

    /// - Parameter concurrent: false runs one item at a time, in order, for work that must not
    ///   overlap with itself, without blocking a thread to wait for its turn.
    public init(label: String, concurrent: Bool, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos, attributes: concurrent ? [.concurrent] : [])
    }

    /// Runs `work` on the queue and returns its result, or rethrows its error.
    public func run<T: Sendable, Failure: Error>(
        _ work: @escaping @Sendable () throws(Failure) -> T
    ) async throws(Failure) -> T {
        let result: Result<T, Failure> = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Result { () throws(Failure) -> T in try work() })
            }
        }
        return try result.get()
    }
}
