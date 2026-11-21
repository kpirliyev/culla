import AppKit
import CullaCommands
import CullaCore
import CullaSession

/// The menu bar. Every item that acts on photos sends a `Command` to the app model, the same
/// command its key and toolbar button send; its key equivalent is read from the key map, and it
/// is enabled exactly when the model says the command is available.
@MainActor
final class MainMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let app: AppModel
    private let recentMenu = NSMenu(title: localized("menu.openRecent", default: "Open Recent"))
    /// Culla ▸ About Culla, Help ▸ Keyboard Shortcuts and Help ▸ Culla Documentation; set by the
    /// app delegate.
    var showAbout: (() -> Void)?
    var showKeyboardShortcuts: (() -> Void)?
    var openDocumentation: (() -> Void)?

    init(app: AppModel) {
        self.app = app
        super.init()
    }

    func build() -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(photoMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(goMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu(title: "Culla")
        let about = menu.addItem(withTitle: localized("menu.aboutCulla", default: "About Culla"), action: #selector(about(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(.separator())
        menu.addItem(command(.openSettings))
        menu.addItem(.separator())
        let services = NSMenuItem(title: localized("menu.services", default: "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: localized("menu.services", default: "Services"))
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: localized("menu.hideCulla", default: "Hide Culla"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: localized("menu.hideOthers", default: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: localized("menu.showAll", default: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: localized("menu.quitCulla", default: "Quit Culla"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.file", default: "File"))
        menu.addItem(command(.openFolder))
        let recent = NSMenuItem(title: localized("menu.openRecent", default: "Open Recent"), action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(command(.closeShoot))
        menu.addItem(.separator())
        menu.addItem(command(.reviewAndApply))
        menu.addItem(command(.undoApply))
        menu.addItem(.separator())
        menu.addItem(command(.rescanFolder))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.edit", default: "Edit"))
        menu.addItem(command(.undo))
        menu.addItem(command(.redo))
        menu.addItem(.separator())
        menu.addItem(command(.selectAll))
        menu.addItem(command(.deselectAll))
        return menu
    }

    private func photoMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.photo", default: "Photo"))
        menu.addItem(command(.keep))
        menu.addItem(command(.reject))
        menu.addItem(command(.clearDecision))
        menu.addItem(.separator())
        let rating = NSMenuItem(title: localized("menu.rating", default: "Rating"), action: nil, keyEquivalent: "")
        let ratingMenu = NSMenu(title: localized("menu.rating", default: "Rating"))
        for command in [Command.rate0, .rate1, .rate2, .rate3, .rate4, .rate5] {
            ratingMenu.addItem(self.command(command))
        }
        rating.submenu = ratingMenu
        menu.addItem(rating)
        menu.addItem(.separator())
        menu.addItem(command(.rejectCertain))
        menu.addItem(.separator())
        menu.addItem(command(.acceptStack))
        menu.addItem(command(.chooseBestPick))
        menu.addItem(command(.addToStack))
        menu.addItem(command(.splitFromStack))
        menu.addItem(.separator())
        menu.addItem(command(.acceptAllExactDuplicates))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.view", default: "View"))
        menu.addItem(command(.showGrid))
        menu.addItem(command(.showLoupe))
        menu.addItem(command(.showCompare))
        menu.addItem(command(.toggleLoupe))
        menu.addItem(command(.back))
        menu.addItem(.separator())
        menu.addItem(command(.toggleStacks))
        menu.addItem(.separator())
        menu.addItem(command(.zoomToggle))
        menu.addItem(command(.toggleFaceBoxes))
        menu.addItem(command(.toggleClippingOverlay))
        menu.addItem(command(.toggleFaceStrip))
        menu.addItem(command(.toggleBestPickPane))
        menu.addItem(.separator())
        menu.addItem(command(.toggleInspector))
        menu.addItem(.separator())
        menu.addItem(command(.showTuning))
        menu.addItem(command(.toggleAnalysis))
        menu.addItem(.separator())
        menu.addItem(command(.largerThumbnails))
        menu.addItem(command(.smallerThumbnails))
        return menu
    }

    private func goMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.go", default: "Go"))
        menu.addItem(command(.startReviewing))
        menu.addItem(.separator())
        for command in [Command.nextPhoto, .previousPhoto, .nextRow, .previousRow, .firstPhoto, .lastPhoto] {
            menu.addItem(self.command(command))
        }
        menu.addItem(.separator())
        menu.addItem(command(.nextGroup))
        menu.addItem(command(.previousGroup))
        menu.addItem(.separator())
        menu.addItem(command(.nextFace))
        menu.addItem(command(.previousFace))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.help", default: "Help"))
        let shortcuts = menu.addItem(withTitle: localized("menu.keyboardShortcuts", default: "Keyboard Shortcuts"), action: #selector(keyboardShortcuts(_:)), keyEquivalent: "/")
        shortcuts.keyEquivalentModifierMask = [.command]
        shortcuts.target = self
        menu.addItem(.separator())
        let docs = menu.addItem(withTitle: localized("menu.cullaDocumentation", default: "Culla Documentation"), action: #selector(documentation(_:)), keyEquivalent: "")
        docs.target = self
        return menu
    }

    @objc private func about(_ sender: Any?) { showAbout?() }
    @objc private func keyboardShortcuts(_ sender: Any?) { showKeyboardShortcuts?() }
    @objc private func documentation(_ sender: Any?) { openDocumentation?() }

    /// The Dock icon's menu: the recent shoots, newest first.
    func dockMenu() -> NSMenu {
        let menu = NSMenu(title: "Dock")
        for recent in app.recents.prefix(8) {
            let item = NSMenuItem(title: recent.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = recent.id
            item.toolTip = recent.displayPath
            menu.addItem(item)
        }
        if !app.recents.isEmpty { menu.addItem(.separator()) }
        menu.addItem(command(.openFolder))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: localized("menu.window", default: "Window"))
        menu.addItem(withTitle: localized("menu.minimize", default: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: localized("menu.zoomWindow", default: "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: localized("menu.bringAllToFront", default: "Bring All to Front"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        return menu
    }

    /// A menu item that sends a command, with the key the key map gives it.
    private func command(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.rawValue
        setKeyEquivalent(of: item, for: command)
        return item
    }

    private func setKeyEquivalent(of item: NSMenuItem, for command: Command) {
        if let chord = app.settings.keyBindings.primaryChord(for: command) {
            item.keyEquivalent = chord.menuKeyEquivalent
            item.keyEquivalentModifierMask = KeyRouter.menuModifiers(chord.modifiers)
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    /// The key map changed in Settings: every command's menu item shows its new key at once.
    func refreshKeyEquivalents() {
        guard let main = NSApp.mainMenu else { return }
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let name = item.representedObject as? String, let command = Command(rawValue: name) {
                    setKeyEquivalent(of: item, for: command)
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        visit(main)
    }

    /// The key each command's menu item shows, as "⇧⌘Z", for the automation dump.
    func keyEquivalents() -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if let name = item.representedObject as? String, Command(rawValue: name) != nil, !item.keyEquivalent.isEmpty {
                    let chord = KeyChord(eventCharacters: item.keyEquivalent, modifiers: KeyRouter.modifiers(item.keyEquivalentModifierMask))
                    result[name] = chord?.displayString ?? item.keyEquivalent
                }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let main = NSApp.mainMenu { visit(main) }
        return result
    }

    // MARK: Actions and validation

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let command = Command(rawValue: name) else { return }
        app.perform(command)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(openRecent(_:)) { return !app.isLoading }
        if item.action == #selector(clearRecents(_:)) { return !app.recents.isEmpty }
        guard let name = item.representedObject as? String, let command = Command(rawValue: name) else { return true }
        let session = app.session
        switch command {
        case .undo: item.title = session?.undoTitle ?? SessionEdit.undoMenuTitle
        case .undoApply:
            item.title = session?.apply.undoMenuTitle.map { localized("menu.withEllipsis", default: "\($0)…") } ?? Command.undoApply.title
        case .reviewAndApply:
            item.title = session?.apply.isOpen == true
                ? localized("menu.leaveReviewAndApply", default: "Leave Review and Apply")
                : localized("menu.reviewAndApply", default: "Review and Apply…")
        case .redo: item.title = session?.redoTitle ?? SessionEdit.redoMenuTitle
        case .toggleInspector: item.title = session?.inspectorVisible == true
                ? localized("menu.hideInspector", default: "Hide Inspector") : localized("menu.showInspector", default: "Show Inspector")
        case .showGrid: item.state = session?.viewMode == .grid ? .on : .off
        case .showLoupe: item.state = session?.viewMode == .loupe ? .on : .off
        case .showCompare: item.state = session?.viewMode == .compare ? .on : .off
        case .toggleStacks: item.title = session?.stacksExpanded == true
                ? localized("menu.collapseStacks", default: "Collapse Stacks") : localized("menu.expandAllStacks", default: "Expand All Stacks")
        case .toggleFaceStrip:
            // In stack review F hides the faces: the strip and the boxes over the panes together.
            if session?.viewMode == .stackReview {
                item.title = session?.faceStripInStackReview == true
                    ? localized("menu.hideFaces", default: "Hide Faces") : localized("menu.showFaces", default: "Show Faces")
            } else {
                item.title = session?.faceStripInLoupe == true
                    ? localized("menu.hideFaceStrip", default: "Hide Face Strip") : localized("menu.showFaceStrip", default: "Show Face Strip")
            }
        case .toggleBestPickPane:
            item.title = app.settings.showsBestPickPane
                ? localized("menu.hideBestPickPane", default: "Hide Best Pick Pane") : localized("menu.showBestPickPane", default: "Show Best Pick Pane")
        case .acceptStack:
            switch session?.viewMode {
            case .duplicateReview: item.title = localized("menu.acceptDuplicateSet", default: "Accept Duplicate Set")
            case .grid, .loupe: item.title = localized("menu.reviewStack", default: "Review Stack")
            default: item.title = localized("menu.acceptStack", default: "Accept Stack")
            }
        case .chooseBestPick:
            let id = session?.viewMode == .compare ? session?.compareFocusedID : session?.focus
            let stack = id.flatMap { session?.state.stack(containing: $0) }
            let isHandPick = stack.map { $0.bestPick == id && session?.state.isHandPicked($0) == true } ?? false
            item.title = isHandPick
                ? localized("menu.useCullasBestPick", default: "Use Culla’s Best Pick") : localized("menu.makeBestPick", default: "Make Best Pick")
        case .nextRow, .previousRow:
            let next = command == .nextRow
            switch session?.viewMode {
            case .stackReview: item.title = next ? localized("menu.nextStack", default: "Next Stack") : localized("menu.previousStack", default: "Previous Stack")
            case .duplicateReview: item.title = next ? localized("menu.nextSet", default: "Next Set") : localized("menu.previousSet", default: "Previous Set")
            default: item.title = command.title
            }
        case .nextPhoto, .previousPhoto:
            let next = command == .nextPhoto
            switch session?.viewMode {
            case .stackReview: item.title = next ? localized("menu.nextFrame", default: "Next Frame") : localized("menu.previousFrame", default: "Previous Frame")
            case .duplicateReview: item.title = next ? localized("menu.nextCopy", default: "Next Copy") : localized("menu.previousCopy", default: "Previous Copy")
            case .compare: item.title = next ? localized("menu.nextPane", default: "Next Pane") : localized("menu.previousPane", default: "Previous Pane")
            default: item.title = command.title
            }
        case .zoomToggle: item.title = session?.loupeZoom.isZoomed == true
                ? localized("menu.zoomToFit", default: "Zoom to Fit") : localized("menu.zoomTo100", default: "Zoom to 100%")
        case .toggleFaceBoxes: item.state = session?.showsFaceBoxes == true ? .on : .off
        case .toggleClippingOverlay: item.state = session?.showsClipping == true ? .on : .off
        case .toggleAnalysis: item.title = session?.analysis?.isPaused == true
                ? localized("menu.resumeAnalysis", default: "Resume Analysis") : localized("menu.pauseAnalysis", default: "Pause Analysis")
        case .showTuning: item.state = session?.tuningPanelGroup != nil ? .on : .off
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5:
            let rating = session?.focusedPhoto?.rating
            item.state = rating == command.rating && session?.targets.count == 1 ? .on : .off
        default: break
        }
        return app.isEnabled(command)
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        if app.recents.isEmpty {
            let empty = NSMenuItem(title: localized("menu.noRecentShoots", default: "No Recent Shoots"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for recent in app.recents {
            let item = NSMenuItem(title: recent.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = recent.id
            item.toolTip = recent.displayPath
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: localized("menu.clearMenu", default: "Clear Menu"), action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// Empties the recent list here and in the welcome view. Sessions are kept: opening the
    /// folder again brings its decisions back.
    @objc private func clearRecents(_ sender: NSMenuItem) {
        app.clearRecents()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? Int64, let recent = app.recents.first(where: { $0.id == id }) else { return }
        app.openRecent(recent)
    }
}
