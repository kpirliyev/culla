import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

@Suite("SessionState order and lookup")
struct SessionOrderTests {
    @Test func photosAreInCaptureOrderWithFallbackAndTies() {
        let state = SessionState(photos: [
            Fixtures.item("c.jpg", at: 30),
            Fixtures.item("b.jpg", at: 10),
            Fixtures.item("a.jpg", at: 10),
            // No capture date: ordered by its modification date, 20 s after the start.
            Fixtures.item("m.jpg", at: nil, modified: Fixtures.start.addingTimeInterval(20)),
        ])
        #expect(state.photos.map(\.id) == ["a.jpg", "b.jpg", "m.jpg", "c.jpg"])
        #expect(state.index(of: "m.jpg") == 2)
        #expect(state.photo("c.jpg")?.id == "c.jpg")
        #expect(state.photo("missing.jpg") == nil)
    }

    @Test func aRepeatedIdKeepsTheFirst() {
        let state = SessionState(photos: [
            Fixtures.item("a.jpg", at: 0, decision: .kept),
            Fixtures.item("a.jpg", at: 5, decision: .rejected),
        ])
        #expect(state.count == 1)
        #expect(state.photo("a.jpg")?.decision == .kept)
    }

    @Test func groupsHaveTitlesInSidebarOrder() {
        #expect(GroupID.allCases.map(\.title) == [
            "All Photos", "Duplicates", "Similar Stacks", "Eyes Closed", "Blurry", "Exposure",
            "Other Issues", "Unreviewed", "Kept", "Rejected",
        ])
    }
}

@Suite("SessionState groups")
struct SessionGroupTests {
    /// One photo per kind of defect, plus a clean one.
    private func state(tuning: Tuning = Tuning()) -> SessionState {
        SessionState(photos: [
            Fixtures.item("clean", at: 0, scores: Fixtures.scores()),
            Fixtures.item("eyes", at: 1, scores: Fixtures.scores(openness: 0.1)),
            Fixtures.item("soft", at: 2, scores: Fixtures.scores(sharpness: 20)),
            Fixtures.item("bright", at: 3, scores: Fixtures.scores(highlights: 0.5)),
            Fixtures.item("dark", at: 4, scores: Fixtures.scores(shadows: 0.7)),
            Fixtures.item("dull", at: 5, scores: Fixtures.scores(aesthetics: 0.1)),
            Fixtures.item("screenshot", at: 6, scores: Fixtures.scores(utility: true)),
            Fixtures.item("smudge", at: 7, scores: Fixtures.scores(smudge: 0.9)),
            Fixtures.item("cut", at: 8, scores: Fixtures.scores(openness: 0.4, faceCut: true)),
            Fixtures.item("tilted", at: 9, scores: Fixtures.scores(horizon: 8)),
            Fixtures.item("pending", at: 10),
        ], tuning: tuning)
    }

    @Test func defectGroupsFollowTheFlags() {
        let state = state()
        #expect(state.members(of: .eyesClosed) == ["eyes"])
        #expect(state.members(of: .blurry) == ["soft"])
        #expect(state.members(of: .exposure) == ["bright", "dark"])
        // The horizon flag is off by default.
        #expect(state.members(of: .otherIssues) == ["dull", "screenshot", "smudge", "cut"])
        #expect(state.members(of: .allPhotos).count == 11)
        #expect(state.members(of: .unreviewed).count == 11)
        #expect(state.members(of: .kept).isEmpty)
    }

    @Test func aPhotoCanBeInSeveralGroups() {
        var state = SessionState(photos: [
            Fixtures.item("both", at: 0, scores: Fixtures.scores(openness: 0.1, sharpness: 10)),
        ])
        #expect(state.groups(of: "both") == [.allPhotos, .eyesClosed, .blurry, .unreviewed])
        state.apply(.setDecision(.rejected, ids: ["both"]))
        #expect(state.groups(of: "both") == [.allPhotos, .eyesClosed, .blurry, .rejected])
        #expect(state.count(of: .eyesClosed) == GroupCount(left: 0, total: 1))
        #expect(state.count(of: .blurry) == GroupCount(left: 0, total: 1))
    }

    @Test func countsAreLeftToReviewAndTotal() {
        var state = state()
        #expect(state.count(of: .allPhotos) == GroupCount(left: 11, total: 11))
        #expect(state.count(of: .exposure) == GroupCount(left: 2, total: 2))
        state.apply(.setDecision(.kept, ids: ["bright"]))
        #expect(state.count(of: .exposure) == GroupCount(left: 1, total: 2))
        #expect(state.count(of: .kept) == GroupCount(left: 0, total: 1))
        #expect(state.count(of: .unreviewed) == GroupCount(left: 10, total: 10))
        #expect(state.count(of: .allPhotos) == GroupCount(left: 10, total: 11))
        #expect(state.totals == SessionTotals(photos: 11, kept: 1, rejected: 0, left: 10, unreadable: 0))
    }

    @Test func changingTuningRegroupsAndNeverChangesADecision() {
        var state = state()
        state.apply(.setDecision(.rejected, ids: ["soft"]))
        state.apply(.setDecision(.kept, ids: ["clean"]))
        let decisions = state.photos.map(\.decision)

        var tuning = state.tuning
        tuning.blurryBelow = 95
        tuning.flagTiltedHorizon = true
        tuning.flagExposure = false
        state.tuning = tuning

        #expect(state.photos.map(\.decision) == decisions)
        #expect(state.members(of: .blurry) == ["clean", "eyes", "soft", "bright", "dark", "dull", "screenshot", "smudge", "cut", "tilted"])
        #expect(state.count(of: .blurry) == GroupCount(left: 8, total: 10))
        #expect(state.members(of: .exposure).isEmpty)
        #expect(state.isMember("tilted", of: .otherIssues))
    }

    @Test func switchingAFlagOffEmptiesItsShareOfTheGroup() {
        var tuning = Tuning()
        tuning.flagUtility = false
        tuning.flagLowAesthetics = false
        tuning.flagLensSmudge = false
        tuning.flagCutOffFaces = false
        #expect(state(tuning: tuning).members(of: .otherIssues).isEmpty)
    }

    @Test func badgesCarryTiers() {
        var tuning = Tuning()
        tuning.flagTiltedHorizon = true
        let state = SessionState(photos: [
            Fixtures.item("certain", at: 0, scores: Fixtures.scores(openness: 0.1, sharpness: 10)),
            Fixtures.item("likely", at: 1, scores: Fixtures.scores(openness: 0.22, sharpness: 20, horizon: -5)),
        ], tuning: tuning)
        #expect(state.badges(for: "certain")?.flags == [
            FlagBadge(flag: .eyesClosed, tier: .certain), FlagBadge(flag: .blurry, tier: .certain),
        ])
        #expect(state.badges(for: "likely")?.flags == [
            FlagBadge(flag: .eyesClosed, tier: .likely), FlagBadge(flag: .blurry, tier: .likely),
            FlagBadge(flag: .tiltedHorizon, tier: .likely),
        ])
        #expect(state.summary(for: "certain")?.tier(of: .blurry) == .certain)
        #expect(state.undecidedCertainMembers(of: .eyesClosed) == ["certain"])
        #expect(state.undecidedCertainMembers(of: .otherIssues).isEmpty)
        #expect(state.undecidedCertainMembers(of: .allPhotos).isEmpty)
    }

    @Test func photosWithoutScoresAreOnlyInDecisionGroups() {
        let state = state()
        #expect(state.groups(of: "pending") == [.allPhotos, .unreviewed])
        #expect(state.summary(for: "pending") == nil)
    }

    @Test func scoresArrivingMovePhotosIntoGroups() {
        var state = state()
        let stored = state.setScores(Fixtures.scores(sharpness: 5), for: "pending")
        #expect(stored)
        #expect(state.isMember("pending", of: .blurry))
        #expect(state.count(of: .blurry) == GroupCount(left: 2, total: 2))
        state.setScores(["pending": Fixtures.scores()])
        #expect(!state.isMember("pending", of: .blurry))
        let missing = state.setScores(nil, for: "missing")
        #expect(!missing)
    }

    @Test func unreadablePhotosAreOnlyInAllPhotos() {
        var state = state()
        state.markUnreadable("soft", reason: "Cannot decode")
        #expect(state.groups(of: "soft") == [.allPhotos])
        #expect(state.photo("soft")?.isUnreadable == true)
        #expect(state.badges(for: "soft")?.isUnreadable == true)
        #expect(state.count(of: .allPhotos) == GroupCount(left: 10, total: 11))
        #expect(state.count(of: .unreviewed).total == 10)
        #expect(state.totals.unreadable == 1)
        #expect(state.totals.left == 10)
        // Scores arriving later make it readable again.
        state.setScores(Fixtures.scores(sharpness: 20), for: "soft")
        #expect(state.totals.unreadable == 0)
        #expect(state.isMember("soft", of: .blurry))
    }
}

@Suite("SessionState decisions and undo")
struct SessionUndoTests {
    private func state() -> SessionState {
        SessionState(photos: (0..<6).map { Fixtures.item("p\($0)", at: Double($0)) })
    }

    @Test func applyReportsOnlyChangedPhotosInCaptureOrder() {
        var state = state()
        let change = state.apply(.setDecision(.kept, ids: ["p3", "p1", "missing"]))
        #expect(change.changedIDs == ["p1", "p3"])
        let again = state.apply(.setDecision(.kept, ids: ["p1", "p2"]))
        #expect(again.changedIDs == ["p2"])
    }

    @Test func aChangeThatChangesNothingRecordsNoStep() {
        var state = state()
        #expect(state.apply(.setDecision(.unreviewed, ids: ["p1"])).isEmpty)
        #expect(!state.canUndo)
    }

    @Test func undoAndRedoRestoreExactly() {
        var state = state()
        state.apply(.setRating(3, ids: ["p1", "p2"]))
        state.apply(.setDecision(.rejected, ids: ["p1", "p2", "p3"]))
        state.apply(.setDecision(.kept, ids: ["p2"]))
        let afterAll = state.photos.map(\.mark)

        var result = state.undo()
        #expect(result?.changedIDs == ["p2"])
        #expect(state.photo("p2")?.decision == .rejected)
        #expect(state.undoAction == .setDecision(.rejected, ids: ["p1", "p2", "p3"]))
        result = state.undo()
        #expect(result?.changedIDs == ["p1", "p2", "p3"])
        #expect(state.photos.allSatisfy { $0.decision == .unreviewed })
        #expect(state.photo("p1")?.rating == 3)
        result = state.undo()
        #expect(result?.changedIDs == ["p1", "p2"])
        #expect(state.photos.allSatisfy { $0.rating == 0 })
        result = state.undo()
        #expect(result == nil)
        #expect(state.count(of: .unreviewed).total == 6)

        state.redo()
        state.redo()
        state.redo()
        result = state.redo()
        #expect(result == nil)
        #expect(state.photos.map(\.mark) == afterAll)
        #expect(state.count(of: .rejected).total == 2)
        #expect(state.count(of: .kept).total == 1)
    }

    @Test func aBulkChangeIsOneStep() {
        var state = state()
        state.apply(.setDecisions(["p0": .kept, "p1": .rejected, "p2": .rejected]))
        #expect(state.totals.kept == 1 && state.totals.rejected == 2)
        state.undo()
        #expect(state.totals.left == 6)
        #expect(!state.canUndo && state.canRedo)
    }

    @Test func aNewChangeClearsRedo() {
        var state = state()
        state.apply(.setDecision(.kept, ids: ["p0"]))
        state.undo()
        state.apply(.setDecision(.rejected, ids: ["p1"]))
        #expect(!state.canRedo)
    }

    @Test func ratingsAreClamped() {
        var state = state()
        state.apply(.setRating(9, ids: ["p0"]))
        state.apply(.setRating(-2, ids: ["p1"]))
        #expect(state.photo("p0")?.rating == 5)
        #expect(state.photo("p1")?.rating == 0)
    }

    @Test func marksForSaving() {
        var state = state()
        state.apply(.setDecision(.kept, ids: ["p4"]))
        #expect(state.marks(for: ["p4", "nope"]) == [PhotoMark(id: "p4", decision: .kept, rating: 0)])
    }
}

@Suite("SessionState navigation")
struct SessionNavigationTests {
    /// p0...p9, with the odd ones blurry.
    private func state() -> SessionState {
        SessionState(photos: (0..<10).map { index in
            Fixtures.item("p\(index)", at: Double(index), scores: Fixtures.scores(sharpness: index % 2 == 1 ? 10 : 90))
        })
    }

    @Test func nextAndPreviousInAGroup() {
        let state = state()
        #expect(state.next(after: "p1", in: .blurry) == "p3")
        // The photo need not be a member itself.
        #expect(state.next(after: "p4", in: .blurry) == "p5")
        #expect(state.previous(before: "p4", in: .blurry) == "p3")
        #expect(state.next(after: "p9", in: .blurry) == nil)
        #expect(state.previous(before: "p1", in: .blurry) == nil)
        #expect(state.first(in: .blurry) == "p1")
        #expect(state.next(after: "missing", in: .blurry) == nil)
    }

    @Test func undecidedOnlySkipsDecidedPhotos() {
        var state = state()
        state.apply(.setDecision(.kept, ids: ["p3", "p1"]))
        #expect(state.next(after: "p1", in: .blurry, undecidedOnly: true) == "p5")
        #expect(state.firstUndecided(in: .blurry) == "p5")
        #expect(state.firstUndecided(in: .unreviewed) == "p0")
    }

    @Test func nextAfterADecisionIsTheSameBeforeAndAfterIt() {
        var state = state()
        let before = state.nextAfterDecision(on: ["p3"], in: .unreviewed)
        state.apply(.setDecision(.rejected, ids: ["p3"]))
        // p3 has left Unreviewed, and the next photo is still the one that followed it.
        let after = state.nextAfterDecision(on: ["p3"], in: .unreviewed)
        #expect(before == "p4")
        #expect(after == "p4")
        #expect(state.next(after: "p3", in: .unreviewed) == "p4")
    }

    @Test func nextAfterADecisionAtTheEndFallsBack() {
        var state = state()
        state.apply(.setDecision(.rejected, ids: ["p9"]))
        #expect(state.nextAfterDecision(on: ["p9"], in: .blurry) == "p7")
        #expect(state.nextAfterDecision(on: ["p1", "p3", "p5", "p7", "p9"], in: .blurry) == nil)
        // A bulk decision continues after its last photo.
        #expect(state.nextAfterDecision(on: ["p1", "p5"], in: .blurry) == "p7")
    }
}

@Suite("SessionState stacks and duplicates")
struct SessionStackTests {
    @Test func setStacksCleansUpItsInput() {
        var state = SessionState(photos: (0..<6).map { Fixtures.item("p\($0)", at: Double($0)) })
        state.setStacks([
            PhotoStack(members: ["p2", "p1", "ghost"], bestPick: "p2"),
            PhotoStack(members: ["p2", "p3", "p4"], bestPick: "p1"),
            PhotoStack(members: ["p5"]),
        ])
        #expect(state.stacks == [
            PhotoStack(members: ["p1", "p2"], bestPick: "p2"),
            PhotoStack(members: ["p3", "p4"], bestPick: nil),
        ])
        #expect(state.members(of: .similarStacks) == ["p1", "p2", "p3", "p4"])
        #expect(state.stack(containing: "p4")?.id == "p3")
        #expect(state.badges(for: "p2")?.isBestPick == true)
        #expect(state.badges(for: "p1")?.isBestPick == false)
        #expect(state.badges(for: "p1")?.stackID == "p1")

        let result = state.setBestPick("p4", ofStackContaining: "p3")
        #expect(result)
        #expect(state.stack(containing: "p3")?.bestPick == "p4")
        let notAMember = state.setBestPick("p1", ofStackContaining: "p3")
        let notStacked = state.setBestPick("p0", ofStackContaining: "p0")
        #expect(!notAMember && !notStacked)
    }

    @Test func duplicateSetsMakeTheDuplicatesGroup() {
        var state = SessionState(photos: (0..<4).map { Fixtures.item("p\($0)", at: Double($0)) })
        state.setDuplicateSets([PhotoDuplicateSet(kind: .exact, members: ["p3", "p0"])])
        #expect(state.members(of: .duplicates) == ["p0", "p3"])
        #expect(state.duplicateSet(containing: "p3")?.kind == .exact)
        #expect(state.badges(for: "p0")?.duplicateSetID == "p0")
        #expect(state.count(of: .duplicates) == GroupCount(left: 2, total: 2))
    }

    @Test func regroupUsesTheStackGrouperAndDuplicateFinder() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        var state = SessionState(photos: [
            // A burst of three similar frames, then a different photo a minute later.
            Fixtures.item("burst1", at: 0, scores: Fixtures.scores(feature: a)),
            Fixtures.item("burst2", at: 0.3, scores: Fixtures.scores(feature: a)),
            Fixtures.item("burst3", at: 0.6, scores: Fixtures.scores(feature: a)),
            Fixtures.item("other", at: 60, scores: Fixtures.scores(feature: b)),
            // The same file twice: same size and, per the hash below, the same bytes.
            Fixtures.item("copy1", at: 120, scores: Fixtures.scores(feature: b)),
            Fixtures.item("copy2", at: 500, scores: Fixtures.scores(feature: a)),
        ])
        state.setStacks([PhotoStack(members: ["burst1", "burst2"], bestPick: "burst2")])
        var hashed: [String] = []
        state.regroup { item in
            hashed.append(item.id)
            return item.id.hasPrefix("copy") ? "same" : item.id
        }
        #expect(state.stacks == [PhotoStack(members: ["burst1", "burst2", "burst3"], bestPick: "burst2")])
        #expect(state.duplicateSets == [PhotoDuplicateSet(kind: .exact, members: ["copy1", "copy2"])])
        // Every fixture has the same size, so every file is hashed.
        #expect(hashed.count == 6)
    }
}

@Suite("SessionState merge")
struct SessionMergeTests {
    @Test func mergeKeepsDecisionsMarksNewAndDropsGone() {
        var state = SessionState(photos: [
            Fixtures.item("stay", at: 0, scores: Fixtures.scores(sharpness: 10)),
            Fixtures.item("edited", at: 1, scores: Fixtures.scores(sharpness: 10)),
            Fixtures.item("gone", at: 2, scores: Fixtures.scores(sharpness: 10)),
        ])
        state.apply(.setDecisions(["stay": .kept, "edited": .rejected, "gone": .rejected]))
        state.apply(.setRating(4, ids: ["stay", "edited"]))
        state.setStacks([PhotoStack(members: ["stay", "gone"]), PhotoStack(members: ["stay", "edited"])])

        let result = state.merge(scanned: [
            Fixtures.scanned("new", at: 0.5),
            Fixtures.scanned("stay", at: 0),
            Fixtures.scanned("edited", at: 1, size: 2000),
        ])
        #expect(result == MergeResult(added: ["new"], removed: ["gone"], modified: ["edited"]))
        #expect(state.photos.map(\.id) == ["stay", "new", "edited"])
        #expect(state.photo("stay")?.decision == .kept)
        #expect(state.photo("stay")?.rating == 4)
        #expect(state.photo("stay")?.scores != nil)
        #expect(state.photo("edited")?.decision == .rejected)
        #expect(state.photo("edited")?.rating == 4)
        #expect(state.photo("edited")?.scores == nil)
        #expect(state.photo("new")?.isNew == true)
        #expect(state.photo("stay")?.isNew == false)
        #expect(state.photo("gone") == nil)
        // The stack that lost a member has too few left.
        #expect(state.stacks.isEmpty)
        #expect(state.members(of: .blurry) == ["stay"])
        #expect(state.totals == SessionTotals(photos: 3, kept: 1, rejected: 1, left: 1, unreadable: 0))
    }

    @Test func undoAfterMergeSkipsPhotosThatAreGone() {
        var state = SessionState(photos: [Fixtures.item("a", at: 0), Fixtures.item("b", at: 1)])
        state.apply(.setDecision(.rejected, ids: ["a", "b"]))
        state.merge(scanned: [Fixtures.scanned("a", at: 0)])
        let result = state.undo()
        #expect(result?.changedIDs == ["a"])
        #expect(state.photo("a")?.decision == .unreviewed)
    }

    @Test func aNewSessionFromAScanHasNothingNew() {
        let state = SessionState(scanned: [Fixtures.scanned("a", at: 0), Fixtures.scanned("b", at: 1)])
        #expect(state.photos.allSatisfy { !$0.isNew && $0.decision == .unreviewed })
    }
}
