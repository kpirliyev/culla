import AppKit
import CullaCommands
import CullaCore
import CullaStore
import SwiftUI

/// What the window shows with no shoot open: a drop target, Open Folder, and recent shoots.
struct WelcomeView: View {
    let app: AppModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 24)
                    VStack(spacing: app.showsIntroduction ? 22 : 28) {
                        header
                        if app.showsIntroduction {
                            IntroductionCard(app: app)
                        }
                        DropTarget(isTargeted: app.isDropTargeted) {
                            app.perform(.openFolder)
                        }
                        if !app.recents.isEmpty {
                            RecentList(app: app)
                        }
                    }
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 40)
                    Spacer(minLength: 24)
                }
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Palette.windowBackgroundColor)
        .alert(
            app.problem?.title ?? "",
            isPresented: Binding(get: { app.problem != nil }, set: { if !$0 { app.problem = nil } }),
            presenting: app.problem
        ) { problem in
            if let session = problem.session {
                Button(localized("Locate Folder…")) { app.locate(session) }
                Button(localized("Try Again")) {
                    if let recent = app.recents.first(where: { $0.id == session.id }) { app.openRecent(recent) }
                }
            }
            Button(localized("alert.ok", default: "OK"), role: .cancel) {}
        } message: { problem in
            Text(problem.message)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(nsImage: Palette.appIcon)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text(verbatim: "Culla")
                .font(.system(size: 28, weight: .semibold))
            Text(localized("Sort a shoot into keepers and rejects, from the keyboard."))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }
}

/// The first-run introduction: what Culla does, and the five keys that matter, read from the
/// live key map so a remapped key shows as it is. Dismissed for good with Got It, or by opening a
/// first shoot; Help ▸ Keyboard Shortcuts lists every key.
private struct IntroductionCard: View {
    let app: AppModel

    var body: some View {
        let keys = app.settings.keyBindings
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("Welcome to Culla"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(localized("Got It")) { app.dismissIntroduction() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            Text(localized("Culla finds the likely rejects in a shoot — closed eyes, blur, bad exposure, duplicates and bursts of lookalikes — and you decide each one from the keyboard. Nothing is moved until you review and apply, and applying can be undone."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(Self.keyCommands, id: \.command) { item in
                    GridRow {
                        KeyCapLabel(text: keys.primaryChord(for: item.command)?.displayString ?? "—")
                        Text(item.text).font(.callout)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(Self.spokenRow(keys.primaryChord(for: item.command)?.spokenName, item.text)))
                }
            }
            Button(localized("All Keyboard Shortcuts…")) { app.showKeyboardShortcuts?() }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.hairlineColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("welcome.introduction", default: "Introduction"))
    }

    /// "Command O: Open a folder", for VoiceOver.
    static func spokenRow(_ key: String?, _ text: String) -> String {
        let key = key ?? localized("welcome.noKey", default: "No key")
        return localized("welcome.keyAndAction", default: "\(key): \(text)")
    }

    static var keyCommands: [(command: Command, text: String)] {
        [
            (.keep, localized("Keep the photo and move to the next")),
            (.reject, localized("Reject it and move to the next")),
            (.clearDecision, localized("Clear the decision")),
            (.toggleLoupe, localized("Switch between the grid and one large photo")),
            (.acceptStack, localized("Accept a stack or duplicate set: keep the pick, reject the rest")),
        ]
    }
}

/// A key as it looks on a keyboard, for help texts.
struct KeyCapLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: 30)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0.18)))
    }
}

private struct DropTarget: View {
    let isTargeted: Bool
    let open: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text(localized("Drop a shoot folder or memory card here"))
                .font(.system(size: 14, weight: .medium))
            Button(action: open) {
                Text(localized("welcome.openFolder", default: "Open Folder…")).frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            Text(localized("Nothing is moved or deleted until you review and apply."))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.white.opacity(0.18),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1.25, dash: [6, 5])
                )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(localized("Drop a shoot folder here, or open one"))
    }
}

private struct RecentList: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localized("Recent Shoots"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(app.recents.prefix(6).enumerated()), id: \.element.id) { index, recent in
                    if index > 0 {
                        Rectangle().fill(Palette.hairlineColor).frame(height: 1).padding(.leading, 44)
                    }
                    RecentRow(recent: recent) { app.openRecent(recent) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairlineColor))
        }
    }
}

private struct RecentRow: View {
    let recent: RecentSession
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recent.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(recent.displayPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    if let counts = recent.counts {
                        Text(countText(counts))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Text(recent.stored.lastOpenedAt, format: Date.RelativeFormatStyle(presentation: .named, locale: Localization.locale))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isHovered ? Color.white.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(recent.displayPath)
        .accessibilityLabel(Text(localized("welcome.openRecent", default: "Open \(recent.name)")))
    }

    private func countText(_ counts: SessionPhotoCounts) -> String {
        var parts = [Formatting.photos(counts.photos)]
        if counts.kept > 0 { parts.append(localized("\(counts.kept) kept")) }
        if counts.rejected > 0 { parts.append(localized("\(counts.rejected) rejected")) }
        return parts.joined(separator: " · ")
    }
}

/// Shown while a shoot is scanned and its capture data read.
struct LoadingView: View {
    let app: AppModel

    var body: some View {
        VStack(spacing: 14) {
            if case .loading(let info) = app.screen {
                Text(localized("Opening “\(info.name)”"))
                    .font(.system(size: 17, weight: .semibold))
                if info.total > 0 {
                    ProgressView(value: Double(info.done), total: Double(max(1, info.total)))
                        .frame(width: 280)
                    Text(localized("Reading \(info.done) of \(info.total) photos"))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(localized("Looking for photos…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(localized("loading.cancel", default: "Cancel")) { app.closeShoot() }
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.windowBackgroundColor)
    }
}
