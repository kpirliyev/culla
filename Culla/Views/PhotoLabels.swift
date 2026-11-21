import CullaCore
import CullaSession
import SwiftUI

/// Small views shared by the loupe and the inspector.

struct UnreadablePhotoView: View {
    let photo: PhotoItem

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Palette.flaggedColor)
            Text(localized("Culla can’t read this file"))
                .font(.title3.weight(.medium))
            Text(photo.unreadableReason ?? "")
                .foregroundStyle(.secondary)
            Text(localized("It is left out of every group and is never moved."))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

/// A decision as an icon and a word, in its colour. Unreviewed shows a quiet outline.
struct DecisionLabel: View {
    let decision: Decision
    var isUnreadable = false

    var body: some View {
        if isUnreadable {
            Label(localized("decision.cannotRead", default: "Can’t read"), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.flaggedColor)
        } else {
            switch decision {
            case .kept:
                Label(Formatting.decision(.kept), systemImage: "checkmark.circle.fill").foregroundStyle(Palette.keptColor)
            case .rejected:
                Label(Formatting.decision(.rejected), systemImage: "xmark.circle.fill").foregroundStyle(Palette.rejectedColor)
            case .unreviewed:
                Label(Formatting.decision(.unreviewed), systemImage: "circle.dashed").foregroundStyle(.secondary)
            }
        }
    }
}

struct StarsView: View {
    let rating: Int
    var size: CGFloat = 10

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < rating ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(index < rating ? Color.primary : Color.secondary.opacity(0.5))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(Formatting.stars(rating)))
    }
}

struct NewPill: View {
    var body: some View {
        Text(localized("badge.new", default: "NEW"))
            .font(.system(size: 9, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(Color(white: 0.08))
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color(white: 0.97)))
            .accessibilityLabel(Text(localized("New since last time")))
    }
}
