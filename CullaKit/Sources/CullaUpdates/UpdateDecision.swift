import Foundation

/// Why a check for updates could not be made. The interface says one thing for all of them (check
/// the internet connection); the cases are for tests and logs.
public enum UpdateCheckError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The request did not complete: offline, timed out, a TLS failure. The `URLError` code.
    case transport(Int)
    /// The answer came from somewhere other than the fixed address (a redirect, or not HTTPS).
    case unexpectedAddress
    /// The server answered with a status other than 200.
    case status(Int)
    /// The answer was larger than `UpdateLimits.maximumBodyBytes`.
    case tooLarge
    /// The answer was not the update file, or named a version that is not a dotted number.
    case invalidDocument
    /// This copy of Culla has a version that is not a dotted number (never in a real build).
    case invalidCurrentVersion

    public var description: String {
        switch self {
        case .transport(let code): "transport error \(code)"
        case .unexpectedAddress: "answer from an unexpected address"
        case .status(let status): "HTTP status \(status)"
        case .tooLarge: "answer too large"
        case .invalidDocument: "not a valid update file"
        case .invalidCurrentVersion: "the app's own version is not a dotted number"
        }
    }
}

/// What a check found.
public enum UpdateDecision: Sendable, Equatable {
    /// This is the newest version, or nothing newer is published.
    case upToDate
    /// A newer version runs on this Mac.
    case available(ReleaseVersion)
    /// A newer version exists but needs a newer macOS than this Mac has.
    case needsNewerSystem(version: ReleaseVersion, minimumSystem: ReleaseVersion)

    /// Compares the published file with this copy of Culla and this Mac. A pure function.
    ///
    /// Nothing is newer while the file names no release (an empty version or date). A version or
    /// a minimum system that is not a dotted number makes the file invalid rather than being
    /// guessed at; an empty minimum system states no requirement.
    public static func make(
        current: ReleaseVersion, system: ReleaseVersion, document: UpdateDocument
    ) throws(UpdateCheckError) -> UpdateDecision {
        guard document.isPublished else { return .upToDate }
        guard let newest = ReleaseVersion(document.version.trimmingCharacters(in: .whitespaces)) else {
            throw .invalidDocument
        }
        guard newest > current else { return .upToDate }
        let minimumText = document.minimumSystem.trimmingCharacters(in: .whitespaces)
        if minimumText.isEmpty { return .available(newest) }
        guard let minimum = ReleaseVersion(minimumText) else { throw .invalidDocument }
        return system >= minimum ? .available(newest) : .needsNewerSystem(version: newest, minimumSystem: minimum)
    }

    /// The newer version, if there is one.
    public var newerVersion: ReleaseVersion? {
        switch self {
        case .upToDate: nil
        case .available(let version), .needsNewerSystem(let version, _): version
        }
    }
}

/// When Culla checks on its own, and what it tells the person then.
public enum UpdateSchedule {
    /// Automatic checks are at least this far apart, counted from the last attempt.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// True when an automatic check should run now: the setting is on and the last attempt,
    /// successful or not, was at least `interval` ago. An attempt dated in the future (the clock
    /// was set back) does not hold checks off until then.
    public static func isAutomaticCheckDue(enabled: Bool, lastAttempt: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastAttempt else { return true }
        if lastAttempt > now { return true }
        return now.timeIntervalSince(lastAttempt) >= interval
    }

    /// The version an automatic check shows a notice for: a newer one that runs on this Mac and
    /// was not skipped. A version needing a newer macOS, being up to date and a failure are
    /// silent. (A manual check reports every outcome, a skipped version included.)
    public static func automaticNotice(for decision: UpdateDecision, skipped: ReleaseVersion?) -> ReleaseVersion? {
        guard case .available(let version) = decision else { return nil }
        if let skipped, skipped == version { return nil }
        return version
    }
}
