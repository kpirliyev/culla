import Foundation
import Observation

/// Counts work in flight that a person would wait for: loading a shoot, thumbnails of visible
/// tiles, the loupe's image, and saves. Quitting waits for saves; the automation harness waits
/// for all of it before it looks at the window.
@MainActor
final class ActivityTracker {
    enum Kind: String, CaseIterable, Sendable {
        case loading
        case thumbnail
        case preview
        case saving
        /// Looking at the shoot folder again for changes made outside Culla.
        case rescan
        /// Applying decisions to disk, or undoing an apply.
        case applying
    }

    private(set) var counts: [Kind: Int] = [:]

    func begin(_ kind: Kind) {
        counts[kind, default: 0] += 1
    }

    func end(_ kind: Kind) {
        let value = (counts[kind] ?? 0) - 1
        counts[kind] = max(0, value)
    }

    func count(_ kind: Kind) -> Int { counts[kind] ?? 0 }

    var isIdle: Bool { counts.values.allSatisfy { $0 == 0 } }

    /// What is still running, for logs: "thumbnail 3, saving 1".
    var summary: String {
        Kind.allCases.compactMap { kind in
            let count = count(kind)
            return count > 0 ? "\(kind.rawValue) \(count)" : nil
        }.joined(separator: ", ")
    }
}

/// Runs `apply` now and again whenever an observable property it read changes, until the token
/// is cancelled or released. For AppKit views that follow the model.
@MainActor
final class ObservationToken {
    fileprivate var isCancelled = false
    func cancel() { isCancelled = true }
}

@MainActor
@discardableResult
func observeChanges(_ apply: @escaping @MainActor () -> Void) -> ObservationToken {
    let token = ObservationToken()
    track(token: token, apply)
    return token
}

@MainActor
private func track(token: ObservationToken, _ apply: @escaping @MainActor () -> Void) {
    guard !token.isCancelled else { return }
    withObservationTracking {
        apply()
    } onChange: { [weak token] in
        Task { @MainActor in
            guard let token else { return }
            track(token: token, apply)
        }
    }
}
