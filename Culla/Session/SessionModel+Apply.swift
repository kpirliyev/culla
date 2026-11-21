import AppKit
import CullaCommands
import CullaCore
import CullaSession
import Foundation

/// Undo Apply from the menus or ⌘Z, waiting for its confirmation.
struct UndoApplyRequest: Equatable, Identifiable {
    let id = UUID()
    var question: String
    var detail: String
}

// Review and Apply, Undo Apply and keeping up with the disk, as the session model sees them.
//
// Rules decided here, where the Design is silent:
// - While Review and Apply is open, the keys work on the screen only: arrows move among the
//   rejects, P rescues, Space and Return look closer, ⌘Z and ⇧⌘Z undo and redo rescues, ⇧⌘Return
//   applies, Escape or ⌘Return leaves. Nothing else changes decisions.
// - While a run (apply or undo) is under way nothing changes decisions, stacks or the disk:
//   decision keys, Review and Apply, Undo Apply, Open and Close are unavailable.
// - ⌘Z right after an apply, when there is no decision to undo, offers Undo Apply (the Edit menu
//   names it), after a confirmation. Once a new decision is made, ⌘Z undoes that first.
extension SessionModel {
    /// Commands that change stacks rather than decisions.
    static let changesStacks: Set<Command> = [.addToStack, .splitFromStack, .chooseBestPick]
    /// Commands that change the disk or leave the shoot.
    static let touchesDisk: Set<Command> = [.reviewAndApply, .applyDecisions, .undoApply, .undo, .redo, .closeShoot, .openFolder, .rescanFolder]

    /// The key a command is on, as menus show it, such as "⇧⌘↩".
    func keyName(_ command: Command) -> String {
        guard let chord = settings.keyBindings.primaryChord(for: command) else { return "" }
        if chord.special == .escape, chord.modifiers.isEmpty { return "Esc" }
        if chord.special == .space, chord.modifiers.isEmpty { return localized("keyName.space", default: "Space") }
        return chord.displayString
    }

    // MARK: - The screen's keys

    func isEnabledOnApplyScreen(_ command: Command) -> Bool {
        let screen = apply!
        let running = screen.isRunning
        let hasRejects = !screen.rejectOrder.isEmpty && !running
        switch command {
        case .reviewAndApply: return !running
        case .back: return running ? screen.run?.cancelling == false : true
        case .applyDecisions:
            return screen.canApply || (screen.isReadOnly && screen.copyDestination == nil && !running && !screen.isPreparing)
        case .keep: return !screen.rescueTargets.isEmpty
        case .undo: return !running && state.canUndo
        case .redo: return !running && state.canRedo
        case .nextPhoto, .previousPhoto, .nextRow, .previousRow, .firstPhoto, .lastPhoto,
             .extendNext, .extendPrevious, .extendNextRow, .extendPreviousRow, .pageDown, .pageUp, .selectAll:
            return hasRejects
        case .deselectAll: return !running && screen.listSelection.selected.count > 1
        case .toggleLoupe, .acceptStack, .showLoupe:
            return !running && (screen.peekID != nil || screen.listSelection.focus != nil)
        default: return false
        }
    }

    func performOnApplyScreen(_ command: Command) {
        let screen = apply!
        switch command {
        case .reviewAndApply: screen.close()
        case .back:
            if screen.isRunning { screen.cancelRun() } else if screen.peekID != nil { screen.closePeek() } else { screen.close() }
        case .applyDecisions: screen.applyNow()
        case .keep: screen.rescue()
        case .undo:
            screen.undoneOnScreen(undo())
        case .redo:
            redo()
            screen.undoneOnScreen([])
        case .nextPhoto: screen.move(by: 1)
        case .previousPhoto: screen.move(by: -1)
        case .nextRow: screen.move(by: screen.columns)
        case .previousRow: screen.move(by: -screen.columns)
        case .extendNext: screen.move(by: 1, extend: true)
        case .extendPrevious: screen.move(by: -1, extend: true)
        case .extendNextRow: screen.move(by: screen.columns, extend: true)
        case .extendPreviousRow: screen.move(by: -screen.columns, extend: true)
        case .pageDown: screen.move(by: screen.columns * 4)
        case .pageUp: screen.move(by: -screen.columns * 4)
        case .firstPhoto: screen.move(toEnd: true)
        case .lastPhoto: screen.move(toEnd: false)
        case .selectAll: screen.selectAll()
        case .deselectAll: screen.deselectAll()
        case .toggleLoupe, .acceptStack, .showLoupe: screen.togglePeek()
        default: break
        }
    }

    // MARK: - Opening and running

    func openReviewAndApply() {
        closeTuningPanel()
        apply.open()
    }

    /// The screen opened: the analysis summary and notes have done their job.
    func screenOpened() {
        if summaryBanner != nil { dismissSummary() }
        dismissNotice()
    }

    func screenClosed() {
        disk?.runPendingRescan()
    }

    /// A run started: the harness waits for it, and quitting waits for it.
    func runStarted() {
        activity.begin(.applying)
    }

    func runEnded() {
        activity.end(.applying)
        if !apply.isOpen { disk?.runPendingRescan() }
    }

    /// P on the screen: an ordinary decision, so ⌘Z takes it back.
    func decideFromApplyScreen(_ decision: Decision, ids: [String]) {
        let change = state.apply(.setDecision(decision, ids: ids))
        didChange(change)
        refreshOrder(fallback: nil)
    }

    /// After an apply or an undo changed which photos the session holds: views follow, the
    /// photos are saved, and analysis learns of photos that came back.
    func photosChangedOnDisk() {
        sessionChangedOnDisk()
        refreshOrder(fallback: selection.focus.flatMap { state.nextAfterDecision(on: [$0], in: group) }, reason: .refill)
        if viewMode == .grid { normalizeGridFocus() }
        saver.savePhotos(state.photos)
        analysis?.update(photos: state.photos)
        savePlace()
    }

    // MARK: - Undo Apply from the menus

    /// Undo Apply from the Edit or File menu, or ⌘Z after an apply: asks first, since it moves files.
    func requestUndoApply() {
        guard apply.canUndoApply, let undoable = apply.undoable else { return }
        let title = ApplyCoordinator.runTitle(undoable)
        let detail: String
        switch (undoable.kind, undoable.options.rejectAction) {
        case (.copyKeepers, _):
            detail = localized("The copies Culla made are removed, unless they were changed since. “\(name)” itself is not touched.")
        case (.apply, .markOnly):
            detail = localized("The sidecars Culla wrote are put back as they were, unless they were changed since. No file moves.")
        case (.apply, _):
            detail = localized("The photos go back to where they were in “\(name)”, with their decisions, and the sidecars Culla wrote are put back as they were. Anything changed since is left alone and listed; nothing is overwritten.")
        }
        setUndoApplyRequest(UndoApplyRequest(question: localized("Undo “\(title)”?"), detail: detail))
    }

    func confirmUndoApply() {
        setUndoApplyRequest(nil)
        apply.undoLatest()
    }

    func cancelUndoApply() {
        setUndoApplyRequest(nil)
    }

    // MARK: - Rescans

    /// Merges a rescan: decisions follow renamed files, their cached scores and stack edits
    /// follow too, new files are marked New, and the focus and selection stay where they are.
    func mergeRescan(_ scanned: [ScannedPhoto]) -> MergeResult {
        let result = state.merge(scanned: scanned)
        guard !result.isEmpty else { return result }
        if !result.renamed.isEmpty {
            let renamed = Dictionary(result.renamed.map { ($0.from, $0.to) }, uniquingKeysWith: { first, _ in first })
            let focus = selection.focus.map { renamed[$0] ?? $0 }
            selection = GridSelection(focus: focus, selected: Set(selection.selected.map { renamed[$0] ?? $0 }))
            let moves = Dictionary(result.renamed.map { ($0.oldURL.path, $0.newURL.path) }, uniquingKeysWith: { first, _ in first })
            saver.enqueue("cached scores") { database, _ in try await database.moveCachedScores(moves) }
            saver.saveStackEdits(state.stackEdits)
        }
        sessionChangedOnDisk()
        refreshOrder(fallback: selection.focus.flatMap { state.nextAfterDecision(on: [$0], in: group) }, reason: .refill)
        saver.savePhotos(state.photos)
        analysis?.update(photos: state.photos)
        if let note = ApplyText.rescanNote(added: result.added.count, removed: result.removed.count, renamed: result.renamed.count, modified: result.modified.count) {
            showNotice(note, symbol: "arrow.triangle.2.circlepath")
        }
        return result
    }
}
