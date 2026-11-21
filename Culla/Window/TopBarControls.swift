import AppKit

/// The flat controls of the shoot window's top bar. They sit directly on the bar, with no glass,
/// no translucency and no shadows: icon buttons show a soft fill only under the pointer, the view
/// switch is a faint track with a lighter pill, and Review and Apply is the one filled button,
/// filled as the selected pill looks.
///
/// Every control is a real AppKit control (`NSButton`, `NSSegmentedControl`, `NSSlider`), so its
/// accessibility role, label, value and actions, and its place in the key view loop, are AppKit's
/// own; only the drawing is Culla's. Colours are neutral, never tinted, so they do not colour how
/// photos are judged.
enum TopBarStyle {
    /// The bar's height when the window has no title bar to match (full screen).
    static let fallbackHeight: CGFloat = 40
    static let controlHeight: CGFloat = 28
    static let buttonRadius: CGFloat = 6
    static let containerRadius: CGFloat = 8
    static let sideMargin: CGFloat = 14
    static let controlSpacing: CGFloat = 8
    static let groupSpacing: CGFloat = 12
    /// Between the zoom button and the shoot's name.
    static let afterTrafficLights: CGFloat = 16
    static let iconPointSize: CGFloat = 15

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }

    // Surfaces. In dark appearance the bar is the panel grey of the sidebar, the group header and
    // the status bar, with the same separator under it.
    static let background = dynamic(dark: Palette.panelBackground, light: NSColor(white: 0.955, alpha: 1))
    static let separator = dynamic(dark: Palette.separator, light: NSColor(white: 0, alpha: 0.12))

    // Ghost buttons.
    static let hoverFill = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(white: 0, alpha: 0.06))
    static let pressedFill = dynamic(dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 0, alpha: 0.11))
    static let onFill = dynamic(dark: NSColor(white: 1, alpha: 0.12), light: NSColor(white: 0, alpha: 0.09))
    /// The 1 pt outline every ghost control gets with Increase Contrast.
    static let contrastBorder = dynamic(dark: NSColor(white: 1, alpha: 0.42), light: NSColor(white: 0, alpha: 0.45))

    // The view switch.
    static let trackFill = dynamic(dark: NSColor(white: 1, alpha: 0.06), light: NSColor(white: 0, alpha: 0.055))
    static let pillFill = dynamic(dark: NSColor(white: 1, alpha: 0.14), light: NSColor(white: 1, alpha: 1))
    /// A hairline around the light appearance's white pill, which would otherwise melt into the bar.
    static let pillEdge = dynamic(dark: .clear, light: NSColor(white: 0, alpha: 0.10))

    // Review and Apply: neutral, in the selected pill's colours. The pill is drawn over the track,
    // the button straight on the bar, so its dark fill folds the two together: 1 − 0.94 × 0.86 ≈ 0.19.
    // In light appearance it is the pill's white with its hairline; white cannot get lighter, so
    // there hover and press step darker.
    static let primaryFill = dynamic(dark: NSColor(white: 1, alpha: 0.19), light: NSColor(white: 1, alpha: 1))
    static let primaryHoverFill = dynamic(dark: NSColor(white: 1, alpha: 0.25), light: NSColor(white: 0.975, alpha: 1))
    static let primaryPressedFill = dynamic(dark: NSColor(white: 1, alpha: 0.31), light: NSColor(white: 0.93, alpha: 1))
    static let primaryEdge = pillEdge
    static let primaryText = NSColor.labelColor

    // The thumbnail size slider.
    static let sliderTrack = dynamic(dark: NSColor(white: 1, alpha: 0.16), light: NSColor(white: 0, alpha: 0.14))
    static let sliderFill = dynamic(dark: NSColor(white: 1, alpha: 0.50), light: NSColor(white: 0, alpha: 0.45))
    static let knobFill = dynamic(dark: NSColor(white: 0.90, alpha: 1), light: NSColor(white: 1, alpha: 1))
    static let knobEdge = dynamic(dark: NSColor(white: 0, alpha: 0.25), light: NSColor(white: 0, alpha: 0.28))

    /// An SF Symbol in one colour, at the bar's icon size unless given another configuration.
    static func symbol(_ image: NSImage, color: NSColor, pointSize: CGFloat = iconPointSize) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return image.withSymbolConfiguration(configuration) ?? image
    }

    /// Draws an image at its own size, centred on a point and snapped to the backing pixels.
    @MainActor static func draw(_ image: NSImage, centredIn rect: NSRect, in view: NSView, alpha: CGFloat = 1) {
        let size = image.size
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        origin = view.backingAlignedRect(NSRect(origin: origin, size: size), options: .alignAllEdgesNearest).origin
        image.draw(in: NSRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    }
}

// MARK: - The bar

/// The strip along the top of the shoot window: opaque, the panel grey, with one hairline under
/// it. Empty parts of it move the window, and a double click there zooms or minimises it as the
/// system setting says, as a title bar does. It is announced as a toolbar.
final class TopBarView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Places the bar's controls; called on every layout pass (see `ShootTopBar.layoutBar`).
    var onLayout: (() -> Void)?

    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        TopBarStyle.background.setFill()
        bounds.fill()
        TopBarStyle.separator.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            Self.titleBarDoubleClick(in: window)
        } else {
            window.performDrag(with: event)
        }
    }

    /// What a double click on a title bar does, from the system setting (Desktop & Dock ▸
    /// "Double-click a window's title bar to").
    static func titleBarDoubleClick(in window: NSWindow) {
        let defaults = UserDefaults.standard
        let action = defaults.string(forKey: "AppleActionOnDoubleClick")
            ?? (defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? "Minimize" : "Maximize")
        switch action {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }

    /// Redraws every control in the bar, for a change of the system's display settings.
    func redrawAll() {
        func mark(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(mark)
        }
        mark(self)
    }
}

/// A label in the bar that lets clicks through to it, so the bar can be dragged by its title.
final class TopBarLabel: NSTextField {
    convenience init(size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        self.init(labelWithString: "")
        font = .systemFont(ofSize: size, weight: weight)
        textColor = color
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        cell?.truncatesLastVisibleLine = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Buttons

/// A button of the bar. `.ghost` is an icon on the bar with a soft fill under the pointer and
/// while pressed or on; `.primary` is a filled button with its title, for the one main action.
final class TopBarButton: NSButton {
    enum Style { case ghost, primary }

    let style: Style
    /// Drawn as on (a soft fill, a full-strength icon), such as the inspector toggle while the
    /// inspector shows. Only the drawing: the button stays a plain push button for VoiceOver.
    var isOn = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }
    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    private var tracking: NSTrackingArea?

    static let primaryPadding: CGFloat = 12
    static let primaryFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    init(style: Style) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: TopBarStyle.controlHeight, height: TopBarStyle.controlHeight))
        isBordered = false
        setButtonType(.momentaryPushIn)
        bezelStyle = .regularSquare
        focusRingType = .default
        imagePosition = style == .ghost ? .imageOnly : .noImage
        font = Self.primaryFont
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        switch style {
        case .ghost:
            return NSSize(width: TopBarStyle.controlHeight, height: TopBarStyle.controlHeight)
        case .primary:
            let width = (title as NSString).size(withAttributes: [.font: Self.primaryFont]).width
            return NSSize(width: (width + Self.primaryPadding * 2).rounded(.up), height: TopBarStyle.controlHeight)
        }
    }

    override var title: String {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    private var shape: NSBezierPath {
        let radius = style == .ghost ? TopBarStyle.buttonRadius : TopBarStyle.containerRadius
        return NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted && isEnabled
        let hovered = isHovered && isEnabled
        switch style {
        case .ghost:
            let fill: NSColor? = pressed ? TopBarStyle.pressedFill : hovered ? TopBarStyle.hoverFill : isOn ? TopBarStyle.onFill : nil
            if let fill {
                fill.setFill()
                shape.fill()
            }
            if SystemAccessibility.increaseContrast {
                TopBarStyle.contrastBorder.setStroke()
                let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: TopBarStyle.buttonRadius - 0.5, yRadius: TopBarStyle.buttonRadius - 0.5)
                border.lineWidth = 1
                border.stroke()
            }
            if let image {
                let color: NSColor = !isEnabled ? .tertiaryLabelColor : (hovered || pressed || isOn) ? .labelColor : .secondaryLabelColor
                TopBarStyle.draw(TopBarStyle.symbol(image, color: color), centredIn: bounds, in: self)
            }
        case .primary:
            NSGraphicsContext.saveGraphicsState()
            if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
            let fill = pressed ? TopBarStyle.primaryPressedFill : hovered ? TopBarStyle.primaryHoverFill : TopBarStyle.primaryFill
            fill.setFill()
            shape.fill()
            let radius = TopBarStyle.containerRadius - 0.5
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            edge.lineWidth = 1
            TopBarStyle.primaryEdge.setStroke()
            edge.stroke()
            if SystemAccessibility.increaseContrast {
                TopBarStyle.contrastBorder.setStroke()
                edge.stroke()
            }
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.primaryFont, .foregroundColor: TopBarStyle.primaryText]
            let text = title as NSString
            let size = text.size(withAttributes: attributes)
            let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
            text.draw(at: backingAlignedRect(NSRect(origin: origin, size: size), options: .alignAllEdgesNearest).origin, withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        shape.fill()
    }
}

// MARK: - View switch

/// Grid, Loupe and Compare: a faint track holding a lighter pill under the selected icon. Still an
/// `NSSegmentedControl`, so VoiceOver reads a radio group of named segments with their help, and
/// the keyboard selects as before; the clicks and the drawing follow the drawn segments.
final class ViewSwitchControl: NSSegmentedControl {
    static let segmentWidth: CGFloat = 32
    static let inset: CGFloat = 2

    private var hovered: Int?
    private var pressed: Int?
    private var tracking: NSTrackingArea?

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.inset * 2 + Self.segmentWidth * CGFloat(segmentCount), height: TopBarStyle.controlHeight)
    }

    func segmentRect(_ index: Int) -> NSRect {
        let inner = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let width = inner.width / CGFloat(max(1, segmentCount))
        return NSRect(x: inner.minX + width * CGFloat(index), y: inner.minY, width: width, height: inner.height)
    }

    private func segment(at point: NSPoint) -> Int? {
        (0..<segmentCount).first { segmentRect($0).insetBy(dx: 0, dy: -Self.inset).contains(point) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private func setHovered(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { setHovered(segment(at: convert(event.locationInWindow, from: nil))) }
    override func mouseMoved(with event: NSEvent) { setHovered(segment(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window, let index = segment(at: convert(event.locationInWindow, from: nil)), isEnabled(forSegment: index) else { return }
        pressed = index
        needsDisplay = true
        // Tracks the press until the button comes up; it counts only if it comes up on the same
        // segment, as a click on a button does.
        var inside = true
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = segment(at: convert(next.locationInWindow, from: nil)) == index
            let wasPressed = pressed
            pressed = inside ? index : nil
            if pressed != wasPressed { needsDisplay = true }
            if next.type == .leftMouseUp { break }
        }
        pressed = nil
        needsDisplay = true
        guard inside else { return }
        selectedSegment = index
        sendAction(action, to: target)
    }

    override func draw(_ dirtyRect: NSRect) {
        let container = NSBezierPath(roundedRect: bounds, xRadius: TopBarStyle.containerRadius, yRadius: TopBarStyle.containerRadius)
        TopBarStyle.trackFill.setFill()
        container.fill()
        if SystemAccessibility.increaseContrast {
            TopBarStyle.contrastBorder.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: TopBarStyle.containerRadius - 0.5, yRadius: TopBarStyle.containerRadius - 0.5)
            border.lineWidth = 1
            border.stroke()
        }
        let radius = TopBarStyle.containerRadius - Self.inset
        for index in 0..<segmentCount {
            let rect = segmentRect(index)
            let enabled = isEnabled && isEnabled(forSegment: index)
            let selected = index == selectedSegment
            let pill = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            if selected {
                TopBarStyle.pillFill.setFill()
                pill.fill()
                TopBarStyle.pillEdge.setStroke()
                let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
                edge.lineWidth = 1
                edge.stroke()
                if SystemAccessibility.increaseContrast {
                    TopBarStyle.contrastBorder.setStroke()
                    edge.stroke()
                }
            } else if enabled, pressed == index {
                TopBarStyle.pressedFill.setFill()
                pill.fill()
            } else if enabled, hovered == index {
                TopBarStyle.hoverFill.setFill()
                pill.fill()
            }
            guard let image = image(forSegment: index) else { continue }
            let color: NSColor = !enabled ? .tertiaryLabelColor : (selected || hovered == index) ? .labelColor : .secondaryLabelColor
            TopBarStyle.draw(TopBarStyle.symbol(image, color: color, pointSize: 14), centredIn: rect, in: self)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: TopBarStyle.containerRadius, yRadius: TopBarStyle.containerRadius).fill()
    }

    /// With the keyboard, ← and → choose the neighbouring view at once, as the pill shows the
    /// choice; the ring is drawn around the whole switch.
    override func keyDown(with event: NSEvent) {
        let step: Int? = switch event.specialKey {
        case .leftArrow?: -1
        case .rightArrow?: 1
        default: nil
        }
        guard let step else { return super.keyDown(with: event) }
        var index = selectedSegment
        repeat {
            index += step
        } while (0..<segmentCount).contains(index) && !isEnabled(forSegment: index)
        guard (0..<segmentCount).contains(index) else { return }
        selectedSegment = index
        sendAction(action, to: target)
    }
}

// MARK: - Slider

/// The thumbnail size slider's look: a thin track, filled up to a small round knob. The control
/// stays an `NSSlider`, with its role, value and increment and decrement actions.
final class TopBarSliderCell: NSSliderCell {
    static let trackThickness: CGFloat = 3
    static let knobDiameter: CGFloat = 12

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let view = controlView else { return }
        let track = NSRect(x: rect.minX, y: rect.midY - Self.trackThickness / 2, width: rect.width, height: Self.trackThickness)
        let fraction = maxValue > minValue ? (doubleValue - minValue) / (maxValue - minValue) : 0
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        TopBarStyle.sliderTrack.setFill()
        NSBezierPath(roundedRect: view.backingAlignedRect(track, options: .alignAllEdgesNearest), xRadius: Self.trackThickness / 2, yRadius: Self.trackThickness / 2).fill()
        var filled = track
        filled.size.width = max(Self.trackThickness, track.width * CGFloat(fraction))
        TopBarStyle.sliderFill.setFill()
        NSBezierPath(roundedRect: view.backingAlignedRect(filled, options: .alignAllEdgesNearest), xRadius: Self.trackThickness / 2, yRadius: Self.trackThickness / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let diameter = Self.knobDiameter
        let rect = NSRect(x: knobRect.midX - diameter / 2, y: knobRect.midY - diameter / 2, width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.4) }
        TopBarStyle.knobFill.setFill()
        let knob = NSBezierPath(ovalIn: rect)
        knob.fill()
        let edge = NSBezierPath(ovalIn: rect.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        (SystemAccessibility.increaseContrast ? TopBarStyle.contrastBorder : TopBarStyle.knobEdge).setStroke()
        edge.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        let knob = knobRect(flipped: controlView.isFlipped)
        let diameter = Self.knobDiameter
        NSBezierPath(ovalIn: NSRect(x: knob.midX - diameter / 2, y: knob.midY - diameter / 2, width: diameter, height: diameter)).fill()
    }
}
