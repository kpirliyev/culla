import Foundation

/// One key press: a key and the modifier keys held with it. Knows nothing about AppKit, so key
/// bindings can be stored, tested and edited as plain data; the app turns its key events into
/// chords with `KeyChord(eventCharacters:keyCode:modifiers:)`.
public struct KeyChord: Hashable, Sendable, Codable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// A key that does not type a character, by name.
    public enum Special: String, CaseIterable, Sendable, Codable {
        case left, right, up, down
        case space, `return`, tab, escape, delete, forwardDelete
        case home, end, pageUp = "pageup", pageDown = "pagedown"
    }

    /// Either a single lowercase character such as "p", "1" or "]", or a `Special` key's name.
    public let key: String
    public let modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        if let special = Special(rawValue: key.lowercased()) {
            self.key = special.rawValue
        } else {
            self.key = key.lowercased()
        }
        self.modifiers = modifiers
    }

    public init(_ special: Special, _ modifiers: Modifiers = []) {
        self.init(special.rawValue, modifiers)
    }

    public var special: Special? { Special(rawValue: key) }

    // MARK: - Text form

    /// Parses the text form used in scripts and saved bindings: modifier names and the key joined
    /// by "+", such as "p", "shift+x", "cmd+]", "shift+cmd+z", "space" or "right". Modifier names:
    /// cmd (or command), shift, opt (option, alt), ctrl (control). A lone "+" is the plus key.
    public init?(string: String) {
        let text = string.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        // "cmd++" splits into ["cmd", "", ""]: the key is "+".
        if text.hasSuffix("+") {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let keyPart = parts.popLast(), !keyPart.isEmpty else { return nil }
        var modifiers: Modifiers = []
        for part in parts {
            switch part.lowercased() {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default: return nil
            }
        }
        if Special(rawValue: keyPart.lowercased()) == nil, keyPart.count != 1 {
            return nil
        }
        self.init(keyPart, modifiers)
    }

    /// The text form, such as "shift+cmd+z". `KeyChord(string:)` reads it back.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// How a menu or a help text shows the chord, such as "⇧⌘Z", "→" or "Space".
    public var displayString: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch special {
        case .left: text += "←"
        case .right: text += "→"
        case .up: text += "↑"
        case .down: text += "↓"
        case .space: text += localized("key.space", default: "Space")
        case .return: text += "↩"
        case .tab: text += "⇥"
        case .escape: text += "⎋"
        case .delete: text += "⌫"
        case .forwardDelete: text += "⌦"
        case .home: text += "↖"
        case .end: text += "↘"
        case .pageUp: text += "⇞"
        case .pageDown: text += "⇟"
        case nil: text += key.uppercased()
        }
        return text
    }

    /// The chord in words, for VoiceOver: "Shift Command Z", "Right Arrow", "Space", in the
    /// language of the interface. Letters and digits stay as they are.
    public var spokenName: String {
        var words: [String] = []
        if modifiers.contains(.control) { words.append(localized("spoken.control", default: "Control")) }
        if modifiers.contains(.option) { words.append(localized("spoken.option", default: "Option")) }
        if modifiers.contains(.shift) { words.append(localized("spoken.shift", default: "Shift")) }
        if modifiers.contains(.command) { words.append(localized("spoken.command", default: "Command")) }
        switch special {
        case .left: words.append(localized("spoken.leftArrow", default: "Left Arrow"))
        case .right: words.append(localized("spoken.rightArrow", default: "Right Arrow"))
        case .up: words.append(localized("spoken.upArrow", default: "Up Arrow"))
        case .down: words.append(localized("spoken.downArrow", default: "Down Arrow"))
        case .space: words.append(localized("spoken.space", default: "Space"))
        case .return: words.append(localized("spoken.return", default: "Return"))
        case .tab: words.append(localized("spoken.tab", default: "Tab"))
        case .escape: words.append(localized("spoken.escape", default: "Escape"))
        case .delete: words.append(localized("spoken.delete", default: "Delete"))
        case .forwardDelete: words.append(localized("spoken.forwardDelete", default: "Forward Delete"))
        case .home: words.append(localized("spoken.home", default: "Home"))
        case .end: words.append(localized("spoken.end", default: "End"))
        case .pageUp: words.append(localized("spoken.pageUp", default: "Page Up"))
        case .pageDown: words.append(localized("spoken.pageDown", default: "Page Down"))
        case nil:
            switch key {
            case "+": words.append(localized("spoken.plus", default: "Plus"))
            case "-": words.append(localized("spoken.minus", default: "Minus"))
            case "=": words.append(localized("spoken.equals", default: "Equals"))
            case ",": words.append(localized("spoken.comma", default: "Comma"))
            case "[": words.append(localized("spoken.leftBracket", default: "Left Bracket"))
            case "]": words.append(localized("spoken.rightBracket", default: "Right Bracket"))
            default: words.append(key.uppercased())
            }
        }
        return words.joined(separator: " ")
    }

    // MARK: - Key events

    /// The chord for a key event, from the event's characters with modifiers ignored (AppKit's
    /// `charactersIgnoringModifiers`, which still applies Shift) and its modifier keys. Nil for
    /// events that are no single key, such as a dead key.
    ///
    /// Letters are matched without case, so Caps Lock does not change the meaning of a key, and
    /// AppKit's private-use characters for arrows and other function keys become `Special` keys.
    public init?(eventCharacters: String, modifiers: Modifiers) {
        guard eventCharacters.unicodeScalars.count == 1, let scalar = eventCharacters.unicodeScalars.first else {
            return nil
        }
        if let special = Self.specialKey(for: scalar.value) {
            self.init(special, modifiers)
        } else if scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) {
            return nil
        } else {
            self.init(String(Character(scalar)), modifiers)
        }
    }

    /// The chord for a key event, as `init(eventCharacters:modifiers:)`, falling back to the key's
    /// position when the typed character is not one a binding can use.
    ///
    /// Bindings are written with ASCII letters, digits and punctuation. On a Russian layout the P
    /// key types "з", and a Turkmen layout puts "ä", "ç", "ž" or "ň" where Latin letters were, so
    /// such a key would match nothing. When the typed character is not printable ASCII, the
    /// character the same key types on the US layout is used instead (from the key's virtual key
    /// code, `NSEvent.keyCode`): "з" on the P key is P, "ч" on the X key is X. Shift stays a
    /// modifier, so "З" on the P key is ⇧P. A typed ASCII character always wins, so a layout that
    /// moves letters (AZERTY's A on the Q key) keeps its own letters, and keys that type no
    /// character (arrows, Return) are named as before.
    public init?(eventCharacters: String, keyCode: UInt16, modifiers: Modifiers) {
        let scalars = eventCharacters.unicodeScalars
        let typed = scalars.count == 1 ? scalars.first : nil
        if let typed, Self.specialKey(for: typed.value) != nil || Self.isBindable(typed) {
            self.init(eventCharacters: eventCharacters, modifiers: modifiers)
        } else if let position = Self.usLayoutCharacter(forKeyCode: keyCode) {
            self.init(position, modifiers)
        } else {
            self.init(eventCharacters: eventCharacters, modifiers: modifiers)
        }
    }

    /// True for the characters key bindings are written with: printable ASCII other than space.
    static func isBindable(_ scalar: Unicode.Scalar) -> Bool {
        (0x21...0x7E).contains(scalar.value)
    }

    /// The character a key types on the US layout without modifiers, by its virtual key code
    /// (`kVK_ANSI_*` in Carbon's Events.h: the key's position, whatever the layout); nil for keys
    /// outside the letter, digit and punctuation block (those type the same on every layout or no
    /// character at all).
    public static func usLayoutCharacter(forKeyCode keyCode: UInt16) -> String? {
        usLayout[keyCode]
    }

    private static let usLayout: [UInt16: String] = [
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h", 0x05: "g", 0x06: "z", 0x07: "x",
        0x08: "c", 0x09: "v", 0x0B: "b", 0x0C: "q", 0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y",
        0x11: "t", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x16: "6", 0x17: "5", 0x18: "=",
        0x19: "9", 0x1A: "7", 0x1B: "-", 0x1C: "8", 0x1D: "0", 0x1E: "]", 0x1F: "o", 0x20: "u",
        0x21: "[", 0x22: "i", 0x23: "p", 0x25: "l", 0x26: "j", 0x27: "'", 0x28: "k", 0x29: ";",
        0x2A: "\\", 0x2B: ",", 0x2C: "/", 0x2D: "n", 0x2E: "m", 0x2F: ".", 0x32: "`",
    ]

    /// AppKit's character codes for keys that type no character (NSEvent function-key constants).
    static func specialKey(for value: UInt32) -> Special? {
        switch value {
        case 0xF702: .left
        case 0xF703: .right
        case 0xF700: .up
        case 0xF701: .down
        case 0x20: .space
        case 0x0D, 0x03: .return  // Return, and Enter on the keypad
        case 0x09, 0x19: .tab  // Tab, and Shift-Tab (back tab)
        case 0x1B: .escape
        case 0x7F, 0x08: .delete
        case 0xF728: .forwardDelete
        case 0xF729: .home
        case 0xF72B: .end
        case 0xF72C: .pageUp
        case 0xF72D: .pageDown
        default: nil
        }
    }

    /// The key as an AppKit menu item's key equivalent: the character, or the function-key
    /// character for a special key. Menus combine it with `modifiers`.
    public var menuKeyEquivalent: String {
        let scalar: UInt32? = switch special {
        case .left: 0xF702
        case .right: 0xF703
        case .up: 0xF700
        case .down: 0xF701
        case .space: 0x20
        case .return: 0x0D
        case .tab: 0x09
        case .escape: 0x1B
        case .delete: 0x08
        case .forwardDelete: 0xF728
        case .home: 0xF729
        case .end: 0xF72B
        case .pageUp: 0xF72C
        case .pageDown: 0xF72D
        case nil: nil
        }
        guard let scalar, let unicode = Unicode.Scalar(scalar) else { return key }
        return String(Character(unicode))
    }
}
