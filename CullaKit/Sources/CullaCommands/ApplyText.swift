import CullaCore
import Foundation

// The words of the Review and Apply screen, the result banner, Undo Apply and the rescan note.
// Pure functions of plain values, so the app's views stay thin and every sentence is tested.
//
// Rules decided here, where the Design is silent:
// - Every number is exact and every place is named: "Move 412 Photos to _Rejected", never
//   "Apply". The primary button says what it will do; when it would do nothing it says so.
// - Photos are counted as the person sees them (a RAW+JPEG pair is one photo); files and bytes
//   follow in brackets so nothing on disk is hidden.
// - A run is named the same way everywhere: the button that started it, the menu item that undoes
//   it ("Undo Apply: Move 412 Photos to _Rejected") and the banner that reports it.

/// What happened when a run ended, in the numbers the banner reports.
public struct ApplyOutcome: Sendable, Hashable {
    public var kind: ApplyRunKind
    public var action: RejectAction
    public var state: ApplyRunState
    /// Photos the plan would move, trash or copy; for Mark Only, the rejects it would mark.
    public var plannedPhotos: Int
    /// Photos with at least one file moved or trashed (Apply), or copied (Copy Keepers).
    public var handledPhotos: Int
    /// Of those, photos the run stopped part-way through.
    public var incompletePhotos: Int
    public var files: Int
    public var bytes: Int64?
    public var sidecarsWritten: Int
    public var plannedSidecars: Int
    /// Sidecars left alone because they could not be parsed.
    public var skippedSidecars: Int
    public var failure: String?
    /// Copy Keepers: the destination folder's name.
    public var destinationName: String?

    public init(
        kind: ApplyRunKind, action: RejectAction, state: ApplyRunState, plannedPhotos: Int, handledPhotos: Int,
        incompletePhotos: Int = 0, files: Int = 0, bytes: Int64? = nil, sidecarsWritten: Int = 0, plannedSidecars: Int = 0,
        skippedSidecars: Int = 0, failure: String? = nil, destinationName: String? = nil
    ) {
        self.kind = kind
        self.action = action
        self.state = state
        self.plannedPhotos = plannedPhotos
        self.handledPhotos = handledPhotos
        self.incompletePhotos = incompletePhotos
        self.files = files
        self.bytes = bytes
        self.sidecarsWritten = sidecarsWritten
        self.plannedSidecars = plannedSidecars
        self.skippedSidecars = skippedSidecars
        self.failure = failure
        self.destinationName = destinationName
    }
}

/// Why undo left something as it was. Mirrors `UndoSkipReason` in CullaFiles.
public enum UndoProblem: String, Sendable, Hashable, CaseIterable {
    case missing
    case changed
    case originalPathOccupied
    case trashLocationUnknown
    case folderNotEmpty
    case failed

    /// True when nothing is wrong: a folder Culla made holds other files now, so it stays.
    public var isHarmless: Bool { self == .folderNotEmpty }
}

public enum ApplyText {
    // MARK: Counting

    public static func number(_ value: Int) -> String { Localization.number(value) }

    /// "1 photo", "412 photos".
    public static func photos(_ value: Int) -> String { localized("\(value) photos") }

    /// "1 Photo", "412 Photos", for buttons and menu items.
    public static func photosTitle(_ value: Int) -> String { localized("\(value) Photos") }

    public static func files(_ value: Int) -> String { localized("\(value) files") }

    public static func sidecars(_ value: Int) -> String { localized("\(value) sidecars") }

    public static func bytes(_ value: Int64) -> String { Localization.bytes(value) }

    /// The folder rejects move into. A name on disk, so never translated.
    static let folder = ApplyOptions.rejectedFolderName

    // MARK: The choice

    /// The radio button's label.
    public static func actionLabel(_ action: RejectAction) -> String {
        switch action {
        case .moveToRejectedFolder: localized("Move to a \(folder) folder in the shoot")
        case .markOnly: localized("Mark only, leave the files in place")
        case .moveToTrash: localized("Move to the Trash")
        }
    }

    /// The action's short name, for the settings and the dump.
    public static func actionName(_ action: RejectAction) -> String {
        switch action {
        case .moveToRejectedFolder: localized("Move to \(folder)")
        case .markOnly: localized("Mark Only")
        case .moveToTrash: localized("Move to the Trash")
        }
    }

    // MARK: The summary

    /// "The rejects take 8.2 GB on disk (1,020 files)." Nil without rejects.
    public static func rejectSpace(_ summary: ApplySummary) -> String? {
        guard summary.rejected > 0 else { return nil }
        let size = bytes(summary.rejectedBytes)
        let count = summary.rejectedFiles
        return summary.rejectedBytesAreExact
            ? localized("The rejects take \(size) on disk (\(count) files).")
            : localized("The rejects take at least \(size) on disk (\(count) files).")
    }

    /// What happens to the photos nobody decided on. Nil when there are none.
    /// - Parameter ratedWithSidecar: unreviewed photos with stars that get a sidecar for them.
    public static func unreviewedNote(_ summary: ApplySummary, ratedWithSidecar: Int) -> String? {
        guard summary.unreviewed > 0 else { return nil }
        // The only one or several, with no number shown: a choice of words, not a plural form.
        let them = summary.unreviewed == 1
            ? localized("The unreviewed photo counts as kept: it stays where it is, untouched.")
            : localized("Unreviewed photos count as kept: they stay where they are, untouched.")
        guard ratedWithSidecar > 0 else { return them }
        return them + " " + localized("The \(ratedWithSidecar) with stars get a sidecar for their rating.")
    }

    /// Mark Only with sidecars: how the sidecars mark the rejects, as the sidecar settings say.
    public static func markOnlyLine(_ rejects: Int, mapping: SidecarMapping) -> String {
        let rating = mapping.writesRating ? mapping.rejectedRating : nil
        let label = mapping.rejectedLabel
        switch (rating, label) {
        case (.some(-1), .some("Red")):
            return localized("No file moves. \(rejects) photos are marked as rejected in their sidecars: rating −1 and the Red label.")
        case let (rating?, label?):
            let value = ratingText(rating)
            return localized("No file moves. Their sidecars mark \(rejects) photos as rejected: rating \(value), label “\(label)”.")
        case let (rating?, nil):
            let value = ratingText(rating)
            return localized("No file moves. Their sidecars mark \(rejects) photos as rejected: rating \(value).")
        case let (nil, label?):
            return localized("No file moves. Their sidecars mark \(rejects) photos as rejected: label “\(label)”.")
        case (nil, nil):
            return localized("No file moves. Their sidecars mark \(rejects) photos as rejected in Culla’s own field only, which other applications do not read.")
        }
    }

    /// An XMP rating as written, with a true minus sign: "−1", "0".
    private static func ratingText(_ rating: Int) -> String {
        rating < 0 ? "−" + Localization.number(-rating) : Localization.number(rating)
    }

    /// The sentences under the chosen action: what moves where, what is written, what stays.
    /// - Parameters:
    ///   - shootName: the shoot folder's name.
    ///   - sidecarsForKept, sidecarsForRejected: sidecars the plan writes for each.
    ///   - mapping: what a sidecar records for a reject (Settings ▸ General ▸ Sidecars).
    public static func consequences(
        action: RejectAction, summary: ApplySummary, writeSidecars: Bool, shootName: String,
        sidecarsForKept: Int, sidecarsForRejected: Int, mapping: SidecarMapping = SidecarMapping()
    ) -> [String] {
        var lines: [String] = []
        let rejects = summary.rejected
        let size = summary.rejectedBytesAreExact
            ? localized("\(summary.rejectedFiles) files, \(bytes(summary.rejectedBytes))")
            : localized("\(summary.rejectedFiles) files, at least \(bytes(summary.rejectedBytes))")
        switch action {
        case .moveToRejectedFolder:
            if rejects > 0 {
                lines.append(localized("\(rejects) photos (\(size)) move into “\(folder)” inside “\(shootName)”, keeping their subfolders. Nothing is deleted."))
            }
        case .markOnly:
            if rejects > 0 {
                lines.append(writeSidecars
                    ? markOnlyLine(rejects, mapping: mapping)
                    : localized("No file moves, and with sidecars off nothing marks the rejects: Mark Only would change nothing on disk."))
            }
        case .moveToTrash:
            if rejects > 0 {
                lines.append(localized("\(rejects) photos (\(size)) move to the Trash. They stay there until you empty it; Culla never empties it."))
            }
        }
        if writeSidecars {
            let kept = sidecarsForKept, rejected = sidecarsForRejected
            if kept > 0, rejected > 0 {
                lines.append(localized("Sidecars (.xmp) are written beside \(kept) kept or rated and \(rejected) rejected photos, recording the decision and star rating. Existing sidecars keep everything else in them. Image files are never changed."))
            } else if kept > 0 {
                lines.append(localized("Sidecars (.xmp) are written beside \(kept) kept or rated photos, recording the decision and star rating. Existing sidecars keep everything else in them. Image files are never changed."))
            } else if rejected > 0 {
                lines.append(localized("Sidecars (.xmp) are written beside \(rejected) rejected photos, recording the decision and star rating. Existing sidecars keep everything else in them. Image files are never changed."))
            }
            if action == .moveToTrash, rejects > 0 { lines.append(localized("Photos moved to the Trash get no sidecar.")) }
        } else if !(action == .markOnly && rejects > 0) {
            lines.append(localized("No sidecars are written."))
        }
        return lines
    }

    // MARK: The button

    /// What the primary button says, or "Nothing to Apply" when the plan changes nothing.
    public static func primaryTitle(plan: ApplyPlan) -> String {
        if plan.blocker != nil || plan.isEmpty {
            if plan.kind == .copyKeepers, plan.destination == nil { return localized("Choose a Folder…") }
            return localized("Nothing to Apply")
        }
        return runTitle(
            kind: plan.kind, action: plan.options.rejectAction, rejected: plan.summary.rejected,
            copied: plan.photos.count, sidecars: plan.summary.sidecarsToWrite,
            destinationName: plan.destination?.lastPathComponent
        )
    }

    /// The name of a run: the button that starts it and the Undo Apply menu item.
    public static func runTitle(kind: ApplyRunKind, action: RejectAction, rejected: Int, copied: Int, sidecars: Int, destinationName: String?) -> String {
        if kind == .copyKeepers {
            let destination = destinationName ?? localized("destination.folder", default: "Folder")
            return localized("Copy \(copied) Photos to “\(destination)”")
        }
        guard rejected > 0 else {
            return sidecars > 0 ? localized("Write \(sidecars) Sidecars") : localized("Nothing to Apply")
        }
        switch action {
        case .moveToRejectedFolder: return localized("Move \(rejected) Photos to \(folder)")
        case .markOnly: return sidecars > 0 ? localized("Mark \(rejected) Photos as Rejected") : localized("Nothing to Apply")
        case .moveToTrash: return localized("Move \(rejected) Photos to the Trash")
        }
    }

    /// The Edit and File menus' item for Undo Apply, naming the run it takes back.
    public static func undoMenuTitle(runTitle: String, state: ApplyRunState) -> String {
        switch state {
        case .done, .undone: localized("Undo Apply: \(runTitle)")
        case .failed, .cancelled, .running: localized("Undo Interrupted Apply: \(runTitle)")
        case .partlyUndone: localized("Retry Undo Apply: \(runTitle)")
        }
    }

    // MARK: Why it cannot run

    /// Why Apply is unavailable for a shoot folder that cannot be written.
    public static func readOnlyExplanation(shootName: String, volumeIsReadOnly: Bool) -> String {
        volumeIsReadOnly
            ? localized("“\(shootName)” is on a card or drive that is locked or mounted read-only, so Culla cannot move or mark anything in it. You can copy the keepers to another folder instead; the card is only read.")
            : localized("Culla is not allowed to change “\(shootName)”, so it cannot move or mark anything in it. You can copy the keepers to another folder instead; this folder is only read.")
    }

    public static func blockerText(_ blocker: ApplyBlocker, destinationName: String?) -> String {
        switch blocker {
        case .readOnlyFolder:
            return localized("The shoot folder cannot be changed.")
        case .destinationInsideShoot:
            guard let destinationName else { return localized("That folder is inside the shoot. Choose a folder outside it.") }
            return localized("“\(destinationName)” is inside the shoot. Choose a folder outside it.")
        case .destinationNotWritable:
            guard let destinationName else { return localized("Culla cannot write to that folder. Choose another folder.") }
            return localized("Culla cannot write to “\(destinationName)”. Choose another folder.")
        }
    }

    // MARK: After a run

    /// The banner's headline and detail lines for a finished, failed or cancelled run.
    public static func outcome(_ outcome: ApplyOutcome) -> (headline: String, details: [String]) {
        var details: [String] = []
        let toTrash = outcome.action == .moveToTrash
        let handled = outcome.handledPhotos, planned = outcome.plannedPhotos
        let headline: String
        switch outcome.state {
        case .done, .undone, .partlyUndone, .running:
            switch (outcome.kind, outcome.action) {
            case (.copyKeepers, _):
                if let name = outcome.destinationName {
                    headline = localized("\(handled) photos copied to “\(name)”")
                } else {
                    headline = localized("\(handled) photos copied to the folder")
                }
                details.append(filesLine(outcome))
            case (.apply, .markOnly):
                headline = planned > 0 ? localized("\(planned) photos marked as rejected") : localized("Sidecars written")
            case (.apply, _):
                if planned > 0 {
                    headline = toTrash ? localized("\(handled) photos moved to the Trash") : localized("\(handled) photos moved to \(folder)")
                } else {
                    headline = localized("Sidecars written")
                }
                if handled > 0 { details.append(filesLine(outcome)) }
            }
        case .failed, .cancelled:
            let failed = outcome.state == .failed
            switch (outcome.kind, outcome.action) {
            case (.copyKeepers, _):
                headline = failed
                    ? localized("Copying stopped: \(handled) of \(planned) photos copied")
                    : localized("Copying cancelled: \(handled) of \(planned) photos copied")
            case (.apply, .markOnly):
                let written = outcome.sidecarsWritten, total = outcome.plannedSidecars
                headline = failed
                    ? localized("Apply stopped: \(written) of \(total) sidecars written")
                    : localized("Apply cancelled: \(written) of \(total) sidecars written")
            case (.apply, _):
                switch (failed, toTrash) {
                case (true, true): headline = localized("Apply stopped: \(handled) of \(planned) photos moved to the Trash")
                case (true, false): headline = localized("Apply stopped: \(handled) of \(planned) photos moved to \(folder)")
                case (false, true): headline = localized("Apply cancelled: \(handled) of \(planned) photos moved to the Trash")
                case (false, false): headline = localized("Apply cancelled: \(handled) of \(planned) photos moved to \(folder)")
                }
            }
            let notDone = max(0, planned - handled)
            if outcome.kind == .apply, outcome.action != .markOnly, notDone > 0 {
                details.append(localized("\(notDone) photos were not moved and are still in place."))
            }
            if outcome.incompletePhotos > 0 {
                details.append(localized("\(outcome.incompletePhotos) photos were moved only in part. Undo puts them back together."))
            }
            if let failure = outcome.failure, failed { details.append(localized("Reason: \(failure)")) }
        }
        if outcome.sidecarsWritten > 0, outcome.kind == .apply {
            details.append(localized("\(outcome.sidecarsWritten) sidecars written."))
        }
        if outcome.skippedSidecars > 0 {
            details.append(localized("\(outcome.skippedSidecars) existing sidecars were left alone because Culla could not read them:"))
        }
        return (headline, details)
    }

    private static func filesLine(_ outcome: ApplyOutcome) -> String {
        guard let bytes = outcome.bytes else { return localized("\(outcome.files) files.") }
        return localized("\(outcome.files) files, \(Self.bytes(bytes)).")
    }

    // MARK: After an undo

    /// The headline and lines after Undo Apply.
    /// - Parameters:
    ///   - restored: photos back in the shoot.
    ///   - problems: what was left as it was, with the file's or folder's name.
    ///   - kind: the run's kind; Copy Keepers undoes by removing the copies.
    public static func undoReport(restored: Int, undoneSteps: Int, problems: [(UndoProblem, String)], kind: ApplyRunKind, shootName: String) -> (headline: String, lines: [String], isWarning: Bool) {
        let serious = problems.filter { !$0.0.isHarmless }
        var lines: [String] = []
        let headline: String
        if kind == .copyKeepers {
            headline = serious.isEmpty ? localized("Copy undone: the copies were removed") : localized("Copy partly undone")
        } else if restored > 0 {
            headline = serious.isEmpty
                ? localized("Undo Apply finished: \(restored) photos back in “\(shootName)”")
                : localized("Undo Apply put \(restored) photos back in “\(shootName)”")
        } else {
            headline = serious.isEmpty
                ? (undoneSteps > 0 ? localized("Undo Apply finished: every sidecar is as it was") : localized("Undo Apply finished: nothing needed taking back"))
                : localized("Undo Apply could not take everything back")
        }
        if !serious.isEmpty {
            lines.append(localized("\(serious.count) items were left where they are; nothing was overwritten. Undo Apply can be tried again."))
        }
        for (problem, name) in problems {
            lines.append(localized("undo.problemLine", default: "\(name): \(message(problem))"))
        }
        return (headline, lines, !serious.isEmpty)
    }

    public static func message(_ problem: UndoProblem) -> String {
        switch problem {
        case .missing: localized("It is no longer where the apply put it.")
        case .changed: localized("It changed since the apply, so it was left alone.")
        case .originalPathOccupied: localized("Another file is now at its original place.")
        case .trashLocationUnknown: localized("It is in the Trash, but where was not recorded.")
        case .folderNotEmpty: localized("It holds other files now, so it was left in place.")
        case .failed: localized("It could not be moved back.")
        }
    }

    // MARK: Disk

    /// The note after a rescan found changes, such as "1 new photo · 1 renamed outside Culla".
    /// Each part is a count of its own.
    public static func rescanNote(added: Int, removed: Int, renamed: Int, modified: Int) -> String? {
        var parts: [String] = []
        if added > 0 { parts.append(localized("\(added) new photos")) }
        if renamed > 0 { parts.append(localized("\(renamed) photos renamed or moved outside Culla, decisions kept")) }
        if removed > 0 { parts.append(localized("\(removed) photos no longer in the folder")) }
        if modified > 0 { parts.append(localized("\(modified) photos changed on disk")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The one line shown while the shoot folder cannot be reached.
    public static func disconnected(shootName: String) -> String {
        localized("“\(shootName)” can’t be reached: its card or drive was disconnected, or the folder was moved or deleted. Every decision is kept, and Culla carries on when it is back.")
    }
}
