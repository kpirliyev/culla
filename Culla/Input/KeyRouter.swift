import AppKit
import CullaCommands

/// Turns key presses into commands. Real key events and the automation harness both come in
/// through `route(_:)`, so a script presses exactly the keys a person does.
///
/// Key events are taken before the window's views see them, so a key always means what the
/// key map says, whatever view has focus. A key that is bound is consumed even when its command
/// is unavailable at the moment; other keys (⌘Q, ⌘H and the like) pass on to the menus.
///
/// On a layout whose keys type letters bindings are not written with (Russian, Turkmen), a key
/// counts by its position: P keeps whatever it types (`KeyChord(eventCharacters:keyCode:modifiers:)`).
@MainActor
final class KeyRouter {
    private let app: AppModel
    private var monitor: Any?
    /// The last chord routed and the command it sent, for diagnostics.
    private(set) var lastRouted: (chord: KeyChord, command: Command?, performed: Bool)?

    init(app: AppModel) {
        self.app = app
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let chord = Self.chord(for: event)
            let windowNumber = event.windowNumber
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.shouldHandle(windowNumber: windowNumber), let chord else { return false }
                return self.route(chord)
            }
            return consumed ? nil : event
        }
    }

    /// Runs the command a chord is bound to. Returns true when the chord is bound (consumed).
    @discardableResult
    func route(_ chord: KeyChord) -> Bool {
        guard let command = app.settings.keyBindings.command(for: chord) else {
            lastRouted = (chord, nil, false)
            return false
        }
        let performed = app.perform(command)
        lastRouted = (chord, command, performed)
        return true
    }

    /// Keys are routed only for the app's main window when no sheet is up and no text is being
    /// typed.
    private func shouldHandle(windowNumber: Int) -> Bool {
        guard let window = app.window, window.windowNumber == windowNumber, window.attachedSheet == nil else { return false }
        if window.firstResponder is NSText { return false }
        return true
    }

    /// The chord of a key event: its characters, or its key's position on layouts whose keys type
    /// letters bindings are not written with. The Settings key recorder reads keys the same way.
    nonisolated static func chord(for event: NSEvent) -> KeyChord? {
        guard let characters = event.charactersIgnoringModifiers else { return nil }
        return KeyChord(eventCharacters: characters, keyCode: event.keyCode, modifiers: modifiers(event.modifierFlags))
    }

    nonisolated static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyChord.Modifiers {
        var modifiers: KeyChord.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        return modifiers
    }

    static func menuModifiers(_ modifiers: KeyChord.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }
}
