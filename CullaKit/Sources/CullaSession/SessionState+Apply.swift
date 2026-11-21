import CullaAnalysis
import CullaCore
import Foundation

extension Decision {
    /// The decision as a sidecar records it.
    public var sidecarDecision: SidecarDecision {
        switch self {
        case .unreviewed: .unreviewed
        case .kept: .kept
        case .rejected: .rejected
        }
    }
}

extension RejectReason {
    /// The reason a flag gives.
    public init(_ flag: PhotoFlag) {
        switch flag {
        case .eyesClosed: self = .eyesClosed
        case .blurry: self = .blurry
        case .clippedHighlights: self = .clippedHighlights
        case .clippedShadows: self = .clippedShadows
        case .lowAesthetics: self = .lowAesthetics
        case .tiltedHorizon: self = .tiltedHorizon
        case .faceCutOff: self = .faceCutOff
        case .lensSmudge: self = .lensSmudge
        case .utility: self = .utility
        }
    }

    /// The sidebar group the reason belongs to, or nil for `noFlag`.
    public var group: GroupID? {
        switch self {
        case .eyesClosed: .eyesClosed
        case .blurry: .blurry
        case .clippedHighlights, .clippedShadows: .exposure
        case .faceCutOff, .lensSmudge, .tiltedHorizon, .utility, .lowAesthetics: .otherIssues
        case .duplicate: .duplicates
        case .similarStack: .similarStacks
        case .noFlag: nil
        }
    }
}

/// A photo as it was when an apply took it out of the session: what `SessionState` needs to bring
/// it back exactly when the apply is undone. Saved with the apply's journal (scores left out
/// there; they come back from the score cache, since an undone file has its old path, size and
/// date again).
public struct AppliedPhoto: Codable, Sendable {
    public var file: PhotoFile
    public var metadata: PhotoMetadata
    public var decision: Decision
    public var rating: Int
    public var scores: PhotoScores?
    public var unreadableReason: String?
    public var isNew: Bool

    public init(_ item: PhotoItem) {
        file = item.file
        metadata = item.metadata
        decision = item.decision
        rating = item.rating
        scores = item.scores
        unreadableReason = item.unreadableReason
        isNew = item.isNew
    }

    public var id: String { file.id }

    /// The same photo without its scores, for saving in the journal.
    public var withoutScores: AppliedPhoto {
        var copy = self
        copy.scores = nil
        return copy
    }

    public var item: PhotoItem {
        PhotoItem(file: file, metadata: metadata, decision: decision, rating: rating, scores: scores, unreadableReason: unreadableReason, isNew: isNew)
    }
}

// MARK: - Planning

extension SessionState {
    /// Every reason the photo would be listed under among the rejects, most severe first (see
    /// `RejectReason` for the order): its flags under the current tuning, then Duplicates if it is
    /// in a duplicate set, then Similar Stacks if it is in a stack; `[.noFlag]` when none applies.
    /// Empty when the session has no such photo.
    public func rejectReasons(for id: String) -> [RejectReason] {
        guard let item = photo(id) else { return [] }
        var reasons = Set<RejectReason>()
        if !item.isUnreadable, let flags = summary(for: id)?.flags {
            reasons.formUnion(flags.map(RejectReason.init))
        }
        if duplicateSet(containing: id) != nil { reasons.insert(.duplicate) }
        if stack(containing: id) != nil { reasons.insert(.similarStack) }
        return reasons.isEmpty ? [.noFlag] : reasons.sorted()
    }

    /// The reason a reject is listed under: the most severe of `rejectReasons(for:)`.
    public func rejectReason(for id: String) -> RejectReason? {
        rejectReasons(for: id).first
    }

    /// What applying the decisions in the shoot folder would do, without touching the disk.
    ///
    /// - Rejected photos (readable ones) are moved to `_Rejected` (keeping their subfolder path
    ///   under it), left in place, or moved to the Trash, as `options.rejectAction` says, with all
    ///   their files: the shown file, its companions and any existing sidecar.
    /// - With `options.writeSidecars`, a sidecar is written for every readable photo with a
    ///   decision, and for unreviewed photos with a rating (rating only, no decision claimed).
    ///   Unreviewed unrated photos get none, and rejects moved to the Trash get none.
    /// - Unreadable photos are never moved and never get sidecars.
    /// - A sidecar path shared by two photos (such as `a.jpg` and `a.heic` shown as two photos) is
    ///   left alone for both, and reported in `notes`.
    ///
    /// - Parameters:
    ///   - folder: the shoot folder.
    ///   - folderIsWritable: from `ShootFolderAccess.writability(of:)`. When false, the plan is
    ///     blocked with `.readOnlyFolder` and offers Copy Keepers instead; the summary and reject
    ///     groups are still filled in.
    ///   - facts: companion sizes and existing sidecars from `ShootFileFacts.gather(...)`. Without
    ///     them the plan is still right, but `summary.rejectedBytes` is a lower bound and
    ///     `summary.rejectedFiles` does not count existing sidecars.
    public func applyPlan(
        folder: URL,
        options: ApplyOptions = ApplyOptions(),
        folderIsWritable: Bool = true,
        facts: ShootFileFacts = ShootFileFacts()
    ) -> ApplyPlan {
        let layout = SidecarLayout(photos: photos, facts: facts)
        var summary = ApplySummary()
        var planned: [PlannedPhoto] = []
        var reasons: [RejectReason: [String]] = [:]

        for item in photos {
            if item.isUnreadable {
                summary.unreadable += 1
                continue
            }
            let files = Self.relativeFiles(of: item)
            var disposition = PlannedDisposition.stay
            var mark: SidecarMark?
            switch item.decision {
            case .kept:
                summary.kept += 1
                mark = SidecarMark(decision: .kept, rating: item.rating)
            case .unreviewed:
                summary.unreviewed += 1
                if item.rating > 0 { mark = SidecarMark(decision: .unreviewed, rating: item.rating) }
            case .rejected:
                summary.rejected += 1
                reasons[rejectReason(for: item.id) ?? .noFlag, default: []].append(item.id)
                let sidecars = layout.isShared(item.id) ? [] : facts.sidecars[item.id] ?? []
                summary.rejectedFiles += files.count + sidecars.count
                for path in files + sidecars {
                    if path == item.id, facts.sizes[path] == nil {
                        summary.rejectedBytes += item.file.fileSize
                    } else if let size = facts.sizes[path] {
                        summary.rejectedBytes += size
                    } else {
                        summary.rejectedBytesAreExact = false
                    }
                }
                switch options.rejectAction {
                case .moveToRejectedFolder:
                    disposition = .moveToRejectedFolder
                    mark = SidecarMark(decision: .rejected, rating: item.rating)
                case .markOnly:
                    mark = SidecarMark(decision: .rejected, rating: item.rating)
                case .moveToTrash:
                    disposition = .moveToTrash
                }
            }
            if !options.writeSidecars || layout.isShared(item.id) { mark = nil }
            guard disposition != .stay || mark != nil else { continue }
            planned.append(PlannedPhoto(
                id: item.id, files: files, disposition: disposition, sidecar: mark, sidecarPath: layout.path(for: item.id),
                sidecarIsShared: layout.isShared(item.id)
            ))
        }

        summary.sidecarsToWrite = planned.count(where: { $0.sidecar != nil })
        let groups = RejectReason.allCases.compactMap { reason in
            reasons[reason].map { RejectGroup(reason: reason, photoIDs: $0) }
        }
        var plan = ApplyPlan(
            kind: .apply, folder: folder, options: options, photos: planned, summary: summary,
            rejectGroups: groups, notes: layout.notes
        )
        if !folderIsWritable {
            plan.blocker = .readOnlyFolder
            plan.photos = []
            plan.summary.sidecarsToWrite = 0
        } else if plan.isEmpty, summary.rejected > 0 {
            plan.notes.insert(.nothingToWrite, at: 0)
        }
        return plan
    }

    /// What Copy Keepers To would do: copy every photo that is not rejected (kept, unreviewed,
    /// and unreadable ones, which are not rejects either) with all its files to `destination`,
    /// keeping relative paths, and write sidecars beside the copies (for kept photos and rated
    /// unreviewed ones, as in `applyPlan`). The shoot folder is only read.
    ///
    /// Blocked with `.destinationInsideShoot` when the destination is the shoot folder or inside
    /// it, and with `.destinationNotWritable` when `destinationIsWritable` is false.
    public func copyKeepersPlan(
        folder: URL,
        destination: URL,
        options: ApplyOptions = ApplyOptions(),
        destinationIsWritable: Bool = true,
        facts: ShootFileFacts = ShootFileFacts()
    ) -> ApplyPlan {
        let layout = SidecarLayout(photos: photos, facts: facts)
        var summary = ApplySummary()
        var planned: [PlannedPhoto] = []
        for item in photos {
            if item.isUnreadable {
                summary.unreadable += 1
                // An unreadable photo the user rejected is not a keeper either.
                if item.decision == .rejected { continue }
            } else {
                switch item.decision {
                case .kept: summary.kept += 1
                case .unreviewed: summary.unreviewed += 1
                case .rejected:
                    summary.rejected += 1
                    continue
                }
            }
            let files = Self.relativeFiles(of: item)
            let sidecars = layout.isShared(item.id) ? [] : facts.sidecars[item.id] ?? []
            summary.filesToCopy += files.count + sidecars.count
            for path in files + sidecars {
                summary.bytesToCopy += facts.sizes[path] ?? (path == item.id ? item.file.fileSize : 0)
            }
            var mark: SidecarMark?
            if options.writeSidecars, !item.isUnreadable, !layout.isShared(item.id),
               item.decision == .kept || item.rating > 0 {
                mark = SidecarMark(decision: item.decision.sidecarDecision, rating: item.rating)
            }
            planned.append(PlannedPhoto(
                id: item.id, files: files, disposition: .copy, sidecar: mark, sidecarPath: layout.path(for: item.id),
                sidecarIsShared: layout.isShared(item.id)
            ))
        }
        summary.sidecarsToWrite = planned.count(where: { $0.sidecar != nil })
        var plan = ApplyPlan(
            kind: .copyKeepers, folder: folder, destination: destination, options: options,
            photos: planned, summary: summary, notes: layout.notes
        )
        if Self.isSameOrInside(destination, folder) {
            plan.blocker = .destinationInsideShoot
        } else if !destinationIsWritable {
            plan.blocker = .destinationNotWritable
        }
        if plan.blocker != nil {
            plan.photos = []
            plan.summary.sidecarsToWrite = 0
        }
        return plan
    }

    /// The photo's files as paths relative to the shoot folder: the shown file, then companions.
    static func relativeFiles(of item: PhotoItem) -> [String] {
        let directory = (item.id as NSString).deletingLastPathComponent
        return [item.id] + item.file.companions.map { join(directory, $0.lastPathComponent) }
    }

    static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    static func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let rootSlash = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(rootSlash)
    }
}

/// Where each photo's sidecar goes, and which sidecar paths are shared by several photos.
private struct SidecarLayout {
    private var paths: [String: String] = [:]
    private var shared: Set<String> = []
    private(set) var notes: [ApplyNote] = []

    init(photos: [PhotoItem], facts: ShootFileFacts) {
        var byKey: [String: [String]] = [:]
        for item in photos {
            let directory = (item.id as NSString).deletingLastPathComponent
            let base = (item.file.url.lastPathComponent as NSString).deletingPathExtension
            var path = SessionState.join(directory, base + ".xmp")
            // An existing sidecar keeps its own spelling, such as `IMG_1.XMP`.
            if let existing = facts.sidecars[item.id]?.first(where: { $0.lowercased() == path.lowercased() }) {
                path = existing
            }
            paths[item.id] = path
            byKey[path.lowercased(), default: []].append(item.id)
        }
        for ids in byKey.values where ids.count > 1 {
            shared.formUnion(ids)
            notes.append(.sharedSidecar(path: paths[ids[0]]!, photoIDs: ids))
        }
        notes.sort { a, b in
            if case let .sharedSidecar(pathA, _) = a, case let .sharedSidecar(pathB, _) = b { return pathA < pathB }
            return false
        }
    }

    func path(for id: String) -> String { paths[id] ?? id }
    func isShared(_ id: String) -> Bool { shared.contains(id) }
}
