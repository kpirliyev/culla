import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

private let shoot = URL(fileURLWithPath: "/shoot", isDirectory: true)

/// A photo at `id` inside /shoot, with companions named in the same folder.
private func photo(
    _ id: String, at seconds: Double, size: Int64 = 1000, companions: [String] = [],
    decision: Decision = .unreviewed, rating: Int = 0, scores: PhotoScores? = nil
) -> PhotoItem {
    let url = shoot.appendingPathComponent(id)
    let directory = url.deletingLastPathComponent()
    return PhotoItem(
        file: PhotoFile(
            id: id, url: url, companions: companions.map { directory.appendingPathComponent($0) },
            fileSize: size, modificationDate: Fixtures.start, isRAW: false
        ),
        metadata: PhotoMetadata(captureDate: Fixtures.start.addingTimeInterval(seconds)),
        decision: decision, rating: rating, scores: scores
    )
}

/// A shoot with one photo of each kind the plan treats differently.
private func sampleState() -> SessionState {
    var state = SessionState(photos: [
        photo("IMG_1.jpg", at: 1, size: 100, companions: ["IMG_1.CR3"], decision: .rejected),
        photo("IMG_2.jpg", at: 2, size: 200, decision: .kept, rating: 3),
        photo("IMG_3.jpg", at: 3, size: 300),
        photo("IMG_4.jpg", at: 4, size: 400, rating: 2),
        photo("day2/IMG_5.jpg", at: 5, size: 500, companions: ["IMG_5.NEF"], decision: .rejected, rating: 4,
              scores: Fixtures.scores(openness: 0.05, sharpness: 5)),
        photo("day2/deep/IMG_6.heic", at: 6, size: 600, decision: .rejected, scores: Fixtures.scores(highlights: 0.9)),
        photo("IMG_7.jpg", at: 7, size: 700, decision: .rejected),
        photo("IMG_8.jpg", at: 8, size: 800, decision: .rejected),
        photo("IMG_9.jpg", at: 9, size: 900, decision: .rejected),
        photo("IMG_10.jpg", at: 10, size: 1000, decision: .kept),
    ])
    state.markUnreadable("IMG_10.jpg", reason: "broken")
    state.markUnreadable("IMG_9.jpg", reason: "broken")
    state.setDuplicateSets([PhotoDuplicateSet(kind: .exact, members: ["IMG_7.jpg", "IMG_2.jpg"])])
    state.setStacks([PhotoStack(members: ["IMG_3.jpg", "IMG_7.jpg", "IMG_8.jpg"], bestPick: "IMG_3.jpg")])
    return state
}

private let facts = ShootFileFacts(
    sizes: [
        "IMG_1.jpg": 100, "IMG_1.CR3": 5000, "IMG_1.xmp": 7,
        "day2/IMG_5.jpg": 500, "day2/IMG_5.NEF": 9000,
    ],
    sidecars: ["IMG_1.jpg": ["IMG_1.xmp"]]
)

@Suite("Apply plan")
struct ApplyPlanTests {
    @Test func moveToRejectedFolderPlansEveryRejectWithItsFiles() {
        let plan = sampleState().applyPlan(folder: shoot, facts: facts)
        #expect(plan.canApply && plan.kind == .apply && plan.notes.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: plan.photos.map { ($0.id, $0) })
        // Pairs keep their companions; subfolders are part of the relative paths.
        #expect(byID["IMG_1.jpg"] == PlannedPhoto(
            id: "IMG_1.jpg", files: ["IMG_1.jpg", "IMG_1.CR3"], disposition: .moveToRejectedFolder,
            sidecar: SidecarMark(decision: .rejected, rating: 0), sidecarPath: "IMG_1.xmp"
        ))
        #expect(byID["day2/IMG_5.jpg"]?.files == ["day2/IMG_5.jpg", "day2/IMG_5.NEF"])
        #expect(byID["day2/IMG_5.jpg"]?.sidecar == SidecarMark(decision: .rejected, rating: 4))
        #expect(byID["day2/IMG_5.jpg"]?.sidecarPath == "day2/IMG_5.xmp")
        #expect(byID["day2/deep/IMG_6.heic"]?.sidecarPath == "day2/deep/IMG_6.xmp")
        // Kept and rated photos get sidecars and stay; an unreviewed unrated photo gets nothing.
        #expect(byID["IMG_2.jpg"]?.disposition == .stay)
        #expect(byID["IMG_2.jpg"]?.sidecar == SidecarMark(decision: .kept, rating: 3))
        #expect(byID["IMG_4.jpg"]?.sidecar == SidecarMark(decision: .unreviewed, rating: 2))
        #expect(byID["IMG_3.jpg"] == nil)
        // Unreadable photos are never moved and get no sidecar, whatever their decision.
        #expect(byID["IMG_9.jpg"] == nil && byID["IMG_10.jpg"] == nil)
        #expect(plan.leavingPhotoIDs == ["IMG_1.jpg", "day2/IMG_5.jpg", "day2/deep/IMG_6.heic", "IMG_7.jpg", "IMG_8.jpg"])
        // Capture order.
        #expect(plan.photos.map(\.id) == ["IMG_1.jpg", "IMG_2.jpg", "IMG_4.jpg", "day2/IMG_5.jpg", "day2/deep/IMG_6.heic", "IMG_7.jpg", "IMG_8.jpg"])
    }

    @Test func theSummaryCountsPhotosFilesAndBytes() {
        let summary = sampleState().applyPlan(folder: shoot, facts: facts).summary
        #expect(summary.kept == 1)
        #expect(summary.rejected == 5)
        #expect(summary.unreviewed == 2)
        #expect(summary.unreadable == 2)
        // IMG_1 jpg+CR3+xmp, IMG_5 jpg+NEF, IMG_6, IMG_7, IMG_8.
        #expect(summary.rejectedFiles == 8)
        #expect(summary.rejectedBytes == 100 + 5000 + 7 + 500 + 9000 + 600 + 700 + 800)
        #expect(summary.rejectedBytesAreExact)
        #expect(summary.sidecarsToWrite == 7)

        // Without facts the companions' sizes are unknown, which the summary says.
        let rough = sampleState().applyPlan(folder: shoot).summary
        #expect(rough.rejectedBytes == 100 + 500 + 600 + 700 + 800)
        #expect(!rough.rejectedBytesAreExact)
        #expect(rough.rejectedFiles == 7)
    }

    @Test func rejectsAreGroupedUnderTheirMostSevereReason() {
        let state = sampleState()
        let plan = state.applyPlan(folder: shoot, facts: facts)
        #expect(plan.rejectGroups == [
            RejectGroup(reason: .eyesClosed, photoIDs: ["day2/IMG_5.jpg"]),
            RejectGroup(reason: .clippedHighlights, photoIDs: ["day2/deep/IMG_6.heic"]),
            RejectGroup(reason: .duplicate, photoIDs: ["IMG_7.jpg"]),
            RejectGroup(reason: .similarStack, photoIDs: ["IMG_8.jpg"]),
            RejectGroup(reason: .noFlag, photoIDs: ["IMG_1.jpg"]),
        ])
        // Every reason of a photo, most severe first.
        #expect(state.rejectReasons(for: "day2/IMG_5.jpg") == [.eyesClosed, .blurry])
        #expect(state.rejectReasons(for: "IMG_7.jpg") == [.duplicate, .similarStack])
        #expect(state.rejectReason(for: "IMG_1.jpg") == .noFlag)
        #expect(RejectReason.allCases.sorted() == RejectReason.allCases)
        #expect(RejectReason.eyesClosed < .noFlag)
        #expect(RejectReason.duplicate.group == .duplicates)
        // Every rejected readable photo is in exactly one group.
        let grouped = plan.rejectGroups.flatMap(\.photoIDs)
        #expect(Set(grouped).count == grouped.count && grouped.count == plan.summary.rejected)
    }

    @Test func markOnlyLeavesFilesInPlaceAndMarksThem() {
        let plan = sampleState().applyPlan(folder: shoot, options: ApplyOptions(rejectAction: .markOnly), facts: facts)
        #expect(plan.photos.allSatisfy { $0.disposition == .stay })
        #expect(plan.leavingPhotoIDs.isEmpty)
        #expect(plan.photos.first { $0.id == "IMG_7.jpg" }?.sidecar == SidecarMark(decision: .rejected, rating: 0))
        #expect(plan.summary.sidecarsToWrite == 7)

        // Mark only without sidecars changes nothing, and says so.
        let nothing = sampleState().applyPlan(folder: shoot, options: ApplyOptions(rejectAction: .markOnly, writeSidecars: false))
        #expect(nothing.photos.isEmpty && nothing.isEmpty)
        #expect(nothing.notes == [.nothingToWrite])
    }

    @Test func trashMovesRejectsWithoutWritingTheirSidecars() {
        let plan = sampleState().applyPlan(folder: shoot, options: ApplyOptions(rejectAction: .moveToTrash), facts: facts)
        let rejects = plan.photos.filter { $0.disposition == .moveToTrash }
        #expect(rejects.map(\.id) == ["IMG_1.jpg", "day2/IMG_5.jpg", "day2/deep/IMG_6.heic", "IMG_7.jpg", "IMG_8.jpg"])
        #expect(rejects.allSatisfy { $0.sidecar == nil })
        #expect(plan.summary.sidecarsToWrite == 2)
    }

    @Test func sidecarsCanBeTurnedOff() {
        let plan = sampleState().applyPlan(folder: shoot, options: ApplyOptions(writeSidecars: false), facts: facts)
        #expect(plan.photos.allSatisfy { $0.sidecar == nil && $0.disposition == .moveToRejectedFolder })
        #expect(plan.summary.sidecarsToWrite == 0)
    }

    @Test func aReadOnlyShootCannotApplyAndOffersCopyKeepers() {
        for action in RejectAction.allCases {
            let plan = sampleState().applyPlan(folder: shoot, options: ApplyOptions(rejectAction: action), folderIsWritable: false, facts: facts)
            #expect(!plan.canApply)
            #expect(plan.blocker == .readOnlyFolder && plan.offersCopyKeepers)
            #expect(plan.photos.isEmpty)
            // The screen still shows what would have happened.
            #expect(plan.summary.rejected == 5 && plan.rejectGroups.count == 5)
        }
    }

    @Test func copyKeepersCopiesEverythingNotRejected() {
        let destination = URL(fileURLWithPath: "/Volumes/Backup/Keepers")
        let plan = sampleState().copyKeepersPlan(folder: shoot, destination: destination, facts: facts)
        #expect(plan.kind == .copyKeepers && plan.canApply && plan.destination == destination)
        // Kept, unreviewed and the unreadable photo that was not rejected.
        #expect(plan.photos.map(\.id) == ["IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg", "IMG_10.jpg"])
        #expect(plan.photos.allSatisfy { $0.disposition == .copy })
        #expect(plan.photos.map(\.sidecar) == [
            SidecarMark(decision: .kept, rating: 3), nil, SidecarMark(decision: .unreviewed, rating: 2), nil,
        ])
        #expect(plan.summary.filesToCopy == 4)
        #expect(plan.summary.bytesToCopy == 200 + 300 + 400 + 1000)

        let inside = sampleState().copyKeepersPlan(folder: shoot, destination: shoot.appendingPathComponent("keep"), facts: facts)
        #expect(inside.blocker == .destinationInsideShoot && inside.photos.isEmpty)
        #expect(sampleState().copyKeepersPlan(folder: shoot, destination: shoot).blocker == .destinationInsideShoot)
        let locked = sampleState().copyKeepersPlan(folder: shoot, destination: destination, destinationIsWritable: false)
        #expect(locked.blocker == .destinationNotWritable)
        // A sibling folder whose name starts like the shoot's is not inside it.
        #expect(sampleState().copyKeepersPlan(folder: shoot, destination: URL(fileURLWithPath: "/shoot-copy")).canApply)
    }

    @Test func aSidecarPathSharedByTwoPhotosIsLeftAlone() {
        let state = SessionState(photos: [
            photo("a.jpg", at: 1, decision: .rejected),
            photo("a.heic", at: 2, decision: .kept),
            photo("b.jpg", at: 3, decision: .kept),
        ])
        let plan = state.applyPlan(folder: shoot, facts: ShootFileFacts(sidecars: ["a.jpg": ["a.xmp"], "a.heic": ["a.xmp"]]))
        let a = plan.photos.first { $0.id == "a.jpg" }!
        #expect(a.disposition == .moveToRejectedFolder && a.sidecar == nil && a.sidecarIsShared)
        #expect(plan.photos.first { $0.id == "a.heic" } == nil)
        #expect(plan.photos.first { $0.id == "b.jpg" }?.sidecarIsShared == false)
        #expect(plan.notes == [.sharedSidecar(path: "a.xmp", photoIDs: ["a.jpg", "a.heic"])])
        #expect(plan.summary.rejectedFiles == 1)
    }

    @Test func anExistingSidecarKeepsItsSpelling() {
        let state = SessionState(photos: [photo("IMG_1.JPG", at: 1, decision: .kept)])
        let plan = state.applyPlan(folder: shoot, facts: ShootFileFacts(sidecars: ["IMG_1.JPG": ["IMG_1.XMP"]]))
        #expect(plan.photos.first?.sidecarPath == "IMG_1.XMP")
    }

    @Test func plansAreCodable() throws {
        let plan = sampleState().applyPlan(folder: shoot, facts: facts)
        let decoded = try JSONDecoder().decode(ApplyPlan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }
}

@Suite("Applied photos in the session")
struct AppliedPhotosSessionTests {
    @Test func removingAndRestoringBringsBackDecisionsRatingsAndScores() {
        var state = sampleState()
        state.apply(.setDecision(.kept, ids: ["IMG_3.jpg"]))
        #expect(state.canUndo)
        let before = state.photos.map(\.mark)
        let leaving = state.applyPlan(folder: shoot).leavingPhotoIDs
        let removed = state.removeAppliedPhotos(leaving)
        #expect(removed.map(\.id).sorted() == leaving.sorted())
        #expect(!state.canUndo && !state.canRedo)
        #expect(leaving.allSatisfy { !state.contains($0) })
        #expect(state.totals.rejected == 0)
        // They left the stack and the duplicate set with them.
        #expect(state.stacks.isEmpty && state.duplicateSets.isEmpty)

        let restored = state.restoreAppliedPhotos(removed)
        #expect(Set(restored) == Set(leaving))
        #expect(state.photos.map(\.mark) == before)
        #expect(state.photo("day2/IMG_5.jpg")?.scores != nil)
        #expect(state.photo("day2/IMG_5.jpg")?.rating == 4)
        #expect(state.photo("day2/IMG_5.jpg")?.isNew == false)
        #expect(state.isMember("day2/IMG_5.jpg", of: .eyesClosed))
        #expect(!state.canUndo)
    }

    @Test func restoringAPhotoARescanAlreadyFoundGivesItsDecisionBack() {
        var state = sampleState()
        let removed = state.removeAppliedPhotos(["IMG_7.jpg"])
        // The rescan after an undo sees the file again before the session is told.
        var scans = state.photos.map { ScannedPhoto(file: $0.file, metadata: $0.metadata) }
        scans.append(ScannedPhoto(file: removed[0].file, metadata: removed[0].metadata))
        let merge = state.merge(scanned: scans)
        #expect(merge.added == ["IMG_7.jpg"])
        #expect(state.photo("IMG_7.jpg")?.decision == .unreviewed)
        state.restoreAppliedPhotos(removed)
        #expect(state.photo("IMG_7.jpg")?.decision == .rejected)
        #expect(state.photo("IMG_7.jpg")?.isNew == false)
        #expect(state.count == 10)
    }

    @Test func journalCopiesHaveNoScores() throws {
        let item = sampleState().appliedPhotos(["day2/IMG_5.jpg"])[0]
        #expect(item.scores != nil && item.withoutScores.scores == nil)
        let decoded = try JSONDecoder().decode(AppliedPhoto.self, from: JSONEncoder().encode(item.withoutScores))
        #expect(decoded.id == "day2/IMG_5.jpg" && decoded.decision == .rejected && decoded.rating == 4)
        #expect(decoded.file.companions.map(\.lastPathComponent) == ["IMG_5.NEF"])
    }
}

@Suite("Renames found by a rescan")
struct RenameDetectionTests {
    private func state() -> SessionState {
        var state = SessionState(photos: [
            photo("a.jpg", at: 1, size: 111, decision: .rejected, rating: 2, scores: Fixtures.scores()),
            photo("b.jpg", at: 2, size: 222, decision: .kept, rating: 5),
            photo("c.jpg", at: 3, size: 333),
        ])
        state.setStacks([PhotoStack(members: ["a.jpg", "b.jpg"], bestPick: "a.jpg")])
        state.setStackEdits(StackEdits(bestPicks: ["a.jpg"]))
        return state
    }

    private func scanned(_ id: String, like item: PhotoItem, size: Int64? = nil, modified: Date? = nil, capture: Date?? = nil) -> ScannedPhoto {
        var file = item.file
        file.id = id
        file.url = shoot.appendingPathComponent(id)
        if let size { file.fileSize = size }
        if let modified { file.modificationDate = modified }
        var metadata = item.metadata
        if let capture { metadata.captureDate = capture }
        return ScannedPhoto(file: file, metadata: metadata)
    }

    @Test func aRenamedPhotoKeepsItsDecisionRatingAndScores() {
        var state = state()
        let a = state.photo("a.jpg")!
        let result = state.merge(scanned: [
            scanned("renamed.jpg", like: a),
            ScannedPhoto(file: state.photo("b.jpg")!.file, metadata: state.photo("b.jpg")!.metadata),
            ScannedPhoto(file: state.photo("c.jpg")!.file, metadata: state.photo("c.jpg")!.metadata),
        ])
        #expect(result.renamed == [PhotoRename(from: "a.jpg", to: "renamed.jpg", oldURL: a.file.url, newURL: shoot.appendingPathComponent("renamed.jpg"))])
        #expect(result.added.isEmpty && result.removed.isEmpty && result.modified.isEmpty)
        let moved = state.photo("renamed.jpg")!
        #expect(moved.decision == .rejected && moved.rating == 2 && moved.scores != nil && !moved.isNew)
        #expect(!state.contains("a.jpg"))
        // Stacks, hand-picked best picks and undo history follow the new id.
        #expect(state.stack(containing: "b.jpg")?.members == ["renamed.jpg", "b.jpg"])
        #expect(state.stackEdits.bestPicks == ["renamed.jpg"])
        #expect(state.stack(containing: "b.jpg")?.bestPick == "renamed.jpg")
    }

    @Test func undoAfterARenameReachesTheRenamedPhoto() {
        var state = state()
        state.apply(.setDecision(.kept, ids: ["a.jpg"]))
        let a = state.photo("a.jpg")!
        let others = ["b.jpg", "c.jpg"].map { ScannedPhoto(file: state.photo($0)!.file, metadata: state.photo($0)!.metadata) }
        state.merge(scanned: [scanned("sub/a.jpg", like: a)] + others)
        #expect(state.photo("sub/a.jpg")?.decision == .kept)
        state.undo()
        #expect(state.photo("sub/a.jpg")?.decision == .rejected)
    }

    @Test func aMoveToASubfolderIsFound() {
        var state = state()
        let c = state.photo("c.jpg")!
        let others = ["a.jpg", "b.jpg"].map { ScannedPhoto(file: state.photo($0)!.file, metadata: state.photo($0)!.metadata) }
        let result = state.merge(scanned: others + [scanned("day 2/c.jpg", like: c)])
        #expect(result.renamed.map(\.to) == ["day 2/c.jpg"])
        #expect(result.isEmpty == false)
    }

    @Test func ambiguousTwinsAreNotMatched() {
        // Two photos with the same size and date vanish and two new ones appear.
        var state = SessionState(photos: [
            photo("x1.jpg", at: 1, size: 500, decision: .kept),
            photo("x2.jpg", at: 1, size: 500, decision: .rejected),
        ])
        let x1 = state.photo("x1.jpg")!
        let x2 = state.photo("x2.jpg")!
        let result = state.merge(scanned: [scanned("y1.jpg", like: x1), scanned("y2.jpg", like: x2)])
        #expect(result.renamed.isEmpty)
        #expect(Set(result.removed) == ["x1.jpg", "x2.jpg"])
        #expect(result.added == ["y1.jpg", "y2.jpg"])
        #expect(state.photos.allSatisfy { $0.decision == .unreviewed && $0.isNew })

        // One gone photo, two new candidates: not matched either.
        var single = SessionState(photos: [photo("x1.jpg", at: 1, size: 500, decision: .kept)])
        let result2 = single.merge(scanned: [scanned("y1.jpg", like: x1), scanned("y2.jpg", like: x1)])
        #expect(result2.renamed.isEmpty && result2.removed == ["x1.jpg"])
    }

    @Test func twinsWithDifferentCaptureTimesAreToldApart() {
        var state = SessionState(photos: [
            photo("x1.jpg", at: 1, size: 500, decision: .kept),
            photo("x2.jpg", at: 2, size: 500, decision: .rejected),
        ])
        // Same size and modification date, different capture times.
        let x1 = state.photo("x1.jpg")!
        let x2 = state.photo("x2.jpg")!
        let result = state.merge(scanned: [scanned("y1.jpg", like: x1), scanned("y2.jpg", like: x2)])
        #expect(Set(result.renamed.map { "\($0.from)>\($0.to)" }) == ["x1.jpg>y1.jpg", "x2.jpg>y2.jpg"])
        #expect(state.photo("y2.jpg")?.decision == .rejected)
    }

    @Test func aChangedFileIsNotMatched() {
        let bigger = state()
        let a = bigger.photo("a.jpg")!
        let others = ["b.jpg", "c.jpg"].map { ScannedPhoto(file: bigger.photo($0)!.file, metadata: bigger.photo($0)!.metadata) }
        var resized = bigger
        let r1 = resized.merge(scanned: others + [scanned("renamed.jpg", like: a, size: 112)])
        #expect(r1.renamed.isEmpty && r1.removed == ["a.jpg"] && r1.added == ["renamed.jpg"])
        var touched = bigger
        let r2 = touched.merge(scanned: others + [scanned("renamed.jpg", like: a, modified: Fixtures.start.addingTimeInterval(1))])
        #expect(r2.renamed.isEmpty)
        var recaptured = bigger
        let r3 = recaptured.merge(scanned: others + [scanned("renamed.jpg", like: a, capture: .some(Fixtures.start.addingTimeInterval(99)))])
        #expect(r3.renamed.isEmpty)
        // A missing capture time on one side does not prevent a match.
        var noCapture = bigger
        let r4 = noCapture.merge(scanned: others + [scanned("renamed.jpg", like: a, capture: .some(nil))])
        #expect(r4.renamed.map(\.to) == ["renamed.jpg"])
    }
}
