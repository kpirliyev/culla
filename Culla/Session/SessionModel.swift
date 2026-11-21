import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaFiles
import CullaSession
import CullaStore
import Foundation
import Observation

/// The photo views of the shoot window.
enum ViewMode: String, Sendable, CaseIterable {
    case grid
    case loupe
    case compare
    /// Similar Stacks: the current frame beside the best pick, the face strip, the stack's frames.
    case stackReview
    /// Duplicates: the copies of one set side by side.
    case duplicateReview

    /// True for the views that show one stack or set at a time.
    var isReview: Bool { self == .stackReview || self == .duplicateReview }
}

/// Where the person was before compare or a review screen opened, so Escape (or accepting a
/// stack opened from the grid) goes back there.
struct ReviewOrigin: Equatable {
    var viewMode: ViewMode
    var selection: GridSelection
}

/// Why the photos of the current group changed, so the grid knows whether to reload, animate,
/// or keep what is on screen where it is.
enum OrderChange {
    /// Another group was opened: reload and scroll to the focus.
    case newGroup
    /// A decision moved photos in or out: animate the difference.
    case decision
    /// Analysis or a tuning change filled the group in: no animation, and the photos on screen
    /// stay where they are.
    case refill
}

/// A short message over the photo area that goes away by itself, such as "Nothing to reject".
struct TransientNotice: Equatable, Identifiable {
    let id = UUID()
    var text: String
    var symbol: String
}

/// ⇧X waiting for its confirmation.
struct BulkRejectRequest: Equatable, Identifiable {
    let id = UUID()
    var group: GroupID
    var ids: [String]
    var question: String { BulkReject.question(count: ids.count, group: group) }
    var buttonTitle: String { BulkReject.buttonTitle(count: ids.count) }
}

/// What the photo area says when the current group is empty.
enum EmptyReason: Equatable {
    /// No photo of the shoot is in the group, and no analysis has run.
    case notAnalysedYet
    /// Analysis is still going; the group may yet fill.
    case stillAnalysing(done: Int, total: Int)
    /// Analysis is paused before it finished.
    case analysisPaused(done: Int, total: Int)
    /// Analysis looked at every photo and found none.
    case noneFound(checked: Int)
    /// Every photo has a decision (Unreviewed).
    case allDecided
    /// A group whose members come from decisions, such as Kept, with nothing yet.
    case nothingYet
    /// The shoot has no photos.
    case noPhotos
}

/// One open shoot: its `SessionState` and everything the window shows about it. Views read it
/// and call its intent methods; nothing else changes the state.
@MainActor
@Observable
final class SessionModel {
    // MARK: Identity

    let folder: URL
    let sessionID: Int64
    var name: String { folder.lastPathComponent }

    // MARK: State

    /// The session itself. Not observed directly, because it is large and changes in place:
    /// read it through `session`, which records a dependency on `revision`.
    @ObservationIgnored var state: SessionState
    /// Bumped on every change to `state`.
    private(set) var revision = 0 {
        didSet { apply?.sessionChanged() }
    }
    /// The session, for views that redraw when it changes.
    var session: SessionState {
        _ = revision
        return state
    }

    // MARK: View state

    private(set) var group: GroupID
    /// The photos of the current group, in capture order: what the photo area shows.
    private(set) var order: PhotoOrder = .empty
    /// Bumped when `order` changes. `orderChangeIsNewGroup` says whether it changed because
    /// another group was opened (the grid reloads) or because photos joined or left it (the grid
    /// animates the difference).
    var orderRevision = 0
    @ObservationIgnored var orderChange = OrderChange.newGroup
    var orderChangeIsNewGroup: Bool { orderChange == .newGroup }
    var selection = GridSelection() {
        didSet {
            guard selection.focus != oldValue.focus else { return }
            // Another photo has other faces.
            if loupeTargetFace != nil { loupeTargetFace = nil }
            followEvidence()
            schedulePriority()
        }
    }
    var viewMode: ViewMode = .grid
    private(set) var inspectorVisible = false

    // MARK: Collapsed stacks

    /// True when the person expanded every stack in All Photos (S).
    var stacksExpanded = false
    /// The grid's tiles when stacks are collapsed (All Photos), else nil: the grid then shows
    /// `order`. Rebuilt after every change; `orderRevision` is bumped when the tiles change.
    @ObservationIgnored var gridEntries: GridEntries?
    /// The photos the grid's tiles show, in order: `order`, or each collapsed stack's
    /// representative in place of its frames. The grid's selection lives in this order.
    @ObservationIgnored var gridOrder: PhotoOrder = .empty
    /// The collapsed stacks on screen, by the photo their tile shows.
    @ObservationIgnored var collapsedStacks: [String: CollapsedStack] = [:]

    // MARK: Stack review, duplicate review and compare

    /// True when stack review has nothing left: every stack has a decision. The screen then says
    /// so and offers the next group.
    var stackReviewDone = false
    /// True when every duplicate set has a decision.
    var duplicateReviewDone = false
    /// Where a stack opened from the grid or the loupe goes back to, on Escape or once accepted.
    @ObservationIgnored var reviewOrigin: ReviewOrigin?
    /// Whether the face strip shows under stack review (on by default) and under the loupe (off).
    var faceStripInStackReview = true
    var faceStripInLoupe = false
    /// The zoom shared by the panes of stack review, compare and duplicate review: zoom and pan
    /// are linked between them. Set by commands through `setReviewZoom`, which bumps
    /// `reviewZoomRevision`; a pane the person zooms reports it with `reviewViewChanged`.
    @ObservationIgnored var reviewZoom = LoupeZoom.fit
    var reviewZoomRevision = 0
    /// The face strip row (the person) the panes are zoomed to: each pane then centres on that
    /// person's face in its own frame. Nil when zoomed to a spot.
    var reviewFaceRow: Int?
    /// The photos compare shows, left to right, and the pane with the focus.
    var compareIDs: [String] = []
    var compareFocus = 0
    @ObservationIgnored var compareOrigin: ReviewOrigin?
    /// When the last Return, ↓ or → in a review screen was pressed, for timing how long the screen
    /// took to show the result.
    @ObservationIgnored var reviewActionAt: (kind: String, at: CFTimeInterval)?
    /// The last Accept All Exact Duplicates, for the automation dump.
    @ObservationIgnored var lastBulkAccept: (sets: Int, rejected: Int)?
    /// The face strip of a stack, kept until the session changes.
    @ObservationIgnored var faceStripCache: (key: String, revision: Int, strip: FaceStrip)?
    /// Photos whose decision, rating, readability or scores changed, by `marksRevision`, so the
    /// grid and the filmstrip can each redraw what changed since they last looked.
    @ObservationIgnored private var changeLog: [(revision: Int, ids: [String])] = []
    /// Bumped when photos' marks change.
    private(set) var marksRevision = 0
    /// Bumped when the focused photo must be scrolled into view.
    var scrollRevision = 0
    /// What the last rescan found, for the "new photos" note. Nil after the first open.
    private(set) var mergeResult: MergeResult?
    /// Set when the shoot folder cannot be reached any more, such as a card that was removed.
    private(set) var folderMissing = false
    /// Photos whose thumbnail could not be made because the folder could not be reached: they
    /// are not unreadable, and their tiles load again when the folder is back.
    @ObservationIgnored private(set) var thumbnailsAwaitingFolder = Set<String>()

    // MARK: Disk

    /// Review and Apply, Undo Apply and the recovery offer.
    @ObservationIgnored private(set) var apply: ApplyCoordinator!
    /// Rescans and the folder's reachability.
    @ObservationIgnored private(set) var disk: ShootDiskMonitor!
    /// The window the shoot is in, for sheets and the open panel.
    @ObservationIgnored weak var window: NSWindow?
    /// Asks the app to find the folder where its bookmark says it moved, and reopen it there.
    @ObservationIgnored var followMovedFolder: (() -> Void)?
    /// Undo Apply from the menus, waiting for its confirmation.
    private(set) var undoApplyRequest: UndoApplyRequest?

    /// The photo the loupe shows at screen size, set by the loupe once the image is on screen.
    @ObservationIgnored var loupeShownID: String?

    // MARK: Loupe state

    /// The loupe's zoom. The loupe writes it as the person pinches, scrolls and drags
    /// (`loupeViewChanged(_:)`), without telling observers; commands set it through
    /// `setLoupeZoom(_:)`, which bumps `loupeZoomRevision` so the loupe applies it.
    /// It is kept when moving to another photo: "sticky zoom".
    @ObservationIgnored private(set) var loupeZoom = LoupeZoom.fit
    private(set) var loupeZoomRevision = 0
    /// The face Z or Tab zoomed to, an index into the focused photo's `scores.faces`.
    var loupeTargetFace: Int?
    /// The face Tab zoomed to in compare, an index into the focused pane's photo's faces.
    @ObservationIgnored var compareTargetFace: Int?
    /// Which overlays are toggled away from their group's default.
    private(set) var loupeOverlays = LoupeOverlays()

    /// Whether face boxes are on screen in the current view. In stack review F hides them with
    /// the face strip (`StackReviewLayout.showsFaceBoxes`).
    var showsFaceBoxes: Bool {
        let on = loupeOverlays.showsFaceBoxes(in: faceBoxGroup)
        guard viewMode == .stackReview else { return on }
        return StackReviewLayout.showsFaceBoxes(faceStripWanted: faceStripInStackReview, faceBoxesOn: on)
    }
    var showsClipping: Bool { loupeOverlays.showsClipping(in: group) }

    /// Asks the app to show the open panel, for the empty-folder message.
    @ObservationIgnored var requestOpenFolder: (() -> Void)?

    // MARK: Analysis state

    /// The background analysis of this shoot; nil until `startAnalysis` (and in tests).
    @ObservationIgnored private(set) var analysis: AnalysisController?
    /// Photos whose scores the automation harness made up. Analysis results for them are
    /// ignored, so a script's simulated faces stay as given while real analysis runs.
    @ObservationIgnored private(set) var pinnedScoreIDs = Set<String>()
    /// The summary banner shown when analysis ends; nil once dismissed or not due.
    private(set) var summaryBanner: AnalysisSummary?
    @ObservationIgnored private var summaryDismissed = false
    @ObservationIgnored private var summaryShown = false
    /// A short message that goes away by itself.
    private(set) var notice: TransientNotice?
    /// ⇧X waiting for its confirmation.
    private(set) var bulkRejectRequest: BulkRejectRequest?
    /// The last ⇧X question shown, for the automation dump.
    @ObservationIgnored private(set) var lastBulkRejectQuestion: String?
    /// The group whose tuning panel is open, if any.
    private(set) var tuningPanelGroup: GroupID?
    /// The counts when the tuning panel opened, so its lines can say "41 → 28".
    @ObservationIgnored private(set) var tuningBaseline = TuningCounts()
    @ObservationIgnored private(set) var tuningBaselineTotal = 0
    /// True when the person switched the view by hand since the group was opened: scores
    /// arriving then never switch it back.
    @ObservationIgnored var viewChosenByHand = false
    /// Where the person was in a group found by analysis, when the shoot reopened before that
    /// group's scores arrived from the cache: applied once the group fills in.
    @ObservationIgnored private var pendingPlace: SessionPlace?
    /// The grid tiles on screen, reported by the grid, for analysis priority.
    @ObservationIgnored private var visibleIDs: [String] = []
    @ObservationIgnored private var priorityTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// The defect group whose last undecided photo was decided while the person looked at it:
    /// the photo area then says so and offers the next group.
    private(set) var completedGroup: GroupID?

    /// The grid's layout, reported by the grid so Up, Down and Page keys move by rows.
    @ObservationIgnored var gridColumns = 1
    @ObservationIgnored var gridRowsPerPage = 4

    var focus: String? { selection.focus }
    var focusedPhoto: PhotoItem? { selection.focus.flatMap { session.photo($0) } }
    var thumbnailSize: Double { settings.thumbnailSize }

    // MARK: Services

    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let thumbnails: ThumbnailCache
    @ObservationIgnored let previews: ScreenPreviewCache
    @ObservationIgnored let saver: SessionSaver
    @ObservationIgnored let activity: ActivityTracker
    @ObservationIgnored private var access: FolderAccess?

    init(
        folder: URL,
        sessionID: Int64,
        state: SessionState,
        place: SessionPlace,
        mergeResult: MergeResult?,
        access: FolderAccess?,
        settings: AppSettings,
        thumbnails: ThumbnailCache,
        saver: SessionSaver,
        activity: ActivityTracker,
        hasOwnTuning: Bool = false
    ) {
        self.hasOwnTuning = hasOwnTuning
        stacksExpanded = !settings.collapseStacksInAllPhotos
        self.folder = folder
        self.sessionID = sessionID
        self.state = state
        self.mergeResult = (mergeResult?.isEmpty ?? true) ? nil : mergeResult
        self.access = access
        self.settings = settings
        self.thumbnails = thumbnails
        self.saver = saver
        self.activity = activity
        previews = ScreenPreviewCache(activity: activity)

        // Come back to where the user was.
        group = place.group.flatMap(GroupID.init(rawValue:)) ?? .allPhotos
        order = PhotoOrder(state.members(of: group))
        let focus = place.focusedPhotoID.flatMap { order.contains($0) ? $0 : nil } ?? order.ids.first
        selection = GridSelection(focus: focus)
        if order.isEmpty, group.needsAnalysis { pendingPlace = place }
        // Review screens come back once their stacks or sets are known (`pendingPlace`).
        if let mode = place.viewMode.flatMap(ViewMode.init(rawValue:)), mode == .grid || mode == .loupe, focus != nil {
            viewMode = mode
        }
        if order.isEmpty == false, let mode = place.viewMode.flatMap(ViewMode.init(rawValue:)), mode.isReview {
            pendingPlace = place
        }
        rebuildEntries()
        scrollRevision = 1
        apply = ApplyCoordinator(model: self, settings: settings)
        disk = ShootDiskMonitor(model: self)
    }

    /// The folder could not be reached, or can be again (`ShootDiskMonitor`).
    func setFolderMissing(_ missing: Bool) {
        guard folderMissing != missing else { return }
        folderMissing = missing
        if !missing, !thumbnailsAwaitingFolder.isEmpty {
            // The tiles left blank while the folder was gone load their thumbnails now.
            let ids = Array(thumbnailsAwaitingFolder)
            thumbnailsAwaitingFolder = []
            noteChanged(ids)
        }
    }

    /// Loads the thumbnails that waited for the folder again in a moment, unless it is missing
    /// by then (they then wait for `setFolderMissing(false)`).
    private func retryAwaitingThumbnailsSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !self.folderMissing, !self.thumbnailsAwaitingFolder.isEmpty else { return }
            let ids = Array(self.thumbnailsAwaitingFolder)
            self.thumbnailsAwaitingFolder = []
            self.noteChanged(ids)
        }
    }

    /// The session changed in a way that touches every photo (an apply, an undo, a rescan):
    /// every view redraws and the change is saved.
    func sessionChangedOnDisk(mergeNote: MergeResult? = nil) {
        revision += 1
        noteAllChanged()
        mergeResult = mergeNote
        faceStripCache = nil
    }

    func setUndoApplyRequest(_ request: UndoApplyRequest?) {
        undoApplyRequest = request
    }

    /// Hides the note about photos added or removed since the shoot was last open.
    func dismissMergeNote() {
        mergeResult = nil
    }

    /// True once any photo has scores. Until then, empty defect groups say so.
    var hasAnalysis: Bool {
        session.photos.contains { $0.scores != nil }
    }

    /// Ends access to the folder. Called when the shoot is closed, after `stopAnalysis()`.
    func close() {
        disk?.stop()
        priorityTask?.cancel()
        noticeTask?.cancel()
        access?.stop()
        access = nil
    }

    // MARK: - Commands

    /// Whether a command can run now; menus and toolbar buttons are disabled when it cannot.
    func isEnabled(_ command: Command) -> Bool {
        if apply.isOpen { return isEnabledOnApplyScreen(command) }
        // While an undo runs, nothing may change decisions.
        if apply.isRunning, command.isDecision || Self.changesStacks.contains(command) || Self.touchesDisk.contains(command) {
            return false
        }
        let hasPhotos = !order.isEmpty
        let inLoupe = viewMode == .loupe && hasPhotos
        let inGrid = viewMode == .grid && hasPhotos
        let inStacks = viewMode == .stackReview && currentStack != nil
        let inSets = viewMode == .duplicateReview && currentSet != nil
        let inCompare = viewMode == .compare && !compareIDs.isEmpty
        switch command {
        case .zoomToggle:
            if inStacks || inCompare || inSets { return true }
            return inLoupe && focusedPhoto.map { !$0.isUnreadable } == true
        case .nextFace, .previousFace:
            if inStacks { return reviewZoom.isZoomed && !(currentFaceStrip?.matching.rows.isEmpty ?? true) }
            if inCompare { return reviewZoom.isZoomed && !compareFaceOrder.isEmpty }
            return inLoupe && loupeZoom.isZoomed && !loupeFaceOrder.isEmpty
        case .toggleFaceBoxes:
            // With faces hidden by F in stack review, B would flip boxes that are not on screen.
            return inLoupe || (inStacks && faceStripInStackReview) || inCompare
        case .toggleClippingOverlay:
            return inLoupe
        case .toggleFaceStrip:
            return inLoupe || inStacks
        case .toggleBestPickPane:
            return inStacks
        case .keep, .reject, .clearDecision, .rate0, .rate1, .rate2, .rate3, .rate4, .rate5:
            if viewMode == .stackReview { return inStacks && !stackReviewDone }
            if viewMode == .duplicateReview { return inSets && !duplicateReviewDone }
            if viewMode == .compare { return inCompare }
            // A collapsed stack on its own still answers, to say how to decide its frames.
            return !targets.isEmpty || !collapsedTargets.isEmpty
        case .undo: return state.canUndo || (apply.canUndoApply && !folderMissing)
        case .redo: return state.canRedo
        case .reviewAndApply: return session.count > 0 && !folderMissing && !apply.isRunning
        case .applyDecisions: return false
        case .undoApply: return apply.canUndoApply && !folderMissing
        case .rescanFolder: return !apply.isRunning
        case .selectAll: return inGrid
        case .deselectAll: return viewMode == .grid && selection.selected.count > 1
        case .nextPhoto, .previousPhoto, .firstPhoto, .lastPhoto:
            if viewMode == .stackReview { return inStacks }
            if viewMode == .duplicateReview { return inSets }
            if viewMode == .compare { return inCompare && command != .firstPhoto && command != .lastPhoto }
            return hasPhotos
        case .nextRow, .previousRow:
            if viewMode == .stackReview { return inStacks }
            if viewMode == .duplicateReview { return inSets }
            return inGrid
        case .extendNext, .extendPrevious, .extendNextRow, .extendPreviousRow, .pageDown, .pageUp:
            return inGrid
        case .nextGroup: return neighbourGroup(after: true) != nil
        case .previousGroup: return neighbourGroup(after: false) != nil
        case .toggleLoupe: return hasPhotos || viewMode != .grid
        case .showLoupe: return hasPhotos
        case .showGrid: return true
        case .showCompare:
            if viewMode == .compare { return true }
            return hasPhotos && !photosToCompare().isEmpty
        case .back:
            return viewMode != .grid
        case .toggleInspector: return true
        case .largerThumbnails: return viewMode == .grid && settings.thumbnailSize < AppSettings.thumbnailSizeRange.upperBound
        case .smallerThumbnails: return viewMode == .grid && settings.thumbnailSize > AppSettings.thumbnailSizeRange.lowerBound
        case .closeShoot: return true
        case .rejectCertain: return group.isDefectGroup && hasPhotos && (viewMode == .grid || viewMode == .loupe)
        case .startReviewing: return ReviewGuide.firstGroupToReview(in: state) != nil
        case .toggleAnalysis: return analysis.map { $0.isRunning || $0.isPaused } ?? false
        case .showTuning: return group.hasTuning
        case .acceptStack:
            switch viewMode {
            case .stackReview: return inStacks
            case .duplicateReview: return inSets
            case .grid, .loupe: return focus.map { state.stack(containing: $0) != nil } ?? false
            case .compare: return false
            }
        case .acceptAllExactDuplicates:
            return group == .duplicates && state.duplicateSetCounts(kind: .exact).left > 0
        case .addToStack:
            return inGrid && !selection.targets(in: gridOrder).isEmpty
        case .splitFromStack:
            if viewMode == .stackReview { return inStacks && !stackReviewDone }
            guard viewMode == .grid || viewMode == .loupe, let focus else { return false }
            return state.stack(containing: focus) != nil
        case .chooseBestPick:
            if viewMode == .stackReview { return inStacks && !stackReviewDone }
            if viewMode == .compare { return inCompare && compareFocusedID.map { state.stack(containing: $0) != nil } == true }
            guard viewMode == .grid || viewMode == .loupe, let focus else { return false }
            return state.stack(containing: focus) != nil && collapsedStacks[focus] == nil
        case .toggleStacks:
            return group == .allPhotos && viewMode == .grid
        // Later milestones, and the app's own.
        case .openFolder, .openSettings:
            return false
        }
    }

    /// Runs a command. Returns false when it is not available now.
    @discardableResult
    func perform(_ command: Command) -> Bool {
        guard isEnabled(command) else { return false }
        if apply.isOpen {
            performOnApplyScreen(command)
            return true
        }
        switch command {
        case .keep: decideAnywhere(.kept)
        case .reject: decideAnywhere(.rejected)
        case .clearDecision: decideAnywhere(.unreviewed)
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5: rate(command.rating ?? 0)
        case .undo: if state.canUndo { undo() } else { requestUndoApply() }
        case .redo: redo()
        case .reviewAndApply: openReviewAndApply()
        case .undoApply: requestUndoApply()
        case .rescanFolder: disk.rescan(trigger: "menu")
        case .applyDecisions: return false
        case .selectAll: updateSelection { $0.selectAll(in: gridOrder) }
        case .deselectAll: updateSelection { $0.deselectAll() }
        case .nextPhoto: step(by: 1)
        case .previousPhoto: step(by: -1)
        case .nextRow: stepRow(forward: true)
        case .previousRow: stepRow(forward: false)
        case .extendNext: move(by: 1, extend: true)
        case .extendPrevious: move(by: -1, extend: true)
        case .extendNextRow: move(by: gridColumns, extend: true)
        case .extendPreviousRow: move(by: -gridColumns, extend: true)
        case .pageDown: move(by: gridColumns * max(1, gridRowsPerPage))
        case .pageUp: move(by: -gridColumns * max(1, gridRowsPerPage))
        case .firstPhoto: stepToEnd(first: true)
        case .lastPhoto: stepToEnd(first: false)
        case .nextGroup: if let next = neighbourGroup(after: true) { selectGroup(next) }
        case .previousGroup: if let previous = neighbourGroup(after: false) { selectGroup(previous) }
        case .toggleLoupe: toggleDetail()
        case .showGrid: setViewMode(.grid)
        case .showLoupe: setViewMode(.loupe)
        case .showCompare: viewMode == .compare ? leaveCompare() : enterCompare()
        case .back: goBack()
        case .rejectCertain: requestBulkReject()
        case .startReviewing: startReviewing()
        case .toggleAnalysis: analysis?.togglePause()
        case .showTuning: toggleTuningPanel()
        case .toggleInspector: inspectorVisible.toggle()
        case .largerThumbnails: settings.thumbnailSize += AppSettings.thumbnailSizeStep
        case .smallerThumbnails: settings.thumbnailSize -= AppSettings.thumbnailSizeStep
        case .zoomToggle: viewMode == .loupe ? toggleZoom() : toggleReviewZoom()
        case .nextFace: viewMode == .loupe ? stepFace(forward: true) : stepReviewFace(forward: true)
        case .previousFace: viewMode == .loupe ? stepFace(forward: false) : stepReviewFace(forward: false)
        case .toggleFaceBoxes: loupeOverlays.toggleFaceBoxes(in: faceBoxGroup)
        case .toggleClippingOverlay: loupeOverlays.toggleClipping(in: group)
        case .toggleFaceStrip:
            if viewMode == .stackReview { faceStripInStackReview.toggle() } else { faceStripInLoupe.toggle() }
        // A preference, saved in the settings: not a decision, so not in the undo history.
        case .toggleBestPickPane: settings.showsBestPickPane.toggle()
        case .acceptStack: accept()
        case .acceptAllExactDuplicates: acceptAllExactDuplicates()
        case .addToStack: addSelectionToStack()
        case .splitFromStack: splitFocusedFromStack()
        case .chooseBestPick: chooseFocusedAsBestPick()
        case .toggleStacks: toggleStacksExpanded()
        case .closeShoot, .openFolder, .openSettings:
            return false
        }
        return true
    }

    /// Face boxes are on by default in stack review and compare, as in Eyes Closed: there the
    /// faces are what tells frames apart.
    var faceBoxGroup: GroupID {
        viewMode == .stackReview || viewMode == .compare ? .eyesClosed : group
    }

    /// The order the selection lives in: the grid's tiles in the grid, else the group's photos.
    var selectionOrder: PhotoOrder {
        viewMode == .grid ? gridOrder : order
    }

    /// The photos a decision applies to: the selection, or the focused photo. In the grid a
    /// collapsed stack is never among them: its frames are decided in stack review
    /// (`collapsedTargets`). In the review screens, the frame or copy on the left (the focus);
    /// in compare, the pane with the focus.
    var targets: [String] {
        switch viewMode {
        case .compare:
            return compareFocusedID.map { [$0] } ?? []
        case .stackReview, .duplicateReview:
            return focus.map { [$0] } ?? []
        case .grid:
            let raw = selection.targets(in: gridOrder)
            return collapsedStacks.isEmpty ? raw : raw.filter { collapsedStacks[$0] == nil }
        case .loupe:
            return selection.targets(in: order)
        }
    }

    /// Collapsed stacks among the grid's selection, by the photo their tile shows.
    var collapsedTargets: [String] {
        guard viewMode == .grid, !collapsedStacks.isEmpty else { return [] }
        return selection.targets(in: gridOrder).filter { collapsedStacks[$0] != nil }
    }

    // MARK: - Decisions

    /// P, X and U wherever they are pressed.
    private func decideAnywhere(_ decision: Decision) {
        switch viewMode {
        case .stackReview, .duplicateReview: decideInReview(decision)
        case .compare: decideInCompare(decision)
        case .grid, .loupe:
            let skipped = collapsedTargets.count
            if skipped > 0 { explainCollapsedStacks(skipped, decided: !targets.isEmpty) }
            decide(decision)
        }
    }

    private func decide(_ decision: Decision) {
        let timing = MainThreadTiming.begin("decide")
        defer { timing.end() }
        let targets = targets
        guard !targets.isEmpty else { return }
        // Asked before the change: the answer is the same, and the photos may leave the group.
        // In a defect group the decided photos stay in it, so the next one is the next undecided.
        let undecidedOnly = group.isDefectGroup
        let following = state.nextAfterDecision(on: targets, in: group, undecidedOnly: undecidedOnly)
        let advances = targets.count == 1 && settings.advanceAfterDecision
        let leftBefore = state.count(of: group).left
        let change = state.apply(.setDecision(decision, ids: targets))
        // The notes about new photos and the analysis summary have been seen once culling starts.
        mergeResult = nil
        dismissSummary()
        didChange(change)
        refreshOrder(fallback: following)
        noteCompletion(leftBefore: leftBefore)
        if advances, let following, let decided = targets.first {
            // Stay on the last photo rather than jump backwards, unless it left the view.
            let movesBack = (order.position(of: following) ?? 0) < (order.position(of: decided) ?? Int.max)
            if !movesBack || !order.contains(decided) {
                selection.select(following)
                normalizeGridFocus()
            }
        }
        scrollRevision += 1
        savePlace()
    }

    private func rate(_ stars: Int) {
        let targets = targets
        guard !targets.isEmpty else {
            if !collapsedTargets.isEmpty { explainCollapsedStacks(collapsedTargets.count, decided: false) }
            return
        }
        didChange(state.apply(.setRating(stars, ids: targets)))
        refreshOrder(fallback: nil)
    }

    @discardableResult
    func undo() -> [String] {
        let timing = MainThreadTiming.begin("undo")
        defer { timing.end() }
        let leftBefore = state.count(of: group).left
        guard let change = state.undo() else { return [] }
        didChange(change)
        refreshOrder(fallback: nil)
        reveal(change.changedIDs)
        noteCompletion(leftBefore: leftBefore)
        reviewChanged()
        return change.changedIDs
    }

    func redo() {
        let leftBefore = state.count(of: group).left
        guard let change = state.redo() else { return }
        didChange(change)
        refreshOrder(fallback: nil)
        reveal(change.changedIDs)
        noteCompletion(leftBefore: leftBefore)
        reviewChanged()
    }

    /// After a decision in a defect group: when its last undecided photo was just decided, the
    /// photo area says so and offers the next group; when one became undecided again, it stops.
    private func noteCompletion(leftBefore: Int) {
        let count = state.count(of: group)
        if group.isDefectGroup, count.total > 0, count.left == 0, leftBefore > 0 {
            completedGroup = group
        } else if count.left > 0, completedGroup != nil {
            completedGroup = nil
        }
    }

    /// The group to offer once the current one is done.
    var nextGroupToReview: GroupID? {
        _ = revision
        return ReviewGuide.nextGroupToReview(after: group, in: state)
    }

    /// The Undo menu item's title, such as "Undo Keep" or "Undo Accept Stack".
    var undoTitle: String {
        _ = revision
        if let edit = state.undoEdit { return edit.undoMenuTitle }
        // After an apply the decision history is empty: ⌘Z offers Undo Apply instead of nothing.
        if !apply.isOpen, let title = apply.undoMenuTitle { return localized("menu.withEllipsis", default: "\(title)…") }
        return SessionEdit.undoMenuTitle
    }

    var redoTitle: String {
        _ = revision
        return state.redoEdit.map(\.redoMenuTitle) ?? SessionEdit.redoMenuTitle
    }

    /// After undo or redo, shows the photos it changed, so the person sees what came back.
    private func reveal(_ ids: [String]) {
        switch viewMode {
        case .compare:
            return
        case .stackReview, .duplicateReview:
            // The first photo the step changed that is in a stack (or set) becomes current.
            let inReview = ids.first { viewMode == .stackReview ? state.stack(containing: $0) != nil : state.duplicateSet(containing: $0) != nil }
            if let inReview, order.contains(inReview) { selection.select(inReview) }
            scrollRevision += 1
            savePlace()
            return
        case .grid, .loupe:
            break
        }
        var visible = ids.filter { order.contains($0) }
        if viewMode == .grid, gridEntries != nil {
            // Frames of a collapsed stack show as its tile.
            var seen = Set<String>()
            visible = visible.compactMap { representative(of: $0) }.filter { seen.insert($0).inserted }
        }
        guard let first = visible.first else { return }
        if visible.count == 1 {
            selection.select(first)
        } else {
            selection = GridSelection(focus: first, selected: Set(visible))
        }
        scrollRevision += 1
        savePlace()
    }

    func didChange(_ change: SessionChange) {
        let timing = MainThreadTiming.begin("didChange")
        defer { timing.end() }
        revision += 1
        guard !change.isEmpty else { return }
        if !change.changedIDs.isEmpty {
            noteChanged(change.changedIDs)
            saver.saveMarks(state.marks(for: change.changedIDs))
        }
        if change.stackEditsChanged {
            // The stacks changed: their stars, counts and tiles may all look different.
            noteAllChanged()
            saver.saveStackEdits(state.stackEdits)
            analysis?.setManualBestPicks(state.handPickedBestPicks)
        }
    }

    private func noteChanged(_ ids: [String]) {
        marksRevision += 1
        changeLog.append((marksRevision, ids))
        if changeLog.count > Self.changeLogLimit { changeLog.removeFirst(changeLog.count - Self.changeLogLimit) }
    }

    /// Every photo may look different, such as after a regrouping: views redraw what they show.
    func noteAllChanged() {
        marksRevision += 1
        changeLog.removeAll()
    }

    private static let changeLogLimit = 200

    /// The photos whose tiles need redrawing because they changed after `revision` (a
    /// `marksRevision` the caller saw), or nil when that is too long ago to say: redraw all.
    func changedIDs(after revision: Int) -> Set<String>? {
        guard revision < marksRevision else { return [] }
        guard let first = changeLog.first, first.revision <= revision + 1 else { return nil }
        var ids = Set<String>()
        for entry in changeLog where entry.revision > revision { ids.formUnion(entry.ids) }
        return ids
    }

    /// Recomputes the photos of the current group after a change, keeping the selection on
    /// photos that are still shown.
    func refreshOrder(fallback: String?, reason: OrderChange = .decision) {
        let timing = MainThreadTiming.begin("refreshOrder")
        defer { timing.end() }
        let ids = state.members(of: group)
        let orderChanged = ids != order.ids
        let wasEmpty = order.isEmpty
        if orderChanged { order = PhotoOrder(ids) }
        let tilesChanged = rebuildEntries()
        if !orderChanged && !tilesChanged {
            restorePendingReviewPlace()
            return
        }
        orderChange = reason
        orderRevision += 1
        if viewMode == .grid { normalizeGridFocus() }
        if viewMode != .compare {
            selection.prune(to: selectionOrder, fallback: viewMode == .grid ? fallback.flatMap { representative(of: $0) } : fallback)
        }
        if wasEmpty, !order.isEmpty, reason == .refill {
            if let place = pendingPlace, !(place.viewMode.flatMap(ViewMode.init(rawValue:))?.isReview ?? false) || group.opening.opensReview {
                // Reopened in this group: back to the photo and view the person left.
                pendingPlace = nil
                viewChosenByHand = true
                selection.select(place.focusedPhotoID.flatMap { order.contains($0) ? $0 : nil } ?? order.ids.first)
                if place.viewMode == ViewMode.loupe.rawValue {
                    switchView(to: .loupe)
                } else if let mode = place.viewMode.flatMap(ViewMode.init(rawValue:)), mode.isReview {
                    resumeReview(mode)
                }
            } else {
                // The group was empty when opened and analysis has filled it: show it the way
                // the group opens, unless the person chose a view by hand meanwhile.
                selection.select(state.firstUndecided(in: group) ?? order.ids.first)
                if !viewChosenByHand { applyOpening() }
            }
            scrollRevision += 1
        } else {
            restorePendingReviewPlace()
        }
        reviewChanged()
    }

    /// A review screen saved in All Photos comes back once the stacks it showed are known.
    private func restorePendingReviewPlace() {
        guard let place = pendingPlace, let mode = place.viewMode.flatMap(ViewMode.init(rawValue:)), mode.isReview,
              let focus = place.focusedPhotoID, order.contains(focus)
        else { return }
        let ready = mode == .stackReview ? state.stack(containing: focus) != nil : state.duplicateSet(containing: focus) != nil
        guard ready else { return }
        pendingPlace = nil
        selection.select(focus)
        resumeReview(mode)
    }

    // MARK: - Moving and selecting

    func move(by offset: Int, extend: Bool = false) {
        let order = selectionOrder
        updateSelection(scroll: true) { $0.move(by: offset, extend: extend, in: order) }
    }

    /// ← and →: the next photo in the grid and the loupe, the next frame in stack review, the next
    /// copy in duplicate review, the next pane in compare.
    private func step(by offset: Int) {
        switch viewMode {
        case .grid, .loupe: move(by: offset)
        case .stackReview, .duplicateReview: stepWithinReview(by: offset)
        case .compare: stepComparePane(by: offset)
        }
    }

    /// ↑ and ↓: rows in the grid, stacks in stack review, sets in duplicate review.
    private func stepRow(forward: Bool) {
        switch viewMode {
        case .grid: move(by: forward ? gridColumns : -gridColumns)
        case .stackReview: stepStack(forward: forward)
        case .duplicateReview: stepSet(forward: forward)
        case .loupe, .compare: break
        }
    }

    /// Home and End.
    private func stepToEnd(first: Bool) {
        switch viewMode {
        case .stackReview, .duplicateReview:
            stepWithinReview(by: first ? -10_000 : 10_000)
        default:
            let order = selectionOrder
            updateSelection(scroll: true) { $0.move(to: first ? 0 : order.count - 1, extend: false, in: order) }
        }
    }

    func updateSelection(scroll: Bool = false, _ change: (inout GridSelection) -> Void) {
        let focusBefore = selection.focus
        change(&selection)
        if scroll { scrollRevision += 1 }
        if selection.focus != focusBefore { savePlace() }
    }

    /// A click on a tile.
    func click(_ id: String, kind: ClickKind) {
        let order = selectionOrder
        guard order.contains(id) else { return }
        updateSelection { $0.click(id, kind: kind, in: order) }
    }

    /// A rubber-band drag in the grid: selects the photos it covers, added to `base` (the
    /// selection when the drag began with Shift or Command held, else empty). The focus goes to the
    /// first photo covered.
    func selectBand(_ ids: [String], base: Set<String>) {
        let covered = ids.filter { selectionOrder.contains($0) }
        let selected = base.union(covered)
        guard let focus = covered.first ?? selection.focus else {
            if !selection.selected.isEmpty { selection = GridSelection() }
            return
        }
        let new = GridSelection(focus: focus, selected: selected.isEmpty ? [focus] : selected)
        if new != selection { updateSelection { $0 = new } }
    }

    /// A double click on a tile opens it in the loupe; on a collapsed stack, in stack review.
    func open(_ id: String) {
        if viewMode == .grid, collapsedStacks[id] != nil {
            selection.select(id)
            openStackReview(from: id)
            return
        }
        guard order.contains(id) else { return }
        selection.select(id)
        setViewMode(.loupe)
    }

    /// Opens a group in the view the Design doc gives it ("Opens in"): the loupe on the first
    /// undecided photo for the defect groups and Unreviewed, zoomed to the evidence for Eyes
    /// Closed and Blurry; the grid for the rest, keeping the focused photo when the group has it.
    func selectGroup(_ newGroup: GroupID) {
        guard newGroup != group else { return }
        openGroup(newGroup)
    }

    private func openGroup(_ newGroup: GroupID) {
        let timing = MainThreadTiming.begin("openGroup")
        defer { timing.end() }
        // Opening a group is starting to review: the summary has done its job.
        if summaryBanner != nil { dismissSummary() }
        group = newGroup
        pendingPlace = nil
        reviewOrigin = nil
        stackReviewDone = false
        duplicateReviewDone = false
        if viewMode == .compare { compareIDs = []; compareOrigin = nil }
        loupeOverlays.groupChanged()
        viewChosenByHand = false
        completedGroup = nil
        if tuningPanelGroup != nil, !newGroup.hasTuning { tuningPanelGroup = nil }
        if tuningPanelGroup != nil {
            tuningPanelGroup = newGroup
            tuningBaseline = TuningCounts(state)
            tuningBaselineTotal = state.count(of: newGroup).total
        }
        order = PhotoOrder(state.members(of: newGroup))
        rebuildEntries()
        orderChange = .newGroup
        orderRevision += 1
        if newGroup.opening.opensLoupe {
            selection.select(state.firstUndecided(in: newGroup) ?? order.ids.first)
        } else if let focus = selection.focus, order.contains(focus) {
            // Keep the focused photo when the new group has it, else start at the top.
            selection.select(representative(of: focus) ?? focus)
        } else {
            selection.select(gridOrder.ids.first)
        }
        applyOpening()
        scrollRevision += 1
        schedulePriority()
        savePlace()
    }

    /// Shows the current group the way it opens: the view, and the zoom to the evidence.
    private func applyOpening() {
        let opening = group.opening
        if order.isEmpty {
            if viewMode != .grid { switchView(to: .grid) }
            return
        }
        switch opening {
        case .stackReview:
            openFirstStack()
        case .duplicateReview:
            openFirstSet()
        case .grid:
            if viewMode != .grid { switchView(to: .grid) }
        case .loupe:
            if viewMode != .loupe { switchView(to: .loupe) }
            if opening.zoomsToEvidence {
                zoomToEvidence(factor: 1)
            } else if loupeZoom.isZoomed {
                setLoupeZoom(.fit)
            }
        }
    }

    /// Opens the first group, in the recommended order, that still has photos to review.
    func startReviewing() {
        dismissSummary()
        guard let next = ReviewGuide.firstGroupToReview(in: state) else { return }
        openGroup(next)
    }

    /// Opens the group offered after the current one was finished.
    func openNextGroupToReview() {
        guard let next = nextGroupToReview else { return }
        openGroup(next)
    }

    /// The next (or previous) group in sidebar order that has photos. All Photos always counts.
    func neighbourGroup(after forward: Bool) -> GroupID? {
        let groups = GroupID.allCases
        guard let index = groups.firstIndex(of: group) else { return nil }
        let candidates = forward ? Array(groups[(index + 1)...]) : Array(groups[..<index].reversed())
        return candidates.first { $0 == .allPhotos || state.count(of: $0).total > 0 }
    }

    /// A view switch the person asked for: it sticks while the group stays open.
    func setViewMode(_ mode: ViewMode) {
        guard mode != viewMode, mode != .compare else { return }
        viewChosenByHand = true
        if viewMode == .compare { leaveCompare() }
        guard mode != viewMode else { return }
        switchView(to: mode)
    }

    func switchView(to mode: ViewMode) {
        guard mode != viewMode, mode != .compare else { return }
        if mode == .loupe || mode.isReview {
            guard !order.isEmpty else { return }
            if selection.focus == nil || !order.contains(selection.focus!) { selection.select(order.ids.first) }
        }
        // The loupe opens fitted; zoom is sticky only while it stays open.
        if viewMode == .loupe, loupeZoom.isZoomed { setLoupeZoom(.fit) }
        if viewMode.isReview || viewMode == .compare {
            setReviewZoom(.fit)
            if !mode.isReview { reviewOrigin = nil }
        }
        if !mode.isReview {
            stackReviewDone = false
            duplicateReviewDone = false
        }
        let multiple = selection.selected.count > 1
        viewMode = mode
        if mode == .grid {
            normalizeGridFocus()
        } else if mode.isReview, multiple, let focus = selection.focus {
            selection.select(focus)
        }
        scrollRevision += 1
        savePlace()
    }

    func setInspectorVisible(_ visible: Bool) {
        inspectorVisible = visible
    }

    // MARK: - Loupe

    /// Sets the zoom for the loupe to apply.
    func setLoupeZoom(_ zoom: LoupeZoom) {
        loupeZoom = zoom
        if !zoom.isZoomed { loupeTargetFace = nil }
        loupeZoomRevision += 1
    }

    /// The loupe reports the zoom the person set by pinching, scrolling or dragging. Observers
    /// are not told; the loupe already shows it.
    func loupeViewChanged(_ zoom: LoupeZoom) {
        if !zoom.isZoomed, loupeTargetFace != nil { loupeTargetFace = nil }
        loupeZoom = zoom
    }

    /// The focused photo's main faces in the order Tab visits them.
    var loupeFaceOrder: [Int] {
        guard let id = focus else { return [] }
        return LoupeTarget.faceOrder(scores: state.photo(id)?.scores, summary: state.summary(for: id))
    }

    private func toggleZoom() {
        if loupeZoom.isZoomed {
            setLoupeZoom(.fit)
            return
        }
        zoomToEvidence(factor: 1)
    }

    /// Zooms the loupe to the focused photo's evidence: the most closed eyes in Eyes Closed, else
    /// the sharpest spot of the subject (the middle without scores).
    private func zoomToEvidence(factor: Double) {
        guard let id = focus else { return }
        let target = LoupeTarget.zoomTarget(scores: state.photo(id)?.scores, summary: state.summary(for: id), group: group)
        setLoupeZoom(.zoomed(factor: factor, centre: target.point))
        loupeTargetFace = target.face
    }

    /// In Eyes Closed and Blurry a zoomed loupe moves to each photo's own evidence as the focus
    /// moves, rather than keeping the same spot as elsewhere.
    private func followEvidence() {
        guard group.opening.zoomsToEvidence, viewMode == .loupe, let factor = loupeZoom.factor else { return }
        zoomToEvidence(factor: factor)
    }

    private func stepFace(forward: Bool) {
        guard let id = focus, let scores = state.photo(id)?.scores, case .zoomed(let factor, _) = loupeZoom else { return }
        let order = LoupeTarget.faceOrder(scores: scores, summary: state.summary(for: id))
        guard let face = LoupeTarget.step(from: loupeTargetFace, in: order, forward: forward) else { return }
        setLoupeZoom(.zoomed(factor: factor, centre: LoupeTarget.eyePoint(of: scores.faces[face])))
        loupeTargetFace = face
    }

    // MARK: - Files

    /// A thumbnail could not be made. When the folder is still there the file is unreadable;
    /// when the folder is gone, the drive or card was disconnected and nothing is marked.
    func thumbnailFailed(for id: String, error: any Error) {
        guard let item = state.photo(id), !item.isUnreadable else { return }
        // A folder already known to be gone: the file is not at fault, and its tile loads again
        // when the folder is back.
        if folderMissing {
            thumbnailsAwaitingFolder.insert(id)
            return
        }
        let folder = folder
        let file = item.file
        let thumbnails = thumbnails
        Task {
            // A folder that cannot be listed means a disconnected card or drive, not a bad file.
            if await !ShootDiskMonitor.reachable(folder) {
                thumbnailsAwaitingFolder.insert(id)
                disk?.checkNow()
                // A folder back before the monitor saw it go is never reported as back: look again shortly.
                if !folderMissing { retryAwaitingThumbnailsSoon() }
                return
            }
            // The folder may have come back between the failure and the check: one more try
            // tells a bad file from a card pulled and put back.
            if (try? await thumbnails.thumbnail(for: file)) != nil {
                noteChanged([id])
                return
            }
            if folderMissing {
                thumbnailsAwaitingFolder.insert(id)
                return
            }
            guard state.photo(id)?.isUnreadable == false else { return }
            state.markUnreadable(id, reason: Self.reason(for: error))
            revision += 1
            noteChanged([id])
            refreshOrder(fallback: state.nextAfterDecision(on: [id], in: group))
        }
    }

    static func reason(for error: any Error) -> String {
        if let error = error as? ImageLoaderError {
            switch error {
            case .cannotOpen: return localized("The file is not an image Culla can open.")
            case .cannotDecode: return localized("The image data is damaged or incomplete.")
            case .cannotWrite: return localized("The thumbnail could not be saved.")
            }
        }
        return error.localizedDescription
    }

    // MARK: - Files of photos

    /// Shows the photos' files in the Finder.
    func revealInFinder(_ ids: [String]) {
        let urls = ids.compactMap { state.photo($0)?.file.url }
        guard !urls.isEmpty else { return }
        #if DEBUG
        // Automation never opens Finder windows in front of the person; it records the request.
        if AutomationRunner.isActive {
            lastFileAction = "reveal: " + urls.map(\.lastPathComponent).joined(separator: ", ")
            return
        }
        #endif
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The last Reveal in Finder or Copy File Name, for the automation harness.
    @ObservationIgnored private(set) var lastFileAction: String?

    /// Puts the photos' file names on the pasteboard, one per line.
    func copyFileNames(_ ids: [String]) {
        let names = ids.compactMap { state.photo($0)?.file.name }
        guard !names.isEmpty else { return }
        var pasteboard = NSPasteboard.general
        #if DEBUG
        // Automation keeps away from the person's clipboard.
        if AutomationRunner.isActive {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("com.kpirliyev.Culla.automation"))
            lastFileAction = "copy: " + names.joined(separator: ", ")
        }
        #endif
        pasteboard.clearContents()
        pasteboard.setString(names.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Analysis

    /// Starts the background analysis of the shoot. Called once, right after the shoot opens.
    func startAnalysis(database: CullaDatabase, power: PowerMonitor, openStartedAt: Date) {
        guard analysis == nil else { return }
        let controller = AnalysisController(model: self, database: database, settings: settings, power: power, openStartedAt: openStartedAt)
        analysis = controller
        controller.start()
        schedulePriority()
    }

    /// Stops analysis; results already received are saved first. Called when the shoot closes.
    func stopAnalysis() async {
        await analysis?.cancel()
    }

    /// Scores and unreadable files from analysis: groups, counts, badges and the loupe follow at
    /// once. Decisions, the focus, the selection and what the grid shows stay as they are.
    func applyAnalysis(scores: [String: PhotoScores], unreadable: [String: String]) {
        let timing = MainThreadTiming.begin("applyAnalysis")
        defer { timing.end() }
        var changed: [String] = []
        changed.reserveCapacity(scores.count + unreadable.count)
        for (id, value) in scores where !pinnedScoreIDs.contains(id) {
            if state.setScores(value, for: id) { changed.append(id) }
        }
        // Files that failed because the folder went away are not unreadable.
        let reachable = unreadable.isEmpty || (!folderMissing && ShootDiskMonitor.isReachable(folder.path))
        if !reachable { disk?.checkNow() }
        for (id, reason) in unreadable where reachable && !pinnedScoreIDs.contains(id) {
            if state.markUnreadable(id, reason: reason) { changed.append(id) }
        }
        guard !changed.isEmpty else { return }
        revision += 1
        noteChanged(changed)
        refreshOrder(fallback: selection.focus.flatMap { state.nextAfterDecision(on: [$0], in: group) }, reason: .refill)
    }

    /// Stacks with their best picks and duplicate sets, computed by analysis.
    func applyGrouping(_ grouping: SessionGrouping) {
        let timing = MainThreadTiming.begin("applyGrouping")
        defer { timing.end() }
        state.applyGrouping(grouping)
        #if DEBUG
        repickStacksWithInjectedScores()
        #endif
        revision += 1
        noteAllChanged()
        refreshOrder(fallback: selection.focus.flatMap { state.nextAfterDecision(on: [$0], in: group) }, reason: .refill)
    }

    /// Analysis ended. The summary banner shows when something was analysed in this open; a shoot
    /// whose scores all came from the cache does not show it again.
    func analysisFinished(analysedSomething: Bool) {
        // Once per open: later work (a rescan's new photos) finishes quietly.
        guard analysedSomething, !summaryDismissed, !summaryShown else { return }
        summaryShown = true
        summaryBanner = AnalysisSummary(state)
    }

    func dismissSummary() {
        summaryDismissed = true
        summaryBanner = nil
    }

    /// Scores made up by the automation harness. They stand until the shoot closes: analysis
    /// results for these photos are ignored, and nothing is saved. Nil removes a photo's scores.
    func injectScores(_ scores: [String: PhotoScores?]) {
        var changed: [String] = []
        for (id, value) in scores where state.setScores(value, for: id) {
            pinnedScoreIDs.insert(id)
            changed.append(id)
        }
        guard !changed.isEmpty else { return }
        #if DEBUG
        if repickStacksWithInjectedScores() { noteAllChanged() }
        #endif
        revision += 1
        noteChanged(changed)
        refreshOrder(fallback: selection.focus.flatMap { state.nextAfterDecision(on: [$0], in: group) }, reason: .refill)
    }

    #if DEBUG
    /// Analysis chooses best picks from the scores it measured, which the harness's made-up
    /// scores never reach: stacks holding injected photos get the pick `BestPick` makes from the
    /// scores the session now has, as analysis would. Hand-chosen picks stay. Returns true when a
    /// pick changed.
    @discardableResult
    private func repickStacksWithInjectedScores() -> Bool {
        guard !pinnedScoreIDs.isEmpty else { return false }
        var stacks = state.automaticStacks
        var changed = false
        for index in stacks.indices where stacks[index].members.contains(where: pinnedScoreIDs.contains) {
            let members = stacks[index].members
            let candidates = members.compactMap { id in state.photo(id)?.scores.map { BestPickCandidate(scores: $0, tuning: state.tuning) } }
            guard candidates.count == members.count, let best = BestPick.best(candidates, tuning: state.tuning) else { continue }
            if stacks[index].bestPick != members[best] {
                stacks[index].bestPick = members[best]
                changed = true
            }
        }
        if changed { state.setStacks(stacks) }
        return changed
    }
    #endif

    /// The grid reports the photos of the tiles on screen, for analysis priority.
    func reportVisible(_ ids: [String]) {
        guard ids != visibleIDs else { return }
        visibleIDs = ids
        schedulePriority()
    }

    /// Tells analysis what to do first, a moment after the view settles: the tiles on screen (or
    /// the loupe's photo and its neighbours), then the rest of the open group. Only photos still
    /// without scores are named.
    private func schedulePriority() {
        guard let analysis, analysis.isRunning || analysis.isPaused else { return }
        priorityTask?.cancel()
        priorityTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self else { return }
            self.analysis?.prioritize(self.priorityList())
        }
    }

    private func priorityList() -> [String] {
        var first: [String] = []
        if viewMode == .stackReview {
            first = currentStack?.members ?? []
            if let focus, let next = state.nextUndecidedStack(after: focus) { first += next.members }
        } else if viewMode == .duplicateReview {
            first = currentSet?.members ?? []
        } else if viewMode == .compare {
            first = compareIDs
        } else if viewMode == .loupe, let focus, let position = order.position(of: focus) {
            let ids = order.ids
            let ahead = ids[position..<min(ids.count, position + 12)]
            let behind = ids[max(0, position - 4)..<position].reversed()
            first = Array(ahead) + Array(behind)
        } else {
            first = visibleIDs
        }
        let state = state
        func waiting(_ id: String) -> Bool {
            guard let item = state.photo(id) else { return false }
            return item.scores == nil && !item.isUnreadable
        }
        var seen = Set<String>()
        var result: [String] = []
        for id in first where waiting(id) && seen.insert(id).inserted { result.append(id) }
        // The rest of the open group, unless it is the whole shoot (capture order does that).
        if group != .allPhotos {
            for id in order.ids where result.count < 5_000 && waiting(id) && seen.insert(id).inserted {
                result.append(id)
            }
        }
        return result
    }

    /// Why the current group is empty, for the photo area's one line.
    var emptyReason: EmptyReason {
        let session = session
        if session.count == 0 { return .noPhotos }
        if group == .unreviewed { return .allDecided }
        guard group.needsAnalysis else { return .nothingYet }
        guard let analysis else { return hasAnalysis ? .noneFound(checked: session.count) : .notAnalysedYet }
        let progress = analysis.progress
        let checked = progress.done + progress.cached
        let total = progress.total + progress.cached
        switch analysis.phase {
        case .finished: return .noneFound(checked: session.count)
        case .paused: return checked == 0 ? .notAnalysedYet : .analysisPaused(done: checked, total: max(total, checked))
        case .starting, .running: return .stillAnalysing(done: checked, total: max(total, session.count))
        case .cancelled: return .notAnalysedYet
        }
    }

    // MARK: - Bulk reject

    /// ⇧X: asks to reject every undecided Certain photo of the defect group, or says there are none.
    private func requestBulkReject() {
        guard group.isDefectGroup else { return }
        let ids = state.undecidedCertainMembers(of: group)
        guard !ids.isEmpty else {
            showNotice(BulkReject.noneMessage(group: group), symbol: "checkmark.circle")
            return
        }
        let request = BulkRejectRequest(group: group, ids: ids)
        lastBulkRejectQuestion = request.question
        bulkRejectRequest = request
    }

    /// The person confirmed ⇧X: one undo step rejects them all.
    func confirmBulkReject() {
        guard let request = bulkRejectRequest else { return }
        bulkRejectRequest = nil
        // Only photos that are still undecided and Certain, in case anything changed meanwhile.
        let still = Set(state.undecidedCertainMembers(of: request.group))
        let ids = request.ids.filter { still.contains($0) }
        guard !ids.isEmpty else { return }
        let leftBefore = state.count(of: group).left
        let following = state.nextAfterDecision(on: ids, in: group, undecidedOnly: true)
        let change = state.apply(.setDecision(.rejected, ids: ids))
        mergeResult = nil
        didChange(change)
        refreshOrder(fallback: following)
        if let following {
            selection.select(following)
        } else if let focus, !order.contains(focus) {
            selection.select(order.ids.first)
        }
        noteCompletion(leftBefore: leftBefore)
        showNotice(localized("Rejected \(ids.count) photos.") + " " + KeyText.undoSentence(.takesItBack, in: settings.keyBindings), symbol: "xmark.circle")
        scrollRevision += 1
        savePlace()
    }

    func cancelBulkReject() {
        bulkRejectRequest = nil
    }

    // MARK: - Notices

    func showNotice(_ text: String, symbol: String) {
        notice = TransientNotice(text: text, symbol: symbol)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func dismissCompletion() {
        completedGroup = nil
    }

    // MARK: - Tuning

    func toggleTuningPanel() {
        if tuningPanelGroup != nil {
            closeTuningPanel()
        } else {
            openTuningPanel()
        }
    }

    func openTuningPanel() {
        guard group.hasTuning else { return }
        tuningBaseline = TuningCounts(state)
        tuningBaselineTotal = state.count(of: group).total
        tuningPanelGroup = group
    }

    func closeTuningPanel() {
        tuningPanelGroup = nil
    }

    /// The numbers the tuning panel shows now.
    /// Counted once per change of the session: the panel and every count line of a Settings pane
    /// read it, and each count is a pass over every photo (about 4 ms on 10,000).
    var tuningCounts: TuningCounts {
        _ = revision
        if let cached = ownCounts, cached.revision == revision { return cached.counts }
        let counts = MainThreadTiming.measure("tuningCounts") { TuningCounts(state) }
        ownCounts = (revision, counts)
        return counts
    }
    @ObservationIgnored private var ownCounts: (revision: Int, counts: TuningCounts)?

    /// True while stacks or duplicate sets are being recomputed for a new tuning.
    var isRegrouping: Bool {
        analysis?.groupingPending ?? false
    }

    // The tuning model: Settings holds the default (`AppSettings.defaultTuning`). A shoot
    // follows the default, and every change to it, until it is adjusted from its tuning panel;
    // from then on it has its own tuning, saved with its session and kept across reopening,
    // until Save as Default makes it the default or Reset to Default drops it.

    /// True when this shoot was adjusted from its tuning panel and no longer follows the default.
    private(set) var hasOwnTuning = false

    /// The tuning panel and the harness's `tuning` step: changes this shoot's detection settings
    /// only. Flags regroup at once from the stored scores, stacks and duplicate sets are
    /// recomputed off the main thread, nothing is analysed again and no decision changes. The
    /// tuning is saved with the session; the default is untouched.
    func setTuning(_ tuning: Tuning) {
        guard tuning != state.tuning else { return }
        applyTuning(tuning)
        let own = tuning != settings.defaultTuning
        hasOwnTuning = own
        saver.saveTuning(own ? tuning : nil)
    }

    /// Sets one value, snapped to its control's step when it has one.
    func setTuningValue(_ key: TuningKey, _ value: Double) {
        var tuning = state.tuning
        key.set(value, in: &tuning)
        setTuning(tuning)
    }

    /// A group's controls back to the default's values, for this shoot.
    func resetTuning(for group: GroupID) {
        setTuning(TuningControl.resetting(group, in: state.tuning, to: settings.defaultTuning))
    }

    /// "Reset to Default" in the tuning panel: the shoot follows the default again.
    func resetTuningToDefault() {
        applyTuning(settings.defaultTuning)
        guard hasOwnTuning else { return }
        hasOwnTuning = false
        saver.saveTuning(nil)
    }

    /// "Save as Default" in the tuning panel: this shoot's tuning becomes the default for every
    /// shoot that follows it and for shoots opened from now on.
    func saveTuningAsDefault() {
        settings.defaultTuning = state.tuning
        if hasOwnTuning {
            hasOwnTuning = false
            saver.saveTuning(nil)
        }
    }

    /// The default changed in Settings: a shoot that follows it changes with it.
    func defaultTuningChanged() {
        if !hasOwnTuning {
            applyTuning(settings.defaultTuning)
        } else if state.tuning == settings.defaultTuning {
            hasOwnTuning = false
            saver.saveTuning(nil)
        }
    }

    /// Puts a tuning into effect: regroups, counts and the photo area follow at once.
    private func applyTuning(_ tuning: Tuning) {
        let timing = MainThreadTiming.begin("applyTuning")
        defer { timing.end() }
        guard tuning != state.tuning else { return }
        state.tuning = tuning
        analysis?.setTuning(tuning)
        revision += 1
        noteAllChanged()
        refreshOrder(fallback: selection.focus.flatMap { state.nextAfterDecision(on: [$0], in: group) }, reason: .refill)
        if completedGroup != nil, state.count(of: group).left > 0 { completedGroup = nil }
    }

    /// The counts a tuning other than the shoot's would give on this shoot's scores: what
    /// Settings shows while the shoot has its own tuning. Flags only; stacks and duplicate sets
    /// are not recomputed for it.
    func counts(for tuning: Tuning) -> TuningCounts {
        _ = revision
        if tuning == state.tuning { return tuningCounts }
        if let cached = otherCounts, cached.revision == revision, cached.tuning == tuning { return cached.counts }
        var copy = state
        copy.tuning = tuning
        let counts = TuningCounts(copy)
        otherCounts = (revision, tuning, counts)
        return counts
    }
    @ObservationIgnored private var otherCounts: (revision: Int, tuning: Tuning, counts: TuningCounts)?

    /// Shows every frame in All Photos, or collapses the stacks (Settings ▸ General).
    func setStacksExpanded(_ expanded: Bool) {
        guard stacksExpanded != expanded else { return }
        toggleStacksExpanded()
    }

    // MARK: - Place

    var place: SessionPlace {
        // Compare is never come back to; where it came from is.
        let mode = viewMode == .compare ? (compareOrigin?.viewMode ?? .grid) : viewMode
        return SessionPlace(group: group.rawValue, focusedPhotoID: selection.focus, viewMode: mode.rawValue)
    }

    func savePlace() {
        saver.savePlace(place)
    }
}
