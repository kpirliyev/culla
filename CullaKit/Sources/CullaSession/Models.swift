import CullaAnalysis
import CullaCore
import Foundation

/// What the user decided about a photo. Unreviewed photos count as kept when decisions are
/// applied, so Unreviewed is a normal state, never a problem to resolve.
public enum Decision: String, Codable, Sendable, Hashable, CaseIterable {
    case unreviewed
    case kept
    case rejected
}

/// One photo of a shoot as the session sees it.
public struct PhotoItem: Sendable, Identifiable {
    public var file: PhotoFile
    public var metadata: PhotoMetadata
    public var decision: Decision
    /// Star rating, 0 (none) to 5.
    public var rating: Int
    /// Nil until the photo has been analysed, and after its file changed on disk.
    public var scores: PhotoScores?
    /// Why the file could not be decoded or analysed. An unreadable photo is shown in All Photos
    /// only: it is left out of every other group and out of the "left to review" counts.
    public var unreadableReason: String?
    /// True when the photo appeared since the session was last open (set by `SessionState.merge`).
    public var isNew: Bool

    public init(
        file: PhotoFile,
        metadata: PhotoMetadata,
        decision: Decision = .unreviewed,
        rating: Int = 0,
        scores: PhotoScores? = nil,
        unreadableReason: String? = nil,
        isNew: Bool = false
    ) {
        self.file = file
        self.metadata = metadata
        self.decision = decision
        self.rating = min(max(rating, 0), 5)
        self.scores = scores
        self.unreadableReason = unreadableReason
        self.isNew = isNew
    }

    /// The photo's path relative to the shoot folder (`PhotoFile.id`).
    public var id: String { file.id }
    /// Capture time, or the file's modification time when it has none.
    public var sortDate: Date { metadata.captureDate ?? file.modificationDate }
    public var isUnreadable: Bool { unreadableReason != nil }
    /// The parts of the photo the user sets, as saved to the store.
    public var mark: PhotoMark { PhotoMark(id: id, decision: decision, rating: rating) }
}

/// A photo's decision and rating: everything the user sets on a photo, and what undo restores.
public struct PhotoMark: Codable, Sendable, Hashable {
    public var id: String
    public var decision: Decision
    public var rating: Int

    public init(id: String, decision: Decision, rating: Int) {
        self.id = id
        self.decision = decision
        self.rating = min(max(rating, 0), 5)
    }
}

/// The sidebar groups, in the order the sidebar lists them (`allCases`).
public enum GroupID: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case allPhotos
    case duplicates
    case similarStacks
    case eyesClosed
    case blurry
    case exposure
    case otherIssues
    case unreviewed
    case kept
    case rejected

    public var id: String { rawValue }

    /// The group's name as the sidebar shows it.
    public var title: String {
        switch self {
        case .allPhotos: localized("All Photos")
        case .duplicates: localized("Duplicates")
        case .similarStacks: localized("Similar Stacks")
        case .eyesClosed: localized("Eyes Closed")
        case .blurry: localized("Blurry")
        case .exposure: localized("Exposure")
        case .otherIssues: localized("Other Issues")
        case .unreviewed: localized("Unreviewed")
        case .kept: localized("Kept")
        case .rejected: localized("Rejected")
        }
    }

    /// The flags that put a photo in this group. Empty for groups that are not about a defect.
    public var flags: [PhotoFlag] {
        switch self {
        case .eyesClosed: [.eyesClosed]
        case .blurry: [.blurry]
        case .exposure: [.clippedHighlights, .clippedShadows]
        case .otherIssues: [.tiltedHorizon, .faceCutOff, .lensSmudge, .utility, .lowAesthetics]
        case .allPhotos, .duplicates, .similarStacks, .unreviewed, .kept, .rejected: []
        }
    }

    /// True for the four groups that hold flagged photos.
    public var isDefectGroup: Bool { !flags.isEmpty }

    /// The group a flag puts a photo in.
    public static func group(for flag: PhotoFlag) -> GroupID {
        switch flag {
        case .eyesClosed: .eyesClosed
        case .blurry: .blurry
        case .clippedHighlights, .clippedShadows: .exposure
        case .tiltedHorizon, .faceCutOff, .lensSmudge, .utility, .lowAesthetics: .otherIssues
        }
    }

    var bit: UInt16 {
        switch self {
        case .allPhotos: 1 << 0
        case .duplicates: 1 << 1
        case .similarStacks: 1 << 2
        case .eyesClosed: 1 << 3
        case .blurry: 1 << 4
        case .exposure: 1 << 5
        case .otherIssues: 1 << 6
        case .unreviewed: 1 << 7
        case .kept: 1 << 8
        case .rejected: 1 << 9
        }
    }

    var slot: Int { Int(bit.trailingZeroBitCount) }
}

/// The two numbers the sidebar shows beside a group.
public struct GroupCount: Sendable, Hashable {
    /// Members whose decision is still Unreviewed.
    public var left: Int
    public var total: Int

    public init(left: Int, total: Int) {
        self.left = left
        self.total = total
    }
}

/// The numbers for the status bar.
public struct SessionTotals: Sendable, Hashable {
    /// Every photo in the session, unreadable ones included.
    public var photos: Int
    public var kept: Int
    public var rejected: Int
    /// Readable photos still Unreviewed.
    public var left: Int
    /// Photos that could not be read. They are not counted in `kept`, `rejected` or `left`.
    public var unreadable: Int

    public init(photos: Int, kept: Int, rejected: Int, left: Int, unreadable: Int) {
        self.photos = photos
        self.kept = kept
        self.rejected = rejected
        self.left = left
        self.unreadable = unreadable
    }
}

/// Photos taken close together that look alike, in capture order.
public struct PhotoStack: Sendable, Hashable, Identifiable {
    /// Photo ids in capture order; at least two.
    public var members: [String]
    /// The frame Culla (or the user) picked as the best one. Always a member, or nil.
    public var bestPick: String?

    public init(members: [String], bestPick: String? = nil) {
        self.members = members
        self.bestPick = bestPick
    }

    /// The first member's id, which names the stack.
    public var id: String { members.first ?? "" }
}

/// Files that hold the same photo, in capture order.
public struct PhotoDuplicateSet: Sendable, Hashable, Identifiable {
    public var kind: DuplicateSet.Kind
    /// Photo ids in capture order; at least two.
    public var members: [String]

    public init(kind: DuplicateSet.Kind, members: [String]) {
        self.kind = kind
        self.members = members
    }

    /// The first member's id, which names the set.
    public var id: String { members.first ?? "" }
}

/// Stacks and duplicate sets computed together, so they can be computed away from the state
/// (for example off the main thread) and handed back to it in one step.
public struct SessionGrouping: Sendable, Hashable {
    public var stacks: [PhotoStack]
    public var duplicateSets: [PhotoDuplicateSet]

    public init(stacks: [PhotoStack], duplicateSets: [PhotoDuplicateSet]) {
        self.stacks = stacks
        self.duplicateSets = duplicateSets
    }
}

/// One flag on a photo with its tier, for a reason badge.
public struct FlagBadge: Sendable, Hashable {
    public var flag: PhotoFlag
    public var tier: FlagTier

    public init(flag: PhotoFlag, tier: FlagTier) {
        self.flag = flag
        self.tier = tier
    }

    /// The sidebar group the flag puts the photo in.
    public var group: GroupID { GroupID.group(for: flag) }
}

/// What a tile needs to draw its badges.
public struct PhotoBadges: Sendable, Hashable {
    /// Raised flags in `PhotoFlag.allCases` order.
    public var flags: [FlagBadge]
    /// True when the photo is its stack's best pick.
    public var isBestPick: Bool
    /// The stack the photo is in, by `PhotoStack.id`.
    public var stackID: String?
    /// The duplicate set the photo is in, by `PhotoDuplicateSet.id`.
    public var duplicateSetID: String?
    public var isNew: Bool
    public var isUnreadable: Bool
}

/// A change to what the user set on photos. Every such change goes through
/// `SessionState.apply(_:)`, which records how to undo it.
public enum SessionAction: Sendable, Hashable {
    /// Gives every listed photo the same decision.
    case setDecision(Decision, ids: [String])
    /// Gives each photo its own decision in one step, such as keeping a stack's pick and
    /// rejecting the rest.
    case setDecisions([String: Decision])
    /// Gives every listed photo the same rating, 0 to 5. Values outside are clamped.
    case setRating(Int, ids: [String])
}

/// Which photos a change touched, so callers save and redraw only those.
public struct SessionChange: Sendable, Hashable {
    /// Ids of photos whose decision or rating actually changed, in capture order.
    public var changedIDs: [String]
    /// True when the manual stack edits (`SessionState.stackEdits`) changed, and with them the
    /// stacks: save the edits (`CullaDatabase.saveStackEdits`) and redraw the stacks.
    public var stackEditsChanged: Bool

    public init(changedIDs: [String] = [], stackEditsChanged: Bool = false) {
        self.changedIDs = changedIDs
        self.stackEditsChanged = stackEditsChanged
    }

    /// True when nothing changed: no decision or rating, and no stack edit.
    public var isEmpty: Bool { changedIDs.isEmpty && !stackEditsChanged }
}

/// What a rescan changed.
public struct MergeResult: Sendable, Hashable {
    /// Photos not seen before, now marked new.
    public var added: [String]
    /// Photos that are gone from the folder and were dropped, with their decisions.
    public var removed: [String]
    /// Photos whose file size or modification date changed. They keep their decision and
    /// rating, but their scores were dropped so they are analysed again.
    public var modified: [String]
    /// Photos renamed or moved outside Culla and recognised under their new id (see
    /// `SessionState.merge(scanned:)`). They keep their decision, rating, scores and new mark; they
    /// are in neither `added` nor `removed`. Move their cached scores
    /// (`CullaDatabase.moveCachedScores(_:)`), save the session's photos again, and save the
    /// stack edits (`SessionState.stackEdits`), whose ids were renamed too.
    public var renamed: [PhotoRename]

    public init(added: [String] = [], removed: [String] = [], modified: [String] = [], renamed: [PhotoRename] = []) {
        self.added = added
        self.removed = removed
        self.modified = modified
        self.renamed = renamed
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && modified.isEmpty && renamed.isEmpty }
}

/// A photo found under a new path by a rescan.
public struct PhotoRename: Sendable, Hashable {
    /// The old id (relative path).
    public var from: String
    /// The new id.
    public var to: String
    /// The shown file's old and new absolute URLs, for moving cached scores.
    public var oldURL: URL
    public var newURL: URL

    public init(from: String, to: String, oldURL: URL, newURL: URL) {
        self.from = from
        self.to = to
        self.oldURL = oldURL
        self.newURL = newURL
    }
}
