import CullaAnalysis
import CullaCommands
import CullaSession
import Observation
import SwiftUI

/// What the loupe shows right now that the model does not hold: the zoom on screen and how
/// sharp the image is. Written by the loupe, read by its header and the automation dump.
@MainActor
@Observable
final class LoupeStatus {
    /// Device pixels per image pixel on screen.
    var factor = 1.0
    var isFit = true
    /// Which image is on screen.
    var resolution = Resolution.none
    /// True while the full-size image the zoom needs is being decoded.
    var loadingFullSize = false
    /// The share of the photo clipped, when the clipping overlay is on and measured.
    var clipping: (highlights: Double, shadows: Double)?

    enum Resolution: String {
        case none, thumbnail, screen, full
    }
}

/// The slim bar along the top of the loupe: the file's name and place in the group, Culla's
/// reasons for flagging it, its rating and decision, and the zoom.
struct LoupeHeaderView: View {
    let model: SessionModel
    let status: LoupeStatus

    var body: some View {
        HStack(spacing: 10) {
            if let photo = model.focusedPhoto {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(photo.file.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let position = model.order.position(of: photo.id) {
                        Text(localized("\(position + 1) of \(model.order.count)"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                    }
                }
                if photo.isNew { NewPill() }
                // The reason for the open group first, named with its tier ("Eyes closed ·
                // Certain"); other reasons follow, shorter.
                // When the bar is too narrow for every badge in words, the other reasons shrink to
                // their icons, then the open group's own badge drops its tier: none is cut.
                let badges = badges(photo)
                let group = model.group
                let own = badges.filter { $0.group == group }
                let others = badges.filter { $0.group != group }
                ViewThatFits(in: .horizontal) {
                    badgeRow(own: own, others: others, ownTier: true, othersInWords: true)
                    badgeRow(own: own, others: others, ownTier: true, othersInWords: false)
                    badgeRow(own: own, others: others, ownTier: false, othersInWords: false)
                    badgeRow(own: [], others: own + others, ownTier: false, othersInWords: false)
                }
                .layoutPriority(-1)
                Spacer(minLength: 12)
                if photo.rating > 0 {
                    StarsView(rating: photo.rating, size: 10)
                }
                DecisionChip(decision: photo.decision, isUnreadable: photo.isUnreadable)
                ZoomReadout(status: status, zoomKey: KeyText.key(.zoomToggle, in: model.settings.keyBindings))
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.panelBackgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.separatorColor).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func badgeRow(own: [FlagBadge], others: [FlagBadge], ownTier: Bool, othersInWords: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(own, id: \.flag) { badge in
                FlagBadgeView(badge: badge, showsTier: ownTier)
            }
            ForEach(others, id: \.flag) { badge in
                FlagBadgeView(badge: badge, iconOnly: !othersInWords)
            }
        }
        .fixedSize()
    }

    private func badges(_ photo: PhotoItem) -> [FlagBadge] {
        model.session.badges(for: photo.id)?.flags ?? []
    }
}

/// A reason Culla flagged the photo, in amber: filled when Certain, outlined when Likely.
struct FlagBadgeView: View {
    let badge: FlagBadge
    /// Names the tier too: "Eyes closed · Certain".
    var showsTier = false
    /// Only the icon, when the bar is narrow; the name stays the tooltip and the spoken label.
    var iconOnly = false

    var body: some View {
        let certain = badge.tier == .certain
        let flag = Formatting.flag(badge.flag)
        let named = certain ? localized("\(flag) · Certain") : localized("\(flag) · Likely")
        Group {
            if iconOnly {
                Image(systemName: Formatting.flagSymbol(badge.flag))
            } else {
                Label(showsTier ? named : flag, systemImage: Formatting.flagSymbol(badge.flag))
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(certain ? Color.black.opacity(0.85) : Palette.flaggedColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(certain ? Palette.flaggedColor : Color.clear))
        .overlay(Capsule().strokeBorder(Palette.flaggedColor, lineWidth: certain ? 0 : 1))
        .fixedSize()
        .help(certain ? named : localized("\(flag) · Likely: past the threshold, worth a look"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(certain ? localized("\(flag), certain") : localized("\(flag), likely"))
    }
}

/// The decision as a chip: filled green or red with its icon, or a quiet outline for Unreviewed.
struct DecisionChip: View {
    let decision: Decision
    var isUnreadable = false

    var body: some View {
        Group {
            if isUnreadable {
                chip(localized("chip.unreadable", default: "Can’t read"), "exclamationmark.triangle.fill", fill: Palette.flaggedColor, text: .black.opacity(0.85))
            } else {
                switch decision {
                case .kept: chip(Formatting.decision(.kept), "checkmark", fill: Palette.keptColor, text: .white)
                case .rejected: chip(Formatting.decision(.rejected), "xmark", fill: Palette.rejectedColor, text: .white)
                case .unreviewed:
                    Label(Formatting.decision(.unreviewed), systemImage: "circle.dashed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                }
            }
        }
        .fixedSize()
    }

    private func chip(_ title: String, _ symbol: String, fill: Color, text: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(text)
            .padding(.horizontal, 8)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(fill))
    }
}

/// The zoom on screen: "Fit · 31%" or "100%", with a spinner while the full-size image loads.
struct ZoomReadout: View {
    let status: LoupeStatus
    /// The Zoom to 100% key, from the live key map.
    var zoomKey: String?

    var body: some View {
        HStack(spacing: 5) {
            if status.loadingFullSize {
                ProgressView().controlSize(.mini).help(localized("Loading the full-size image"))
            }
            Text(status.isFit ? localized("Fit · \(Formatting.zoom(status.factor))") : Formatting.zoom(status.factor))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(status.isFit ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .frame(minWidth: 74, alignment: .trailing)
        .help(zoomKey.map { localized("Zoom: \($0) switches between fit and 100%") }
            ?? localized("Zoom: double-click switches between fit and 100%"))
        .accessibilityLabel(localized("Zoom \(Formatting.zoom(status.factor))"))
    }
}

/// The legend of the clipping overlay, over the bottom left of the photo.
struct ClippingLegend: View {
    let status: LoupeStatus

    var body: some View {
        if let clipping = status.clipping {
            HStack(spacing: 12) {
                legend(color: Color(red: 0.7, green: 0, blue: 0.7), striped: false,
                       text: localized("Highlights clipped \(Formatting.percent(clipping.highlights))"),
                       spoken: localized("Highlights clipped: \(Formatting.percent(clipping.highlights)), shown solid"))
                legend(color: Color(red: 0, green: 0.24, blue: 0.7), striped: true,
                       text: localized("Shadows clipped \(Formatting.percent(clipping.shadows))"),
                       spoken: localized("Shadows clipped: \(Formatting.percent(clipping.shadows)), shown in stripes"))
            }
            .font(.system(size: 11, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(white: 0.08, opacity: 0.85)))
            .overlay(Capsule().strokeBorder(Palette.hairlineColor))
            .fixedSize()
        }
    }

    /// A swatch as the overlay draws it: highlights solid, shadows in stripes, so the two differ
    /// by more than their colour.
    private func legend(color: Color, striped: Bool, text: String, spoken: String) -> some View {
        HStack(spacing: 5) {
            Group {
                if striped {
                    Canvas { context, size in
                        for x in stride(from: -size.height, to: size.width, by: 4) {
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: size.height))
                            path.addLine(to: CGPoint(x: x + size.height, y: 0))
                            context.stroke(path, with: .color(color), lineWidth: 2)
                        }
                    }
                } else {
                    Rectangle().fill(color)
                }
            }
            .frame(width: 10, height: 10)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(0.4), lineWidth: 0.5))
            .accessibilityHidden(true)
            Text(text)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }
}

