import AppKit
import SwiftUI

/// The app's colours. The interface is a neutral dark grey, so it does not tint how photos are
/// judged, and has no translucent materials that would let the desktop show through. Colour
/// carries meaning only, always beside an icon: green kept, red rejected, amber flagged or
/// unreadable. Selection uses the system accent colour, as everywhere on the Mac.
enum Palette {
    // Surfaces, darkest to lightest.
    static let gridBackground = NSColor(white: 0.115, alpha: 1)
    static let windowBackground = NSColor(white: 0.135, alpha: 1)
    static let panelBackground = NSColor(white: 0.155, alpha: 1)
    static let separator = NSColor(white: 0.0, alpha: 0.55)
    static let hairline = NSColor(white: 1.0, alpha: 0.07)
    /// A tile's mat when it is not selected: just enough to show the grid's rhythm.
    static let tileMat = NSColor(white: 1.0, alpha: 0.045)
    static let placeholder = NSColor(white: 0.22, alpha: 1)
    /// Behind the photo in the loupe: the grid's neutral grey, so a photo is judged against the
    /// same surround in both views.
    static let loupeBackground = NSColor(white: 0.115, alpha: 1)

    // Meaning.
    static let kept = NSColor(srgbRed: 0.20, green: 0.74, blue: 0.36, alpha: 1)
    static let rejected = NSColor(srgbRed: 0.92, green: 0.26, blue: 0.24, alpha: 1)
    static let flagged = NSColor(srgbRed: 0.98, green: 0.70, blue: 0.16, alpha: 1)
    static let star = NSColor(white: 0.92, alpha: 1)

    static var accent: NSColor { .controlAccentColor }

    // SwiftUI forms of the same colours.
    static let gridBackgroundColor = Color(nsColor: gridBackground)
    static let windowBackgroundColor = Color(nsColor: windowBackground)
    static let panelBackgroundColor = Color(nsColor: panelBackground)
    static let separatorColor = Color(nsColor: separator)
    static let hairlineColor = Color(nsColor: hairline)
    static let keptColor = Color(nsColor: kept)
    static let rejectedColor = Color(nsColor: rejected)
    static let flaggedColor = Color(nsColor: flagged)
    static var accentColor: Color { Color(nsColor: .controlAccentColor) }

    /// Culla's icon from the asset catalog, as drawn by Scripts/make_icon.swift. Read from the
    /// bundle rather than from Launch Services, which may not know a freshly built copy yet.
    @MainActor static var appIcon: NSImage { NSImage(named: "AppIcon") ?? NSApp.applicationIconImage }
}
