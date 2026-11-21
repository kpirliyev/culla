import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import Foundation
import Testing

/// Apply and undo on the file systems memory cards use. Builds a small disk image with
/// `hdiutil`, mounts it inside a temporary folder (never under /Volumes), runs the standard
/// shoot through every reject action and back, and ejects it.
///
/// Off by default, since it needs `hdiutil` and takes a few seconds: run with
/// `CULLA_CARD_FORMAT_TESTS=1 swift test --filter MemoryCardFormatTests`.
@Suite(
    "Apply on memory card file systems", .serialized, .timeLimit(.minutes(5)),
    .enabled(if: ProcessInfo.processInfo.environment["CULLA_CARD_FORMAT_TESTS"] == "1")
)
struct MemoryCardFormatTests {
    @Test(arguments: ["ExFAT", "MS-DOS FAT32"])
    func applyAndUndoOnACard(format: String) async throws {
        let scratch = try Scratch("CullaCard")
        let image = scratch.url.appendingPathComponent("card.dmg")
        let mount = scratch.url.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "64m", "-fs", format, "-volname", "CULLATEST", image.path])
        try run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noautoopen", "-mountpoint", mount.path, image.path])
        defer { try? run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }

        for action in RejectAction.allCases {
            let shootFolder = mount.appendingPathComponent("DCIM-\(action.rawValue)")
            try FileManager.default.createDirectory(at: shootFolder, withIntermediateDirectories: true)
            let (shoot, state) = try standardShoot(in: shootFolder)
            let original = Listing(shootFolder)
            let applier = try await applier(for: shootFolder)
            let plan = await ShootApplier.plan(for: state, folder: shootFolder, options: ApplyOptions(rejectAction: action))
            #expect(plan.canApply, "\(format) \(action)")
            let applied = try await applier.apply(plan, session: state)
            #expect(applied.result.state == .done, "\(format) \(action): \(applied.result.failure ?? "")")
            let undone = try await applier.undo(runID: applied.run.id)
            #expect(undone.report.state == .undone, "\(format) \(action): \(undone.report.skipped)")
            let restored = Listing(shootFolder)
            #expect(restored.files == original.files, "\(format) \(action): \(restored.difference(from: original))")
            removeTrashedFiles(of: applied.result.steps)
            _ = shoot
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments) exited \(process.terminationStatus)"])
        }
    }
}
