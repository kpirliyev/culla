import AppKit
import CullaCommands
import CullaSession

/// What the grid and the filmstrip share: filling a tile from the model and loading its
/// thumbnail, and the context menu of a tile.
@MainActor
struct TileConfigurator {
    let model: SessionModel

    /// Shows a photo in a tile and starts loading its thumbnail. In the grid with stacks
    /// collapsed, the tile of a stack's representative stands for the whole stack.
    func configure(_ item: PhotoTileItem, id: String, collapsed: Bool = false) {
        let state = model.state
        guard let photo = state.photo(id) else { return }
        let selection = model.selection
        let content: TileContent
        if collapsed, let stack = model.collapsedStacks[id] {
            content = TileContent(collapsed: stack, item: photo, isSelected: selection.selected.contains(id), isFocused: selection.focus == id)
        } else {
            content = TileContent(
                item: photo,
                badges: state.badges(for: id),
                stackSize: state.stack(containing: id)?.members.count,
                duplicate: state.duplicateSet(containing: id)?.kind,
                isSelected: selection.selected.contains(id),
                isFocused: selection.focus == id
            )
        }
        item.configure(content)
        setAccessibilityActions(of: item, id: id, isStack: content.collapsed != nil)
        if !photo.isUnreadable {
            // The load lasts as long as the tile shows the photo; holding the model that long is fine.
            let model = model
            item.loadThumbnail(file: photo.file, cache: model.thumbnails, activity: model.activity) { error in
                model.thumbnailFailed(for: id, error: error)
            }
        }
    }

    /// What VoiceOver can do with a tile: press opens it (a collapsed stack in stack review), and
    /// the actions decide it, as the keys do on the selected photo.
    private func setAccessibilityActions(of item: PhotoTileItem, id: String, isStack: Bool) {
        guard let view = item.view as? PhotoTileView else { return }
        let model = model
        view.accessibilityPress = { [weak model] in model?.open(id) }
        guard !isStack else {
            view.setAccessibilityCustomActions(nil)
            return
        }
        let actions: [(String, Command)] = [
            (localized("tileAction.keep", default: "Keep"), .keep),
            (localized("tileAction.reject", default: "Reject"), .reject),
            (localized("tileAction.clearDecision", default: "Clear Decision"), .clearDecision),
        ]
        view.setAccessibilityCustomActions(actions.map { name, command in
            NSAccessibilityCustomAction(name: name) { [weak model] in
                guard let model else { return false }
                model.click(id, kind: .plain)
                return model.perform(command)
            }
        })
    }

    /// Visible tiles still waiting for their thumbnail, for the automation harness. Tiles whose
    /// thumbnail waits for a disconnected folder to come back are not counted: nothing can load
    /// them until it does, and they load again then (`SessionModel.setFolderMissing`).
    static func tilesWithoutImage(in collectionView: NSCollectionView, model: SessionModel) -> Int {
        let waiting = model.folderMissing ? model.thumbnailsAwaitingFolder : []
        return collectionView.visibleItems().compactMap { $0 as? PhotoTileItem }.filter { item in
            guard let content = item.content, let view = item.view as? PhotoTileView else { return false }
            return !content.isUnreadable && !view.hasImage && !waiting.contains(content.id)
        }.count
    }
}

/// The context menu of a grid tile or a filmstrip cell: Keep, Reject, Clear Decision, the
/// ratings, Reveal in Finder and Copy File Name.
///
/// It acts on the selection when the clicked photo is part of it, else on the clicked photo,
/// which is then selected first (as in the Finder), so the menu and the keys always act on what
/// is shown selected.
@MainActor
final class PhotoContextMenu: NSObject, NSMenuDelegate {
    private let model: SessionModel

    init(model: SessionModel) {
        self.model = model
        super.init()
    }

    /// The menu for a click on a photo. Selects the photo first when it is not selected.
    func menu(for id: String) -> NSMenu? {
        guard model.selectionOrder.contains(id) else { return nil }
        if !model.selection.selected.contains(id) {
            model.click(id, kind: .plain)
        }
        let targets = model.targets
        if targets.isEmpty, model.collapsedStacks[id] != nil {
            return stackMenu(for: id)
        }
        guard !targets.isEmpty else { return nil }
        let photos = targets.compactMap { model.state.photo($0) }
        let menu = NSMenu(title: "Photo")
        menu.autoenablesItems = false
        let many = targets.count > 1
        menu.addItem(commandItem(.keep, title: many ? localized("Keep \(targets.count) Photos") : localized("photoMenu.keep", default: "Keep"), symbol: "checkmark.circle"))
        menu.addItem(commandItem(.reject, title: many ? localized("Reject \(targets.count) Photos") : localized("photoMenu.reject", default: "Reject"), symbol: "xmark.circle"))
        menu.addItem(commandItem(.clearDecision, title: many ? localized("Clear \(targets.count) Decisions") : localized("photoMenu.clearDecision", default: "Clear Decision"), symbol: "circle.dashed"))
        menu.addItem(.separator())
        let rating = NSMenuItem(title: localized("photoMenu.rating", default: "Rating"), action: nil, keyEquivalent: "")
        rating.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        let ratingMenu = NSMenu(title: rating.title)
        ratingMenu.autoenablesItems = false
        let ratings = Set(photos.map(\.rating))
        for command in [Command.rate0, .rate1, .rate2, .rate3, .rate4, .rate5] {
            let item = commandItem(command, title: command.title, symbol: nil)
            item.state = ratings == [command.rating ?? -1] ? .on : .off
            ratingMenu.addItem(item)
        }
        rating.submenu = ratingMenu
        menu.addItem(rating)
        menu.addItem(.separator())
        let reveal = NSMenuItem(title: localized("photoMenu.revealInFinder", default: "Reveal in Finder"), action: #selector(revealInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = targets
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(reveal)
        let copy = NSMenuItem(title: many ? localized("Copy \(targets.count) File Names") : localized("photoMenu.copyFileName", default: "Copy File Name"), action: #selector(copyFileNames(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = targets
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)
        return menu
    }

    /// The menu of a collapsed stack: open it, expand the stacks, or join the selection.
    private func stackMenu(for id: String) -> NSMenu {
        let menu = NSMenu(title: "Stack")
        menu.autoenablesItems = false
        let frames = model.collapsedStacks[id]?.frameCount ?? 0
        menu.addItem(commandItem(.acceptStack, title: localized("Review Stack of \(frames)"), symbol: "square.stack.3d.up"))
        menu.addItem(commandItem(.toggleStacks, title: localized("stackMenu.expandAllStacks", default: "Expand All Stacks"), symbol: "square.grid.3x3"))
        if model.selection.selected.count > 1 {
            menu.addItem(commandItem(.addToStack, title: localized("stackMenu.joinSelection", default: "Join Selection in One Stack"), symbol: "square.stack"))
        }
        menu.addItem(.separator())
        let ids = model.state.stack(containing: id)?.members ?? [id]
        let reveal = NSMenuItem(title: localized("Reveal \(frames) Frames in Finder"), action: #selector(revealInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = ids
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        menu.addItem(reveal)
        return menu
    }

    private func commandItem(_ command: Command, title: String, symbol: String?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.rawValue
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        // Key equivalents in a context menu are only shown, as a reminder of the key.
        if let chord = model.settings.keyBindings.primaryChord(for: command) {
            item.keyEquivalent = chord.menuKeyEquivalent
            item.keyEquivalentModifierMask = KeyRouter.menuModifiers(chord.modifiers)
        }
        item.isEnabled = model.isEnabled(command)
        return item
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let command = Command(rawValue: name) else { return }
        model.perform(command)
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        model.revealInFinder(ids)
    }

    @objc private func copyFileNames(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String] else { return }
        model.copyFileNames(ids)
    }

    /// The titles of the menu's items, enabled ones only, for the automation harness.
    static func titles(of menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            if let submenu = item.submenu { return titles(of: submenu).map { "\(item.title) ▸ \($0)" } }
            return item.isSeparatorItem || !item.isEnabled ? [] : [item.title]
        }
    }

    /// Runs the item with this title, as a click on it would. Returns false when there is none.
    static func perform(_ title: String, in menu: NSMenu) -> Bool {
        for item in menu.items {
            if let submenu = item.submenu, perform(title, in: submenu) { return true }
            if item.title == title, item.isEnabled, let action = item.action {
                return NSApp.sendAction(action, to: item.target, from: item)
            }
        }
        return false
    }
}
