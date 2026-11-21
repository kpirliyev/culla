import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import Testing

/// Times are CPU time of the test's thread, so a busy machine does not fail the test (see
/// `Timing`). Operations that walk the whole shoot are compared with a baseline pass over All
/// Photos measured beside them; the one per-decision operation, which must stay cheap however
/// large the shoot, has an absolute CPU limit.
@Suite("SessionState speed")
struct SessionPerformanceTests {
    /// 20,000 photos with a spread of scores, every tenth one not analysed yet.
    private static func photos(count: Int) -> [PhotoItem] {
        (0..<count).map { index in
            let scores: PhotoScores? = index % 10 == 9 ? nil : Fixtures.scores(
                openness: index % 7 == 0 ? 0.1 : 0.4,
                sharpness: Double(index % 100),
                highlights: index % 50 == 0 ? 0.6 : 0,
                aesthetics: Double(index % 20) / 20,
                utility: index % 97 == 0
            )
            return Fixtures.item(String(format: "IMG_%05d.jpg", index), at: Double(index) * 2, scores: scores)
        }
    }

    @Test func commonOperationsOn20000Photos() {
        let count = 20_000
        let photos = Self.photos(count: count)
        var state = SessionState()
        var timings: [(String, Double)] = []
        var passes: [String: Double] = [:]
        // One pass over the shoot, the unit the costly operations are measured in.
        let pass = { _ = state.members(of: .allPhotos) }
        func measure(_ name: String, _ work: () -> Void) {
            timings.append((name, Timing.cpuSeconds(work)))
        }
        /// Measures work that changes the state once, beside the best of a few baseline passes.
        func measureInPasses(_ name: String, _ work: () -> Void) {
            let baseline = Timing.best(pass)
            let seconds = Timing.cpuSeconds(work)
            let after = Timing.best(pass)
            timings.append((name, seconds))
            passes[name] = seconds / min(baseline, after)
        }

        measure("create") { state = SessionState(photos: photos.shuffled()) }
        #expect(state.count == count)
        measureInPasses("stacks: 5,000 of 4") {
            state.setStacks(stride(from: 0, to: count, by: 4).map { start in
                PhotoStack(members: (start..<start + 4).map { state.photos[$0].id })
            })
        }

        // What the interface does on every decision: apply it, read every count, list the
        // current group and find the next photo.
        let id = state.photos[count / 2].id
        measure("one decision with every count, a group list and the next photo") {
            let change = state.apply(.setDecision(.rejected, ids: [id]))
            #expect(change.changedIDs == [id])
            for group in GroupID.allCases { _ = state.count(of: group) }
            _ = state.totals
            _ = state.members(of: .blurry)
            _ = state.nextAfterDecision(on: [id], in: .blurry)
        }
        measureInPasses("members of every group") {
            for group in GroupID.allCases { _ = state.members(of: group) }
        }
        let blurry = state.members(of: .blurry)
        measureInPasses("bulk reject of a group") { state.apply(.setDecision(.rejected, ids: blurry)) }
        measureInPasses("undo the bulk reject") { state.undo() }
        measureInPasses("redo the bulk reject") { state.redo() }
        measureInPasses("first undecided in every group") {
            for group in GroupID.allCases { _ = state.firstUndecided(in: group) }
        }
        measureInPasses("change a threshold") { state.tuning.blurryBelow = 40 }
        measure("scores arriving for 1,000 photos") {
            for index in 0..<1000 { state.setScores(Fixtures.scores(sharpness: 5), for: state.photos[index].id) }
        }

        for (name, seconds) in timings {
            let ratio = passes[name].map { String(format: " (%.1f passes)", $0) } ?? ""
            print(String(format: "  %@: %.2f ms CPU", name, seconds * 1000) + ratio)
        }
        let byName = Dictionary(uniqueKeysWithValues: timings)
        // A decision with everything the interface reads after it walks the shoot about once
        // (the group list); measured at about 4 ms CPU in a debug build on an M2. The limit is
        // what the interface can afford per key press, and still catches anything that redoes
        // the counts from scratch on every decision.
        #expect(byName["one decision with every count, a group list and the next photo"]! < 0.05)
        // In passes over All Photos. Measured on an M2 in a debug build: about 6 for every
        // group's members (ten groups), 5 for a bulk reject and 4 for its undo, and 14 to
        // change a threshold, which recomputes every summary. Each limit is several times that
        // and far below a per-photo pass over the shoot (20,000 passes).
        #expect(passes["members of every group"]! < 30)
        #expect(passes["bulk reject of a group"]! < 40)
        #expect(passes["undo the bulk reject"]! < 40)
        #expect(passes["redo the bulk reject"]! < 40)
        #expect(passes["first undecided in every group"]! < 30)
        #expect(passes["change a threshold"]! < 100)
        #expect(passes["stacks: 5,000 of 4"]! < 60)

        // The counts kept up to date along the way match a count from scratch.
        let fresh = SessionState(photos: state.photos, tuning: state.tuning)
        for group in GroupID.allCases where group != .similarStacks {
            #expect(fresh.count(of: group) == state.count(of: group))
        }
    }
}
