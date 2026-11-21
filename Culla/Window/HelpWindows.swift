import AppKit
import CullaCommands
import SwiftUI

/// Culla ▸ About Culla: the name, version, what it is, that it is free and open source under
/// the MIT licence, and the credits.
@MainActor
final class AboutWindowController: NSWindowController {
    init() {
        let host = NSHostingController(rootView: AboutView())
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = localized("About Culla")
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("about")
        window.backgroundColor = Palette.windowBackground
        super.init(window: window)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(activate: Bool) {
        if activate {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }
}

/// What the About window says. The version and build come from the bundle.
struct AboutView: View {
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String ?? "1"
        return localized("Version \(version) (\(build))")
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: Palette.appIcon)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityLabel(localized("Culla icon"))
            Text(verbatim: "Culla")
                .font(.system(size: 24, weight: .semibold))
            Text(Self.version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(localized("Sort a shoot into keepers and rejects, from the keyboard."))
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            VStack(spacing: 3) {
                Text(localized("Free and open source"))
                    .font(.callout.weight(.medium))
                Text(localized("Released under the MIT License"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
            Divider().padding(.vertical, 4)
            VStack(spacing: 3) {
                Text(localized("Built with Apple Vision"))
                Text(localized("Core Image and ImageIO, on this Mac only. No network access."))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .multilineTextAlignment(.center)
            Text(localized("© 2026 Kerim Pirliyev"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 24)
        .frame(width: 360)
        .background(Palette.windowBackgroundColor)
    }
}

/// Help ▸ Keyboard Shortcuts: every command with the keys the live key map gives it, so a key
/// remapped in Settings shows here as it is.
@MainActor
final class KeyboardShortcutsWindowController: NSWindowController {
    init(app: AppModel) {
        let host = NSHostingController(rootView: KeyboardShortcutsView(app: app))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        window.contentViewController = host
        window.setContentSize(NSSize(width: 620, height: 600))
        window.minSize = NSSize(width: 480, height: 320)
        window.title = localized("window.keyboardShortcuts", default: "Keyboard Shortcuts")
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("keyboardShortcuts")
        window.backgroundColor = Palette.windowBackground
        super.init(window: window)
        window.center()
        if !app.environment.isAutomation { window.setFrameAutosaveName("KeyboardShortcuts") }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(activate: Bool) {
        if activate {
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }
}

struct KeyboardShortcutsView: View {
    let app: AppModel

    var body: some View {
        // Read here so the sheet follows a key remapped while it is open.
        let keys = app.settings.keyBindings
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Every culling action is one key. Unreviewed photos count as kept, so you only have to find the rejects."))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(localized("Change any key in Settings ▸ Keys (\(keys.primaryChord(for: .openSettings)?.displayString ?? "⌘,"))."))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                ForEach(Command.settingsSections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                            ForEach(Command.allCases.filter { $0.settingsSection == section }, id: \.self) { command in
                                let chords = keys.chords(for: command)
                                GridRow {
                                    HStack(spacing: 4) {
                                        if chords.isEmpty {
                                            Text(localized("No key")).foregroundStyle(.tertiary)
                                        } else {
                                            ForEach(chords, id: \.self) { KeyCapLabel(text: $0.displayString) }
                                        }
                                    }
                                    .frame(width: 130, alignment: .trailing)
                                    Text(command.settingsTitle)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(Self.spoken(command, chords)))
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.windowBackgroundColor)
    }

    static func spoken(_ command: Command, _ chords: [KeyChord]) -> String {
        chords.isEmpty
            ? localized("\(command.settingsTitle): no key")
            : localized("shortcuts.spoken", default: "\(command.settingsTitle): \(KeyText.list(chords.map(\.spokenName)))")
    }
}

/// Where the documentation lives: the `docs` folder of the source repository, opened as a local
/// folder. A debug build knows the folder it was built from; any build also looks beside the
/// app, for a copy of Culla kept in its source folder.
enum DocumentationFolder {
    static var url: URL? {
        var candidates: [URL] = []
        #if DEBUG
        // Culla/Window/HelpWindows.swift → the repository's docs folder.
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true))
        #endif
        let app = Bundle.main.bundleURL
        candidates.append(app.deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true))
        candidates.append(app.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true))
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("design.md").path) }
    }
}
