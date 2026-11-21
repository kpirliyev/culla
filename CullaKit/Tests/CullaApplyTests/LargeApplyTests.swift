import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Testing

@Suite("Apply at scale", .serialized, .timeLimit(.minutes(10)))
struct LargeApplyTests {
    /// 2,000 small files (1,000 RAW+JPEG pairs in ten folders), half of them rejected: plan,
    /// apply with the journal in a database file, undo, and compare every file.
    @Test func twoThousandFilesHalfRejected() async throws {
        let shoot = try ShootFixture()
        for index in 0..<1000 {
            let folder = "card\(index % 10)"
            try shoot.write(String(format: "%@/DSC_%04d.JPG", folder, index), bytes: 200)
            try shoot.write(String(format: "%@/DSC_%04d.ARW", folder, index), bytes: 400)
        }
        var decisions: [String: Decision] = [:]
        var ratings: [String: Int] = [:]
        for index in 0..<1000 {
            let id = String(format: "card%d/DSC_%04d.JPG", index % 10, index)
            if index % 2 == 0 { decisions[id] = .rejected } else if index % 3 == 0 { decisions[id] = .kept }
            if index % 7 == 0 { ratings[id] = index % 5 + 1 }
        }
        let state = try shoot.session(decisions: decisions, ratings: ratings)
        #expect(state.count == 1000)
        let original = shoot.listing
        #expect(original.files.count == 2000)

        let databaseFolder = try Scratch("CullaDatabase")
        let database = try await CullaDatabase.open(at: databaseFolder.url.appendingPathComponent("Culla.sqlite"))
        let session = try await database.openSession(folder: shoot.root)
        let applier = ShootApplier(database: database, sessionID: session.id)

        let clock = ContinuousClock()
        var start = clock.now
        let plan = await ShootApplier.plan(for: state, folder: shoot.root, options: ApplyOptions())
        let planTime = clock.now - start
        #expect(plan.summary.rejected == 500 && plan.summary.rejectedFiles == 1000)
        #expect(plan.summary.rejectedBytesAreExact)

        start = clock.now
        let applied = try await applier.apply(plan, session: state)
        let applyTime = clock.now - start
        #expect(applied.result.state == .done, "\(applied.result.failure ?? "")")
        #expect(applied.result.movedFiles == 1000)
        #expect(applied.result.removedPhotoIDs.count == 500)
        let afterApply = shoot.listing
        #expect(afterApply.files.keys.filter { $0.hasPrefix("_Rejected/") && !$0.hasSuffix(".xmp") }.count == 1000)
        #expect(try PhotoScanner.scan(folder: shoot.root).count == 500)

        start = clock.now
        let undone = try await applier.undo(runID: applied.run.id)
        let undoTime = clock.now - start
        #expect(undone.report.state == .undone && undone.report.skipped.isEmpty)
        #expect(undone.restoredPhotos.count == 500)

        start = clock.now
        let restored = shoot.listing
        let compareTime = clock.now - start
        #expect(restored == original, "\(restored.difference(from: original).prefix(10))")

        let steps = applied.result.steps.count
        print("""
              2,000 files, 500 of 1,000 photos rejected, \(steps) steps:
                plan (with disk facts): \(planTime)
                apply: \(applyTime)
                undo: \(undoTime)
                listing with SHA-256 of 2,000 files: \(compareTime)
              """)
    }
}
