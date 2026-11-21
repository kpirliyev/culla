import AppKit
import CullaCore

/// The app's entry point. Culla uses the AppKit life cycle: one window whose content is SwiftUI
/// and AppKit views, a menu bar built from the command list, and a key router in front of both.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    private let model: AppModel
    private let router: KeyRouter
    private let menu: MainMenu
    private var windowController: MainWindowController?
    /// The Settings window, made the first time it is asked for.
    private var madeSettingsController: SettingsWindowController?
    private var settingsController: SettingsWindowController {
        if let madeSettingsController { return madeSettingsController }
        let controller = SettingsWindowController(app: model)
        madeSettingsController = controller
        return controller
    }
    /// The About window and Help ▸ Keyboard Shortcuts, made the first time they are asked for.
    private var aboutController: AboutWindowController?
    private var shortcutsController: KeyboardShortcutsWindowController?
    /// What Help ▸ Culla Documentation did last, for the automation dump.
    private var lastDocumentationAction: [String: Any]?
    /// A folder handed over before the window existed, such as one dropped on the Dock icon to
    /// launch the app.
    private var pendingOpen: URL?
    private var isTerminating = false

    #if DEBUG
    private var automation: AutomationRunner?
    #endif

    override init() {
        #if DEBUG
        let script = AutomationRunner.scriptPath()
        let environment = AppEnvironment.make(automation: script != nil)
        if script != nil { AutomationRunner.prepareEnvironment(environment) }
        #else
        let environment = AppEnvironment.make(automation: false)
        #endif
        model = AppModel(environment: environment)
        router = KeyRouter(app: model)
        menu = MainMenu(app: model)
        super.init()
        model.showSettings = { [weak self] in self?.showSettings() }
        model.keyBindingsChanged = { [weak self] in self?.menu.refreshKeyEquivalents() }
        model.showKeyboardShortcuts = { [weak self] in self?.showKeyboardShortcuts() }
        menu.showAbout = { [weak self] in self?.showAbout() }
        menu.showKeyboardShortcuts = { [weak self] in self?.showKeyboardShortcuts() }
        menu.openDocumentation = { [weak self] in self?.openDocumentation() }
        #if DEBUG
        if let script {
            automation = AutomationRunner(scriptPath: script, app: model, router: router)
            automation?.settingsController = { [weak self] in self?.settingsController }
            automation?.existingSettingsController = { [weak self] in self?.madeSettingsController }
            automation?.menuKeyEquivalents = { [weak self] in self?.menu.keyEquivalents() ?? [:] }
            automation?.auxiliaryWindows = { [weak self] in
                var windows: [String: NSWindow] = [:]
                if let window = self?.aboutController?.window { windows["about"] = window }
                if let window = self?.shortcutsController?.window { windows["help"] = window }
                return windows
            }
            automation?.auxiliaryNote = { [weak self] in self?.lastDocumentationAction }
            automation?.showAuxiliaryWindow = { [weak self] name in
                guard let self else { return "" }
                switch name {
                case "about": self.showAbout()
                case "help": self.showKeyboardShortcuts()
                case "docs": self.openDocumentation()
                case "close":
                    self.aboutController?.close()
                    self.shortcutsController?.close()
                case "dockMenu":
                    let titles = self.menu.dockMenu().items.map(\.title)
                    self.lastDocumentationAction = ["dockMenu": titles]
                    return titles.joined(separator: " | ")
                default: throw AutomationRunner.Failure("Windows: about, help, docs, dockMenu, close")
                }
                return name
            }
        }
        #endif
    }

    // MARK: About and Help

    private var isAutomation: Bool { model.environment.isAutomation }

    private func showAbout() {
        let controller = aboutController ?? AboutWindowController()
        aboutController = controller
        controller.show(activate: !isAutomation)
    }

    private func showKeyboardShortcuts() {
        let controller = shortcutsController ?? KeyboardShortcutsWindowController(app: model)
        shortcutsController = controller
        controller.show(activate: !isAutomation)
    }

    /// Opens the repository's docs folder in the Finder, a local folder rather than a web page.
    private func openDocumentation() {
        guard let folder = DocumentationFolder.url else {
            lastDocumentationAction = ["opened": NSNull()]
            let alert = NSAlert()
            alert.messageText = localized("The documentation is in Culla’s source code")
            alert.informativeText = localized("Culla’s docs folder holds the design, the user flows and the plan, as Markdown files. Keyboard Shortcuts in this menu lists every key.")
            alert.addButton(withTitle: localized("button.ok", default: "OK"))
            alert.addButton(withTitle: localized("Show Keyboard Shortcuts"))
            if isAutomation { return }
            if alert.runModal() == .alertSecondButtonReturn { showKeyboardShortcuts() }
            return
        }
        lastDocumentationAction = ["opened": folder.path]
        // Automation records the folder; it never opens Finder windows on the person's screen.
        if isAutomation { return }
        if !NSWorkspace.shared.open(folder) {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }

    /// The Dock icon's menu lists the recent shoots.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        menu.dockMenu()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.mainMenu = menu.build()
        #if DEBUG
        if automation != nil {
            // Runs in the background: no Dock icon, never takes focus from what the person is doing.
            NSApp.setActivationPolicy(.accessory)
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainWindowController(app: model)
        windowController = controller
        router.install()
        SystemAccessibility.startObserving()
        // The thumbnail cache is kept under its limit from the start.
        model.pruneCache()
        // The shoot's top bar is laid out while the welcome view waits, not when a folder is opened.
        DispatchQueue.main.async { controller.prewarmTopBar() }
        #if DEBUG
        if let automation {
            controller.showInBackground()
            automation.start(window: controller)
            return
        }
        #endif
        controller.showWindow(nil)
        NSApp.activate()
        Task { await model.reloadRecents() }
        if let pendingOpen {
            self.pendingOpen = nil
            model.openFolder(at: pendingOpen)
        }
    }

    /// ⌘, and App ▸ Settings…
    private func showSettings() {
        #if DEBUG
        if automation != nil {
            settingsController.show(activate: false)
            return
        }
        #endif
        settingsController.show()
    }

    /// Folders dropped on the Dock icon or opened from the Finder. The system grants the sandbox
    /// access to them.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if windowController == nil {
            pendingOpen = url
        } else {
            windowController?.window?.makeKeyAndOrderFront(nil)
            model.openFolder(at: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Quitting waits until every decision is written, so quitting at any moment loses nothing.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }
        isTerminating = true
        Task {
            await model.prepareToQuit()
            if model.reopensAfterQuit { await reopen() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Opens a new instance of Culla once this one has saved everything, for a language change.
    /// The new instance starts before this one exits, so the request reaches Launch Services;
    /// by then this one holds no unsaved work and only finishes quitting.
    private func reopen() async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }
}
