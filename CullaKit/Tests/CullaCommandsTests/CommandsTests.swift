import CullaCommands
import CullaSession
import Foundation
import Testing

@Suite("Key chords")
struct KeyChordTests {
    @Test func parsesTheTextForm() throws {
        #expect(KeyChord(string: "p") == KeyChord("p"))
        #expect(KeyChord(string: "P") == KeyChord("p"))
        #expect(KeyChord(string: "shift+x") == KeyChord("x", .shift))
        #expect(KeyChord(string: "shift+cmd+z") == KeyChord("z", [.command, .shift]))
        #expect(KeyChord(string: "cmd+]") == KeyChord("]", .command))
        #expect(KeyChord(string: "cmd++") == KeyChord("+", .command))
        #expect(KeyChord(string: "space") == KeyChord(.space))
        #expect(KeyChord(string: "Right") == KeyChord(.right))
        #expect(KeyChord(string: "shift+pagedown") == KeyChord(.pageDown, .shift))
        #expect(KeyChord(string: "") == nil)
        #expect(KeyChord(string: "hyper+p") == nil)
        #expect(KeyChord(string: "pp") == nil)
    }

    @Test func textFormRoundTrips() {
        for binding in KeyBindings.defaults.bindings {
            #expect(KeyChord(string: binding.chord.description) == binding.chord, "\(binding.chord)")
        }
    }

    @Test func displayStringsFollowMacMenus() {
        #expect(KeyChord("z", [.command, .shift]).displayString == "⇧⌘Z")
        #expect(KeyChord(.right).displayString == "→")
        #expect(KeyChord(.space).displayString == "Space")
        #expect(KeyChord("]", .command).displayString == "⌘]")
    }

    @Test func spokenNamesAreWords() {
        #expect(KeyChord("z", [.command, .shift]).spokenName == "Shift Command Z")
        #expect(KeyChord(.right).spokenName == "Right Arrow")
        #expect(KeyChord("+", .command).spokenName == "Command Plus")
        #expect(KeyChord(.return, .command).spokenName == "Command Return")
    }

    @Test func readsKeyEventCharacters() {
        // AppKit's function-key characters for the arrows.
        #expect(KeyChord(eventCharacters: "\u{F703}", modifiers: []) == KeyChord(.right))
        #expect(KeyChord(eventCharacters: "\u{F700}", modifiers: .shift) == KeyChord(.up, .shift))
        #expect(KeyChord(eventCharacters: " ", modifiers: []) == KeyChord(.space))
        #expect(KeyChord(eventCharacters: "\r", modifiers: .command) == KeyChord(.return, .command))
        // Shift is applied to the characters, and letters ignore case (Caps Lock).
        #expect(KeyChord(eventCharacters: "X", modifiers: .shift) == KeyChord("x", .shift))
        #expect(KeyChord(eventCharacters: "P", modifiers: []) == KeyChord("p"))
        #expect(KeyChord(eventCharacters: "", modifiers: []) == nil)
        #expect(KeyChord(eventCharacters: "\u{F704}", modifiers: []) == nil)  // F1
        // Shift-Tab arrives as the back-tab character.
        #expect(KeyChord(eventCharacters: "\u{19}", modifiers: .shift) == KeyChord(.tab, .shift))
    }

    @Test func fallsBackToTheKeyPositionOnOtherLayouts() {
        // Virtual key codes (kVK_ANSI_*): P 0x23, X 0x07, U 0x20, C 0x08, Q 0x0C, V 0x09, S 0x01.
        // Russian: P types "з", X "ч", U "г", S "ы"; Shift gives the capital, still the same key.
        #expect(KeyChord(eventCharacters: "з", keyCode: 0x23, modifiers: []) == KeyChord("p"))
        #expect(KeyChord(eventCharacters: "ч", keyCode: 0x07, modifiers: []) == KeyChord("x"))
        #expect(KeyChord(eventCharacters: "г", keyCode: 0x20, modifiers: []) == KeyChord("u"))
        #expect(KeyChord(eventCharacters: "Ч", keyCode: 0x07, modifiers: .shift) == KeyChord("x", .shift))
        #expect(KeyChord(eventCharacters: "ы", keyCode: 0x01, modifiers: .command) == KeyChord("s", .command))
        // Turkmen puts its own letters where Latin ones were.
        #expect(KeyChord(eventCharacters: "ç", keyCode: 0x08, modifiers: []) == KeyChord("c"))
        #expect(KeyChord(eventCharacters: "ä", keyCode: 0x0C, modifiers: []) == KeyChord("q"))
        #expect(KeyChord(eventCharacters: "ž", keyCode: 0x07, modifiers: []) == KeyChord("x"))
        #expect(KeyChord(eventCharacters: "ň", keyCode: 0x09, modifiers: []) == KeyChord("v"))
        // Russian punctuation keys: "х" on [ and "ъ" on ], "б" on the comma key.
        #expect(KeyChord(eventCharacters: "х", keyCode: 0x21, modifiers: .command) == KeyChord("[", .command))
        #expect(KeyChord(eventCharacters: "ъ", keyCode: 0x1E, modifiers: []) == KeyChord("]"))
        #expect(KeyChord(eventCharacters: "б", keyCode: 0x2B, modifiers: .command) == KeyChord(",", .command))
        // A typed ASCII character wins over the position: AZERTY's A sits on the Q key, and the
        // Russian layout types "." on the US slash key.
        #expect(KeyChord(eventCharacters: "a", keyCode: 0x0C, modifiers: []) == KeyChord("a"))
        #expect(KeyChord(eventCharacters: ".", keyCode: 0x2C, modifiers: []) == KeyChord("."))
        #expect(KeyChord(eventCharacters: "P", keyCode: 0x23, modifiers: .shift) == KeyChord("p", .shift))
        // Keys that type no character are named as before, whatever their code.
        #expect(KeyChord(eventCharacters: "\u{F703}", keyCode: 0x7C, modifiers: []) == KeyChord(.right))
        #expect(KeyChord(eventCharacters: " ", keyCode: 0x31, modifiers: []) == KeyChord(.space))
        #expect(KeyChord(eventCharacters: "\r", keyCode: 0x24, modifiers: []) == KeyChord(.return))
        // A key outside the table keeps the typed character; a function key stays unbound.
        #expect(KeyChord(eventCharacters: "§", keyCode: 0x0A, modifiers: []) == KeyChord("§"))
        #expect(KeyChord(eventCharacters: "\u{F704}", keyCode: 0x7A, modifiers: []) == nil)
    }

    @Test func usLayoutTableCoversTheLetterDigitAndPunctuationKeys() {
        let codes: [UInt16] = [0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
                               0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D,
                               0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C,
                               0x2D, 0x2E, 0x2F, 0x32]
        let characters = codes.compactMap(KeyChord.usLayoutCharacter(forKeyCode:))
        #expect(characters.count == codes.count)
        #expect(Set(characters).count == codes.count)
        #expect(Set(characters).isSuperset(of: "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)))
        #expect(KeyChord.usLayoutCharacter(forKeyCode: 0x31) == nil)  // Space
        #expect(KeyChord.usLayoutCharacter(forKeyCode: 0x7C) == nil)  // Right arrow
    }

    @Test func menuKeyEquivalents() {
        #expect(KeyChord(.right).menuKeyEquivalent == "\u{F703}")
        #expect(KeyChord("p").menuKeyEquivalent == "p")
        #expect(KeyChord(.space).menuKeyEquivalent == " ")
    }
}

@Suite("Key bindings")
struct KeyBindingsTests {
    let keys = KeyBindings.defaults

    @Test func defaultsFollowTheDesignTable() {
        let expected: [(String, Command)] = [
            ("p", .keep), ("x", .reject), ("u", .clearDecision),
            ("left", .previousPhoto), ("right", .nextPhoto), ("up", .previousRow), ("down", .nextRow),
            ("return", .acceptStack), ("shift+x", .rejectCertain), ("space", .toggleLoupe),
            ("z", .zoomToggle), ("tab", .nextFace), ("c", .showCompare), ("f", .toggleFaceStrip),
            ("g", .addToStack), ("shift+g", .splitFromStack),
            ("1", .rate1), ("2", .rate2), ("3", .rate3), ("4", .rate4), ("5", .rate5), ("0", .rate0),
            ("cmd+]", .nextGroup), ("cmd+[", .previousGroup), ("i", .toggleInspector),
            ("cmd+z", .undo), ("shift+cmd+z", .redo), ("cmd+return", .reviewAndApply),
            ("cmd+o", .openFolder), ("cmd+,", .openSettings),
            ("shift+tab", .previousFace), ("b", .toggleFaceBoxes), ("j", .toggleClippingOverlay),
            ("h", .toggleBestPickPane),
        ]
        for (text, command) in expected {
            #expect(keys.command(for: KeyChord(string: text)!) == command, "\(text)")
        }
    }

    @Test func everyCommandHasAKey() {
        for command in Command.allCases {
            #expect(keys.primaryChord(for: command) != nil, "\(command) has no key")
        }
    }

    @Test func theBestPickPaneKeyIsAViewChange() {
        let command = Command.toggleBestPickPane
        #expect(command.rawValue == "toggleBestPickPane")
        #expect(command.title == "Show Best Pick Pane")
        #expect(command.settingsTitle == "Show or Hide Best Pick Pane")
        #expect(command.settingsSection == "Views")
        #expect(!command.isDecision)
        #expect(keys.primaryChord(for: command) == KeyChord("h"))
        // Plain H is free, and ⌘H stays the system's.
        #expect(keys.conflict(assigning: KeyChord("h"), to: command) == nil)
        #expect(keys.command(for: KeyChord("h", .command)) == nil)
        #expect(keys.conflicts.isEmpty)
    }

    @Test func noChordIsBoundTwice() {
        let chords = keys.bindings.map(\.chord)
        #expect(Set(chords).count == chords.count)
    }

    @Test func shiftedSymbolsFallBackToTheUnshiftedBinding() {
        // ⌘+ arrives as "+" with Shift held.
        #expect(keys.command(for: KeyChord("+", [.command, .shift])) == .largerThumbnails)
        // Shift with a letter is its own chord: ⇧P is not bound.
        #expect(keys.command(for: KeyChord("p", .shift)) == nil)
        #expect(keys.command(for: KeyChord("q")) == nil)
    }

    @Test func rebindingIsADataChange() throws {
        var custom = keys
        custom.bind(KeyChord("k"), to: .keep)
        #expect(custom.command(for: KeyChord("k")) == .keep)
        #expect(custom.command(for: KeyChord("p")) == .keep)
        #expect(custom.primaryChord(for: .keep) == KeyChord("p"))
        custom.unbind(.keep)
        #expect(custom.command(for: KeyChord("p")) == nil)
        custom.bind(KeyChord("p"), to: .reject)
        #expect(custom.command(for: KeyChord("p")) == .reject)

        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(KeyBindings.self, from: data)
        #expect(decoded == custom)
        #expect(decoded.command(for: KeyChord("p")) == .reject)
    }

    @Test func commandsHaveStableNamesAndTitles() {
        #expect(Command(rawValue: "keep") == .keep)
        #expect(Command.rate(3) == .rate3)
        #expect(Command.rate(9) == .rate5)
        #expect(Command.rate3.rating == 3)
        #expect(Command.keep.rating == nil)
        #expect(Command.allCases.allSatisfy { !$0.title.isEmpty })
    }
}

@Suite("Grid selection")
struct GridSelectionTests {
    let order = PhotoOrder(["a", "b", "c", "d", "e", "f", "g"])

    @Test func arrowsMoveTheFocusAndStayInside() {
        var selection = GridSelection(focus: "a")
        selection.move(by: 1, extend: false, in: order)
        #expect(selection.focus == "b")
        #expect(selection.selected == ["b"])
        selection.move(by: -5, extend: false, in: order)
        #expect(selection.focus == "a")
        selection.move(by: 3, extend: false, in: order)  // a row of three
        #expect(selection.focus == "d")
        selection.move(by: 30, extend: false, in: order)
        #expect(selection.focus == "g")
    }

    @Test func withoutAFocusTheFirstOrLastIsFocused() {
        var selection = GridSelection()
        selection.move(by: 1, extend: false, in: order)
        #expect(selection.focus == "a")
        var back = GridSelection()
        back.move(by: -1, extend: false, in: order)
        #expect(back.focus == "g")
    }

    @Test func shiftExtendsFromTheAnchor() {
        var selection = GridSelection(focus: "c")
        selection.move(by: 1, extend: true, in: order)
        selection.move(by: 1, extend: true, in: order)
        #expect(selection.focus == "e")
        #expect(selection.selected == ["c", "d", "e"])
        selection.move(by: -3, extend: true, in: order)
        #expect(selection.selected == ["b", "c"])
        #expect(selection.targets(in: order) == ["b", "c"])
        selection.move(by: 1, extend: false, in: order)
        #expect(selection.selected == ["c"])
    }

    @Test func clicksSelectExtendAndToggle() {
        var selection = GridSelection()
        selection.click("b", kind: .plain, in: order)
        selection.click("e", kind: .extend, in: order)
        #expect(selection.selected == ["b", "c", "d", "e"])
        #expect(selection.focus == "e")
        selection.click("g", kind: .toggle, in: order)
        #expect(selection.selected == ["b", "c", "d", "e", "g"])
        selection.click("c", kind: .toggle, in: order)
        #expect(selection.selected == ["b", "d", "e", "g"])
        #expect(selection.targets(in: order) == ["b", "d", "e", "g"])
        selection.click("a", kind: .plain, in: order)
        #expect(selection.selected == ["a"])
    }

    @Test func selectAllAndDeselect() {
        var selection = GridSelection(focus: "c")
        selection.selectAll(in: order)
        #expect(selection.selected.count == 7)
        #expect(selection.focus == "c")
        selection.deselectAll()
        #expect(selection.selected == ["c"])
    }

    @Test func pruneMovesALostFocusToTheFallback() {
        var selection = GridSelection(focus: "c")
        selection.prune(to: PhotoOrder(["a", "b", "d"]), fallback: "d")
        #expect(selection.focus == "d")
        #expect(selection.selected == ["d"])

        var multiple = GridSelection(focus: "a")
        multiple.selectAll(in: order)
        multiple.prune(to: PhotoOrder(["a", "e"]))
        #expect(multiple.selected == ["a", "e"])
        #expect(multiple.focus == "a")

        var gone = GridSelection(focus: "a")
        gone.prune(to: .empty)
        #expect(gone.focus == nil)
        #expect(gone.selected.isEmpty)
    }

    @Test func targetsAreTheFocusWhenOnlyOneIsSelected() {
        var selection = GridSelection(focus: "b")
        #expect(selection.targets(in: order) == ["b"])
        selection.click("b", kind: .toggle, in: order)  // unselect the focus
        #expect(selection.selected.isEmpty)
        #expect(selection.targets(in: order) == ["b"])
    }
}

@Suite("Undo menu names")
struct ActionNameTests {
    @Test func namesSayWhatUndoTakesBack() {
        #expect(SessionAction.setDecision(.kept, ids: ["a"]).menuName == "Keep")
        #expect(SessionAction.setDecision(.rejected, ids: ["a", "b", "c"]).menuName == "Reject 3 Photos")
        #expect(SessionAction.setDecision(.unreviewed, ids: ["a"]).menuName == "Clear Decision")
        #expect(SessionAction.setRating(4, ids: ["a"]).menuName == "Rate 4 Stars")
        #expect(SessionAction.setRating(1, ids: ["a"]).menuName == "Rate 1 Star")
        #expect(SessionAction.setRating(0, ids: ["a", "b"]).menuName == "Clear 2 Ratings")
    }

    @Test func sidebarCountsAndEmptyLines() {
        #expect(GroupID.allPhotos.showsLeftCount)
        #expect(!GroupID.kept.showsLeftCount)
        #expect(GroupID.eyesClosed.emptyMessage == "No closed eyes found")
        #expect(GroupID.allCases.filter(\.needsAnalysis).count == 6)
    }
}
