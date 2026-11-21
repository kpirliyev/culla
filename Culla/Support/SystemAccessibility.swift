import AppKit

/// The system's accessibility display settings the interface follows: Reduce Motion (no
/// animation anywhere), Increase Contrast (stronger outlines on badges and the selection) and
/// Differentiate Without Colour. Read in one place so every view agrees, and so the automation
/// harness can stand in for the system settings in debug builds.
@MainActor
enum SystemAccessibility {
    static var reduceMotion: Bool {
        #if DEBUG
        if let overrideReduceMotion { return overrideReduceMotion }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var increaseContrast: Bool {
        #if DEBUG
        if let overrideIncreaseContrast { return overrideIncreaseContrast }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    static var differentiateWithoutColor: Bool {
        #if DEBUG
        if let overrideDifferentiateWithoutColor { return overrideDifferentiateWithoutColor }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    /// Posted when any of the settings above changes, by the system or by the harness.
    static let didChange = Notification.Name("CullaSystemAccessibilityDidChange")

    #if DEBUG
    static var overrideReduceMotion: Bool?
    static var overrideIncreaseContrast: Bool?
    static var overrideDifferentiateWithoutColor: Bool?
    #endif

    static func notifyChanged() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Forwards the system's own notification as `didChange`. Called once at launch.
    static func startObserving() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { notifyChanged() }
        }
    }
}
