import AppKit
import CullaCommands
import CullaCore
import CullaFiles
import CullaPipeline
import CullaSession
import CullaStore
import Foundation
import Observation
import Synchronization
import UniformTypeIdentifiers
import os

/// The task of the run under way, reachable from the fault injector's thread.
final class RunTaskBox: Sendable {
    private let task = Mutex<Task<Void, Never>?>(nil)
    func set(_ value: Task<Void, Never>?) { task.withLock { $0 = value } }
    func cancel() { task.withLock { $0?.cancel() } }
}

/// A flag set from another thread.
final class AtomicFlag: Sendable {
    private let value = Atomic<Bool>(false)
    func set(_ flag: Bool) { value.store(flag, ordering: .sequentiallyConsistent) }
    var isSet: Bool { value.load(ordering: .sequentiallyConsistent) }
}

/// A run of Apply, Copy Keepers or Undo Apply under way, for the progress shown.
struct ApplyRunProgress: Equatable {
    enum Kind: Equatable { case apply, undo }
    var kind: Kind
    /// What is being done, such as "Moving 412 photos to _Rejected".
    var title: String
    var done = 0
    var total = 0
    var currentName: String?
    var cancelling = false
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// What the banner after a run shows.
struct ApplyResultInfo: Equatable {
    var runID: Int64
    var runTitle: String
    var kind: ApplyRunKind
    var state: ApplyRunState
    var headline: String
    var details: [String]
    /// Sidecars left alone because they could not be read: file name and why.
    var skippedSidecars: [String]
    var destination: URL?
    var isProblem: Bool { state == .failed || state == .cancelled }
}

/// What the banner after Undo Apply shows.
struct UndoReportInfo: Equatable {
    var runTitle: String
    var headline: String
    var lines: [String]
    var isWarning: Bool
    /// True when undo can be tried again (the run is partly undone).
    var canRetry: Bool
    var restored: Int
    var skipped: [[String: String]]
}

/// The persistent notices about applying, at the top of the photo area.
enum ApplyBanner: Equatable {
    case result(ApplyResultInfo)
    case undo(UndoReportInfo)
    /// Runs a crash interrupted, found when the shoot opened.
    case recovery(runTitle: String, done: Int, total: Int)
    /// Something stopped an apply or an undo before it changed anything.
    case error(String)
}

/// Review and Apply for one open shoot: the screen's plan and choices, the run with its progress
/// and cancel, the banner afterwards, Undo Apply, and the recovery offer after a crash.
///
/// The session stays with `SessionModel`; this object computes plans from it, hands the plan to
/// `ShootApplier`, and brings the session in line with the disk afterwards. It is the only code
/// in the app that changes files in the shoot folder.
///
/// Rules decided here, where the Design is silent:
/// - P on the screen keeps the focused or selected rejects (a rescue is an ordinary decision), so
///   ⌘Z puts a rescue back while the screen is open and afterwards.
/// - Space and Return look closer at the focused reject over the screen; ← → keep stepping and P
///   keeps rescuing while looking; Escape closes the closer look first, then the screen.
/// - ⇧⌘Return carries the plan out (Return peeks and ⌘Return leaves). Escape during a run cancels it
///   after the current file.
/// - The choice of action and sidecars holds for this apply; "Use as Default" saves it.
/// - Undo Apply from the menus asks first (it moves files); the banner's Undo button does not,
///   since it sits next to the result it takes back.
@MainActor
@Observable
final class ApplyCoordinator {
    @ObservationIgnored private weak var owner: SessionModel?
    /// The session this belongs to. Work that finishes after the shoot closed checks
    /// `isAttached` first.
    @ObservationIgnored private var model: SessionModel { owner! }
    var isAttached: Bool { owner != nil }
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var database: CullaDatabase { model.saver.database }
    nonisolated private static let log = Logger(subsystem: "com.kpirliyev.Culla", category: "apply")

    // MARK: The screen

    private(set) var isOpen = false
    /// True until the disk facts and the first plan are ready.
    private(set) var isPreparing = false
    /// The choices for this apply, from the settings when the screen opens.
    private(set) var options = ApplyOptions()
    /// Applying in the shoot folder: always computed, so the screen shows the rejects and the
    /// summary even when the folder is read-only (then blocked with `.readOnlyFolder`).
    private(set) var plan: ApplyPlan?
    /// Copy Keepers To, once a destination is chosen for a read-only shoot.
    private(set) var copyPlan: ApplyPlan?
    private(set) var writability = ShootFolderAccess.Writability.writable
    private(set) var copyDestination: URL?
    @ObservationIgnored private var copyAccess: FolderAccess?
    @ObservationIgnored private var copyBookmark: Data?
    @ObservationIgnored private var facts: ShootFileFacts?
    /// The rejects in the order the screen lists them: by reason, most severe first.
    private(set) var rejectOrder = PhotoOrder.empty
    var listSelection = GridSelection()
    /// Tiles per row on the screen, reported by the view, so ↑ ↓ move by rows.
    @ObservationIgnored var columns = 6
    /// The reject shown large over the screen, if any.
    private(set) var peekID: String?
    /// Rejects kept from this screen since it opened.
    private(set) var rescuedThisVisit = 0
    /// Bumped when the focus must be scrolled into view.
    private(set) var scrollRevision = 0
    @ObservationIgnored private var recomputeQueued = false
    @ObservationIgnored private(set) var openedAt: CFTimeInterval?
    @ObservationIgnored private(set) var readyMs: Double?
    @ObservationIgnored private var openTask: Task<Void, Never>?

    // MARK: Runs

    private(set) var run: ApplyRunProgress?
    @ObservationIgnored private let runTask = RunTaskBox()
    private(set) var banner: ApplyBanner?
    /// The run Undo Apply acts on.
    private(set) var undoable: ApplyRunRecord?
    /// Photos each run of this open took out of the session, with their scores, for undo.
    @ObservationIgnored private var removedPhotos: [Int64: [AppliedPhoto]] = [:]
    /// Interrupted runs found when the shoot opened, newest first.
    @ObservationIgnored private var recovered: [ApplyRunRecord] = []

    // For the automation dump.
    @ObservationIgnored private(set) var lastResult: [String: Any]?
    @ObservationIgnored private(set) var lastUndo: [String: Any]?
    @ObservationIgnored private(set) var lastApplyMs: Double?
    @ObservationIgnored private(set) var lastUndoMs: Double?
    @ObservationIgnored private(set) var lastFileAction: String?

    #if DEBUG
    /// A fault for the automation harness to inject into the next run.
    struct Fault {
        var failAt: Int?
        var crashAt: Int?
        var cancelAt: Int?
        var holdAt: Int?
        var delayMs: Int = 0
        /// Called just before the simulated crash: writes the harness's result.
        var beforeCrash: (@Sendable () -> Void)?
    }
    @ObservationIgnored var fault: Fault?
    /// Released by the harness to let a held run go on.
    @ObservationIgnored let hold = DispatchSemaphore(value: 0)
    @ObservationIgnored let isHeld = AtomicFlag()
    #endif

    init(model: SessionModel, settings: AppSettings) {
        owner = model
        self.settings = settings
        options = settings.applyOptions
    }

    var isRunning: Bool { run != nil }

    /// The plan the primary button carries out.
    var currentPlan: ApplyPlan? {
        if writability.isWritable { return plan }
        return copyPlan
    }

    var isReadOnly: Bool { !writability.isWritable }

    var canApply: Bool {
        guard let plan = currentPlan, !isRunning, !isPreparing, !planPending else { return false }
        return plan.canApply && !plan.isEmpty
    }

    var primaryTitle: String {
        if isPreparing { return localized("Preparing…") }
        if isReadOnly, copyDestination == nil { return localized("Copy Keepers To…") }
        guard let plan = currentPlan else { return localized("Nothing to Apply") }
        return ApplyText.primaryTitle(plan: plan)
    }

    // MARK: - Opening and leaving the screen

    /// ⌘Return: opens the screen. The disk facts (sizes, existing sidecars, writability) are read
    /// off the main thread; the plan follows.
    func open() {
        guard !isOpen, !isRunning else { return }
        isOpen = true
        isPreparing = true
        openedAt = CACurrentMediaTime()
        readyMs = nil
        options = settings.applyOptions
        plan = nil
        copyPlan = nil
        copyDestination = nil
        copyAccess?.stop()
        copyAccess = nil
        peekID = nil
        rescuedThisVisit = 0
        listSelection = GridSelection()
        rejectOrder = .empty
        model.screenOpened()
        let folder = model.folder
        let photos = model.state.photos
        openTask = Task { [weak self] in
            async let writable = ShootApplier.writability(of: folder)
            async let gathered = ShootApplier.facts(for: photos, folder: folder)
            let (writability, facts) = await (writable, gathered)
            guard let self, self.isAttached, self.isOpen else { return }
            self.writability = writability
            self.facts = facts
            self.recompute { [weak self] in
                guard let self else { return }
                self.isPreparing = false
                if let opened = self.openedAt { self.readyMs = (CACurrentMediaTime() - opened) * 1000 }
                self.listSelection.select(self.rejectOrder.ids.first)
                self.scrollRevision += 1
            }
        }
    }

    /// Escape or ⌘Return: leaves without applying. Rescues stay (they are decisions).
    func close() {
        guard isOpen, !isRunning else { return }
        openTask?.cancel()
        isOpen = false
        isPreparing = false
        peekID = nil
        copyAccess?.stop()
        copyAccess = nil
        model.screenClosed()
    }

    // MARK: - The plan

    /// The session changed while the screen is open (a rescue, its undo, scores arriving): the
    /// plan is computed again on the next turn of the main thread, once however many changes came.
    func sessionChanged() {
        guard isOpen, !isPreparing, !recomputeQueued else { return }
        recomputeQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAttached else { return }
            self.recomputeQueued = false
            guard self.isOpen, !self.isRunning else { return }
            self.recompute()
        }
    }

    /// Shoots with more photos than this have their plan computed off the main thread: a plan
    /// of 10,000 photos with 5,000 rejects takes about 40 ms.
    static let backgroundPlanThreshold = 3000
    @ObservationIgnored private var planGeneration = 0
    /// True while a newer plan is being computed off the main thread: Apply waits for it, so a
    /// photo just rescued is never applied from the plan before.
    private(set) var planPending = false

    private func recompute(completion: (() -> Void)? = nil) {
        guard let facts else {
            completion?()
            return
        }
        let state = model.state
        let folder = model.folder
        let options = options
        let writable = writability.isWritable
        let destination = copyDestination
        let destinationWritable = destinationWritable
        planGeneration += 1
        let generation = planGeneration
        let make = { @Sendable () -> (ApplyPlan, ApplyPlan?) in
            let plan = state.applyPlan(folder: folder, options: options, folderIsWritable: writable, facts: facts)
            var copy: ApplyPlan?
            if let destination {
                var made = state.copyKeepersPlan(folder: folder, destination: destination, options: options, destinationIsWritable: true, facts: facts)
                if made.blocker == nil, !destinationWritable {
                    made.blocker = .destinationNotWritable
                    made.photos = []
                }
                copy = made
            }
            return (plan, copy)
        }
        guard state.count > Self.backgroundPlanThreshold else {
            let timing = MainThreadTiming.begin("apply.recompute")
            let (plan, copy) = make()
            install(plan, copy: copy)
            timing.end()
            completion?()
            return
        }
        model.activity.begin(.preview)
        planPending = true
        Task { [weak self] in
            let (plan, copy) = await Task.detached(priority: .userInitiated) { make() }.value
            guard let self else { return }
            self.model.activity.end(.preview)
            guard self.isAttached, self.planGeneration == generation else { return }
            self.planPending = false
            guard self.isOpen else { return }
            let timing = MainThreadTiming.begin("apply.installPlan")
            self.install(plan, copy: copy)
            timing.end()
            completion?()
        }
    }

    private func install(_ plan: ApplyPlan, copy: ApplyPlan?) {
        self.plan = plan
        if copyDestination != nil { copyPlan = copy }
        let ids = plan.rejectGroups.flatMap(\.photoIDs)
        if ids != rejectOrder.ids {
            let keeping = Set(ids)
            let following = listSelection.focus.flatMap { focus in
                keeping.contains(focus) ? focus : nextAfter(focus, in: rejectOrder, keeping: keeping)
            }
            rejectOrder = PhotoOrder(ids)
            listSelection.prune(to: rejectOrder, fallback: following ?? ids.first)
            if let peekID, !rejectOrder.contains(peekID) { self.peekID = listSelection.focus }
        }
    }

    @ObservationIgnored private var destinationWritable = true

    /// The first photo after `id` in `order` that is still in `keeping`, else the one before.
    private func nextAfter(_ id: String, in order: PhotoOrder, keeping: Set<String>) -> String? {
        guard let position = order.position(of: id) else { return nil }
        let ids = order.ids
        if let after = ids[(position + 1)...].first(where: keeping.contains) { return after }
        return ids[..<position].last(where: keeping.contains)
    }

    func setRejectAction(_ action: RejectAction) {
        guard options.rejectAction != action, !isRunning else { return }
        options.rejectAction = action
        recompute()
    }

    func setWriteSidecars(_ write: Bool) {
        guard options.writeSidecars != write, !isRunning else { return }
        options.writeSidecars = write
        recompute()
    }

    /// True when the choice on screen differs from the saved default.
    var differsFromDefault: Bool {
        options.rejectAction != settings.rejectAction || options.writeSidecars != settings.writeSidecars
    }

    /// "Use as Default": the next apply starts with these choices.
    func makeDefault() {
        settings.rejectAction = options.rejectAction
        settings.writeSidecars = options.writeSidecars
    }

    /// Sidecars the plan writes for kept (and rated) photos and for rejects.
    var sidecarCounts: (kept: Int, rejected: Int, ratedUnreviewed: Int) {
        guard let plan = currentPlan else { return (0, 0, 0) }
        var kept = 0, rejected = 0, rated = 0
        for photo in plan.photos {
            guard let mark = photo.sidecar else { continue }
            switch mark.decision {
            case .kept: kept += 1
            case .rejected: rejected += 1
            case .unreviewed: kept += 1; rated += 1
            }
        }
        return (kept, rejected, rated)
    }

    // MARK: - Moving, rescuing and looking closer

    func move(by offset: Int, extend: Bool = false) {
        guard !rejectOrder.isEmpty else { return }
        listSelection.move(by: offset, extend: extend, in: rejectOrder)
        if peekID != nil { peekID = listSelection.focus }
        scrollRevision += 1
    }

    func move(toEnd first: Bool) {
        guard !rejectOrder.isEmpty else { return }
        listSelection.move(to: first ? 0 : rejectOrder.count - 1, extend: false, in: rejectOrder)
        if peekID != nil { peekID = listSelection.focus }
        scrollRevision += 1
    }

    func click(_ id: String, kind: ClickKind) {
        guard rejectOrder.contains(id) else { return }
        listSelection.click(id, kind: kind, in: rejectOrder)
    }

    func selectAll() { listSelection.selectAll(in: rejectOrder) }
    func deselectAll() { listSelection.deselectAll() }

    var rescueTargets: [String] { isRunning ? [] : listSelection.targets(in: rejectOrder) }

    /// P: keeps the focused or selected rejects. They leave the list; ⌘Z puts them back.
    func rescue() {
        let targets = rescueTargets
        guard !targets.isEmpty else { return }
        let remaining = Set(rejectOrder.ids).subtracting(targets)
        let following = targets.last.flatMap { nextAfter($0, in: rejectOrder, keeping: remaining) }
        model.decideFromApplyScreen(.kept, ids: targets)
        rescuedThisVisit += targets.count
        recompute()
        listSelection.select(following.flatMap { rejectOrder.contains($0) ? $0 : nil } ?? rejectOrder.ids.first)
        if peekID != nil { peekID = listSelection.focus }
        scrollRevision += 1
    }

    /// After ⌘Z on the screen: the plan follows, and a reject that came back is focused.
    func undoneOnScreen(_ ids: [String]) {
        recompute()
        if let back = ids.first(where: rejectOrder.contains) {
            listSelection.select(back)
            rescuedThisVisit = max(0, rescuedThisVisit - ids.count)
            scrollRevision += 1
        }
    }

    /// Space or Return: looks closer at the focused reject, or stops looking.
    func togglePeek() {
        if peekID != nil {
            peekID = nil
        } else if let focus = listSelection.focus {
            peekID = focus
        }
    }

    func closePeek() { peekID = nil }

    // MARK: - Copy Keepers To

    /// Asks for the folder to copy keepers into (the open panel grants access to it).
    func chooseCopyDestination() {
        #if DEBUG
        if AutomationRunner.isActive { return }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = localized("Copy Here")
        panel.message = localized("Choose a folder for the keepers of “\(model.name)”. The shoot itself is only read.")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.setCopyDestination(url)
        }
        if let window = model.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    /// Uses a folder for Copy Keepers To: checks it can be written, then plans the copy.
    func setCopyDestination(_ url: URL) {
        copyAccess?.stop()
        copyAccess = FolderAccess(url: url)
        copyBookmark = try? FolderBookmark.create(for: url, securityScoped: true)
        copyDestination = url
        Task { [weak self] in
            let writability = await ShootApplier.writability(of: url)
            guard let self, self.isAttached, self.copyDestination == url else { return }
            self.destinationWritable = writability.isWritable
            self.recompute()
        }
    }

    // MARK: - Applying

    /// ⇧⌘Return or the primary button: carries the plan out, journalled. Progress shows on the
    /// screen; Escape or Cancel stops it after the current file.
    func applyNow() {
        if isReadOnly, copyDestination == nil {
            chooseCopyDestination()
            return
        }
        guard canApply, let plan = currentPlan else { return }
        #if DEBUG
        if plan.options.rejectAction == .moveToTrash, plan.kind == .apply, AutomationRunner.isActive, !Self.trashIsInsideContainer(for: plan.folder) {
            banner = .error("The Trash for this folder is outside the app’s container, so automation does not use it.")
            return
        }
        #endif
        peekID = nil
        let title = Self.progressTitle(plan)
        run = ApplyRunProgress(kind: .apply, title: title, total: max(plan.photos.count, 1))
        let applier = makeApplier()
        let state = model.state
        let bookmark = plan.kind == .copyKeepers ? copyBookmark : nil
        let started = CACurrentMediaTime()
        model.runStarted()
        let onProgress = progressReporter()
        let task = Task { [weak self] in
            do {
                let applied = try await applier.apply(plan, session: state, destinationBookmark: bookmark, progress: onProgress)
                if let self, self.isAttached { self.finishApply(applied, plan: plan, startedAt: started) }
            } catch {
                if let self, self.isAttached { self.applyFailedToStart(error) }
            }
        }
        runTask.set(task)
    }

    private static func progressTitle(_ plan: ApplyPlan) -> String {
        if plan.kind == .copyKeepers {
            let destination = plan.destination?.lastPathComponent ?? ""
            return localized("Copying \(plan.photos.count) photos to “\(destination)”")
        }
        let rejects = plan.summary.rejected
        guard rejects > 0 else { return localized("Writing \(plan.summary.sidecarsToWrite) sidecars") }
        switch plan.options.rejectAction {
        case .moveToRejectedFolder: return localized("Moving \(rejects) photos to \(ApplyOptions.rejectedFolderName)")
        case .markOnly: return localized("Marking \(rejects) photos as rejected")
        case .moveToTrash: return localized("Moving \(rejects) photos to the Trash")
        }
    }

    /// Hands each step's progress to the main thread.
    private func progressReporter() -> @Sendable (ApplyProgress) -> Void {
        { [weak self] progress in
            let coordinator = self
            Task { @MainActor in if coordinator?.isAttached == true { coordinator?.progressArrived(progress) } }
        }
    }

    private func progressArrived(_ progress: ApplyProgress) {
        guard var run else { return }
        run.done = progress.done
        run.total = progress.total
        run.currentName = progress.currentPhotoID.map { ($0 as NSString).lastPathComponent }
        self.run = run
    }

    /// Escape or Cancel during a run: stops after the current file. What was done can be undone.
    func cancelRun() {
        guard var run, !run.cancelling else { return }
        run.cancelling = true
        self.run = run
        runTask.cancel()
    }

    /// Quitting during a run: an apply stops after the current file (what it did stays undoable),
    /// an undo is let finish. Waits a little while at most.
    func stopRunForQuit() async {
        guard isRunning else { return }
        if run?.kind == .apply { cancelRun() }
        let deadline = Date().addingTimeInterval(15)
        while isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func applyFailedToStart(_ error: any Error) {
        run = nil
        model.runEnded()
        Self.log.error("Apply could not start: \(String(describing: error), privacy: .public)")
        let reason = Formatting.embedded(Self.describe(error))
        banner = .error(localized("Nothing was changed: \(reason). Culla looked at the folder again; review and apply once more."))
        lastResult = ["state": "notStarted", "error": Self.describe(error)]
        close()
        model.disk?.rescan(trigger: "applyFailed")
        refreshUndoable()
    }

    private func finishApply(_ applied: ShootApplier.Applied, plan: ApplyPlan, startedAt: CFTimeInterval) {
        let result = applied.result
        // The screen goes first, so its hundreds of tiles are not redrawn for photos that left.
        run = nil
        close()
        lastApplyMs = (CACurrentMediaTime() - startedAt) * 1000
        if plan.kind == .apply, result.changedAnything {
            // The sidecars and files now record the decisions as they were: the way back is Undo
            // Apply, not undoing single decisions (see `SessionState.removeAppliedPhotos`).
            model.state.removeAppliedPhotos(result.removedPhotoIDs)
            removedPhotos[applied.run.id] = applied.removedPhotos
            model.photosChangedOnDisk()
        }
        let outcome = Self.outcome(result, plan: plan)
        let text = ApplyText.outcome(outcome)
        let runTitle = Self.runTitle(applied.run)
        let skipped = result.skippedSidecars.map { step -> String in
            let name = Self.sidecarPath(step).map { self.displayName($0) } ?? step.photoID
            // The journal's note is English; people see the reason in their language.
            let reason = step.note.flatMap(XMPSidecarError.reason(forNote:)) ?? localized("apply.sidecarLeftAlone", default: "left as it was")
            return localized("apply.skippedSidecar", default: "\(name) (\(reason))")
        }
        banner = .result(ApplyResultInfo(
            runID: applied.run.id, runTitle: runTitle, kind: plan.kind, state: result.state,
            headline: text.headline, details: text.details, skippedSidecars: skipped,
            destination: plan.destination
        ))
        lastResult = [
            "state": result.state.rawValue, "headline": text.headline, "details": text.details,
            "removed": result.removedPhotoIDs.count, "incomplete": result.incompletePhotoIDs, "movedFiles": result.movedFiles,
            "trashedFiles": result.trashedFiles, "copiedFiles": result.copiedFiles, "sidecarsWritten": result.sidecarsWritten,
            "skippedSidecars": skipped, "failure": result.failure ?? NSNull(), "runID": applied.run.id, "runTitle": runTitle,
            "ms": ((lastApplyMs ?? 0) * 10).rounded() / 10,
            "trashedPaths": result.steps.compactMap { step -> String? in
                if case let .trash(_, _, trashed) = step.action { return trashed }
                return nil
            },
        ]
        model.runEnded()
        refreshUndoable()
    }

    private static func outcome(_ result: ApplyRunResult, plan: ApplyPlan) -> ApplyOutcome {
        let planned = plan.kind == .copyKeepers ? plan.photos.count : plan.summary.rejected
        var handled = result.removedPhotoIDs.count
        if plan.kind == .copyKeepers {
            var copied = Set<String>()
            for step in result.steps where step.state == .done { if case .copy = step.action { copied.insert(step.photoID) } }
            handled = copied.count
        }
        let bytes: Int64? = plan.kind == .copyKeepers ? plan.summary.bytesToCopy : (result.state == .done ? plan.summary.rejectedBytes : nil)
        return ApplyOutcome(
            kind: plan.kind, action: plan.options.rejectAction, state: result.state, plannedPhotos: planned,
            handledPhotos: handled, incompletePhotos: result.incompletePhotoIDs.count,
            files: result.movedFiles + result.trashedFiles + result.copiedFiles,
            bytes: result.state == .done ? bytes : nil,
            sidecarsWritten: result.sidecarsWritten, plannedSidecars: plan.summary.sidecarsToWrite,
            skippedSidecars: result.skippedSidecars.count, failure: result.failure,
            destinationName: plan.destination?.lastPathComponent
        )
    }

    private static func sidecarPath(_ step: ApplyStep) -> String? {
        if case let .writeSidecar(path, _, _, _, _) = step.action { return path }
        return nil
    }

    /// A path for the person: relative to the shoot when inside it.
    private func displayName(_ path: String) -> String {
        let root = model.folder.path.hasSuffix("/") ? model.folder.path : model.folder.path + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : (path as NSString).lastPathComponent
    }

    // MARK: - Undo Apply

    /// The name of a run, as its button said.
    static func runTitle(_ run: ApplyRunRecord) -> String {
        let summary = run.summary
        return ApplyText.runTitle(
            kind: run.kind, action: run.options.rejectAction, rejected: summary.rejected,
            copied: summary.kept + summary.unreviewed, sidecars: summary.sidecarsToWrite,
            destinationName: run.destinationPath.map { ($0 as NSString).lastPathComponent }
        )
    }

    /// The Undo Apply menu item's title, or nil when nothing can be undone.
    var undoMenuTitle: String? {
        guard let undoable else { return nil }
        return ApplyText.undoMenuTitle(runTitle: Self.runTitle(undoable), state: undoable.state)
    }

    var canUndoApply: Bool { undoable != nil && !isRunning && !isOpen }

    /// Reads the journal for the run Undo Apply acts on.
    func refreshUndoable() {
        let sessionID = model.sessionID
        let database = database
        Task { [weak self] in
            let run = try? await ShootApplier(database: database, sessionID: sessionID).latestUndoableRun()
            guard let self, self.isAttached else { return }
            self.undoable = run
        }
    }

    /// Undo Apply: takes back the latest undoable run. Progress shows in the banner.
    func undoLatest() {
        guard canUndoApply, let record = undoable else { return }
        let title = Self.runTitle(record)
        run = ApplyRunProgress(kind: .undo, title: localized("Undoing “\(title)”"), total: max(record.undoableStepCount, 1))
        let applier = makeApplier()
        let known = removedPhotos[record.id] ?? []
        let started = CACurrentMediaTime()
        // Copy Keepers wrote into a folder outside the shoot: its bookmark gives access again.
        var access: FolderAccess?
        if let data = record.destinationBookmark, let resolved = try? FolderBookmark.resolve(data, securityScoped: true) {
            access = FolderAccess(url: resolved.url)
        }
        model.runStarted()
        let onProgress = progressReporter()
        let task = Task { [weak self] in
            defer { access?.stop() }
            do {
                let undone = try await applier.undo(runID: record.id, known: known, progress: onProgress)
                if let self, self.isAttached { self.finishUndo(undone, record: record, startedAt: started) }
            } catch {
                guard let self, self.isAttached else { return }
                self.run = nil
                self.model.runEnded()
                let reason = Formatting.embedded(Self.describe(error))
                self.banner = .error(localized("Undo Apply could not start: \(reason). Nothing was changed."))
                self.refreshUndoable()
            }
        }
        runTask.set(task)
    }

    private func finishUndo(_ undone: ShootApplier.Undone, record: ApplyRunRecord, startedAt: CFTimeInterval) {
        lastUndoMs = (CACurrentMediaTime() - startedAt) * 1000
        let report = undone.report
        if !undone.restoredPhotos.isEmpty {
            model.state.restoreAppliedPhotos(undone.restoredPhotos)
            model.photosChangedOnDisk()
        }
        if report.state == .undone { removedPhotos[record.id] = nil }
        let problems = report.skipped.map { skip -> (UndoProblem, String) in
            (UndoProblem(rawValue: skip.reason.rawValue) ?? .failed, displayName(skip.path))
        }
        let title = Self.runTitle(record)
        let text = ApplyText.undoReport(
            restored: undone.restoredPhotos.count, undoneSteps: report.undoneSteps, problems: problems,
            kind: record.kind, shootName: model.name
        )
        let skipped = report.skipped.map { ["path": displayName($0.path), "reason": $0.reason.rawValue, "message": $0.reason.message] }
        banner = .undo(UndoReportInfo(
            runTitle: title, headline: text.headline, lines: text.lines, isWarning: text.isWarning,
            canRetry: report.state == .partlyUndone, restored: undone.restoredPhotos.count, skipped: skipped
        ))
        lastUndo = [
            "state": report.state.rawValue, "restored": undone.restoredPhotos.count, "undoneSteps": report.undoneSteps,
            "skipped": skipped, "headline": text.headline, "lines": text.lines, "ms": ((lastUndoMs ?? 0) * 10).rounded() / 10,
        ]
        run = nil
        model.runEnded()
        refreshUndoable()
    }

    // MARK: - Recovery

    /// On opening the shoot: runs a crash interrupted are marked so they can be undone, and the
    /// person is offered to undo what was done. Also reads the run Undo Apply acts on.
    func shootOpened() {
        let applier = makeApplier()
        Task { [weak self] in
            let runs = (try? await applier.recoverInterruptedRuns()) ?? []
            let undoable = try? await applier.latestUndoableRun()
            guard let self, self.isAttached else { return }
            self.undoable = undoable
            self.recovered = runs.filter(\.isUndoable)
            if let run = self.recovered.first {
                // Photos the interrupted run moved look "no longer in the folder"; the offer says why.
                self.model.dismissMergeNote()
                self.banner = .recovery(runTitle: Self.runTitle(run), done: run.undoableStepCount, total: run.stepCount)
            }
        }
    }

    /// "Undo What Was Done" on the recovery offer.
    func undoRecovered() {
        banner = nil
        undoLatest()
    }

    func dismissBanner() {
        banner = nil
    }

    // MARK: - After applying

    /// The keepers' files: what Reveal Keepers and Open Keepers In act on.
    func keeperURLs(for result: ApplyResultInfo) -> [URL] {
        if result.kind == .copyKeepers, let destination = result.destination {
            return model.state.photos.filter { $0.decision != .rejected && !$0.isUnreadable }.map {
                destination.appendingPathComponent($0.id)
            }
        }
        return model.state.photos.filter { $0.decision != .rejected && !$0.isUnreadable }.map(\.file.url)
    }

    func revealKeepers(_ result: ApplyResultInfo) {
        let urls = keeperURLs(for: result)
        #if DEBUG
        if AutomationRunner.isActive {
            lastFileAction = "revealKeepers: \(urls.count) files"
            return
        }
        #endif
        if result.kind == .copyKeepers, let destination = result.destination {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } else if urls.count > 400 {
            // Selecting hundreds of files makes the Finder slow; show the folder, which now holds
            // only the keepers (unless the rejects were only marked).
            NSWorkspace.shared.activateFileViewerSelecting([model.folder])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// Opens the keepers in the remembered application, asking for one the first time.
    func openKeepers(_ result: ApplyResultInfo, choosing: Bool = false) {
        guard let editor = settings.editorApplication, !choosing else {
            chooseEditor { [weak self] in self?.openKeepers(result) }
            return
        }
        let urls = keeperURLs(for: result)
        #if DEBUG
        if AutomationRunner.isActive {
            lastFileAction = "openKeepers: \(editor.deletingPathExtension().lastPathComponent): \(urls.count) files"
            return
        }
        #endif
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: editor, configuration: configuration) { _, error in
            if let error { Self.log.error("Opening keepers failed: \(String(describing: error), privacy: .public)") }
        }
    }

    /// Asks for the application Open Keepers In uses, and remembers it.
    func chooseEditor(then: (() -> Void)? = nil) {
        #if DEBUG
        if AutomationRunner.isActive {
            lastFileAction = "chooseEditor"
            return
        }
        #endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = localized("panel.choose", default: "Choose")
        panel.message = localized("Choose the application to open keepers in, such as Photomator. Culla remembers it.")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.settings.editorApplication = url
            then?()
        }
        if let window = model.window { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }

    var editorName: String? {
        settings.editorApplication.map { $0.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Helpers

    private func makeApplier() -> ShootApplier {
        #if DEBUG
        if let fault {
            self.fault = nil
            return ShootApplier(database: database, sessionID: model.sessionID, faultInjector: makeInjector(fault))
        }
        #endif
        return ShootApplier(database: database, sessionID: model.sessionID)
    }

    static func describe(_ error: any Error) -> String {
        // ApplyPrepareError's `description` stays English for the journal; people see its errorDescription.
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return String(describing: error)
    }

    #if DEBUG
    struct SimulatedFailure: Error, CustomStringConvertible {
        var step: Int
        var description: String { "A failure the automation harness simulated at step \(step)." }
    }

    private func makeInjector(_ fault: Fault) -> ApplyExecutor.FaultInjector {
        let task = runTask
        let hold = hold
        let held = isHeld
        return { step in
            if fault.delayMs > 0 { usleep(useconds_t(fault.delayMs * 1000)) }
            if step.index == fault.holdAt {
                held.set(true)
                hold.wait()
                held.set(false)
            }
            if step.index == fault.crashAt {
                fault.beforeCrash?()
                _exit(0)
            }
            if step.index == fault.failAt { throw SimulatedFailure(step: step.index) }
            if step.index == fault.cancelAt { task.cancel() }
        }
    }

    /// Where the Trash for a folder is, checked before automation moves anything there: only a
    /// Trash inside the app's container is used by scripts.
    static func trashIsInsideContainer(for folder: URL) -> Bool {
        guard let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: folder, create: false) else {
            return false
        }
        let home = NSHomeDirectory()
        return trash.resolvingSymlinksInPath().path.hasPrefix(home + "/")
    }

    var dumpState: [String: Any] {
        var state: [String: Any] = [
            "screenOpen": isOpen, "preparing": isPreparing, "readOnly": isReadOnly, "writability": writability.rawValue,
            "action": options.rejectAction.rawValue, "writeSidecars": options.writeSidecars,
            "buttonTitle": primaryTitle, "canApply": canApply, "rescuedThisVisit": rescuedThisVisit,
            "focus": listSelection.focus ?? NSNull(), "selected": listSelection.selected.sorted(), "peek": peekID ?? NSNull(),
            "rejectOrder": rejectOrder.ids, "differsFromDefault": differsFromDefault,
            "defaultAction": settings.rejectAction.rawValue, "defaultWriteSidecars": settings.writeSidecars,
            "editor": settings.editorApplication?.path ?? NSNull(),
            "copyDestination": copyDestination?.lastPathComponent ?? NSNull(),
            "openMs": readyMs.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
            "lastApplyMs": lastApplyMs.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
            "lastUndoMs": lastUndoMs.map { ($0 * 10).rounded() / 10 } ?? NSNull(),
            "lastFileAction": lastFileAction ?? NSNull(),
            "undoMenuTitle": undoMenuTitle ?? NSNull(),
        ]
        if let plan = currentPlan ?? plan {
            let summary = plan.summary
            state["plan"] = [
                "kind": plan.kind.rawValue, "kept": summary.kept, "rejected": summary.rejected, "unreviewed": summary.unreviewed,
                "unreadable": summary.unreadable, "rejectedFiles": summary.rejectedFiles, "rejectedBytes": summary.rejectedBytes,
                "sidecarsToWrite": summary.sidecarsToWrite, "filesToCopy": summary.filesToCopy, "photos": plan.photos.count,
                "blocker": plan.blocker?.rawValue ?? NSNull(), "isEmpty": plan.isEmpty,
                // Developer text for the dump; the screen shows its own counts.
                "summaryLine": "\(summary.kept) kept · \(summary.rejected) rejected · \(summary.unreviewed) unreviewed"
                    + (summary.unreadable > 0 ? " · \(summary.unreadable) unreadable" : ""),
            ] as [String: Any]
            state["groups"] = (self.plan?.rejectGroups ?? []).map { ["reason": $0.reason.rawValue, "title": $0.reason.title, "photos": $0.photoIDs] as [String: Any] }
        }
        if let run {
            state["run"] = ["kind": run.kind == .apply ? "apply" : "undo", "title": run.title, "done": run.done, "total": run.total, "cancelling": run.cancelling, "held": isHeld.isSet]
        }
        if let lastResult { state["result"] = lastResult }
        if let lastUndo { state["undoReport"] = lastUndo }
        if let undoable {
            state["undoable"] = ["id": undoable.id, "state": undoable.state.rawValue, "title": Self.runTitle(undoable), "undoableSteps": undoable.undoableStepCount, "steps": undoable.stepCount]
        } else {
            state["undoable"] = NSNull()
        }
        switch banner {
        case .result(let info): state["banner"] = ["kind": "result", "headline": info.headline, "details": info.details, "skippedSidecars": info.skippedSidecars, "state": info.state.rawValue]
        case .undo(let info): state["banner"] = ["kind": "undo", "headline": info.headline, "lines": info.lines, "warning": info.isWarning, "canRetry": info.canRetry]
        case .recovery(let title, let done, let total): state["banner"] = ["kind": "recovery", "runTitle": title, "done": done, "total": total]
        case .error(let text): state["banner"] = ["kind": "error", "text": text]
        case nil: state["banner"] = NSNull()
        }
        return state
    }
    #endif
}
