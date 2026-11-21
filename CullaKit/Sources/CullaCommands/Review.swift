import CullaAnalysis
import CullaSession
import Foundation

/// How a sidebar group is shown when it is opened: the Design doc's "Opens in" column.
public enum GroupOpening: Sendable, Hashable {
    case grid
    /// The loupe on the first undecided photo, prepared to show the evidence for the group.
    case loupe(Evidence)
    /// Stack review on the first undecided stack: the current frame beside the best pick, the
    /// face strip and the stack's filmstrip.
    case stackReview
    /// Duplicate review on the first undecided set: its copies side by side.
    case duplicateReview

    public enum Evidence: Sendable, Hashable {
        /// Fitted, with the filmstrip.
        case none
        /// Zoomed to the eyes of the face with the most closed eyes.
        case closedEyes
        /// Zoomed to the sharpest spot of the subject: where focus was judged.
        case focusPoint
        /// Fitted, with the clipping overlay on.
        case clipping
    }

    public var opensLoupe: Bool {
        if case .loupe = self { return true }
        return false
    }

    /// True for the review screens of Similar Stacks and Duplicates.
    public var opensReview: Bool {
        self == .stackReview || self == .duplicateReview
    }

    /// True when the loupe opens zoomed to 100% on the evidence, and follows the evidence from
    /// photo to photo while it stays zoomed.
    public var zoomsToEvidence: Bool {
        self == .loupe(.closedEyes) || self == .loupe(.focusPoint)
    }
}

extension GroupID {
    /// The view the group opens in: the Design's "Opens in" column.
    public var opening: GroupOpening {
        switch self {
        case .duplicates: .duplicateReview
        case .similarStacks: .stackReview
        case .eyesClosed: .loupe(.closedEyes)
        case .blurry: .loupe(.focusPoint)
        case .exposure: .loupe(.clipping)
        case .otherIssues, .unreviewed: .loupe(.none)
        case .allPhotos, .kept, .rejected: .grid
        }
    }

    /// The groups in the order the Design doc recommends clearing them: duplicates first (the
    /// fastest), then stacks (the most photos per key), then the defects, then the sweep.
    public static let reviewOrder: [GroupID] = [
        .duplicates, .similarStacks, .eyesClosed, .blurry, .exposure, .otherIssues, .unreviewed,
    ]

    /// True for the groups whose membership the tuning panel can change.
    public var hasTuning: Bool {
        isDefectGroup || self == .duplicates || self == .similarStacks
    }

    /// True when a flag of this group can ever be Certain, so ⇧X can find something.
    public var canBeCertain: Bool {
        self == .eyesClosed || self == .blurry
    }

    /// The empty group's title while analysis is still running: "No closed eyes found yet". For
    /// groups that do not need analysis, `emptyMessage`.
    public var noneFoundYetMessage: String {
        switch self {
        case .duplicates: localized("No duplicates found yet")
        case .similarStacks: localized("No similar stacks found yet")
        case .eyesClosed: localized("No closed eyes found yet")
        case .blurry: localized("No blurry photos found yet")
        case .exposure: localized("No exposure problems found yet")
        case .otherIssues: localized("No other issues found yet")
        case .allPhotos, .unreviewed, .kept, .rejected: emptyMessage
        }
    }

    /// The empty group's title while analysis is paused: "No closed eyes found so far".
    public var noneFoundSoFarMessage: String {
        switch self {
        case .duplicates: localized("No duplicates found so far")
        case .similarStacks: localized("No similar stacks found so far")
        case .eyesClosed: localized("No closed eyes found so far")
        case .blurry: localized("No blurry photos found so far")
        case .exposure: localized("No exposure problems found so far")
        case .otherIssues: localized("No other issues found so far")
        case .allPhotos, .unreviewed, .kept, .rejected: emptyMessage
        }
    }

    /// The empty group's detail before analysis has started: "Culla finds closed eyes once it has
    /// analysed the shoot." Nil for groups that do not need analysis.
    public var findsAfterAnalysisMessage: String? {
        switch self {
        case .duplicates: localized("Culla finds duplicates once it has analysed the shoot.")
        case .similarStacks: localized("Culla finds similar stacks once it has analysed the shoot.")
        case .eyesClosed: localized("Culla finds closed eyes once it has analysed the shoot.")
        case .blurry: localized("Culla finds blurry photos once it has analysed the shoot.")
        case .exposure: localized("Culla finds exposure problems once it has analysed the shoot.")
        case .otherIssues: localized("Culla finds other issues once it has analysed the shoot.")
        case .allPhotos, .unreviewed, .kept, .rejected: nil
        }
    }
}

/// Where reviewing goes next.
public enum ReviewGuide {
    /// The first group in `GroupID.reviewOrder` with photos left to review, or nil when every
    /// photo has a decision.
    public static func firstGroupToReview(in state: SessionState) -> GroupID? {
        GroupID.reviewOrder.first { state.count(of: $0).left > 0 }
    }

    /// The group to offer once `group` is done: the next one in review order with photos left,
    /// else the first such group before it. Nil when nothing is left anywhere.
    public static func nextGroupToReview(after group: GroupID, in state: SessionState) -> GroupID? {
        let order = GroupID.reviewOrder
        let start = order.firstIndex(of: group).map { $0 + 1 } ?? 0
        let rotated = Array(order[start...]) + Array(order[..<start])
        return rotated.first { $0 != group && state.count(of: $0).left > 0 }
    }
}

/// The words of the ⇧X confirmation.
public enum BulkReject {
    /// "Reject 12 photos that are certainly blurry?"
    public static func question(count: Int, group: GroupID) -> String {
        switch group {
        case .eyesClosed: localized("Reject \(count) photos that certainly have closed eyes?")
        case .blurry: localized("Reject \(count) photos that are certainly blurry?")
        case .exposure: localized("Reject \(count) photos that are certainly badly exposed?")
        default: localized("Reject \(count) photos that certainly have other issues?")
        }
    }

    /// The confirming button: "Reject 12 Photos".
    public static func buttonTitle(count: Int) -> String {
        localized("Reject \(count) Photos")
    }

    /// What ⇧X says when there is nothing to reject.
    public static func noneMessage(group: GroupID) -> String {
        guard group.isDefectGroup else { return localized("Rejecting Certain photos works in Eyes Closed and Blurry.") }
        guard group.canBeCertain else {
            return localized("Nothing in \(group.title) is flagged Certain; its flags are always Likely, so review them one by one.")
        }
        switch group {
        case .eyesClosed: return localized("No undecided photos left that certainly have closed eyes.")
        case .blurry: return localized("No undecided photos left that are certainly blurry.")
        case .exposure: return localized("No undecided photos left that are certainly badly exposed.")
        default: return localized("No undecided photos left that certainly have other issues.")
        }
    }
}

/// The analysis line in the toolbar and the summary when analysis ends.
public enum AnalysisText {
    /// "Analysing 420 of 1,240 · about 2 min left", or without the time while it is unknown.
    public static func running(done: Int, total: Int, secondsRemaining: Double?) -> String {
        let base = localized("Analysing \(done) of \(total)")
        guard let left = timeLeft(secondsRemaining) else { return base }
        return "\(base) · \(left)"
    }

    /// "Paused · 420 of 1,240 analysed"
    public static func paused(done: Int, total: Int) -> String {
        localized("Paused · \(done) of \(total) analysed")
    }

    /// "about 2 min left", rounded so it does not flicker: under a minute it says so.
    public static func timeLeft(_ seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds < 1 { return localized("finishing") }
        if seconds < 50 { return localized("less than a minute left") }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return localized("about \(max(1, minutes)) min left") }
        let hours = minutes / 60
        let rest = minutes % 60
        // Above an hour, five minutes is precise enough.
        let roundedRest = (rest / 5) * 5
        return roundedRest == 0 ? localized("about \(hours) h left") : localized("about \(hours) h \(roundedRest) min left")
    }

    /// The banner when analysis ends: "1,240 photos · 86 stacks · 41 likely rejects".
    public static func summary(_ summary: AnalysisSummary) -> String {
        let photos = localized("\(summary.photos) photos")
        // No number for none: "no stacks" is a choice of words, not a plural form.
        let stacks = summary.stacks == 0 ? localized("no stacks") : localized("\(summary.stacks) stacks")
        let rejects = summary.likelyRejects == 0 ? localized("no likely rejects") : localized("\(summary.likelyRejects) likely rejects")
        return [photos, stacks, rejects].joined(separator: " · ")
    }
}

/// What analysis found in a shoot, for the summary banner.
public struct AnalysisSummary: Sendable, Hashable {
    public var photos: Int
    public var stacks: Int
    public var duplicateSets: Int
    /// Readable photos with at least one raised flag (in Eyes Closed, Blurry, Exposure or Other
    /// Issues), decided or not.
    public var likelyRejects: Int

    public init(photos: Int, stacks: Int, duplicateSets: Int, likelyRejects: Int) {
        self.photos = photos
        self.stacks = stacks
        self.duplicateSets = duplicateSets
        self.likelyRejects = likelyRejects
    }

    public init(_ state: SessionState) {
        var flagged = Set<String>()
        for group in GroupID.allCases where group.isDefectGroup {
            flagged.formUnion(state.members(of: group))
        }
        self.init(photos: state.count, stacks: state.stacks.count, duplicateSets: state.duplicateSets.count, likelyRejects: flagged.count)
    }
}

/// How many photos are analysed at once.
///
/// The rule: start from the engine's default (one per core, 2 to 8); let analysis use at most an
/// eighth of the Mac's memory, at about 256 MB per photo in flight (eight in flight peak at about
/// 2 GB), so 4 on an 8 GB Mac and 8 on 16 GB; halve it on battery when "reduced on battery" is on;
/// halve it again under memory pressure, and analyse one at a time when memory is critical.
public enum AnalysisConcurrency {
    public static let bytesPerPhoto: UInt64 = 256 << 20
    public static let memoryShare: UInt64 = 8

    public enum MemoryPressure: String, Sendable, Hashable {
        case normal, warning, critical
    }

    /// The most photos the Mac's memory allows at once.
    public static func memoryCap(physicalMemory: UInt64) -> Int {
        max(1, Int(physicalMemory / memoryShare / bytesPerPhoto))
    }

    public static func limit(
        engineDefault: Int,
        physicalMemory: UInt64,
        onBattery: Bool,
        reduceOnBattery: Bool,
        memoryPressure: MemoryPressure = .normal
    ) -> Int {
        var limit = min(max(1, engineDefault), memoryCap(physicalMemory: physicalMemory))
        if onBattery, reduceOnBattery { limit = max(1, limit / 2) }
        switch memoryPressure {
        case .normal: break
        case .warning: limit = max(1, limit / 2)
        case .critical: limit = 1
        }
        return limit
    }

    /// Why the limit is what it is, for diagnostics.
    public static func reason(
        engineDefault: Int, physicalMemory: UInt64, onBattery: Bool, reduceOnBattery: Bool, memoryPressure: MemoryPressure
    ) -> String {
        var parts = ["default \(engineDefault)", "memory allows \(memoryCap(physicalMemory: physicalMemory))"]
        if onBattery { parts.append(reduceOnBattery ? "halved on battery" : "on battery, not reduced") }
        if memoryPressure != .normal { parts.append("memory pressure \(memoryPressure.rawValue)") }
        return parts.joined(separator: ", ")
    }
}
