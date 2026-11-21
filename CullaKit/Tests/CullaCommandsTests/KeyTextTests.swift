import CullaCommands
import Testing

@Suite("Key text")
struct KeyTextTests {
    let keys = KeyBindings.defaults

    @Test func defaultsGiveTodaysText() {
        #expect(KeyText.stackReviewHints(keys, pickPaneShown: true, facesShown: true)
            == "↩ accept · P keep · X reject · ←→ frame · ↓ skip · ⇧S pick · F hide faces · H hide pick")
        #expect(KeyText.stackReviewHints(keys, pickPaneShown: false, facesShown: true).hasSuffix("F hide faces · H show pick"))
        #expect(KeyText.stackReviewHints(keys, pickPaneShown: true, facesShown: false).hasSuffix("F show faces · H hide pick"))
        #expect(KeyText.compareHints(keys) == "←→ pane · P keep · X reject · U clear · Z zoom · ⎋ back")
        #expect(KeyText.duplicateReviewHints(keys) == "↩ accept · P keep this copy · ←→ copy · ↓ next set")
        #expect(KeyText.advanceNote(keys) == "After P, X or U on one photo, the next one is shown.")
        #expect(KeyText.collapseStacksNote(keys) == "Each stack shows as one tile until S expands it.")
        #expect(KeyText.bestPickPaneNote(keys) == "In stack review. When off, the current frame fills the row; H switches it.")
        #expect(KeyText.backHelp(to: .group(.similarStacks), commands: [.back], in: keys) == "Back to Similar Stacks (⎋)")
        #expect(KeyText.backHelp(to: .previousView, commands: [.back, .showCompare], in: keys) == "Back to where you were (⎋ or C)")
        #expect(KeyText.undoSentence(.takesItBack, in: keys) == "⌘Z takes it back.")
    }

    @Test func aRemappedKeyShowsTheNewKey() {
        var custom = keys
        custom.setChords([KeyChord("k")], for: .keep)
        custom.setChords([KeyChord("p", .shift)], for: .toggleBestPickPane)
        custom.setChords([KeyChord("e")], for: .toggleStacks)
        custom.setChords([KeyChord("y")], for: .toggleFaceStrip)
        #expect(KeyText.stackReviewHints(custom, pickPaneShown: true, facesShown: true)
            == "↩ accept · K keep · X reject · ←→ frame · ↓ skip · ⇧S pick · Y hide faces · ⇧P hide pick")
        #expect(KeyText.stackReviewHints(custom, pickPaneShown: true, facesShown: false).contains("Y show faces"))
        #expect(KeyText.advanceNote(custom) == "After K, X or U on one photo, the next one is shown.")
        #expect(KeyText.collapseStacksNote(custom) == "Each stack shows as one tile until E expands it.")
        #expect(KeyText.bestPickPaneNote(custom).hasSuffix("; ⇧P switches it."))
    }

    @Test func aCommandWithoutAKeyIsLeftOut() {
        var custom = keys
        custom.unbind(.toggleFaceStrip)
        custom.unbind(.toggleBestPickPane)
        custom.unbind(.nextPhoto)
        custom.unbind(.reject)
        custom.unbind(.toggleStacks)
        custom.unbind(.undo)
        // Half of a pair keeps its other half.
        #expect(KeyText.stackReviewHints(custom, pickPaneShown: true, facesShown: true) == "↩ accept · P keep · ← frame · ↓ skip · ⇧S pick")
        #expect(KeyText.stackReviewHints(custom, pickPaneShown: true, facesShown: false) == "↩ accept · P keep · ← frame · ↓ skip · ⇧S pick")
        #expect(KeyText.advanceNote(custom) == "After P or U on one photo, the next one is shown.")
        #expect(KeyText.bestPickPaneNote(custom) == "In stack review. When off, the current frame fills the row.")
        #expect(KeyText.collapseStacksNote(custom) == "Each stack shows as one tile until View ▸ Expand All Stacks.")
        #expect(KeyText.undoSentence(.takesItBack, in: custom) == "Edit ▸ Undo takes it back.")
        custom.unbind(.keep)
        custom.unbind(.clearDecision)
        #expect(KeyText.advanceNote(custom) == "After a decision on one photo, the next one is shown.")
        custom.unbind(.back)
        #expect(KeyText.backHelp(to: .group(.similarStacks), commands: [.back], in: custom) == "Back to Similar Stacks")
    }

    @Test func listsReadAsSentences() {
        #expect(KeyText.list([]) == "")
        #expect(KeyText.list(["P"]) == "P")
        #expect(KeyText.list(["P", "X"]) == "P or X")
        #expect(KeyText.list(["P", "X", "U"]) == "P, X or U")
    }
}
