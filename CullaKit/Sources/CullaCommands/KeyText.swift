import CullaCore
import CullaSession

/// Text that names keys, built from the live key map: a remapped key shows as remapped, and a
/// command with no key is left out rather than shown blank (Architecture: "Commands and keys").
public enum KeyText {
    /// The key a command is on, as menus show it ("⇧S", "↩"), or nil when it has none.
    public static func key(_ command: Command, in keys: KeyBindings) -> String? {
        keys.primaryChord(for: command)?.displayString
    }

    /// One item of a hint line: the keys of one or more commands, side by side, and what they do.
    public struct Hint: Sendable, Equatable {
        public var commands: [Command]
        /// What the keys do, in the language of the interface: one or two lowercase words.
        public var label: String
        /// Puts a space between the commands' keys ("← → ↑ ↓") instead of none ("←→").
        public var spaced: Bool

        public init(_ commands: Command..., label: String, spaced: Bool = false) {
            self.commands = commands
            self.label = label
            self.spaced = spaced
        }
    }

    /// "↩ accept · P keep": each hint whose commands have at least one key.
    public static func hintLine(_ hints: [Hint], in keys: KeyBindings, separator: String = " · ") -> String {
        hints.compactMap { hint(for: $0, in: keys) }.joined(separator: separator)
    }

    /// "← → move", or nil when none of the hint's commands has a key.
    public static func hint(for hint: Hint, in keys: KeyBindings) -> String? {
        guard let names = keyNames(hint, in: keys) else { return nil }
        return localized("hint.item", default: "\(names) \(hint.label)")
    }

    /// The hint's keys alone ("← → ↑ ↓"), or nil when none has a key.
    public static func keyNames(_ hint: Hint, in keys: KeyBindings) -> String? {
        let names = hint.commands.compactMap { key($0, in: keys) }
        return names.isEmpty ? nil : names.joined(separator: hint.spaced ? " " : "")
    }

    /// Key names as alternatives, in the language of the interface: "P", "P or X", "P, X or U".
    public static func list(_ items: [String]) -> String {
        Localization.list(items, .or)
    }

    // MARK: - Stack review, compare and duplicate review headers

    /// Stack review's header: "↩ accept · P keep · X reject · ←→ frame · ↓ skip · ⇧S pick · F hide faces · H hide pick".
    /// `facesShown` is what F last asked for (the strip and the face boxes), not whether this
    /// stack has faces.
    public static func stackReviewHints(_ keys: KeyBindings, pickPaneShown: Bool, facesShown: Bool) -> String {
        hintLine([
            Hint(.acceptStack, label: localized("hint.accept", default: "accept")),
            Hint(.keep, label: localized("hint.keep", default: "keep")),
            Hint(.reject, label: localized("hint.reject", default: "reject")),
            Hint(.previousPhoto, .nextPhoto, label: localized("hint.frame", default: "frame")),
            Hint(.nextRow, label: localized("hint.skip", default: "skip")),
            Hint(.chooseBestPick, label: localized("hint.pick", default: "pick")),
            Hint(.toggleFaceStrip, label: facesShown
                ? localized("hint.hideFaces", default: "hide faces") : localized("hint.showFaces", default: "show faces")),
            Hint(.toggleBestPickPane, label: pickPaneShown
                ? localized("hint.hidePick", default: "hide pick") : localized("hint.showPick", default: "show pick")),
        ], in: keys)
    }

    /// Compare's header: "←→ pane · P keep · X reject · U clear · Z zoom · ⎋ back".
    public static func compareHints(_ keys: KeyBindings) -> String {
        hintLine([
            Hint(.previousPhoto, .nextPhoto, label: localized("hint.pane", default: "pane")),
            Hint(.keep, label: localized("hint.keep", default: "keep")),
            Hint(.reject, label: localized("hint.reject", default: "reject")),
            Hint(.clearDecision, label: localized("hint.clear", default: "clear")),
            Hint(.zoomToggle, label: localized("hint.zoom", default: "zoom")),
            Hint(.back, label: localized("hint.back", default: "back")),
        ], in: keys)
    }

    /// Duplicate review's header: "↩ accept · P keep this copy · ←→ copy · ↓ next set".
    public static func duplicateReviewHints(_ keys: KeyBindings) -> String {
        hintLine([
            Hint(.acceptStack, label: localized("hint.accept", default: "accept")),
            Hint(.keep, label: localized("hint.keepThisCopy", default: "keep this copy")),
            Hint(.previousPhoto, .nextPhoto, label: localized("hint.copy", default: "copy")),
            Hint(.nextRow, label: localized("hint.nextSet", default: "next set")),
        ], in: keys)
    }

    /// Where a "Back" button goes.
    public enum BackDestination: Sendable, Hashable {
        /// The sidebar group the review was opened from.
        case group(GroupID)
        /// Wherever the person was before, such as the grid or the loupe.
        case previousView
    }

    /// A "Back" button's tooltip: "Back to Similar Stacks (⎋)", "Back to where you were (⎋ or C)".
    public static func backHelp(to destination: BackDestination, commands: [Command], in keys: KeyBindings) -> String {
        let names = commands.compactMap { key($0, in: keys) }
        switch destination {
        case .group(let group):
            let title = group.title
            return names.isEmpty ? localized("Back to \(title)") : localized("Back to \(title) (\(list(names)))")
        case .previousView:
            return names.isEmpty ? localized("Back to where you were") : localized("Back to where you were (\(list(names)))")
        }
    }

    // MARK: - Settings ▸ General notes

    /// "After P, X or U on one photo, the next one is shown."
    public static func advanceNote(_ keys: KeyBindings) -> String {
        let names = [Command.keep, .reject, .clearDecision].compactMap { key($0, in: keys) }
        return names.isEmpty
            ? localized("After a decision on one photo, the next one is shown.")
            : localized("After \(list(names)) on one photo, the next one is shown.")
    }

    /// "Each stack shows as one tile until S expands it."
    public static func collapseStacksNote(_ keys: KeyBindings) -> String {
        guard let name = key(.toggleStacks, in: keys) else {
            return localized("Each stack shows as one tile until View ▸ Expand All Stacks.")
        }
        return localized("Each stack shows as one tile until \(name) expands it.")
    }

    /// "In stack review. When off, the current frame fills the row; H switches it."
    public static func bestPickPaneNote(_ keys: KeyBindings) -> String {
        guard let name = key(.toggleBestPickPane, in: keys) else {
            return localized("In stack review. When off, the current frame fills the row.")
        }
        return localized("In stack review. When off, the current frame fills the row; \(name) switches it.")
    }

    // MARK: - Undo

    /// What undoing does, for `undoSentence(_:in:)`.
    public enum UndoPhrase: Sendable, Hashable, CaseIterable {
        /// "⌘Z takes it back."
        case takesItBack
        /// "⌘Z takes it back in one step."
        case takesItBackInOneStep
        /// "⌘Z puts it back."
        case putsItBack
        /// "⌘Z cannot bring it back."
        case cannotBringItBack
    }

    /// "⌘Z takes it back." or, with no key for Undo, "Edit ▸ Undo takes it back."
    public static func undoSentence(_ phrase: UndoPhrase, in keys: KeyBindings) -> String {
        guard let name = key(.undo, in: keys) else {
            return switch phrase {
            case .takesItBack: localized("Edit ▸ Undo takes it back.")
            case .takesItBackInOneStep: localized("Edit ▸ Undo takes it back in one step.")
            case .putsItBack: localized("Edit ▸ Undo puts it back.")
            case .cannotBringItBack: localized("Edit ▸ Undo cannot bring it back.")
            }
        }
        return switch phrase {
        case .takesItBack: localized("\(name) takes it back.")
        case .takesItBackInOneStep: localized("\(name) takes it back in one step.")
        case .putsItBack: localized("\(name) puts it back.")
        case .cannotBringItBack: localized("\(name) cannot bring it back.")
        }
    }
}
