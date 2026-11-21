import CullaCore
import Foundation

/// Why a plan could not be started. Nothing on disk was changed.
public enum ApplyPrepareError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// The plan is blocked (`ApplyPlan.blocker`).
    case blocked(ApplyBlocker)
    /// A file of the plan is not there any more; rescan and plan again.
    case missingFile(String)
    /// A file of the plan is a folder or a link, which Culla does not move.
    case notAFile(String)

    public var description: String {
        switch self {
        case .blocked(let blocker): "The plan cannot be applied (\(blocker.rawValue))"
        case .missingFile(let path): "\(path) is missing"
        case .notAFile(let path): "\(path) is not a regular file"
        }
    }

    /// In the person's language, for the interface. `description` stays English: it is what the
    /// journal records as the run's failure.
    public var errorDescription: String? {
        switch self {
        case .blocked: localized("The plan cannot be applied.")
        case .missingFile(let path): localized("\(path) is missing")
        case .notAFile(let path): localized("\(path) is not a regular file")
        }
    }
}

/// What a run did.
public struct ApplyRunResult: Sendable {
    /// `.done`, `.failed` or `.cancelled`.
    public var state: ApplyRunState
    /// Every step with its final state.
    public var steps: [ApplyStep]
    /// What stopped the run, for the report.
    public var failure: String?
    /// The step that failed.
    public var failedStepIndex: Int?
    /// Photos with at least one file moved out of the shoot (to `_Rejected` or the Trash): take
    /// them out of the session with `SessionState.removeAppliedPhotos(_:)`.
    public var removedPhotoIDs: [String]
    /// Of those, photos with some files still in place, because the run stopped part-way
    /// through them. Undo puts them back together.
    public var incompletePhotoIDs: [String]
    /// Sidecars left alone because they could not be parsed or changed meanwhile, with the reason
    /// in `note`.
    public var skippedSidecars: [ApplyStep]
    public var movedFiles: Int
    public var trashedFiles: Int
    public var copiedFiles: Int
    public var sidecarsWritten: Int

    /// True when there is anything for undo to take back.
    public var changedAnything: Bool {
        steps.contains { $0.state == .done || $0.state == .started }
    }
}

/// Why undo left a step as it was.
public enum UndoSkipReason: String, Codable, Sendable, Hashable {
    /// The file is no longer where the apply put it: deleted, moved, `_Rejected` or the Trash
    /// emptied.
    case missing
    /// The file is there but its size or modification date changed, so it may not be the file
    /// the apply moved, or a sidecar holds something other than what Culla wrote.
    case changed
    /// Something now exists at the original path. Undo never replaces it.
    case originalPathOccupied
    /// The file went to the Trash but where in the Trash was not recorded (a crash right after
    /// trashing it).
    case trashLocationUnknown
    /// A folder the apply created holds other files now; it is left in place.
    case folderNotEmpty
    /// A file system call failed.
    case failed

    /// In English: it is recorded in the journal as the step's note. The interface shows
    /// `ApplyText.message(_:)` (CullaCommands) instead, in the person's language.
    public var message: String {
        switch self {
        case .missing: "It is no longer where the apply put it."
        case .changed: "It changed since the apply."
        case .originalPathOccupied: "Another file is now at its original place."
        case .trashLocationUnknown: "It is in the Trash, but where was not recorded."
        case .folderNotEmpty: "The folder is not empty, so it was left in place."
        case .failed: "The file could not be moved back."
        }
    }
}

/// One thing undo could not take back.
public struct UndoSkip: Sendable, Hashable {
    public var stepIndex: Int
    public var photoID: String
    /// The path the apply left the file at, or the folder.
    public var path: String
    public var reason: UndoSkipReason
    public var detail: String?
}

/// What an undo did.
public struct UndoReport: Sendable {
    /// `.undone`, or `.partlyUndone` when something could not be taken back. A folder left in
    /// place because it holds other files does not make an undo partial.
    public var state: ApplyRunState
    public var steps: [ApplyStep]
    /// What was left as it was, and why. Nothing is ever overwritten.
    public var skipped: [UndoSkip]
    /// Photos whose shown file is back at its original path: bring them back into the session
    /// with `SessionState.restoreAppliedPhotos(_:)`.
    public var restoredPhotoIDs: [String]
    /// Files moved back, sidecars restored, copies and folders removed.
    public var undoneSteps: Int
}

/// Carries out an `ApplyPlan` step by step, journalled so it can be undone, and undoes it.
///
/// ## Applying
///
/// 1. **Prepare** (reads only): every file of the plan must still be there, or nothing is done
///    (`ApplyPrepareError`). Existing sidecars are found beside each photo (`<basename>.xmp`,
///    and `<file name>.xmp` as darktable writes them). Destination names are chosen: a photo's
///    files keep their names unless any of them is taken in the destination folder, in which
///    case all of them get the same suffix, `IMG_1 2.jpg`, `IMG_1 2.CR3`, `IMG_1 2.xmp` (then
///    3, 4, ...), so the pair and its sidecar still go together. Folders to create are listed one
///    by one. All steps go to the journal as pending.
/// 2. **Execute**, one step at a time: the step is recorded as started (for a sidecar, with the
///    bytes it holds now and the bytes it will hold), then carried out, then recorded as done.
///    Moves are `renamex_np` with `RENAME_EXCL` and copies are renamed into place the same way,
///    so nothing is ever overwritten, even if a file appears after the names were chosen.
///    A sidecar that cannot be parsed is left alone and the step is marked skipped; the run goes
///    on. Any other failure stops the run, and so does cancellation between steps.
///
/// Rejects moved to `_Rejected` get their sidecar there, after their files have moved. Rejects
/// moved to the Trash get none.
///
/// ## Undoing
///
/// Done steps (and steps recorded as started, after a crash) are taken back newest first: files
/// are moved back only when they are still the file the apply moved (same size and modification
/// time to the nanosecond) and nothing is at the original path; sidecars are restored to their
/// previous bytes and modification time, or removed if there was none, only while they still
/// hold what Culla wrote; copies are removed only while unchanged; folders the run created are
/// removed if they are empty (a lone `.DS_Store` counts as empty). Anything else is skipped,
/// reported and left done, so a later undo can try again. Undo can be run any number of times.
///
/// File work runs on a serial `BlockingQueue`, never on Swift's cooperative pool.
public struct ApplyExecutor: Sendable {
    /// Called with each step just before it is carried out, after it was journalled as started.
    /// Throw to make the step fail. For tests.
    public typealias FaultInjector = @Sendable (ApplyStep) throws -> Void

    private let journal: any ApplyJournal
    private let faultInjector: FaultInjector?
    private let queue = BlockingQueue(label: "Culla.apply", concurrent: false)

    public init(journal: any ApplyJournal, faultInjector: FaultInjector? = nil) {
        self.journal = journal
        self.faultInjector = faultInjector
    }

    // MARK: - Preparing

    /// The steps that carrying out `plan` would take, with destination names chosen. Reads the
    /// disk; changes nothing.
    public func steps(for plan: ApplyPlan) async throws -> [ApplyStep] {
        try await queue.run { try Self.makeSteps(for: plan) }
    }

    static func makeSteps(for plan: ApplyPlan) throws -> [ApplyStep] {
        if let blocker = plan.blocker { throw ApplyPrepareError.blocked(blocker) }
        let root = plan.folder.standardizedFileURL.path
        let destinationRoot = plan.destination?.standardizedFileURL.path
        var steps: [ApplyStep] = []
        var plannedFolders = Set<String>()
        var reserved = Set<String>()
        var listings: [String: [String]] = [:]

        func add(_ photoID: String, _ role: ApplyFileRole, _ action: ApplyStepAction) {
            steps.append(ApplyStep(index: steps.count, photoID: photoID, role: role, action: action))
        }
        func listing(_ directory: String) -> [String] {
            if let cached = listings[directory] { return cached }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            listings[directory] = names
            return names
        }
        /// Adds a step for every folder from `base` (which must exist) down to `directory` that
        /// is not there yet.
        func ensureFolders(_ directory: String, under base: String) {
            var missing: [String] = []
            var current = directory
            while current.count > base.count, !FileOps.exists(current), !plannedFolders.contains(current) {
                missing.append(current)
                current = (current as NSString).deletingLastPathComponent
            }
            for folder in missing.reversed() {
                plannedFolders.insert(folder)
                add("", .folder, .createFolder(path: folder))
            }
        }

        for photo in plan.photos {
            let relativeDirectory = (photo.id as NSString).deletingLastPathComponent
            let sourceDirectory = join(root, relativeDirectory)
            // The photo's files, then the sidecars already beside them.
            var files: [(name: String, role: ApplyFileRole)] = []
            for (number, relative) in photo.files.enumerated() {
                let path = join(root, relative)
                guard let _ = FileOps.stamp(path) else { throw ApplyPrepareError.missingFile(path) }
                guard !FileOps.isDirectory(path), (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else {
                    throw ApplyPrepareError.notAFile(path)
                }
                files.append(((relative as NSString).lastPathComponent, number == 0 ? .photo : .companion))
            }
            let existingSidecars = SidecarFinder.sidecars(
                forFiles: files.map(\.name), in: listing(sourceDirectory), includeBaseSidecar: !photo.sidecarIsShared
            )
            let base = (files[0].name as NSString).deletingPathExtension
            let sidecarName = (photo.sidecarPath as NSString).lastPathComponent
            let baseSidecar = existingSidecars.first { $0.lowercased() == (base + ".xmp").lowercased() }

            switch photo.disposition {
            case .stay:
                if let mark = photo.sidecar {
                    let name = baseSidecar ?? sidecarName
                    add(photo.id, .sidecar, .writeSidecar(path: join(sourceDirectory, name), mark: mark, previous: nil, written: nil, tempPath: nil))
                }

            case .moveToTrash:
                for (name, role) in files + existingSidecars.map({ ($0, ApplyFileRole.existingSidecar) }) {
                    let path = join(sourceDirectory, name)
                    add(photo.id, role, .trash(path: path, stamp: FileOps.stamp(path)!, trashedPath: nil))
                }

            case .moveToRejectedFolder, .copy:
                let isCopy = photo.disposition == .copy
                let destinationBase = isCopy ? destinationRoot! : join(root, ApplyOptions.rejectedFolderName)
                let destinationDirectory = join(destinationBase, relativeDirectory)
                if !isCopy { ensureFolders(destinationBase, under: root) }
                ensureFolders(destinationDirectory, under: destinationBase)
                let moving = files + existingSidecars.map { ($0, ApplyFileRole.existingSidecar) }
                var names = moving.map(\.name)
                let writesNewSidecar = photo.sidecar != nil && baseSidecar == nil
                if writesNewSidecar { names.append(base + ".xmp") }
                let suffix = freeSuffix(for: names, base: base, in: destinationDirectory, reserved: reserved)
                for name in names { reserved.insert(join(destinationDirectory, renamed(name, base: base, suffix: suffix)).lowercased()) }
                for (name, role) in moving {
                    let from = join(sourceDirectory, name)
                    let to = join(destinationDirectory, renamed(name, base: base, suffix: suffix))
                    if isCopy {
                        add(photo.id, role, .copy(from: from, to: to, tempPath: FileOps.temporaryPath(beside: to), stamp: nil))
                    } else {
                        add(photo.id, role, .move(from: from, to: to, stamp: FileOps.stamp(from)!))
                    }
                }
                if let mark = photo.sidecar {
                    let name = renamed(baseSidecar ?? base + ".xmp", base: base, suffix: suffix)
                    add(photo.id, .sidecar, .writeSidecar(path: join(destinationDirectory, name), mark: mark, previous: nil, written: nil, tempPath: nil))
                }
            }
        }
        return steps
    }

    /// The smallest suffix (1 meaning none) under which none of `names` is taken in `directory`.
    static func freeSuffix(for names: [String], base: String, in directory: String, reserved: Set<String>) -> Int {
        var suffix = 1
        while names.contains(where: { name in
            let path = join(directory, renamed(name, base: base, suffix: suffix))
            return FileOps.exists(path) || reserved.contains(path.lowercased())
        }) {
            suffix += 1
        }
        return suffix
    }

    /// `name` with ` <suffix>` after the shared basename: `IMG_1.CR3` becomes `IMG_1 2.CR3`, and
    /// `IMG_1.CR3.xmp` becomes `IMG_1 2.CR3.xmp`. Suffix 1 leaves the name alone.
    public static func renamed(_ name: String, base: String, suffix: Int) -> String {
        guard suffix > 1 else { return name }
        if name.count > base.count, name.prefix(base.count).lowercased() == base.lowercased() {
            return String(name.prefix(base.count)) + " \(suffix)" + name.dropFirst(base.count)
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
    }

    static func join(_ directory: String, _ name: String) -> String {
        name.isEmpty ? directory : (directory as NSString).appendingPathComponent(name)
    }

    // MARK: - Executing

    /// Carries out the plan, journalling each step under `runID` (created by the caller, such as
    /// `CullaDatabase.startApplyRun`). Never throws: a failure stops the run and is reported in
    /// the result, and the run's state is set in the journal.
    public func run(
        _ plan: ApplyPlan,
        runID: Int64,
        progress: @escaping @Sendable (ApplyProgress) -> Void = { _ in }
    ) async -> ApplyRunResult {
        var steps: [ApplyStep]
        do {
            steps = try await self.steps(for: plan)
            try await Self.shielded { [journal, steps] in try await journal.recordSteps(steps, runID: runID) }
        } catch {
            let message = String(describing: error)
            try? await Self.shielded { [journal] in try await journal.setRunState(.failed, failure: message, runID: runID) }
            return Self.result(state: .failed, steps: [], failure: message, failedStep: nil)
        }
        var state = ApplyRunState.done
        var failure: String?
        var failedStep: Int?
        progress(ApplyProgress(done: 0, total: steps.count, currentPhotoID: steps.first?.photoID))

        stepLoop: for index in steps.indices {
            if Task.isCancelled {
                state = .cancelled
                failure = "Cancelled"
                break
            }
            var step = steps[index]
            step.state = .started
            // A sidecar's previous and new bytes are worked out (reading only) and journalled
            // before anything is written.
            if case let .writeSidecar(path, mark, _, _, _) = step.action {
                let mapping = plan.options.sidecarMapping
                let prepared = await queue.run { () -> Result<(SidecarPrevious, Data), Error> in
                    Result { try XMPSidecar.prepareWrite(mark: mark, mapping: mapping, at: URL(fileURLWithPath: path)) }
                }
                switch prepared {
                case let .success((previous, written)):
                    step.action = .writeSidecar(
                        path: path, mark: mark, previous: previous, written: written,
                        tempPath: FileOps.temporaryPath(beside: path)
                    )
                case let .failure(error):
                    guard error is XMPSidecarError else {
                        // Not a sidecar Culla cannot parse but a disk that cannot be read: stop.
                        step.state = .failed
                        step.note = String(describing: error)
                        steps[index] = step
                        try? await Self.record(step, in: journal, runID: runID)
                        (state, failure, failedStep) = (.failed, step.note, index)
                        break stepLoop
                    }
                    step.state = .skipped
                    step.note = String(describing: error)
                    steps[index] = step
                    do {
                        try await Self.record(step, in: journal, runID: runID)
                    } catch {
                        (state, failure, failedStep) = (.failed, "The journal could not be written: \(error)", index)
                        break stepLoop
                    }
                    progress(ApplyProgress(done: index + 1, total: steps.count, currentPhotoID: step.photoID))
                    continue stepLoop
                }
            }
            do {
                try await Self.record(step, in: journal, runID: runID)
            } catch {
                // Nothing was done for this step; its record may say started, which undo checks.
                steps[index] = step
                (state, failure, failedStep) = (.failed, "The journal could not be written: \(error)", index)
                break stepLoop
            }
            steps[index] = step

            let injector = faultInjector
            let started = step
            let outcome = await queue.run { () -> Result<StepOutcome, Error> in
                Result {
                    try injector?(started)
                    return try Self.perform(started)
                }
            }
            switch outcome {
            case let .success(result):
                switch result {
                case .done(let action):
                    step.action = action
                    step.state = .done
                case .skipped(let note):
                    step.state = .skipped
                    step.note = note
                }
                steps[index] = step
                do {
                    try await Self.record(step, in: journal, runID: runID)
                } catch {
                    (state, failure, failedStep) = (.failed, "The journal could not be written: \(error)", index)
                }
            case let .failure(error):
                step.state = .failed
                step.note = String(describing: error)
                steps[index] = step
                try? await Self.record(step, in: journal, runID: runID)
                (state, failure, failedStep) = (.failed, step.note, index)
            }
            if state != .done { break stepLoop }
            progress(ApplyProgress(done: index + 1, total: steps.count, currentPhotoID: steps[safe: index + 1]?.photoID))
        }
        try? await Self.shielded { [journal, state, failure] in try await journal.setRunState(state, failure: failure, runID: runID) }
        return Self.result(state: state, steps: steps, failure: failure, failedStep: failedStep)
    }

    /// Runs journal work in a task of its own, so cancelling the run (which happens between
    /// steps) can never stop the record of a step that was carried out. GRDB's async calls
    /// throw `CancellationError` in a cancelled task.
    static func shielded<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task { try await work() }.value
    }

    static func record(_ step: ApplyStep, in journal: any ApplyJournal, runID: Int64) async throws {
        try await shielded { try await journal.updateStep(step, runID: runID) }
    }

    enum StepOutcome: Sendable {
        case done(ApplyStepAction)
        case skipped(String)
    }

    static func perform(_ step: ApplyStep) throws -> StepOutcome {
        switch step.action {
        case let .createFolder(path):
            if FileOps.isDirectory(path) { return .skipped("The folder was already there.") }
            try FileOps.makeDirectory(path)
            return .done(step.action)

        case let .move(from, to, stamp):
            guard FileOps.stamp(from) == stamp else {
                throw FileOps.Failure(operation: "Checking", path: from, code: FileOps.exists(from) ? ESTALE : ENOENT)
            }
            try FileOps.moveExclusive(from: from, to: to)
            return .done(step.action)

        // Moves the file to the Trash of its volume, as the Finder would: for a shoot on the
        // startup disk that is the user's own Trash (~/.Trash), for one on a card or drive that
        // volume's .Trashes folder. A sandboxed app that the user gave a folder to may move its
        // files there; `trashItem` returns where the file went, which is journalled so the apply
        // can be undone.
        //
        // The package does not refuse a Trash outside the app's sandbox container, on purpose:
        // for a real shoot the user's Trash is the right place, since "Move to the Trash" is
        // what the person chose on Review and Apply. Only the automation harness, which runs on
        // generated fixtures inside the container and must never touch the person's Trash,
        // refuses it (`ApplyCoordinator.trashIsInsideContainer`). Nothing in Culla ever
        // empties the Trash.
        case let .trash(path, stamp, _):
            guard FileOps.stamp(path) == stamp else {
                throw FileOps.Failure(operation: "Checking", path: path, code: FileOps.exists(path) ? ESTALE : ENOENT)
            }
            var resulting: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
            return .done(.trash(path: path, stamp: stamp, trashedPath: (resulting as URL?)?.path))

        case let .writeSidecar(path, mark, previous, written, tempPath):
            guard let previous, let written, let tempPath else { return .skipped("Nothing to write.") }
            do {
                try XMPSidecar.commitWrite(written, previous: previous, at: URL(fileURLWithPath: path), tempPath: tempPath)
            } catch let error as XMPSidecarError {
                return .skipped(String(describing: error))
            }
            return .done(.writeSidecar(path: path, mark: mark, previous: previous, written: written, tempPath: tempPath))

        case let .copy(from, to, tempPath, _):
            let stamp = try FileOps.copyExclusive(from: from, to: to, tempPath: tempPath)
            return .done(.copy(from: from, to: to, tempPath: tempPath, stamp: stamp))
        }
    }

    static func result(state: ApplyRunState, steps: [ApplyStep], failure: String?, failedStep: Int?) -> ApplyRunResult {
        var removed: [String] = []
        var incomplete: [String] = []
        var seen = Set<String>()
        for step in steps where !step.photoID.isEmpty && !seen.contains(step.photoID) {
            switch step.action {
            case .move, .trash: break
            default: continue
            }
            let fileSteps = steps.filter { other in
                guard other.photoID == step.photoID else { return false }
                switch other.action {
                case .move, .trash: return true
                default: return false
                }
            }
            seen.insert(step.photoID)
            let moved = fileSteps.filter { $0.state == .done }.count
            if moved > 0 {
                removed.append(step.photoID)
                if moved < fileSteps.count { incomplete.append(step.photoID) }
            }
        }
        func count(_ matches: (ApplyStepAction) -> Bool) -> Int {
            steps.count(where: { $0.state == .done && matches($0.action) })
        }
        return ApplyRunResult(
            state: state,
            steps: steps,
            failure: failure,
            failedStepIndex: failedStep,
            removedPhotoIDs: removed,
            incompletePhotoIDs: incomplete,
            skippedSidecars: steps.filter { if case .writeSidecar = $0.action { $0.state == .skipped } else { false } },
            movedFiles: count { if case .move = $0 { true } else { false } },
            trashedFiles: count { if case .trash = $0 { true } else { false } },
            copiedFiles: count { if case .copy = $0 { true } else { false } },
            sidecarsWritten: count { if case .writeSidecar = $0 { true } else { false } }
        )
    }

    // MARK: - Undoing

    /// Takes back a run's steps, newest first (see the type's notes), journalling each under
    /// `runID` and setting the run's state to `.undone` or `.partlyUndone`. Steps already undone,
    /// pending, skipped or failed are left alone. Never throws.
    public func undo(
        _ steps: [ApplyStep],
        runID: Int64,
        progress: @escaping @Sendable (ApplyProgress) -> Void = { _ in }
    ) async -> UndoReport {
        var steps = steps.sorted { $0.index < $1.index }
        var skipped: [UndoSkip] = []
        var undone = 0
        let todo = steps.indices.reversed().filter { [.done, .started, .undoSkipped].contains(steps[$0].state) }
        progress(ApplyProgress(done: 0, total: todo.count, currentPhotoID: nil))
        for (number, index) in todo.enumerated() {
            let step = steps[index]
            let outcome = await queue.run { Self.undoOne(step) }
            var updated = step
            switch outcome {
            case .undone(let changed):
                updated.state = .undone
                updated.note = nil
                if changed { undone += 1 }
            case let .skipped(reason, path, detail):
                updated.state = .undoSkipped
                updated.note = reason.message + (detail.map { " \($0)" } ?? "")
                skipped.append(UndoSkip(stepIndex: step.index, photoID: step.photoID, path: path, reason: reason, detail: detail))
            }
            steps[index] = updated
            try? await Self.record(updated, in: journal, runID: runID)
            progress(ApplyProgress(done: number + 1, total: todo.count, currentPhotoID: step.photoID))
        }
        let partly = skipped.contains { $0.reason != .folderNotEmpty }
        let state: ApplyRunState = partly ? .partlyUndone : .undone
        try? await Self.shielded { [journal] in try await journal.setRunState(state, failure: nil, runID: runID) }

        // A photo is back when its shown file is: its move or trash step is undone.
        let restored = steps.filter { step in
            guard step.role == .photo, step.state == .undone else { return false }
            switch step.action {
            case .move, .trash: return true
            default: return false
            }
        }.map(\.photoID)
        return UndoReport(state: state, steps: steps, skipped: skipped, restoredPhotoIDs: restored, undoneSteps: undone)
    }

    enum UndoOutcome: Sendable {
        /// Taken back, or found already as it was before (`changed` false).
        case undone(changed: Bool)
        case skipped(UndoSkipReason, path: String, detail: String?)
    }

    static func undoOne(_ step: ApplyStep) -> UndoOutcome {
        do {
            switch step.action {
            case let .createFolder(path):
                guard FileOps.isDirectory(path) else { return .undone(changed: false) }
                return try FileOps.removeDirectoryIfEmpty(path) ? .undone(changed: true) : .skipped(.folderNotEmpty, path: path, detail: nil)

            case let .move(from, to, stamp):
                return try moveBack(from: to, to: from, stamp: stamp)

            case let .trash(path, stamp, trashedPath):
                guard let trashedPath else {
                    if FileOps.stamp(path) == stamp { return .undone(changed: false) }
                    return .skipped(.trashLocationUnknown, path: path, detail: nil)
                }
                return try moveBack(from: trashedPath, to: path, stamp: stamp)

            case let .writeSidecar(path, _, previous, written, tempPath):
                if let tempPath, FileOps.exists(tempPath) { try? FileOps.removeFile(tempPath) }
                guard let previous, let written else { return .undone(changed: false) }
                do {
                    let changed = try XMPSidecar.restore(previous, written: written, at: URL(fileURLWithPath: path))
                    return .undone(changed: changed)
                } catch XMPSidecar.RestoreConflict.changedSince {
                    return .skipped(.changed, path: path, detail: nil)
                } catch XMPSidecar.RestoreConflict.missing {
                    return .skipped(.missing, path: path, detail: nil)
                }

            case let .copy(from, to, tempPath, stamp):
                if FileOps.exists(tempPath) { try? FileOps.removeFile(tempPath) }
                guard let current = FileOps.stamp(to) else { return .undone(changed: false) }
                // A copy that finished but was not recorded before a crash has the source's size
                // and date, which the copy keeps.
                let expected = stamp ?? FileOps.stamp(from)
                guard current == expected else { return .skipped(.changed, path: to, detail: nil) }
                try FileOps.removeFile(to)
                return .undone(changed: true)
            }
        } catch {
            let path: String
            switch step.action {
            case .createFolder(let folder): path = folder
            case .move(_, let to, _): path = to
            case .trash(let original, _, let trashed): path = trashed ?? original
            case .writeSidecar(let sidecar, _, _, _, _): path = sidecar
            case .copy(_, let to, _, _): path = to
            }
            return .skipped(.failed, path: path, detail: String(describing: error))
        }
    }

    /// Moves a file back to where it was, if it is still the same file and its place is free.
    private static func moveBack(from current: String, to original: String, stamp: FileStamp) throws -> UndoOutcome {
        guard let found = FileOps.stamp(current) else {
            // Already back (an earlier undo, or the step never ran before a crash)?
            if FileOps.stamp(original) == stamp { return .undone(changed: false) }
            return .skipped(.missing, path: current, detail: nil)
        }
        guard found == stamp else { return .skipped(.changed, path: current, detail: nil) }
        if FileOps.exists(original) { return .skipped(.originalPathOccupied, path: current, detail: original) }
        let directory = (original as NSString).deletingLastPathComponent
        if !FileOps.isDirectory(directory) {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        do {
            try FileOps.moveExclusive(from: current, to: original)
        } catch let failure where failure.isExists {
            return .skipped(.originalPathOccupied, path: current, detail: original)
        }
        return .undone(changed: true)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A journal kept in memory, for tests and previews.
public actor MemoryApplyJournal: ApplyJournal {
    public private(set) var steps: [Int64: [ApplyStep]] = [:]
    public private(set) var states: [Int64: ApplyRunState] = [:]
    public private(set) var failures: [Int64: String] = [:]

    public init() {}

    public func recordSteps(_ steps: [ApplyStep], runID: Int64) {
        self.steps[runID] = steps
        states[runID] = .running
    }

    public func updateStep(_ step: ApplyStep, runID: Int64) {
        steps[runID, default: []][step.index] = step
    }

    public func setRunState(_ state: ApplyRunState, failure: String?, runID: Int64) {
        states[runID] = state
        failures[runID] = failure
    }

    public func steps(runID: Int64) -> [ApplyStep] { steps[runID] ?? [] }
    public func state(runID: Int64) -> ApplyRunState? { states[runID] }
}
