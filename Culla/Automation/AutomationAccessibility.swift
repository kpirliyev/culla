#if DEBUG
import AppKit
import Foundation

/// The accessibility tree of a window as VoiceOver reads it: every element with its role,
/// label, title, value and actions, so scripts can check that nothing a person acts on is
/// unlabelled. Read through the same NSAccessibility protocol assistive apps are served from.
///
/// It sees the AppKit side: windows, toolbars, the grid's tiles, the filmstrips, the face strip's
/// cells, the loupe and alerts. SwiftUI builds its own elements only for a connected assistive
/// app, so SwiftUI views show as one hosting element here; `Scripts/check-accessibility.py`
/// checks their labels in the source instead.
@MainActor
enum AccessibilityTree {
    struct Node {
        var depth: Int
        var role: String
        var subrole: String?
        var label: String
        var title: String
        var value: String?
        var help: String
        var identifier: String
        var enabled: Bool
        var selected: Bool
        var actions: [String]
        var childCount: Int
        /// The name of the nearest element above it, for a control inside a named one (a toolbar
        /// item's button, named by its item).
        var parentName = ""
        /// Inside a SwiftUI hosting view, whose labels SwiftUI gives only to a connected assistive
        /// app: such controls are checked in the source by Scripts/check-accessibility.py.
        var inHosting = false

        /// The name VoiceOver speaks: the label, else the title, else the value of static text.
        var name: String {
            if !label.isEmpty { return label }
            if !title.isEmpty { return title }
            if role == NSAccessibility.Role.staticText.rawValue, let value { return value }
            return ""
        }

        var dictionary: [String: Any] {
            var entry: [String: Any] = ["depth": depth, "role": role, "name": name]
            if let subrole { entry["subrole"] = subrole }
            if !label.isEmpty, label != name { entry["label"] = label }
            if !title.isEmpty, title != name { entry["title"] = title }
            if let value, !value.isEmpty, value != name { entry["value"] = value }
            if !help.isEmpty { entry["help"] = help }
            if !identifier.isEmpty { entry["identifier"] = identifier }
            if !enabled { entry["enabled"] = false }
            if selected { entry["selected"] = true }
            if !actions.isEmpty { entry["actions"] = actions }
            if childCount > 0 { entry["children"] = childCount }
            if inHosting { entry["swiftUI"] = true }
            return entry
        }
    }

    /// Roles a person acts on: each needs a name.
    static let actionableRoles: Set<String> = [
        NSAccessibility.Role.button.rawValue, NSAccessibility.Role.checkBox.rawValue, NSAccessibility.Role.radioButton.rawValue,
        NSAccessibility.Role.slider.rawValue, NSAccessibility.Role.popUpButton.rawValue, NSAccessibility.Role.menuButton.rawValue,
        NSAccessibility.Role.textField.rawValue, NSAccessibility.Role.incrementor.rawValue, NSAccessibility.Role.disclosureTriangle.rawValue,
        NSAccessibility.Role.link.rawValue, NSAccessibility.Role.image.rawValue, NSAccessibility.Role.cell.rawValue,
        NSAccessibility.Role.comboBox.rawValue, NSAccessibility.Role.radioGroup.rawValue, "AXSwitch", "AXToggle",
    ]

    /// Reads an accessibility attribute by its getter's name, through Key-Value Coding, from any
    /// object that answers it: AppKit's views and windows, and SwiftUI's own elements alike.
    private static func get(_ object: NSObject, _ name: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(name)) else { return nil }
        let value = object.value(forKey: name)
        return value is NSNull ? nil : value
    }

    private static func string(_ object: NSObject, _ name: String) -> String {
        (get(object, name) as? String) ?? ""
    }

    private static func bool(_ object: NSObject, _ name: String, default fallback: Bool) -> Bool {
        (get(object, name) as? NSNumber)?.boolValue ?? fallback
    }

    static func read(_ root: Any, maxNodes: Int = 6000) -> [Node] {
        var nodes: [Node] = []
        var seen = Set<ObjectIdentifier>()
        func visit(_ element: Any, depth: Int, parentName: String, inHosting: Bool) {
            guard nodes.count < maxNodes, depth < 60, let object = element as? NSObject else { return }
            let id = ObjectIdentifier(object)
            guard !seen.contains(id) else { return }
            seen.insert(id)
            var children = (get(object, "accessibilityChildren") as? [Any]) ?? []
            if children.isEmpty { children = (get(object, "accessibilityContents") as? [Any]) ?? [] }
            if children.isEmpty, object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) {
                // SwiftUI's hosting views vend their elements through the attribute-based API.
                for attribute in [NSAccessibility.Attribute.children, .contents, .visibleChildren] {
                    if let legacy = object.perform(NSSelectorFromString("accessibilityAttributeValue:"), with: attribute.rawValue)?
                        .takeUnretainedValue() as? [Any], !legacy.isEmpty {
                        children = legacy
                        break
                    }
                }
            }
            if children.isEmpty, let view = object as? NSView, !view.subviews.isEmpty {
                // A view whose accessibility children are not built yet (SwiftUI builds them on
                // demand): look through its subviews.
                children = view.subviews.filter { !$0.isHidden }
            }
            let role = (get(object, "accessibilityRole") as? NSAccessibility.Role)?.rawValue ?? string(object, "accessibilityRole")
            // Ignored elements (decorative views, plain containers) are left out, as VoiceOver
            // leaves them out; their children are still visited.
            let isElement = object.responds(to: NSSelectorFromString("isAccessibilityElement"))
                ? bool(object, "isAccessibilityElement", default: false)
                : !role.isEmpty && role != NSAccessibility.Role.unknown.rawValue
            if isElement {
                var actions: [String] = []
                if object.responds(to: #selector(NSAccessibilityProtocol.accessibilityPerformPress)) { actions.append("press") }
                for action in (get(object, "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? [] { actions.append(action.name) }
                if role == NSAccessibility.Role.slider.rawValue || role == NSAccessibility.Role.incrementor.rawValue {
                    actions.append("increment")
                }
                let subrole = (get(object, "accessibilitySubrole") as? NSAccessibility.Subrole)?.rawValue ?? (get(object, "accessibilitySubrole") as? String)
                nodes.append(Node(
                    depth: depth, role: role, subrole: subrole,
                    label: string(object, "accessibilityLabel"), title: string(object, "accessibilityTitle"),
                    value: get(object, "accessibilityValue").map { "\($0)" }, help: string(object, "accessibilityHelp"),
                    identifier: string(object, "accessibilityIdentifier"),
                    enabled: bool(object, "isAccessibilityEnabled", default: true), selected: bool(object, "isAccessibilitySelected", default: false),
                    actions: actions, childCount: children.count, parentName: parentName, inHosting: inHosting
                ))
            }
            let name = isElement ? (nodes.last?.name ?? "") : parentName
            let hosting = inHosting || String(describing: type(of: object)).contains("Hosting")
                || (get(object, "accessibilitySubrole") as? NSAccessibility.Subrole)?.rawValue == "AXHostingView"
            for child in children { visit(child, depth: depth + 1, parentName: name.isEmpty ? parentName : name, inHosting: hosting) }
        }
        visit(root, depth: 0, parentName: "", inHosting: false)
        return nodes
    }

    /// The window's own buttons, which VoiceOver names by their subrole.
    static let namedBySubrole: Set<String> = [
        NSAccessibility.Subrole.closeButton.rawValue, NSAccessibility.Subrole.minimizeButton.rawValue,
        NSAccessibility.Subrole.zoomButton.rawValue, NSAccessibility.Subrole.fullScreenButton.rawValue,
        NSAccessibility.Subrole.toolbarButton.rawValue, NSAccessibility.Subrole.incrementArrow.rawValue,
        NSAccessibility.Subrole.decrementArrow.rawValue, NSAccessibility.Subrole.incrementPage.rawValue,
        NSAccessibility.Subrole.decrementPage.rawValue,
    ]

    /// Elements a person can act on that have no name.
    static func unlabelled(_ nodes: [Node]) -> [Node] {
        nodes.filter { node in
            actionableRoles.contains(node.role) && node.name.isEmpty && !namedBySubrole.contains(node.subrole ?? "") && !node.inHosting
                // A button inside a named toolbar item is spoken with the item's name.
                && !(node.role == NSAccessibility.Role.button.rawValue && !node.parentName.isEmpty && node.childCount == 0)
        }
    }
}

extension AutomationRunner {
    /// `{"accessibility": "main", "save": "a11y-grid", "check": {"unlabelled": 0, "contains": [["AXButton", "Review and Apply"]], "count": [["AXImage", "kept", 3]]}}`
    func accessibilityStep(_ step: [String: Any]) async throws -> String? {
        let which = step["accessibility"] as? String ?? "main"
        let window: NSWindow?
        switch which {
        case "main": window = windowController?.window
        case "settings": window = existingSettingsController?()?.window
        default: window = auxiliaryWindows?()[which]
        }
        guard let window, window.isVisible else { throw Failure("The \(which) window is not shown") }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let nodes = AccessibilityTree.read(window)
        let unlabelled = AccessibilityTree.unlabelled(nodes)
        if let name = step["save"] as? String {
            let output: [String: Any] = [
                "window": which, "title": window.title, "elements": nodes.count,
                "unlabelled": unlabelled.map(\.dictionary), "tree": nodes.map(\.dictionary),
                "swiftUIUnnamed": nodes.filter { $0.inHosting && AccessibilityTree.actionableRoles.contains($0.role) && $0.name.isEmpty }.map(\.dictionary),
            ]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: outputFolder.appendingPathComponent("\(name).json"))
        }
        var problems: [String] = []
        if let expect = step["check"] as? [String: Any] {
            if let limit = expect["unlabelled"] as? Int, unlabelled.count > limit {
                let names = unlabelled.prefix(8).map { "\($0.role)\($0.subrole.map { "/\($0)" } ?? "") at depth \($0.depth)" }
                problems.append("\(unlabelled.count) unlabelled elements: \(names.joined(separator: ", "))")
            }
            for item in expect["contains"] as? [[String]] ?? [] where item.count == 2 {
                let found = nodes.contains { (item[0].isEmpty || $0.role == item[0]) && $0.name.localizedCaseInsensitiveContains(item[1]) }
                if !found { problems.append("no \(item[0]) named like “\(item[1])”") }
            }
            for item in expect["absent"] as? [[String]] ?? [] where item.count == 2 {
                if nodes.contains(where: { (item[0].isEmpty || $0.role == item[0]) && $0.name.localizedCaseInsensitiveContains(item[1]) }) {
                    problems.append("an unexpected \(item[0]) named like “\(item[1])”")
                }
            }
            for item in expect["atLeast"] as? [[Any]] ?? [] where item.count == 3 {
                guard let role = item[0] as? String, let text = item[1] as? String, let count = item[2] as? Int else { continue }
                let found = nodes.filter { (role.isEmpty || $0.role == role) && (text.isEmpty || $0.name.localizedCaseInsensitiveContains(text)) }.count
                if found < count { problems.append("\(found) \(role) named like “\(text)”, expected at least \(count)") }
            }
            for item in expect["actions"] as? [[String]] ?? [] where item.count == 3 {
                // [role, name contains, action]: such an element offers that action.
                let found = nodes.contains { (item[0].isEmpty || $0.role == item[0]) && $0.name.localizedCaseInsensitiveContains(item[1]) && $0.actions.contains(item[2]) }
                if !found { problems.append("no \(item[0]) named like “\(item[1])” with the action \(item[2])") }
            }
        }
        if !problems.isEmpty { throw Failure(problems.joined(separator: "; ")) }
        return "\(nodes.count) elements, \(unlabelled.count) unlabelled"
    }
}
#endif
