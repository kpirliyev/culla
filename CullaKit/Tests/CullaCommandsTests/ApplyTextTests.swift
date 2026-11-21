import CullaCommands
import CullaCore
import Foundation
import Testing

@Suite("Apply wording")
struct ApplyTextTests {
    private func plan(action: RejectAction, rejected: Int, sidecars: Int, kind: ApplyRunKind = .apply, blocker: ApplyBlocker? = nil, destination: URL? = nil) -> ApplyPlan {
        var photos: [PlannedPhoto] = []
        for index in 0..<rejected {
            let disposition: PlannedDisposition = switch action {
            case .moveToRejectedFolder: .moveToRejectedFolder
            case .markOnly: .stay
            case .moveToTrash: .moveToTrash
            }
            let mark = index < sidecars ? SidecarMark(decision: .rejected, rating: 0) : nil
            photos.append(PlannedPhoto(id: "r\(index).jpg", files: ["r\(index).jpg"], disposition: kind == .copyKeepers ? .copy : disposition, sidecar: mark, sidecarPath: "r\(index).xmp"))
        }
        let summary = ApplySummary(kept: 3, rejected: rejected, unreviewed: 2, rejectedFiles: rejected * 2, rejectedBytes: Int64(rejected) * 1_000_000, sidecarsToWrite: sidecars)
        return ApplyPlan(kind: kind, folder: URL(fileURLWithPath: "/tmp/Shoot"), destination: destination, options: ApplyOptions(rejectAction: action, writeSidecars: sidecars > 0), photos: photos, summary: summary, blocker: blocker)
    }

    @Test func theButtonSaysExactlyWhatHappens() {
        #expect(ApplyText.primaryTitle(plan: plan(action: .moveToRejectedFolder, rejected: 412, sidecars: 0)) == "Move 412 Photos to _Rejected")
        #expect(ApplyText.primaryTitle(plan: plan(action: .moveToRejectedFolder, rejected: 1, sidecars: 0)) == "Move 1 Photo to _Rejected")
        #expect(ApplyText.primaryTitle(plan: plan(action: .moveToTrash, rejected: 2_500, sidecars: 0)) == "Move \(ApplyText.number(2_500)) Photos to the Trash")
        #expect(ApplyText.primaryTitle(plan: plan(action: .markOnly, rejected: 12, sidecars: 12)) == "Mark 12 Photos as Rejected")
        // Mark Only without sidecars changes nothing.
        #expect(ApplyText.primaryTitle(plan: plan(action: .markOnly, rejected: 12, sidecars: 0)) == "Nothing to Apply")
        #expect(ApplyText.primaryTitle(plan: plan(action: .moveToRejectedFolder, rejected: 0, sidecars: 0)) == "Nothing to Apply")
        let blocked = plan(action: .moveToRejectedFolder, rejected: 3, sidecars: 0, blocker: .readOnlyFolder)
        #expect(ApplyText.primaryTitle(plan: blocked) == "Nothing to Apply")
        let copy = plan(action: .moveToRejectedFolder, rejected: 5, sidecars: 0, kind: .copyKeepers, destination: URL(fileURLWithPath: "/tmp/Backup"))
        #expect(ApplyText.primaryTitle(plan: copy) == "Copy 5 Photos to “Backup”")
    }

    @Test func sidecarsOnlyWhenNothingIsRejected() {
        #expect(ApplyText.runTitle(kind: .apply, action: .moveToRejectedFolder, rejected: 0, copied: 0, sidecars: 7, destinationName: nil) == "Write 7 Sidecars")
        #expect(ApplyText.runTitle(kind: .apply, action: .markOnly, rejected: 0, copied: 0, sidecars: 1, destinationName: nil) == "Write 1 Sidecar")
    }

    @Test func undoNamesTheRun() {
        #expect(ApplyText.undoMenuTitle(runTitle: "Move 412 Photos to _Rejected", state: .done) == "Undo Apply: Move 412 Photos to _Rejected")
        #expect(ApplyText.undoMenuTitle(runTitle: "Move 412 Photos to _Rejected", state: .failed) == "Undo Interrupted Apply: Move 412 Photos to _Rejected")
        #expect(ApplyText.undoMenuTitle(runTitle: "Move 412 Photos to _Rejected", state: .partlyUndone) == "Retry Undo Apply: Move 412 Photos to _Rejected")
    }

    @Test func summaryAndUnreviewed() {
        let summary = ApplySummary(kept: 312, rejected: 412, unreviewed: 86, rejectedFiles: 1_020, rejectedBytes: 8_200_000_000)
        #expect(ApplyText.rejectSpace(summary) == "The rejects take \(ApplyText.bytes(8_200_000_000)) on disk (\(ApplyText.number(1_020)) files).")
        #expect(ApplyText.unreviewedNote(summary, ratedWithSidecar: 0) == "Unreviewed photos count as kept: they stay where they are, untouched.")
        #expect(ApplyText.unreviewedNote(summary, ratedWithSidecar: 3)?.hasSuffix("The 3 with stars get a sidecar for their rating.") == true)
        #expect(ApplyText.unreviewedNote(ApplySummary(kept: 1), ratedWithSidecar: 0) == nil)
        #expect(ApplyText.rejectSpace(ApplySummary(kept: 1)) == nil)
    }

    @Test func consequencesNameThePlaces() {
        let summary = ApplySummary(kept: 3, rejected: 2, rejectedFiles: 3, rejectedBytes: 2_000_000)
        let move = ApplyText.consequences(action: .moveToRejectedFolder, summary: summary, writeSidecars: true, shootName: "Wedding", sidecarsForKept: 3, sidecarsForRejected: 2)
        #expect(move[0] == "2 photos (3 files, \(ApplyText.bytes(2_000_000))) move into “_Rejected” inside “Wedding”, keeping their subfolders. Nothing is deleted.")
        #expect(move[1].hasPrefix("Sidecars (.xmp) are written beside 3 kept or rated and 2 rejected photos"))
        let trash = ApplyText.consequences(action: .moveToTrash, summary: summary, writeSidecars: true, shootName: "Wedding", sidecarsForKept: 3, sidecarsForRejected: 0)
        #expect(trash.contains("Photos moved to the Trash get no sidecar."))
        let mark = ApplyText.consequences(action: .markOnly, summary: summary, writeSidecars: false, shootName: "Wedding", sidecarsForKept: 0, sidecarsForRejected: 0)
        #expect(mark[0].contains("Mark Only would change nothing on disk"))
        #expect(!mark.contains("No sidecars are written."))
    }

    @Test func markOnlyFollowsTheSidecarSettings() {
        #expect(ApplyText.markOnlyLine(2, mapping: SidecarMapping())
            == "No file moves. 2 photos are marked as rejected in their sidecars: rating −1 and the Red label.")
        #expect(ApplyText.markOnlyLine(1, mapping: SidecarMapping(rejectedRating: 0, rejectedLabel: "Purple"))
            == "No file moves. Their sidecars mark 1 photo as rejected: rating 0, label “Purple”.")
        #expect(ApplyText.markOnlyLine(3, mapping: SidecarMapping(rejectedLabel: nil))
            == "No file moves. Their sidecars mark 3 photos as rejected: rating −1.")
        #expect(ApplyText.markOnlyLine(3, mapping: SidecarMapping(writesRating: false))
            == "No file moves. Their sidecars mark 3 photos as rejected: label “Red”.")
        #expect(ApplyText.markOnlyLine(3, mapping: SidecarMapping(writesRating: false, rejectedLabel: nil))
            == "No file moves. Their sidecars mark 3 photos as rejected in Culla’s own field only, which other applications do not read.")
        let summary = ApplySummary(kept: 3, rejected: 2, rejectedFiles: 3, rejectedBytes: 2_000_000)
        let mark = ApplyText.consequences(action: .markOnly, summary: summary, writeSidecars: true, shootName: "Wedding",
                                          sidecarsForKept: 0, sidecarsForRejected: 2, mapping: SidecarMapping(rejectedRating: nil))
        #expect(mark[0] == "No file moves. Their sidecars mark 2 photos as rejected: label “Red”.")
    }

    @Test func outcomesSayWhatWasAndWasNotDone() {
        let done = ApplyText.outcome(ApplyOutcome(kind: .apply, action: .moveToRejectedFolder, state: .done, plannedPhotos: 412, handledPhotos: 412, files: 1_020, sidecarsWritten: 724, plannedSidecars: 724))
        #expect(done.headline == "412 photos moved to _Rejected")
        #expect(done.details == ["\(ApplyText.number(1_020)) files.", "724 sidecars written."])
        let failed = ApplyText.outcome(ApplyOutcome(kind: .apply, action: .moveToRejectedFolder, state: .failed, plannedPhotos: 10, handledPhotos: 4, incompletePhotos: 1, files: 7, failure: "The disk is full."))
        #expect(failed.headline == "Apply stopped: 4 of 10 photos moved to _Rejected")
        #expect(failed.details.contains("6 photos were not moved and are still in place."))
        #expect(failed.details.contains("1 photo was moved only in part. Undo puts it back together."))
        #expect(failed.details.contains("Reason: The disk is full."))
        let cancelled = ApplyText.outcome(ApplyOutcome(kind: .apply, action: .moveToTrash, state: .cancelled, plannedPhotos: 10, handledPhotos: 3))
        #expect(cancelled.headline == "Apply cancelled: 3 of 10 photos moved to the Trash")
        let marked = ApplyText.outcome(ApplyOutcome(kind: .apply, action: .markOnly, state: .done, plannedPhotos: 5, handledPhotos: 0, sidecarsWritten: 9, plannedSidecars: 9, skippedSidecars: 1))
        #expect(marked.headline == "5 photos marked as rejected")
        #expect(marked.details.last?.hasPrefix("1 existing sidecar was left alone") == true)
        let copied = ApplyText.outcome(ApplyOutcome(kind: .copyKeepers, action: .moveToRejectedFolder, state: .done, plannedPhotos: 8, handledPhotos: 8, files: 9, bytes: 3_000_000, destinationName: "Backup"))
        #expect(copied.headline == "8 photos copied to “Backup”")
    }

    @Test func undoReportIsCalmAboutAFolderThatStays() {
        let calm = ApplyText.undoReport(restored: 12, undoneSteps: 30, problems: [(.folderNotEmpty, "_Rejected")], kind: .apply, shootName: "Shoot")
        #expect(calm.headline == "Undo Apply finished: 12 photos back in “Shoot”")
        #expect(!calm.isWarning)
        #expect(calm.lines == ["_Rejected: It holds other files now, so it was left in place."])
        let partial = ApplyText.undoReport(restored: 11, undoneSteps: 29, problems: [(.changed, "IMG_1.jpg")], kind: .apply, shootName: "Shoot")
        #expect(partial.isWarning)
        #expect(partial.headline == "Undo Apply put 11 photos back in “Shoot”")
        #expect(partial.lines[0].contains("nothing was overwritten"))
        #expect(partial.lines[1] == "IMG_1.jpg: It changed since the apply, so it was left alone.")
        #expect(UndoProblem.allCases.allSatisfy { !ApplyText.message($0).isEmpty })
    }

    @Test func rescanNote() {
        #expect(ApplyText.rescanNote(added: 1, removed: 0, renamed: 2, modified: 0) == "1 new photo · 2 photos renamed or moved outside Culla, decisions kept")
        #expect(ApplyText.rescanNote(added: 0, removed: 0, renamed: 0, modified: 0) == nil)
    }

    @Test func applyKeysDoNotClash() {
        let keys = KeyBindings.defaults
        #expect(keys.command(for: KeyChord(string: "shift+cmd+return")!) == .applyDecisions)
        #expect(keys.command(for: KeyChord(string: "opt+cmd+z")!) == .undoApply)
        #expect(keys.command(for: KeyChord(string: "opt+cmd+r")!) == .rescanFolder)
    }
}
