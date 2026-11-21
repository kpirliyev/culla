import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaFiles
import CullaSession

/// What a tile shows about its photo.
struct TileContent: Equatable {
    var id: String
    var name: String
    var decision: Decision
    var rating: Int
    var isNew: Bool
    var isUnreadable: Bool
    var isBestPick: Bool
    /// Reasons Culla flagged the photo, Certain ones first, then a duplicate mark if any.
    var reasons: [TileReason]
    /// The number of frames in the photo's stack, if it is in one.
    var stackSize: Int?
    /// Width over height, from the metadata, so the placeholder has the photo's shape.
    var aspect: CGFloat
    var isSelected: Bool
    var isFocused: Bool
    /// Set when the tile stands for a whole collapsed stack: its frame count and decisions.
    var collapsed: CollapsedSummary?
    /// Notes of stack review (such as "softer than the pick"), shown as badges after the flags.
    var notes: [TileReason] = []

    struct CollapsedSummary: Equatable {
        var frameCount: Int
        var decisions: DecisionSummary
    }

    init(item: PhotoItem, badges: PhotoBadges?, stackSize: Int? = nil, duplicate: DuplicateSet.Kind? = nil, isSelected: Bool, isFocused: Bool) {
        id = item.id
        name = item.file.name
        decision = item.decision
        rating = item.rating
        isNew = item.isNew
        isUnreadable = item.isUnreadable
        isBestPick = badges?.isBestPick ?? false
        var reasons = (badges?.flags ?? [])
            .sorted { ($0.tier == .certain ? 0 : 1) < ($1.tier == .certain ? 0 : 1) }
            .map { TileReason(flag: $0.flag, tier: $0.tier) }
        if let duplicate, !item.isUnreadable {
            reasons.append(TileReason(duplicate: duplicate))
        }
        self.reasons = item.isUnreadable ? [] : reasons
        self.stackSize = item.isUnreadable ? nil : stackSize
        if let width = item.metadata.pixelWidth, let height = item.metadata.pixelHeight, width > 0, height > 0 {
            aspect = CGFloat(width) / CGFloat(height)
        } else {
            aspect = 3.0 / 2.0
        }
        self.isSelected = isSelected
        self.isFocused = isFocused
    }

    /// A collapsed stack's tile: the representative's look, the stack's count and decisions.
    init(collapsed stack: CollapsedStack, item: PhotoItem, isSelected: Bool, isFocused: Bool) {
        self.init(item: item, badges: nil, isSelected: isSelected, isFocused: isFocused)
        isBestPick = stack.representativeIsBestPick
        reasons = []
        stackSize = stack.frameCount
        collapsed = CollapsedSummary(frameCount: stack.frameCount, decisions: stack.decisions)
        // The tile's own decision is the stack's when every frame shares one.
        decision = stack.decisions.uniform ?? .unreviewed
    }

    var accessibilityLabel: String {
        if let collapsed {
            var parts = [localized("Stack of \(collapsed.frameCount) photos"), localized("best pick \(name)")]
            parts.append(Self.summaryText(collapsed.decisions))
            return parts.joined(separator: ", ")
        }
        var parts = [name]
        if isUnreadable {
            parts.append(localized("tile.cannotBeRead", default: "cannot be read"))
        } else {
            switch decision {
            case .kept: parts.append(localized("tile.kept", default: "kept"))
            case .rejected: parts.append(localized("tile.rejected", default: "rejected"))
            case .unreviewed: parts.append(localized("tile.unreviewed", default: "unreviewed"))
            }
        }
        if rating > 0 { parts.append(Formatting.stars(rating)) }
        if isNew { parts.append(localized("tile.new", default: "new")) }
        for reason in reasons { parts.append(reason.spokenName) }
        if let stackSize { parts.append(localized("in a stack of \(stackSize)")) }
        if isBestPick { parts.append(localized("tile.bestPick", default: "best pick")) }
        return parts.joined(separator: ", ")
    }

    /// "2 kept, 5 rejected", "all 7 unreviewed", "3 kept, 4 unreviewed"
    static func summaryText(_ decisions: DecisionSummary) -> String {
        if decisions.unreviewed == decisions.total { return localized("all \(decisions.total) unreviewed") }
        var parts: [String] = []
        if decisions.kept > 0 { parts.append(localized("\(decisions.kept) kept")) }
        if decisions.rejected > 0 { parts.append(localized("\(decisions.rejected) rejected")) }
        if decisions.unreviewed > 0 { parts.append(localized("\(decisions.unreviewed) unreviewed")) }
        return parts.joined(separator: ", ")
    }

    /// The tile's tooltip: the name, then each reason with its tier, the stack and the pick.
    var toolTip: String {
        if let collapsed {
            let summary = Self.summaryText(collapsed.decisions)
            return [
                localized("Stack of \(collapsed.frameCount) photos: \(summary)"),
                isBestPick ? localized("Showing the best pick, \(name)") : localized("Showing \(name)"),
                localized("Return or double-click to review it"),
            ].joined(separator: "\n")
        }
        var lines = [name]
        lines += reasons.map(\.displayName)
        if let stackSize {
            lines.append(isBestPick ? localized("Stack of \(stackSize) photos · best pick") : localized("Stack of \(stackSize) photos"))
        }
        return lines.joined(separator: "\n")
    }
}

/// One reason badge on a tile: a flag with its tier, or a duplicate (exact copies are certain).
struct TileReason: Hashable {
    var symbol: String
    var name: String
    var isCertain: Bool

    init(flag: PhotoFlag, tier: FlagTier) {
        symbol = Formatting.flagSymbol(flag)
        name = Formatting.flag(flag)
        isCertain = tier == .certain
    }

    init(duplicate: DuplicateSet.Kind) {
        symbol = "plus.square.on.square"
        name = duplicate == .exact
            ? localized("badge.exactDuplicate", default: "Exact duplicate") : localized("badge.nearDuplicate", default: "Near-duplicate")
        isCertain = duplicate == .exact
    }

    /// A note of stack review, such as "softer than the pick": always outlined, as a Likely flag.
    init(note: FrameNote) {
        symbol = note.symbol
        name = note.text.prefix(1).uppercased() + note.text.dropFirst()
        isCertain = false
    }

    var tierName: String { isCertain ? localized("tier.certain", default: "Certain") : localized("tier.likely", default: "Likely") }
    /// "Blurry · Certain"
    var displayName: String { localized("badge.nameAndTier", default: "\(name) · \(tierName)") }
    /// "blurry, certain", for VoiceOver.
    var spokenName: String {
        let locale = Localization.locale
        let reason = name.lowercased(with: locale)
        let tier = tierName.lowercased(with: locale)
        return localized("tile.reasonSpoken", default: "\(reason), \(tier)")
    }
}

/// One grid cell. Its thumbnail is requested when the cell is shown and the request is
/// cancelled when it scrolls away or is reused.
final class PhotoTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoTile")

    private var loadTask: Task<Void, Never>?
    private(set) var content: TileContent?
    private var tileView: PhotoTileView { view as! PhotoTileView }

    override func loadView() {
        view = PhotoTileView(frame: NSRect(x: 0, y: 0, width: 160, height: 176))
    }

    func configure(_ content: TileContent) {
        if self.content?.id != content.id {
            cancelLoad()
            tileView.setImage(nil)
        }
        self.content = content
        tileView.content = content
    }

    /// Shows the thumbnail: at once when it is in memory, else when it arrives.
    @MainActor
    func loadThumbnail(file: PhotoFile, cache: ThumbnailCache, activity: ActivityTracker, onFailure: @escaping @MainActor (any Error) -> Void) {
        guard let id = content?.id, !(content?.isUnreadable ?? false) else { return }
        if tileView.hasImage { return }
        if let image = cache.cachedThumbnail(for: file) {
            tileView.setImage(image)
            return
        }
        loadTask?.cancel()
        activity.begin(.thumbnail)
        loadTask = Task { @MainActor [weak self] in
            defer { activity.end(.thumbnail) }
            do {
                let image = try await cache.thumbnail(for: file)
                guard !Task.isCancelled, let self, self.content?.id == id else { return }
                self.tileView.setImage(image)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                onFailure(error)
            }
        }
    }

    func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelLoad()
        content = nil
        tileView.setImage(nil)
    }
}

/// Draws a tile with layers: the mat (selection), the focus ring, the photo or its placeholder,
/// the decision badge, the "New" pill, the stars, and the unreadable mark. Room is left for the
/// reason badges (bottom left of the photo) and the best-pick star (top left) of later milestones.
final class PhotoTileView: NSView {
    var content: TileContent? {
        didSet {
            if content != oldValue { needsLayout = true; updateAccessibility() }
        }
    }

    private let matLayer = CALayer()
    private let focusLayer = CALayer()
    private let placeholderLayer = CALayer()
    private let photoLayer = CALayer()
    /// Darkens a rejected photo the same way on any mat, selected or not.
    private let dimLayer = CALayer()
    private let decisionLayer = CALayer()
    private let newLayer = CALayer()
    private let bestPickLayer = CALayer()
    private let starsLayer = CALayer()
    private let warningLayer = CALayer()
    private let captionLayer = CALayer()
    /// Reason badges along the bottom left of the photo; more are made as needed.
    private var reasonLayers: [CALayer] = []
    private let stackLayer = CALayer()
    /// Two frames peeking out behind a collapsed stack's photo.
    private let pileLayers = [CALayer(), CALayer()]
    private var image: CGImage?

    var hasImage: Bool { image != nil }

    /// Space under the photo for the stars.
    static let footerHeight: CGFloat = 20
    static let photoInset: CGFloat = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        let root = layer!
        for sublayer in [matLayer] + pileLayers.reversed() + [placeholderLayer, photoLayer, dimLayer, decisionLayer, newLayer, bestPickLayer, stackLayer, starsLayer, warningLayer, captionLayer, focusLayer] {
            sublayer.actions = Self.noActions
            root.addSublayer(sublayer)
        }
        matLayer.cornerRadius = 8
        matLayer.cornerCurve = .continuous
        focusLayer.cornerRadius = 9
        focusLayer.cornerCurve = .continuous
        focusLayer.borderWidth = 2
        placeholderLayer.cornerRadius = 2
        photoLayer.contentsGravity = .resize
        photoLayer.minificationFilter = .trilinear
        photoLayer.magnificationFilter = .linear
        photoLayer.masksToBounds = true
        photoLayer.cornerRadius = 1.5
        for badge in [decisionLayer, newLayer, bestPickLayer, stackLayer, starsLayer, warningLayer, captionLayer] {
            badge.contentsGravity = .resize
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        NotificationCenter.default.addObserver(self, selector: #selector(systemAccessibilityChanged), name: SystemAccessibility.didChange, object: nil)
    }

    /// What VoiceOver's press does: opens the photo (the grid, the filmstrip) or shows the frame
    /// (stack review), as a double-click or click does.
    var accessibilityPress: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let accessibilityPress else { return false }
        accessibilityPress()
        return true
    }

    /// Increase Contrast changed: the badges and the selection are drawn again.
    @objc private func systemAccessibilityChanged() {
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let noActions: [String: any CAAction] = [
        "contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "frame": NSNull(),
        "opacity": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
        "borderWidth": NSNull(),
    ]

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    func setImage(_ image: CGImage?) {
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photoLayer.contents = image
        CATransaction.commit()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let content else {
            for sublayer in layer?.sublayers ?? [] { sublayer.isHidden = true }
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        for sublayer in layer?.sublayers ?? [] { sublayer.contentsScale = scale }
        let bounds = self.bounds

        // Mat and focus ring. A selected tile is outlined as well as tinted, so selection does not
        // depend on colour; Increase Contrast makes both outlines heavier.
        let contrast = SystemAccessibility.increaseContrast
        matLayer.isHidden = false
        matLayer.frame = bounds.insetBy(dx: 1.5, dy: 1.5)
        matLayer.backgroundColor = content.isSelected
            ? Palette.accent.withAlphaComponent(contrast ? 0.5 : 0.34).cgColor
            : Palette.tileMat.cgColor
        matLayer.borderColor = Palette.accent.cgColor
        matLayer.borderWidth = content.isSelected ? (contrast ? 3 : 2) : 0
        focusLayer.isHidden = !content.isFocused
        focusLayer.frame = bounds.insetBy(dx: 0.5, dy: 0.5)
        focusLayer.borderColor = NSColor(white: contrast ? 1 : 0.96, alpha: 1).cgColor
        focusLayer.borderWidth = contrast ? 3 : 2

        // The photo, fitted into the box above the footer. A collapsed stack leaves room for the
        // frames peeking out behind it, up and to the right.
        let inset = Self.photoInset
        let pile: CGFloat = content.collapsed == nil ? 0 : (bounds.width < 110 ? 3 : 4)
        let box = CGRect(
            x: inset, y: Self.footerHeight,
            width: bounds.width - inset * 2 - pile * 2, height: bounds.height - Self.footerHeight - inset - pile * 2
        )
        let aspect = image.map { CGFloat($0.width) / CGFloat(max(1, $0.height)) } ?? content.aspect
        let fitted = Self.fit(aspect: aspect, in: box)
        let dimmed = content.decision == .rejected && !content.isUnreadable
        for (index, layer) in pileLayers.enumerated() {
            layer.isHidden = content.collapsed == nil
            let offset = pile * CGFloat(index + 1)
            layer.frame = fitted.offsetBy(dx: offset, dy: offset)
            layer.backgroundColor = NSColor(white: index == 0 ? 0.34 : 0.26, alpha: 1).cgColor
            layer.borderColor = NSColor(white: 0.06, alpha: 0.9).cgColor
            layer.borderWidth = 1
            layer.cornerRadius = 1.5
        }
        placeholderLayer.isHidden = image != nil && !content.isUnreadable
        placeholderLayer.frame = fitted
        placeholderLayer.backgroundColor = Palette.placeholder.cgColor
        photoLayer.isHidden = image == nil || content.isUnreadable
        photoLayer.frame = fitted
        dimLayer.isHidden = !dimmed
        dimLayer.frame = fitted
        dimLayer.backgroundColor = NSColor(white: 0.06, alpha: 0.68).cgColor

        // Badge size follows the tile size, within readable limits.
        let badge = min(22, max(15, (bounds.width * 0.115).rounded()))
        let margin: CGFloat = bounds.width < 110 ? 4 : 6

        // Decision: top right of the photo. A collapsed stack whose frames differ shows how they
        // split: a ring in green, red and grey.
        var decisionKind: TileArtwork.Kind? = content.isUnreadable ? nil
            : content.decision == .kept ? .kept : content.decision == .rejected ? .rejected : nil
        if let summary = content.collapsed?.decisions, summary.isMixed {
            decisionKind = .decisionSummary(kept: summary.kept, rejected: summary.rejected, unreviewed: summary.unreviewed)
        }
        place(decisionLayer, kind: decisionKind, size: badge, scale: scale) { size in
            CGPoint(x: fitted.maxX - margin - size.width, y: fitted.maxY - margin - size.height)
        }

        // Best pick then New: top left of the photo.
        var leftX = fitted.minX + margin
        place(bestPickLayer, kind: content.isBestPick ? .bestPick : nil, size: badge, scale: scale) { size in
            CGPoint(x: leftX, y: fitted.maxY - margin - size.height)
        }
        if content.isBestPick { leftX += badge + 4 }
        let pillHeight = (badge * 0.8).rounded()
        place(newLayer, kind: content.isNew ? .new : nil, size: pillHeight, scale: scale) { size in
            CGPoint(x: leftX, y: fitted.maxY - margin - size.height + (badge - pillHeight) / 2 - 0.5)
        }

        // Stars, or the unreadable caption, just under the photo, so they read as part of it
        // whatever the photo's shape.
        let starSize: CGFloat = bounds.width < 110 ? 9 : 11
        func underPhoto(_ size: CGSize) -> CGFloat {
            max(3, fitted.minY - 5 - size.height).rounded()
        }
        place(starsLayer, kind: content.rating > 0 && !content.isUnreadable ? .stars(content.rating) : nil, size: starSize, scale: scale) { size in
            CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: underPhoto(size))
        }
        place(captionLayer, kind: content.isUnreadable ? .unreadableCaption : nil, size: 11, scale: scale) { size in
            CGPoint(x: ((bounds.width - size.width) / 2).rounded(), y: underPhoto(size))
        }
        if !captionLayer.isHidden, captionLayer.frame.width > bounds.width - 8 {
            captionLayer.isHidden = true
        }
        layoutReasons(content, in: fitted, margin: margin, scale: scale, dimmed: dimmed)

        let warning = min(30, max(18, (fitted.height * 0.3).rounded()))
        place(warningLayer, kind: content.isUnreadable ? .unreadable : nil, size: warning, scale: scale) { size in
            CGPoint(x: fitted.midX - size.width / 2, y: fitted.midY - size.height / 2)
        }
    }

    /// Reason badges along the bottom left of the photo, and the stack marker at its bottom right.
    /// They are smaller than the decision badge and sit on the photo's edge, so they read at a
    /// glance without covering what is being judged. When they do not all fit, the last shows
    /// how many more there are.
    private func layoutReasons(_ content: TileContent, in fitted: CGRect, margin: CGFloat, scale: CGFloat, dimmed: Bool) {
        // Small enough to stay off the subject: 12 points at the smallest thumbnails, 20 at the largest.
        let size = min(20, max(12, (bounds.width * 0.1).rounded()))
        let gap: CGFloat = bounds.width < 110 ? 2 : 3
        var right = fitted.maxX - margin
        place(stackLayer, kind: content.stackSize.map { .stackCount($0) }, size: size, scale: scale) { points in
            CGPoint(x: fitted.maxX - margin - points.width, y: fitted.minY + margin)
        }
        if !stackLayer.isHidden { right = stackLayer.frame.minX - gap }
        stackLayer.opacity = dimmed ? 0.7 : 1

        let available = right - (fitted.minX + margin)
        let fits = max(0, Int((available + gap) / (size + gap)))
        let reasons = content.reasons + content.notes
        var kinds: [TileArtwork.Kind] = reasons.map { .reason(symbol: $0.symbol, certain: $0.isCertain) }
        // Small tiles show at most two marks, so most of the photo stays visible.
        let limit = bounds.width < 110 ? min(fits, 2) : fits
        if kinds.count > limit {
            let fits = limit
            kinds = fits > 0 ? Array(kinds.prefix(fits - 1)) + [.more(reasons.count - (fits - 1))] : []
        }
        while reasonLayers.count < kinds.count {
            let layer = CALayer()
            layer.actions = Self.noActions
            layer.contentsGravity = .resize
            self.layer?.insertSublayer(layer, below: focusLayer)
            reasonLayers.append(layer)
        }
        for (index, layer) in reasonLayers.enumerated() {
            layer.contentsScale = scale
            guard index < kinds.count else {
                layer.isHidden = true
                continue
            }
            let x = fitted.minX + margin + CGFloat(index) * (size + gap)
            place(layer, kind: kinds[index], size: size, scale: scale) { _ in CGPoint(x: x, y: fitted.minY + margin) }
            layer.opacity = dimmed ? 0.7 : 1
        }
    }

    private func place(_ layer: CALayer, kind: TileArtwork.Kind?, size: CGFloat, scale: CGFloat, origin: (CGSize) -> CGPoint) {
        guard let kind, let image = TileArtwork.image(kind, size: size, scale: scale) else {
            layer.isHidden = true
            return
        }
        let points = TileArtwork.pointSize(kind, size: size.rounded())
        layer.isHidden = false
        layer.contents = image
        layer.frame = CGRect(origin: origin(points), size: points).integral
    }

    static func fit(aspect: CGFloat, in box: CGRect) -> CGRect {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        var size = CGSize(width: box.width, height: box.width / aspect)
        if size.height > box.height {
            size = CGSize(width: box.height * aspect, height: box.height)
        }
        return CGRect(
            x: (box.midX - size.width / 2).rounded(),
            y: (box.midY - size.height / 2).rounded(),
            width: size.width.rounded(),
            height: size.height.rounded()
        )
    }

    private func updateAccessibility() {
        setAccessibilityLabel(content?.accessibilityLabel)
        setAccessibilitySelected(content?.isSelected ?? false)
        toolTip = content?.toolTip
    }
}
