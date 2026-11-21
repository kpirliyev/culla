import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaSession
import Foundation

/// What the right pane of stack review shows.
enum PickPaneRole: Equatable {
    /// The stack's best pick, beside the current frame.
    case bestPick
    /// The current frame is the pick: the right pane shows the runner-up instead, so the same
    /// picture never shows twice.
    case runnerUp
}

// Stack review, duplicate review, compare, collapsed stacks in the grid and stack edits.
//
// Rules the Design leaves open, decided here:
// - Stack review keeps the focus on the current frame; ← → move along the stack only, P X U
//   decide it and move to the next frame of the same stack, ↓ goes to the next stack with an
//   Unreviewed frame (else the next stack), ↑ to the previous stack.
// - Return accepts the stack and opens the next undecided one, coming round to stacks skipped
//   with ↓; when none is left the screen says so and offers the next group. A stack opened from
//   another group's grid or loupe (Return or a double click on its tile) goes back there once
//   accepted, and on Escape.
// - When the current frame is the pick, the right pane shows the runner-up (Culla's next best
//   frame), labelled as such.
// - In the grid, a collapsed stack is never decided by P, X, U or a rating: those act on the
//   single photos of the selection and say how many stacks they left alone. Return or a double
//   click opens the stack in stack review. G joins whatever is selected, collapsed stacks
//   included (joining two stacks merges them); ⇧G and ⇧S need a single frame, so they ask for
//   the stack to be opened.
extension SessionModel {
    // MARK: - Collapsed stacks in the grid

    /// True when the grid shows each stack as one tile: All Photos, unless expanded with S.
    var collapsesStacks: Bool {
        SessionState.collapsesStacks(in: group) && !stacksExpanded && !state.stacks.isEmpty
    }

    /// Rebuilds the grid's tiles. Returns true when the tiles (not just their looks) changed.
    @discardableResult
    func rebuildEntries() -> Bool {
        guard collapsesStacks else {
            let changed = gridEntries != nil || gridOrder.ids != order.ids
            gridEntries = nil
            collapsedStacks = [:]
            if gridOrder.ids != order.ids { gridOrder = order }
            return changed
        }
        let entries = state.gridEntries(of: group, collapsingStacks: true)
        var stacks: [String: CollapsedStack] = [:]
        var representatives: [String] = []
        representatives.reserveCapacity(entries.count)
        for entry in entries.entries {
            representatives.append(entry.representative)
            if case .stack(let stack) = entry { stacks[stack.representative] = stack }
        }
        collapsedStacks = stacks
        gridEntries = entries
        guard representatives != gridOrder.ids else { return false }
        gridOrder = PhotoOrder(representatives)
        return true
    }

    /// The photo whose tile shows this photo in the grid: itself, or its collapsed stack's
    /// representative. Nil when the grid does not show it.
    func representative(of id: String) -> String? {
        guard let entries = gridEntries else { return order.contains(id) ? id : nil }
        if gridOrder.contains(id) { return id }
        return state.entryIndex(containing: id, in: entries).map { entries[$0].representative }
    }

    /// In the grid, a focused frame of a collapsed stack moves to the stack's tile, and selected
    /// frames to theirs.
    func normalizeGridFocus() {
        guard viewMode == .grid, gridEntries != nil else { return }
        let selected = selection.selected.compactMap { representative(of: $0) }
        guard let focus = selection.focus, !gridOrder.contains(focus) || selected.count != selection.selected.count
                || selection.selected.contains(where: { !gridOrder.contains($0) })
        else { return }
        let target = representative(of: focus)
        if Set(selected).count > 1 {
            selection = GridSelection(focus: target ?? selected.first, selected: Set(selected))
        } else {
            selection.select(target)
        }
    }

    /// S: shows every frame of the stacks in All Photos, or collapses them again.
    func toggleStacksExpanded() {
        stacksExpanded.toggle()
        let focus = selection.focus
        rebuildEntries()
        orderChange = .newGroup
        orderRevision += 1
        if stacksExpanded {
            // The tile's photo stays focused, now as a frame of its own.
            selection.select(focus)
        } else {
            normalizeGridFocus()
        }
        scrollRevision += 1
        let collapseKey = settings.keyBindings.primaryChord(for: .toggleStacks)?.displayString
        showNotice(stacksExpanded
            ? (collapseKey.map { localized("Showing every frame of the stacks. \($0) collapses them again.") }
                ?? localized("Showing every frame of the stacks."))
            : localized("Stacks collapsed to one tile each."), symbol: "square.stack.3d.up")
    }

    /// A key that marks photos was pressed with collapsed stacks selected: they are left alone,
    /// and the person is told how to decide their frames.
    func explainCollapsedStacks(_ count: Int, decided: Bool) {
        let open = settings.keyBindings.primaryChord(for: .acceptStack)?.displayString ?? localized("key.return", default: "Return")
        if decided {
            showNotice(localized("notice.leftCollapsedStacks", default: "Left \(count) collapsed stacks undecided: open a stack with \(open) to decide its frames."),
                       symbol: "square.stack.3d.up")
        } else {
            showNotice(localized("A collapsed stack is decided frame by frame: press \(open) to review it."), symbol: "square.stack.3d.up")
        }
    }

    // MARK: - Current stack and set

    var currentStack: PhotoStack? {
        guard let focus else { return nil }
        return state.stack(containing: focus)
    }

    var currentSet: PhotoDuplicateSet? {
        guard let focus else { return nil }
        return state.duplicateSet(containing: focus)
    }

    /// The face strip of the current stack, kept until the session changes.
    var currentFaceStrip: FaceStrip? {
        guard let focus else { return nil }
        return faceStrip(forPhoto: focus)
    }

    /// The face strip of a photo's stack; for a photo in no stack, the photo alone (one column).
    func faceStrip(forPhoto id: String) -> FaceStrip {
        let frames = state.stack(containing: id)?.members ?? [id]
        let key = frames.joined(separator: "\u{1}")
        if let cache = faceStripCache, cache.key == key, cache.revision == revision { return cache.strip }
        let strip = state.faceStrip(frames: frames)
        faceStripCache = (key, revision, strip)
        return strip
    }

    /// The photos the two panes show: the current frame, and the pick (or the runner-up when the
    /// current frame is the pick).
    var stackPanes: (current: String, other: String?, role: PickPaneRole)? {
        guard let focus, let stack = currentStack else { return nil }
        if let pick = stack.bestPick, pick != focus { return (focus, pick, .bestPick) }
        return (focus, StackReview.runnerUp(of: stack, state: state), stack.bestPick == focus ? .runnerUp : .bestPick)
    }

    // MARK: - Opening

    /// Similar Stacks opens on the first stack with an Unreviewed frame; with none left, on the
    /// first stack, saying everything is decided.
    func openFirstStack() {
        if let stack = state.nextUndecidedStack() ?? state.stacks.first {
            selection.select(StackReview.openingFrame(of: stack, state: state))
            stackReviewDone = state.nextUndecidedStack() == nil
        }
        reviewOrigin = nil
        if currentStack == nil {
            if viewMode != .grid { switchView(to: .grid) }
            return
        }
        if viewMode != .stackReview { switchView(to: .stackReview) }
        setReviewZoom(.fit)
        prefetchAroundStack()
    }

    /// Return or a double click on a stack outside Similar Stacks: opens it in stack review, and
    /// comes back here once it is accepted or on Escape.
    func openStackReview(from id: String) {
        guard let stack = state.stack(containing: id) else { return }
        reviewOrigin = ReviewOrigin(viewMode: viewMode, selection: selection)
        selection.select(StackReview.openingFrame(of: stack, state: state))
        stackReviewDone = false
        let origin = reviewOrigin
        switchView(to: .stackReview)
        reviewOrigin = origin
        setReviewZoom(.fit)
        prefetchAroundStack()
    }

    /// Duplicates opens on the first set with an Unreviewed copy, on the copy Culla would keep.
    func openFirstSet() {
        if let set = state.nextUndecidedDuplicateSet() ?? state.duplicateSets.first {
            selection.select(openingCopy(of: set))
            duplicateReviewDone = state.nextUndecidedDuplicateSet() == nil
        }
        if currentSet == nil {
            if viewMode != .grid { switchView(to: .grid) }
            return
        }
        if viewMode != .duplicateReview { switchView(to: .duplicateReview) }
        setReviewZoom(.fit)
        prefetchSet()
    }

    /// A review screen saved when the shoot was closed comes back.
    func resumeReview(_ mode: ViewMode) {
        switch mode {
        case .stackReview:
            guard let stack = currentStack else { return openFirstStack() }
            stackReviewDone = state.nextUndecidedStack() == nil && state.isDecided(stackAt: state.stackIndex(containing: stack.id) ?? 0)
            switchView(to: .stackReview)
        case .duplicateReview:
            guard currentSet != nil else { return openFirstSet() }
            duplicateReviewDone = state.nextUndecidedDuplicateSet() == nil
            switchView(to: .duplicateReview)
        default:
            break
        }
    }

    private func openingCopy(of set: PhotoDuplicateSet) -> String? {
        state.duplicatePick(forSetContaining: set.id)?.id ?? set.members.first
    }

    func showStack(_ stack: PhotoStack, startedAt: CFTimeInterval = CACurrentMediaTime()) {
        reviewActionAt = ("stack", startedAt)
        stackReviewDone = false
        selection.select(StackReview.openingFrame(of: stack, state: state))
        // A new burst is another scene: back to fit.
        setReviewZoom(.fit)
        savePlace()
        prefetchAroundStack()
    }

    func showSet(_ set: PhotoDuplicateSet) {
        duplicateReviewDone = false
        selection.select(openingCopy(of: set))
        setReviewZoom(.fit)
        savePlace()
        prefetchSet()
    }

    /// A click on a copy in duplicate review.
    func selectCopy(at index: Int) {
        guard viewMode == .duplicateReview, let members = currentSet?.members, members.indices.contains(index) else { return }
        duplicateReviewDone = false
        selection.select(members[index])
        savePlace()
    }

    // MARK: - Moving in the review screens

    func stepWithinReview(by offset: Int) {
        let members = viewMode == .stackReview ? currentStack?.members : currentSet?.members
        guard let focus, let members, let index = members.firstIndex(of: focus) else { return }
        if viewMode == .stackReview { stackReviewDone = false } else { duplicateReviewDone = false }
        let target = min(max(index + offset, 0), members.count - 1)
        guard target != index else { return }
        reviewActionAt = ("frame", CACurrentMediaTime())
        selection.select(members[target])
        savePlace()
    }

    /// A click on a frame of stack review's filmstrip: it becomes the current frame.
    func selectFrame(_ id: String) {
        guard viewMode == .stackReview, currentStack?.members.contains(id) == true, id != focus else { return }
        stackReviewDone = false
        reviewActionAt = ("frame", CACurrentMediaTime())
        selection.select(id)
        savePlace()
    }

    func stepStack(forward: Bool) {
        guard let focus else { return }
        if stackReviewDone {
            // The end card gives way to the stack behind it.
            stackReviewDone = false
            return
        }
        let next = forward
            ? (state.nextUndecidedStack(after: focus) ?? state.nextStack(after: focus))
            : state.previousStack(before: focus)
        guard let next else {
            showNotice(forward ? localized("This is the last stack.") : localized("This is the first stack."), symbol: "square.stack.3d.up")
            return
        }
        showStack(next)
    }

    func stepSet(forward: Bool) {
        guard let focus else { return }
        if duplicateReviewDone {
            duplicateReviewDone = false
            return
        }
        let next = forward
            ? (state.nextUndecidedDuplicateSet(after: focus) ?? state.nextDuplicateSet(after: focus))
            : state.previousDuplicateSet(before: focus)
        guard let next else {
            showNotice(forward ? localized("This is the last set.") : localized("This is the first set."), symbol: "plus.square.on.square")
            return
        }
        showSet(next)
    }

    // MARK: - Deciding in the review screens

    /// P, X and U in stack review decide the current frame and move to the next frame of the same
    /// stack; in duplicate review they decide the copy and move to the next copy.
    func decideInReview(_ decision: Decision) {
        guard let id = focus else { return }
        let members = (viewMode == .stackReview ? currentStack?.members : currentSet?.members) ?? []
        let change = state.apply(.setDecision(decision, ids: [id]))
        mergeResultSeen()
        didChange(change)
        refreshOrder(fallback: nil)
        if settings.advanceAfterDecision, let index = members.firstIndex(of: id), index + 1 < members.count,
           order.contains(members[index + 1]) {
            selection.select(members[index + 1])
        }
        savePlace()
    }

    /// Return: accepts the stack or set on screen, or opens the focused photo's stack.
    func accept() {
        switch viewMode {
        case .stackReview: acceptStack()
        case .duplicateReview: acceptSet()
        case .grid, .loupe:
            guard let focus else { return }
            openStackReview(from: focus)
        case .compare: break
        }
    }

    private func acceptStack() {
        guard let id = focus, currentStack != nil else { return }
        let started = CACurrentMediaTime()
        if stackReviewDone {
            // Everything is decided: Return takes the offer of the next group.
            if nextGroupToReview != nil { openNextGroupToReview() }
            return
        }
        let change = state.acceptStack(containing: id)
        mergeResultSeen()
        didChange(change)
        refreshOrder(fallback: nil)
        if let origin = reviewOrigin {
            // Back to where the stack was opened from, on the stack's tile.
            reviewOrigin = nil
            returnFrom(origin, focusing: id)
            return
        }
        if let next = StackReview.stackAfterAccepting(id, state: state) {
            showStack(next, startedAt: started)
        } else {
            stackReviewDone = true
            savePlace()
        }
    }

    private func acceptSet() {
        guard let id = focus, currentSet != nil else { return }
        if duplicateReviewDone {
            if nextGroupToReview != nil { openNextGroupToReview() }
            return
        }
        let change = state.acceptDuplicateSet(containing: id)
        mergeResultSeen()
        didChange(change)
        refreshOrder(fallback: nil)
        if let next = state.nextUndecidedDuplicateSet(after: id, wrapping: true) {
            showSet(next)
        } else {
            duplicateReviewDone = true
            savePlace()
        }
    }

    /// Accept All Exact Duplicates: every byte-identical set still undecided, as one undo step.
    /// Near-duplicates are never touched.
    func acceptAllExactDuplicates() {
        let result = state.acceptAllExactDuplicates()
        guard !result.change.isEmpty else { return }
        mergeResultSeen()
        didChange(result.change)
        refreshOrder(fallback: nil)
        let rejected = result.change.changedIDs.count { state.photo($0)?.decision == .rejected }
        lastBulkAccept = (result.sets, rejected)
        let bulk = DuplicateReview.bulkResult(sets: result.sets, rejected: rejected)
        let undo = KeyText.undoSentence(.takesItBack, in: settings.keyBindings)
        showNotice(bulk + " " + undo, symbol: "checkmark.circle")
        if viewMode == .duplicateReview, let id = focus, state.isDuplicateSetDecided(containing: id) {
            if let next = state.nextUndecidedDuplicateSet(after: id, wrapping: true) {
                showSet(next)
            } else {
                duplicateReviewDone = true
            }
        }
        savePlace()
    }

    // MARK: - Correcting stacks

    /// G: puts the selected photos in one stack; collapsed stacks among them join with every frame.
    func addSelectionToStack() {
        let ids = selection.targets(in: gridOrder)
        let before = ids.compactMap { state.stack(containing: $0)?.members.count }.max() ?? 0
        let change = state.addToStack(ids)
        guard !change.isEmpty else {
            if ids.count < 2 {
                showNotice(localized("Select two or more photos to put them in one stack."), symbol: "square.stack.3d.up")
            } else {
                showNotice(localized("These photos are already one stack."), symbol: "square.stack.3d.up")
            }
            return
        }
        didChange(change)
        refreshOrder(fallback: nil)
        let frames = ids.first.flatMap { state.stack(containing: $0)?.members.count } ?? max(before, ids.count)
        if let first = ids.first, let tile = representative(of: first) { selection.select(tile) }
        normalizeGridFocus()
        scrollRevision += 1
        showNotice(localized("Made one stack of \(frames) frames.") + " " + KeyText.undoSentence(.takesItBack, in: settings.keyBindings), symbol: "square.stack.3d.up")
        savePlace()
    }

    /// ⇧G: takes the focused frame out of its stack, back to Unreviewed.
    func splitFocusedFromStack() {
        guard let id = focus, let stack = state.stack(containing: id), let index = stack.members.firstIndex(of: id) else { return }
        if viewMode == .grid, collapsedStacks[id] != nil {
            let open = settings.keyBindings.primaryChord(for: .acceptStack)?.displayString ?? localized("key.return", default: "Return")
            showNotice(localized("Open the stack with \(open) to split one of its frames out."), symbol: "square.stack.3d.up")
            return
        }
        let neighbours = Array(stack.members[(index + 1)...]) + stack.members[..<index].reversed()
        let change = state.splitFromStack(id)
        didChange(change)
        refreshOrder(fallback: nil)
        let name = state.photo(id)?.file.name ?? id
        showNotice(localized("Split \(name) out of its stack.") + " " + KeyText.undoSentence(.putsItBack, in: settings.keyBindings), symbol: "square.stack.3d.up")
        if viewMode == .stackReview {
            if let stay = neighbours.first(where: { state.stack(containing: $0) != nil }) {
                selection.select(stay)
            } else if let next = state.nextUndecidedStack(after: id, wrapping: true) {
                showStack(next)
            } else if let any = state.nextStack(after: id) ?? state.previousStack(before: id) {
                showStack(any)
                stackReviewDone = true
            } else {
                stackReviewDone = true
            }
        }
        savePlace()
    }

    /// ⇧S: makes the focused frame its stack's pick, chosen by hand; on the hand-chosen pick, back
    /// to Culla's pick.
    func chooseFocusedAsBestPick() {
        let id = viewMode == .compare ? compareFocusedID : focus
        guard let id, let stack = state.stack(containing: id) else { return }
        let undo = stack.bestPick == id && state.isHandPicked(stack)
        let change = state.chooseBestPick(undo ? nil : id, inStackContaining: id)
        guard !change.isEmpty else {
            let name = state.photo(id)?.file.name ?? id
            showNotice(localized("\(name) is already the best pick."), symbol: "star")
            return
        }
        didChange(change)
        refreshOrder(fallback: nil)
        let name = state.photo(id)?.file.name ?? id
        showNotice(undo ? localized("Back to Culla’s pick.") : localized("\(name) is now the best pick. Culla keeps your choice."), symbol: "star.fill")
    }

    // MARK: - Keeping the review screens consistent

    /// After any change that may move stacks or sets (a regrouping, undo, a split): the review
    /// screen keeps a current stack or set, or moves to the next one.
    func reviewChanged() {
        switch viewMode {
        case .stackReview:
            guard let focus else { return }
            if state.stack(containing: focus) == nil {
                if let next = state.nextUndecidedStack(after: focus, wrapping: true) ?? state.nextStack(after: focus) ?? state.previousStack(before: focus) {
                    selection.select(StackReview.openingFrame(of: next, state: state))
                    stackReviewDone = state.nextUndecidedStack() == nil
                } else if order.isEmpty {
                    switchView(to: .grid)
                }
            } else if stackReviewDone, state.nextUndecidedStack() != nil {
                stackReviewDone = false
            }
        case .duplicateReview:
            guard let focus else { return }
            if state.duplicateSet(containing: focus) == nil {
                if let next = state.nextUndecidedDuplicateSet(after: focus, wrapping: true) ?? state.nextDuplicateSet(after: focus) ?? state.previousDuplicateSet(before: focus) {
                    selection.select(openingCopy(of: next))
                    duplicateReviewDone = state.nextUndecidedDuplicateSet() == nil
                } else if order.isEmpty {
                    switchView(to: .grid)
                }
            } else if duplicateReviewDone, state.nextUndecidedDuplicateSet() != nil {
                duplicateReviewDone = false
            }
        case .compare:
            compareIDs = compareIDs.filter { state.contains($0) }
            if compareIDs.count < 2 { leaveCompare() } else { compareFocus = min(compareFocus, compareIDs.count - 1) }
        case .grid, .loupe:
            break
        }
    }

    // MARK: - Leaving

    /// Escape: compare and the review screens go back to where they were opened from; the loupe
    /// goes to the grid.
    func goBack() {
        switch viewMode {
        case .compare:
            leaveCompare()
        case .stackReview, .duplicateReview:
            if let origin = reviewOrigin {
                reviewOrigin = nil
                returnFrom(origin, focusing: focus)
            } else {
                setViewMode(.grid)
            }
        case .loupe:
            setViewMode(.grid)
        case .grid:
            break
        }
    }

    /// Back to the view a stack was opened from, with that stack's photo focused.
    private func returnFrom(_ origin: ReviewOrigin, focusing id: String?) {
        let target = id.flatMap { state.contains($0) ? $0 : nil }
        switchView(to: origin.viewMode == .compare ? .grid : origin.viewMode)
        if let target {
            selection.select(target)
            normalizeGridFocus()
        } else {
            selection = origin.selection
        }
        scrollRevision += 1
        savePlace()
    }

    /// Space: from the grid to the group's own view (stack review in Similar Stacks, duplicate
    /// review in Duplicates, else the loupe); from anywhere else back to the grid.
    func toggleDetail() {
        guard viewMode == .grid else {
            if viewMode == .compare { leaveCompare() }
            setViewMode(.grid)
            return
        }
        viewChosenByHand = true
        if group == .similarStacks, let focus, state.stack(containing: focus) != nil {
            stackReviewDone = false
            switchView(to: .stackReview)
            setReviewZoom(.fit)
        } else if group == .duplicates, let focus, state.duplicateSet(containing: focus) != nil {
            duplicateReviewDone = false
            switchView(to: .duplicateReview)
            setReviewZoom(.fit)
        } else {
            if let focus, collapsedStacks[focus] != nil {
                // The tile shows its stack's pick: the loupe opens on it.
                selection.select(focus)
            }
            switchView(to: .loupe)
        }
    }

    // MARK: - Compare

    /// The photos C would compare from here: the selection, or the focused photo against its
    /// stack's pick; in duplicate review, the set's copies.
    func photosToCompare() -> [String] {
        switch viewMode {
        case .stackReview:
            guard let focus else { return [] }
            return state.compareWithBestPick(focus)
        case .duplicateReview:
            return Array((currentSet?.members ?? []).prefix(SessionState.compareLimit))
        case .grid, .loupe:
            return state.comparePhotos(selection: selection.selected, focused: focus)
        case .compare:
            return compareIDs
        }
    }

    func enterCompare() {
        let ids = photosToCompare()
        guard ids.count >= 2 else {
            showNotice(localized("Select two to four photos to compare, or a photo in a stack."), symbol: "rectangle.split.2x1")
            return
        }
        compareOrigin = ReviewOrigin(viewMode: viewMode, selection: selection)
        compareIDs = ids
        compareFocus = focus.flatMap { ids.firstIndex(of: $0) } ?? 0
        setReviewZoom(.fit)
        viewMode = .compare
        selection = GridSelection(focus: ids[compareFocus])
        scrollRevision += 1
    }

    /// Escape or C: back to the view compare was opened from, with its selection.
    func leaveCompare() {
        guard viewMode == .compare else { return }
        let origin = compareOrigin ?? ReviewOrigin(viewMode: .grid, selection: selection)
        compareOrigin = nil
        compareIDs = []
        setReviewZoom(.fit)
        viewMode = origin.viewMode == .compare ? .grid : origin.viewMode
        selection = origin.selection
        selection.prune(to: selectionOrder)
        reviewChanged()
        scrollRevision += 1
        savePlace()
    }

    var compareFocusedID: String? {
        compareIDs.indices.contains(compareFocus) ? compareIDs[compareFocus] : nil
    }

    /// A click on a pane, or ← →, gives it the focus.
    func focusComparePane(_ index: Int) {
        guard compareIDs.indices.contains(index) else { return }
        compareFocus = index
        compareTargetFace = nil
        selection = GridSelection(focus: compareIDs[index])
    }

    func stepComparePane(by offset: Int) {
        focusComparePane(min(max(compareFocus + offset, 0), compareIDs.count - 1))
    }

    /// P, X and U decide the focused pane's photo; the focus stays, so the result shows.
    func decideInCompare(_ decision: Decision) {
        guard let id = compareFocusedID else { return }
        mergeResultSeen()
        didChange(state.apply(.setDecision(decision, ids: [id])))
        refreshOrder(fallback: nil)
    }

    /// The focused pane's main faces in reading order, for Tab.
    var compareFaceOrder: [Int] {
        guard let id = compareFocusedID else { return [] }
        return LoupeTarget.faceOrder(scores: state.photo(id)?.scores, summary: state.summary(for: id))
    }

    // MARK: - Linked zoom

    func setReviewZoom(_ zoom: LoupeZoom, faceRow: Int? = nil) {
        reviewZoom = zoom
        if reviewFaceRow != faceRow { reviewFaceRow = faceRow }
        reviewZoomRevision += 1
    }

    /// A pane the person zoomed or panned: the others follow it. Not a face any more.
    func reviewViewChanged(_ zoom: LoupeZoom) {
        reviewZoom = zoom
        if reviewFaceRow != nil { reviewFaceRow = nil }
        reviewZoomRevision += 1
    }

    /// Z in stack review, compare and duplicate review: 100% on the evidence of the photo with
    /// the focus, the same spot in every pane; or back to fit.
    func toggleReviewZoom() {
        if reviewZoom.isZoomed {
            setReviewZoom(.fit)
            return
        }
        guard let id = viewMode == .compare ? compareFocusedID : focus else { return }
        let reviewGroup: GroupID = state.summary(for: id)?.flags.contains(.eyesClosed) == true ? .eyesClosed : group
        let target = LoupeTarget.zoomTarget(scores: state.photo(id)?.scores, summary: state.summary(for: id), group: reviewGroup)
        var row: Int?
        if viewMode == .stackReview, let face = target.face, let strip = currentFaceStrip, let column = strip.frames.firstIndex(of: id) {
            row = strip.matching.rows.firstIndex { $0.faces[column] == face }
        }
        setReviewZoom(.zoomed(factor: 1, centre: target.point), faceRow: row)
    }

    /// Tab in stack review: the next person of the face strip, in both panes; in compare, the
    /// next face of the focused photo.
    func stepReviewFace(forward: Bool) {
        guard case .zoomed(let factor, _) = reviewZoom else { return }
        if viewMode == .stackReview {
            guard let strip = currentFaceStrip, let focus, let column = strip.frames.firstIndex(of: focus) else { return }
            let rows = strip.matching.rows.indices.filter { strip.matching.rows[$0].faces[column] != nil }
            let candidates = rows.isEmpty ? Array(strip.matching.rows.indices) : rows
            guard let row = LoupeTarget.step(from: reviewFaceRow, in: candidates, forward: forward) else { return }
            setReviewZoom(.zoomed(factor: factor, centre: faceCentre(row: row, in: strip, frame: focus) ?? reviewZoom.centre ?? UnitPoint(x: 0.5, y: 0.5)), faceRow: row)
        } else if let id = compareFocusedID, let scores = state.photo(id)?.scores {
            let order = LoupeTarget.faceOrder(scores: scores, summary: state.summary(for: id))
            guard let face = LoupeTarget.step(from: compareTargetFace, in: order, forward: forward) else { return }
            compareTargetFace = face
            setReviewZoom(.zoomed(factor: factor, centre: LoupeTarget.eyePoint(of: scores.faces[face])))
        }
    }

    /// Where a person's eyes are in one frame of the strip, or nil when the person is not in it.
    func faceCentre(row: Int, in strip: FaceStrip, frame id: String) -> UnitPoint? {
        guard let column = strip.frames.firstIndex(of: id), let face = strip.matching.face(row: row, frame: column),
              let scores = state.photo(id)?.scores, scores.faces.indices.contains(face)
        else { return nil }
        return LoupeTarget.eyePoint(of: scores.faces[face])
    }

    /// A click on a face strip cell: that frame becomes current and both panes zoom to that face;
    /// in the loupe, the loupe zooms to it (and moves to the frame when the group shows it).
    func selectFaceCell(row: Int, column: Int) {
        guard let focus else { return }
        let strip = faceStrip(forPhoto: focus)
        guard strip.frames.indices.contains(column), let face = strip.matching.face(row: row, frame: column) else { return }
        let frame = strip.frames[column]
        if viewMode == .stackReview {
            stackReviewDone = false
            if frame != focus { selection.select(frame) }
            let factor = max(1, reviewZoom.factor ?? 1)
            let centre = faceCentre(row: row, in: strip, frame: frame) ?? UnitPoint(x: 0.5, y: 0.5)
            setReviewZoom(.zoomed(factor: factor, centre: centre), faceRow: row)
            savePlace()
        } else if viewMode == .loupe {
            if frame != focus, order.contains(frame) { selection.select(frame) }
            let shown = self.focus ?? frame
            let shownStrip = faceStrip(forPhoto: shown)
            let shownColumn = shownStrip.frames.firstIndex(of: shown) ?? column
            let shownFace = shownStrip.matching.face(row: row, frame: shownColumn) ?? (shown == frame ? face : nil)
            guard let shownFace, let scores = state.photo(shown)?.scores, scores.faces.indices.contains(shownFace) else { return }
            setLoupeZoom(.zoomed(factor: max(1, loupeZoom.factor ?? 1), centre: LoupeTarget.eyePoint(of: scores.faces[shownFace])))
            loupeTargetFace = shownFace
        }
    }

    /// A click on a face of a single photo's strip in the loupe: zooms the loupe to it.
    func zoomLoupe(toFace face: Int) {
        guard let id = focus, let scores = state.photo(id)?.scores, scores.faces.indices.contains(face) else { return }
        setLoupeZoom(.zoomed(factor: max(1, loupeZoom.factor ?? 1), centre: LoupeTarget.eyePoint(of: scores.faces[face])))
        loupeTargetFace = face
    }

    // MARK: - Reading ahead

    /// Decodes ahead what the next stack will show: its first frame and its pick, and the next
    /// frame of this stack, so Return and → show sharp images at once.
    func prefetchAroundStack() {
        guard let focus, let stack = currentStack else { return }
        var ids: [String] = []
        if let index = stack.members.firstIndex(of: focus), index + 1 < stack.members.count { ids.append(stack.members[index + 1]) }
        if let next = StackReview.stackAfterAccepting(focus, state: state) {
            if let first = StackReview.openingFrame(of: next, state: state) { ids.append(first) }
            if let pick = next.bestPick { ids.append(pick) }
            ids += next.members
        }
        for id in ids.prefix(4) {
            if let item = state.photo(id), !item.isUnreadable { previews.prefetch(item.file) }
        }
        // Thumbnails of the next stack's frames, for its filmstrip and first face crops.
        let thumbnails = thumbnails
        let files = ids.compactMap { state.photo($0)?.file }
        Task.detached(priority: .utility) {
            for file in files { _ = try? await thumbnails.thumbnail(for: file) }
        }
    }

    func prefetchSet() {
        guard let focus, let next = state.nextUndecidedDuplicateSet(after: focus, wrapping: true) else { return }
        for id in next.members.prefix(SessionState.compareLimit) {
            if let item = state.photo(id), !item.isUnreadable { previews.prefetch(item.file) }
        }
    }

    // MARK: - Helpers

    /// The note about new photos has been seen once culling starts; it would cover the panes.
    func mergeResultSeen() {
        dismissMergeNote()
    }
}
