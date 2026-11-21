/// Why a chord cannot simply be given to a command.
public enum KeyConflict: Hashable, Sendable {
    /// Another command sends the chord now.
    case command(KeyChord, Command)
    /// The system or a fixed menu item (named) uses the chord.
    case reserved(KeyChord, String)

    public var chord: KeyChord {
        switch self {
        case .command(let chord, _), .reserved(let chord, _): chord
        }
    }

    /// The warning, such as "⇧X is used by Reject All Certain in Group".
    public var message: String {
        switch self {
        case .command(let chord, let command): localized("\(chord.displayString) is used by \(command.settingsTitle).")
        case .reserved(let chord, let name): localized("\(chord.displayString) is kept for \(name) and cannot be changed.")
        }
    }
}

/// One key chord and the command it sends.
public struct KeyBinding: Hashable, Sendable, Codable {
    public var chord: KeyChord
    public var command: Command

    public init(_ chord: KeyChord, _ command: Command) {
        self.chord = chord
        self.command = command
    }
}

/// Which key sends which command. The only place that knows about keys: remapping a key is a
/// change to this data, and menus show whatever chord it gives a command.
///
/// A command may have several chords (the first is the one menus show); a chord sends at most
/// one command, the last one listed for it.
public struct KeyBindings: Hashable, Sendable, Codable {
    public private(set) var bindings: [KeyBinding]
    private var byChord: [KeyChord: Command]

    public init(_ bindings: [KeyBinding]) {
        self.bindings = bindings
        var byChord: [KeyChord: Command] = [:]
        for binding in bindings { byChord[binding.chord] = binding.command }
        self.byChord = byChord
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode([KeyBinding].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bindings)
    }

    /// Two maps are equal when every command has the same chords in the same order, wherever it
    /// sits in the list.
    public static func == (lhs: KeyBindings, rhs: KeyBindings) -> Bool { lhs.byCommand == rhs.byCommand }
    public func hash(into hasher: inout Hasher) { hasher.combine(byCommand) }

    private var byCommand: [Command: [KeyChord]] {
        Dictionary(grouping: bindings, by: \.command).mapValues { $0.map(\.chord) }
    }

    /// The command a key press sends, or nil when the key is not bound.
    ///
    /// When the exact chord is not bound and Shift is held with a key that is not a letter, the
    /// chord is tried again without Shift, because Shift is then already part of the character:
    /// ⌘+ arrives as "+" with Shift held, and is bound as "cmd++".
    public func command(for chord: KeyChord) -> Command? {
        if let command = byChord[chord] { return command }
        if chord.modifiers.contains(.shift), chord.special == nil,
           let first = chord.key.unicodeScalars.first, !first.properties.isAlphabetic {
            var modifiers = chord.modifiers
            modifiers.remove(.shift)
            return byChord[KeyChord(chord.key, modifiers)]
        }
        return nil
    }

    /// Every chord bound to a command, the one menus show first.
    public func chords(for command: Command) -> [KeyChord] {
        bindings.filter { $0.command == command }.map(\.chord)
    }

    /// The chord menus show for a command.
    public func primaryChord(for command: Command) -> KeyChord? {
        bindings.first { $0.command == command }?.chord
    }

    /// Binds a chord to a command, replacing what the chord sent before.
    public mutating func bind(_ chord: KeyChord, to command: Command) {
        bindings.removeAll { $0.chord == chord }
        bindings.append(KeyBinding(chord, command))
        byChord[chord] = command
    }

    /// Removes every chord of a command.
    public mutating func unbind(_ command: Command) {
        for binding in bindings where binding.command == command { byChord[binding.chord] = nil }
        bindings.removeAll { $0.command == command }
    }

    // MARK: - Remapping

    /// Gives a command exactly these chords, in this order (the first is the one menus show).
    /// A chord another command had moves to this one: a chord never sends two commands.
    public mutating func setChords(_ chords: [KeyChord], for command: Command) {
        var list: [KeyBinding] = []
        var placed = false
        // The command keeps its place in the list, so the key map reads in the same order.
        for binding in bindings {
            if binding.command == command {
                if !placed { list += chords.map { KeyBinding($0, command) } }
                placed = true
            } else if !chords.contains(binding.chord) {
                list.append(binding)
            }
        }
        if !placed { list += chords.map { KeyBinding($0, command) } }
        self = KeyBindings(list)
    }

    /// Replaces one of a command's chords with another, or adds one when `old` is nil or not one
    /// of its chords, keeping its other chords where they are (so ⌘= stays when ⌘+ is changed).
    /// A chord another command had moves to this one.
    public mutating func replace(_ old: KeyChord?, with new: KeyChord, for command: Command) {
        var chords = chords(for: command)
        if let old, let index = chords.firstIndex(of: old) {
            chords[index] = new
        } else {
            chords.append(new)
        }
        var seen = Set<KeyChord>()
        setChords(chords.filter { seen.insert($0).inserted }, for: command)
    }

    /// Removes one chord from a command, keeping its others.
    public mutating func remove(_ chord: KeyChord, from command: Command) {
        setChords(chords(for: command).filter { $0 != chord }, for: command)
    }

    /// The command's default chords put back, taken from any command that had them since.
    public mutating func reset(_ command: Command) {
        setChords(Self.defaults.chords(for: command), for: command)
    }

    /// What stops a chord from being given to a command, if anything: another command already
    /// sends it, or the system or a fixed menu item uses it.
    public func conflict(assigning chord: KeyChord, to command: Command) -> KeyConflict? {
        if let reserved = Self.reserved[chord] { return .reserved(chord, reserved) }
        if let other = byChord[chord], other != command { return .command(chord, other) }
        return nil
    }

    /// Problems in the map itself: a chord listed for more than one command (only the last one
    /// listed sends it), or a chord the system or a fixed menu item takes first. Saved maps from
    /// an older version can have these; maps edited in Settings cannot.
    public var conflicts: [KeyConflict] {
        var result: [KeyConflict] = []
        var seen: [KeyChord: Command] = [:]
        let reservedNames = Self.reserved
        for binding in bindings {
            if let reserved = reservedNames[binding.chord] {
                result.append(.reserved(binding.chord, reserved))
            } else if let first = seen[binding.chord], first != binding.command {
                result.append(.command(binding.chord, first))
            }
            seen[binding.chord] = binding.command
        }
        return result
    }

    /// Chords Culla cannot give to a command: the application and window menu items that are
    /// not commands (they are fixed, as in every Mac app), and the keys macOS keeps for itself.
    /// The names are in the language of the interface, as the menus show them.
    public static var reserved: [KeyChord: String] {
        [
            KeyChord("q", .command): localized("Quit Culla"),
            KeyChord("h", .command): localized("Hide Culla"),
            KeyChord("h", [.command, .option]): localized("Hide Others"),
            KeyChord("m", .command): localized("Minimize"),
            KeyChord("`", .command): localized("Cycle Through Windows"),
            KeyChord(.tab, .command): localized("the app switcher"),
            KeyChord(.space, .command): "Spotlight",
            KeyChord("/", .command): localized("Help ▸ Keyboard Shortcuts"),
            KeyChord("/", [.command, .shift]): localized("reserved.help", default: "Help"),
        ]
    }

    /// True for chords a key recorder should not take as a shortcut at all: modifier-only or
    /// Control-Tab style chords are never produced; a bare Escape cancels recording and a bare
    /// Delete clears the command's keys, so neither is recorded.
    public static func isRecorderControl(_ chord: KeyChord) -> Bool {
        chord.modifiers.isEmpty && (chord.special == .escape || chord.special == .delete)
    }

    /// The key map of the Design doc's keyboard table, plus the usual Mac keys for the menu
    /// commands the table does not list (Select All, Close, Home and End, Page Up and Down,
    /// view switching and thumbnail size).
    public static let defaults = KeyBindings([
        // Decisions, as in Lightroom.
        KeyBinding(KeyChord("p"), .keep),
        KeyBinding(KeyChord("x"), .reject),
        KeyBinding(KeyChord("u"), .clearDecision),
        KeyBinding(KeyChord("0"), .rate0),
        KeyBinding(KeyChord("1"), .rate1),
        KeyBinding(KeyChord("2"), .rate2),
        KeyBinding(KeyChord("3"), .rate3),
        KeyBinding(KeyChord("4"), .rate4),
        KeyBinding(KeyChord("5"), .rate5),
        KeyBinding(KeyChord("x", .shift), .rejectCertain),
        KeyBinding(KeyChord(.return), .acceptStack),
        KeyBinding(KeyChord("g"), .addToStack),
        KeyBinding(KeyChord("g", .shift), .splitFromStack),
        // ⇧S, as Lightroom's "Move to Top of Stack".
        KeyBinding(KeyChord("s", .shift), .chooseBestPick),
        KeyBinding(KeyChord(.return, .shift), .acceptAllExactDuplicates),

        // Moving.
        KeyBinding(KeyChord(.right), .nextPhoto),
        KeyBinding(KeyChord(.left), .previousPhoto),
        KeyBinding(KeyChord(.down), .nextRow),
        KeyBinding(KeyChord(.up), .previousRow),
        KeyBinding(KeyChord(.right, .shift), .extendNext),
        KeyBinding(KeyChord(.left, .shift), .extendPrevious),
        KeyBinding(KeyChord(.down, .shift), .extendNextRow),
        KeyBinding(KeyChord(.up, .shift), .extendPreviousRow),
        KeyBinding(KeyChord(.home), .firstPhoto),
        KeyBinding(KeyChord(.end), .lastPhoto),
        KeyBinding(KeyChord(.pageDown), .pageDown),
        KeyBinding(KeyChord(.pageUp), .pageUp),
        KeyBinding(KeyChord("]", .command), .nextGroup),
        KeyBinding(KeyChord("[", .command), .previousGroup),
        KeyBinding(KeyChord("r", [.command, .shift]), .startReviewing),

        // Analysis.
        KeyBinding(KeyChord("p", [.command, .option]), .toggleAnalysis),
        KeyBinding(KeyChord("t", [.command, .option]), .showTuning),

        // Views.
        KeyBinding(KeyChord(.space), .toggleLoupe),
        KeyBinding(KeyChord("1", .command), .showGrid),
        KeyBinding(KeyChord("2", .command), .showLoupe),
        KeyBinding(KeyChord("c"), .showCompare),
        KeyBinding(KeyChord("3", .command), .showCompare),
        KeyBinding(KeyChord("z"), .zoomToggle),
        KeyBinding(KeyChord(.tab), .nextFace),
        KeyBinding(KeyChord(.tab, .shift), .previousFace),
        // B for face boxes; J for clipping, as in Lightroom.
        KeyBinding(KeyChord("b"), .toggleFaceBoxes),
        KeyBinding(KeyChord("j"), .toggleClippingOverlay),
        KeyBinding(KeyChord("f"), .toggleFaceStrip),
        // H hides the best pick beside the current frame (⌘H stays the system's Hide Culla).
        KeyBinding(KeyChord("h"), .toggleBestPickPane),
        // S expands and collapses stacks, as in Lightroom.
        KeyBinding(KeyChord("s"), .toggleStacks),
        KeyBinding(KeyChord(.escape), .back),
        KeyBinding(KeyChord("i"), .toggleInspector),
        KeyBinding(KeyChord("=", .command), .largerThumbnails),
        KeyBinding(KeyChord("+", .command), .largerThumbnails),
        KeyBinding(KeyChord("-", .command), .smallerThumbnails),

        // Edit and File.
        KeyBinding(KeyChord("z", .command), .undo),
        KeyBinding(KeyChord("z", [.command, .shift]), .redo),
        KeyBinding(KeyChord("a", .command), .selectAll),
        KeyBinding(KeyChord("a", [.command, .shift]), .deselectAll),
        KeyBinding(KeyChord(.return, .command), .reviewAndApply),
        // On the Review and Apply screen, where Return peeks at a reject and ⌘Return leaves.
        KeyBinding(KeyChord(.return, [.command, .shift]), .applyDecisions),
        KeyBinding(KeyChord("z", [.command, .option]), .undoApply),
        KeyBinding(KeyChord("r", [.command, .option]), .rescanFolder),
        KeyBinding(KeyChord("o", .command), .openFolder),
        KeyBinding(KeyChord("w", .command), .closeShoot),
        KeyBinding(KeyChord(",", .command), .openSettings),
    ])
}
