import Foundation

// Value types shared by the three modules that take part in applying decisions to disk:
// `CullaSession` computes an `ApplyPlan` from the session (pure, no I/O), `CullaFiles` carries it
// out and undoes it (`ApplyExecutor`, `XMPSidecar`), and `CullaStore` keeps the journal of every
// run (`CullaDatabase` conforms to `ApplyJournal`). They live here so those modules need not
// depend on each other.

// MARK: - Options

/// What happens to rejected photos when decisions are applied.
public enum RejectAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Move them into a `_Rejected` folder inside the shoot, keeping each photo's subfolder path
    /// under it. The default.
    case moveToRejectedFolder
    /// Leave the files where they are; only sidecars record the rejection.
    case markOnly
    /// Move them to the Trash.
    case moveToTrash
}

/// How a photo's decision and rating are written into an XMP sidecar. The defaults follow what
/// Adobe Bridge and Lightroom Classic read; see `XMPSidecar` in CullaFiles for what each editor
/// reads.
public struct SidecarMapping: Codable, Sendable, Hashable {
    /// Write star ratings to `xmp:Rating` (0 to 5), and `rejectedRating` for rejects.
    public var writesRating: Bool
    /// The `xmp:Rating` a rejected photo gets; -1 is what Bridge and Lightroom read as rejected.
    /// Nil leaves a rejected photo's `xmp:Rating` alone (its star rating is not written either).
    public var rejectedRating: Int?
    /// The colour label (`xmp:Label`) for kept photos, or nil to leave the label alone.
    public var keptLabel: String?
    /// The colour label for rejected photos, or nil to leave the label alone.
    public var rejectedLabel: String?

    public init(writesRating: Bool = true, rejectedRating: Int? = -1, keptLabel: String? = "Green", rejectedLabel: String? = "Red") {
        self.writesRating = writesRating
        self.rejectedRating = rejectedRating
        self.keptLabel = keptLabel
        self.rejectedLabel = rejectedLabel
    }
}

/// The user's choices on the Review and Apply screen.
public struct ApplyOptions: Codable, Sendable, Hashable {
    public var rejectAction: RejectAction
    /// Write XMP sidecars for photos with a decision or a rating. On by default.
    public var writeSidecars: Bool
    public var sidecarMapping: SidecarMapping

    /// The folder inside the shoot that rejects move to. `PhotoScanner` never reads it.
    public static let rejectedFolderName = "_Rejected"

    public init(rejectAction: RejectAction = .moveToRejectedFolder, writeSidecars: Bool = true, sidecarMapping: SidecarMapping = SidecarMapping()) {
        self.rejectAction = rejectAction
        self.writeSidecars = writeSidecars
        self.sidecarMapping = sidecarMapping
    }
}

// MARK: - Plan

/// A photo's decision as it is written into a sidecar. Mirrors `Decision` in CullaSession.
public enum SidecarDecision: String, Codable, Sendable, Hashable, CaseIterable {
    case unreviewed
    case kept
    case rejected
}

/// What a sidecar records for one photo.
public struct SidecarMark: Codable, Sendable, Hashable {
    public var decision: SidecarDecision
    /// 0 to 5.
    public var rating: Int

    public init(decision: SidecarDecision, rating: Int) {
        self.decision = decision
        self.rating = min(max(rating, 0), 5)
    }
}

/// Why a photo is among the rejects, for the Review and Apply screen's sections.
///
/// `allCases` is the order of severity, most severe first; a photo with several reasons is listed
/// under the first that applies:
/// 1. Faults of the frame itself that no edit fixes: eyes closed, then blur (the two that can be
///    Certain).
/// 2. Exposure faults (often partly recoverable from a RAW): clipped highlights, clipped shadows.
/// 3. Framing faults: a face cut by the edge, lens smudge, a tilted horizon.
/// 4. Judgements about the picture: a utility shot (screenshot, document, accident), a low
///    aesthetics score.
/// 5. Redundancy, where the photo may be fine but another frame is kept: a duplicate copy, then
///    a frame of a similar stack.
/// 6. No reason: rejected by hand with no flag and in no group.
public enum RejectReason: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case eyesClosed
    case blurry
    case clippedHighlights
    case clippedShadows
    case faceCutOff
    case lensSmudge
    case tiltedHorizon
    case utility
    case lowAesthetics
    case duplicate
    case similarStack
    case noFlag

    /// The section heading on the Review and Apply screen, in the person's language.
    public var title: String {
        switch self {
        case .eyesClosed: localized("Eyes Closed")
        case .blurry: localized("Blurry")
        case .clippedHighlights: localized("Clipped Highlights")
        case .clippedShadows: localized("Clipped Shadows")
        case .faceCutOff: localized("Face Cut Off")
        case .lensSmudge: localized("Lens Smudge")
        case .tiltedHorizon: localized("Tilted Horizon")
        case .utility: localized("Screenshots and Accidental Shots")
        case .lowAesthetics: localized("Low Aesthetics")
        case .duplicate: localized("Duplicates")
        case .similarStack: localized("Similar Stacks")
        case .noFlag: localized("No Flag")
        }
    }

    /// Position in `allCases`: lower is more severe.
    public var severityRank: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (lhs: RejectReason, rhs: RejectReason) -> Bool { lhs.severityRank < rhs.severityRank }
}

/// The rejects listed under one reason, in capture order.
public struct RejectGroup: Codable, Sendable, Hashable, Identifiable {
    public var reason: RejectReason
    public var photoIDs: [String]

    public init(reason: RejectReason, photoIDs: [String]) {
        self.reason = reason
        self.photoIDs = photoIDs
    }

    public var id: RejectReason { reason }
}

/// What happens to a photo's files.
public enum PlannedDisposition: String, Codable, Sendable, Hashable {
    /// The files stay; at most a sidecar is written beside them.
    case stay
    case moveToRejectedFolder
    case moveToTrash
    /// The files are copied to the Copy Keepers destination, keeping their relative path.
    case copy
}

/// One photo in a plan: its files and what happens to them.
public struct PlannedPhoto: Codable, Sendable, Hashable, Identifiable {
    /// The photo's id: the shown file's path relative to the shoot folder.
    public var id: String
    /// Paths relative to the shoot folder: the shown file first, then its companions (such as the
    /// RAW of a pair). Existing sidecars are found again when the plan is carried out, so they are
    /// not listed here.
    public var files: [String]
    public var disposition: PlannedDisposition
    /// What to write into the photo's sidecar, or nil for no sidecar.
    public var sidecar: SidecarMark?
    /// The sidecar's path relative to the shoot folder, `<folder>/<basename>.xmp`, wherever the
    /// photo ends up (the executor puts it beside the moved or copied files).
    public var sidecarPath: String
    /// True when another photo has the same sidecar path: no sidecar is written for this photo,
    /// and an existing `<basename>.xmp` is neither moved nor changed.
    public var sidecarIsShared: Bool

    public init(id: String, files: [String], disposition: PlannedDisposition, sidecar: SidecarMark?, sidecarPath: String, sidecarIsShared: Bool = false) {
        self.id = id
        self.files = files
        self.disposition = disposition
        self.sidecar = sidecar
        self.sidecarPath = sidecarPath
        self.sidecarIsShared = sidecarIsShared
    }
}

/// Why a plan cannot be carried out.
public enum ApplyBlocker: String, Codable, Sendable, Hashable {
    /// The shoot folder or its volume is not writable (for example a locked card). None of the
    /// reject actions can run; offer Copy Keepers To instead.
    case readOnlyFolder
    /// Copy Keepers: the destination is the shoot folder or inside it.
    case destinationInsideShoot
    /// Copy Keepers: the destination folder or its volume is not writable.
    case destinationNotWritable
}

/// Something the user should know about a plan that does not stop it.
public enum ApplyNote: Codable, Sendable, Hashable {
    /// Mark only with sidecars off: nothing on disk changes.
    case nothingToWrite
    /// These photos share one sidecar path with another photo (for example `a.jpg` and `a.heic`
    /// as separate photos), so no sidecar is written for them and an existing one is not moved.
    case sharedSidecar(path: String, photoIDs: [String])
}

/// The numbers the Review and Apply screen shows.
public struct ApplySummary: Codable, Sendable, Hashable {
    public var kept: Int
    public var rejected: Int
    /// Readable photos without a decision. They count as kept: they stay.
    public var unreviewed: Int
    /// Photos that could not be read. Never moved and never given sidecars.
    public var unreadable: Int
    /// Files of the readable rejected photos: shown files, companions and existing sidecars.
    public var rejectedFiles: Int
    /// Their size on disk.
    public var rejectedBytes: Int64
    /// False when the size of some of those files was not known to the planner, so
    /// `rejectedBytes` is a lower bound. Pass `ShootFileFacts` gathered by CullaFiles to get the
    /// exact numbers.
    public var rejectedBytesAreExact: Bool
    /// How many sidecars the plan writes.
    public var sidecarsToWrite: Int
    /// Copy Keepers: files and bytes to copy.
    public var filesToCopy: Int
    public var bytesToCopy: Int64

    public init(
        kept: Int = 0, rejected: Int = 0, unreviewed: Int = 0, unreadable: Int = 0,
        rejectedFiles: Int = 0, rejectedBytes: Int64 = 0, rejectedBytesAreExact: Bool = true,
        sidecarsToWrite: Int = 0, filesToCopy: Int = 0, bytesToCopy: Int64 = 0
    ) {
        self.kept = kept
        self.rejected = rejected
        self.unreviewed = unreviewed
        self.unreadable = unreadable
        self.rejectedFiles = rejectedFiles
        self.rejectedBytes = rejectedBytes
        self.rejectedBytesAreExact = rejectedBytesAreExact
        self.sidecarsToWrite = sidecarsToWrite
        self.filesToCopy = filesToCopy
        self.bytesToCopy = bytesToCopy
    }
}

/// Which kind of run a plan or journal entry is.
public enum ApplyRunKind: String, Codable, Sendable, Hashable {
    /// Applying decisions in the shoot folder: one of the three reject actions plus sidecars.
    case apply
    /// Copying keepers of a read-only shoot to another folder.
    case copyKeepers
}

/// Everything applying would do, computed without touching the disk
/// (`SessionState.applyPlan(...)`, `SessionState.copyKeepersPlan(...)`), plus what the Review and
/// Apply screen shows about it.
public struct ApplyPlan: Codable, Sendable, Hashable {
    public var kind: ApplyRunKind
    /// The shoot folder.
    public var folder: URL
    /// Copy Keepers: the folder keepers are copied into.
    public var destination: URL?
    public var options: ApplyOptions
    /// Photos with something to do, in capture order. Photos with nothing to do (an unrated
    /// unreviewed photo, any unreadable photo) are not listed.
    public var photos: [PlannedPhoto]
    public var summary: ApplySummary
    /// The rejects by reason, most severe reason first; empty reasons are left out. Every
    /// readable rejected photo is in exactly one group.
    public var rejectGroups: [RejectGroup]
    /// Set when the plan cannot be carried out; `photos` is then empty.
    public var blocker: ApplyBlocker?
    public var notes: [ApplyNote]

    public init(
        kind: ApplyRunKind, folder: URL, destination: URL? = nil, options: ApplyOptions,
        photos: [PlannedPhoto], summary: ApplySummary, rejectGroups: [RejectGroup] = [],
        blocker: ApplyBlocker? = nil, notes: [ApplyNote] = []
    ) {
        self.kind = kind
        self.folder = folder
        self.destination = destination
        self.options = options
        self.photos = photos
        self.summary = summary
        self.rejectGroups = rejectGroups
        self.blocker = blocker
        self.notes = notes
    }

    /// True when the plan can be carried out.
    public var canApply: Bool { blocker == nil }
    /// True when the plan is blocked because the shoot is read-only, so the screen should offer
    /// Copy Keepers To instead.
    public var offersCopyKeepers: Bool { blocker == .readOnlyFolder }
    /// Photos whose files the plan moves out of the shoot (to `_Rejected` or the Trash): the ones
    /// a successful run takes out of the session.
    public var leavingPhotoIDs: [String] {
        photos.filter { $0.disposition == .moveToRejectedFolder || $0.disposition == .moveToTrash }.map(\.id)
    }

    /// True when carrying the plan out would change nothing on disk.
    public var isEmpty: Bool { photos.allSatisfy { $0.disposition == .stay && $0.sidecar == nil } }
}

/// What the planner knows about files on disk beyond `PhotoFile`: sizes of companions and the
/// sidecars that already exist. Gathered by `ShootFileFacts.gather(...)` in CullaFiles; an empty
/// value is allowed and only makes `ApplySummary.rejectedBytes` a lower bound.
public struct ShootFileFacts: Codable, Sendable, Hashable {
    /// File sizes by path relative to the shoot folder.
    public var sizes: [String: Int64]
    /// Existing sidecars of each photo, by photo id, as paths relative to the shoot folder.
    public var sidecars: [String: [String]]

    public init(sizes: [String: Int64] = [:], sidecars: [String: [String]] = [:]) {
        self.sizes = sizes
        self.sidecars = sidecars
    }
}

// MARK: - Journal

/// A file's size and modification time to the nanosecond, as `stat` gives them. What undo checks
/// to be sure a file is still the one an apply moved, and what it restores on a sidecar.
public struct FileStamp: Codable, Sendable, Hashable {
    public var size: Int64
    public var seconds: Int64
    public var nanoseconds: Int64

    public init(size: Int64, seconds: Int64, nanoseconds: Int64) {
        self.size = size
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    public var modificationDate: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1e9)
    }
}

/// A sidecar's state before a run wrote it, so it can be put back exactly.
public enum SidecarPrevious: Codable, Sendable, Hashable {
    /// There was no file.
    case absent
    /// There was a file with these bytes and this size and modification time.
    case existed(Data, FileStamp)
}

/// What one step of a run does. Paths are absolute.
public enum ApplyStepAction: Codable, Sendable, Hashable {
    /// Create one folder (its parent exists or is created by an earlier step).
    case createFolder(path: String)
    /// Move a file within a volume, never replacing anything. `stamp` is the file's before the move.
    case move(from: String, to: String, stamp: FileStamp)
    /// Move a file to the Trash. `trashedPath` is where it went, filled in once it is done.
    case trash(path: String, stamp: FileStamp, trashedPath: String?)
    /// Write (or merge into) a sidecar. `previous` and `written` are filled in when the step
    /// starts, before anything is written, so undo can restore the file exactly. `tempPath` is the
    /// file written beside it before it replaces the sidecar.
    case writeSidecar(path: String, mark: SidecarMark, previous: SidecarPrevious?, written: Data?, tempPath: String?)
    /// Copy a file, never replacing anything: to `tempPath` beside the destination first, then
    /// renamed. `stamp` is the copy's once it is done.
    case copy(from: String, to: String, tempPath: String, stamp: FileStamp?)
}

/// Which of a photo's files a step is about.
public enum ApplyFileRole: String, Codable, Sendable, Hashable {
    /// The shown file, whose path is the photo's id.
    case photo
    /// A companion, such as the RAW of a pair.
    case companion
    /// A sidecar that was already there.
    case existingSidecar
    /// The sidecar this run writes.
    case sidecar
    /// A folder the run creates.
    case folder
}

/// Where a step is.
public enum ApplyStepState: String, Codable, Sendable, Hashable {
    /// Not started yet.
    case pending
    /// Recorded as about to run (write-ahead). After a crash it may or may not have happened;
    /// undo looks at the disk to tell.
    case started
    case done
    /// Not carried out on purpose, such as a sidecar that could not be parsed and was left alone,
    /// or a folder that already existed. Undo ignores it.
    case skipped
    /// Tried and failed; nothing was changed by it. The run stopped here.
    case failed
    /// Taken back by undo.
    case undone
    /// Undo could not take it back (see `note`); it stays done and a later undo tries again.
    case undoSkipped
}

/// One step of a run, as the journal keeps it.
public struct ApplyStep: Codable, Sendable, Hashable, Identifiable {
    /// Position in the run, from 0.
    public var index: Int
    /// The photo the step belongs to; empty for folders.
    public var photoID: String
    public var role: ApplyFileRole
    public var action: ApplyStepAction
    public var state: ApplyStepState
    /// Why it failed, was skipped, or could not be undone.
    public var note: String?

    public init(index: Int, photoID: String, role: ApplyFileRole, action: ApplyStepAction, state: ApplyStepState = .pending, note: String? = nil) {
        self.index = index
        self.photoID = photoID
        self.role = role
        self.action = action
        self.state = state
        self.note = note
    }

    public var id: Int { index }
}

/// Where a run is.
public enum ApplyRunState: String, Codable, Sendable, Hashable, CaseIterable {
    /// Under way, or interrupted by a crash when found on the next launch.
    case running
    /// Every step done.
    case done
    /// Stopped at a failed step. What was done before it can be undone.
    case failed
    /// Cancelled between steps. What was done can be undone.
    case cancelled
    /// Every done step was taken back.
    case undone
    /// Undo took back some steps and could not take back others; undo can be tried again.
    case partlyUndone

    /// True when the run changed something that undo can still take back.
    public var isUndoable: Bool {
        switch self {
        case .done, .failed, .cancelled, .partlyUndone, .running: true
        case .undone: false
        }
    }
}

/// Where the executor records a run's steps before and after it carries them out. `CullaDatabase`
/// is the real one; `MemoryApplyJournal` in CullaFiles is for tests.
///
/// Every call must be durable when it returns: the executor does not touch the disk for a step
/// until `updateStep` recording it as started has returned.
public protocol ApplyJournal: Sendable {
    /// Records the full list of steps of a run, all pending, before the first one is carried out.
    func recordSteps(_ steps: [ApplyStep], runID: Int64) async throws
    /// Replaces one step's record.
    func updateStep(_ step: ApplyStep, runID: Int64) async throws
    /// Sets the run's state, with a message when it failed.
    func setRunState(_ state: ApplyRunState, failure: String?, runID: Int64) async throws
}

/// How far a run or an undo has got, for a progress bar.
public struct ApplyProgress: Sendable, Hashable {
    public var done: Int
    public var total: Int
    /// The photo of the step being carried out.
    public var currentPhotoID: String?

    public init(done: Int, total: Int, currentPhotoID: String?) {
        self.done = done
        self.total = total
        self.currentPhotoID = currentPhotoID
    }

    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 1 }
}
