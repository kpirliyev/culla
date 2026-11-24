// Left out of the App Store variant, which has no update check (see UpdateChecker.swift).
#if !APP_STORE
import AppKit
import CullaCore
import CullaUpdates
import SwiftUI

/// Culla ▸ Check for Updates…: asks at once; the answer is an alert on the window in front (the
/// main window if none is). Disabled while a check is under way. The item is its own target, so
/// the menu bar needs nothing else to offer it.
@MainActor
final class CheckForUpdatesMenuItem: NSMenuItem, NSMenuItemValidation {
    private let updates: UpdateChecker

    init(updates: UpdateChecker) {
        self.updates = updates
        super.init(title: localized("menu.checkForUpdates", default: "Check for Updates…"),
                   action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func checkForUpdates(_ sender: Any?) { updates.checkNow(window: NSApp.keyWindow) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { !updates.isChecking }
}

extension SettingsModel {
    /// Settings ▸ General ▸ Check Now: the same check as Culla ▸ Check for Updates…, answered
    /// with an alert on the Settings window.
    func checkForUpdatesNow() {
        app.updates.checkNow(window: window)
    }
}

/// Settings ▸ General ▸ Updates: the automatic check, what it sends, Check Now and when Culla
/// last checked.
struct UpdatesSection: View {
    let model: SettingsModel

    var body: some View {
        let settings = model.settings
        let updates = model.app.updates
        Section(localized("settings.section.updates", default: "Updates")) {
            LabeledContent {
                Toggle(UpdateText.settingTitle, isOn: Binding(get: { settings.checksForUpdatesAutomatically },
                                                             set: { updates.setChecksAutomatically($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            } label: {
                SettingLabel(title: UpdateText.settingTitle, help: UpdateText.settingHelp)
            }
            // On the row, not the section: a section hands its modifiers to each of its rows.
            .automationMark("settingsUpdatesSection")
            LabeledContent {
                HStack(spacing: 8) {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel(UpdateText.checking)
                    }
                    Button(UpdateText.checkNow) { model.checkForUpdatesNow() }
                        .disabled(updates.isChecking)
                }
            } label: {
                Text(verbatim: updates.isChecking
                     ? UpdateText.checking
                     : UpdateText.lastChecked(settings.lastUpdateCheck, failed: settings.lastUpdateCheckFailed))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One quiet line when an automatic check found a newer version: "Culla 1.1 is available.", with
/// Download, Release Notes and Skip This Version. It is only ever shown here, with no shoot open.
/// The buttons go below the sentence when one line has no room for them.
struct UpdateNotice: View {
    let version: ReleaseVersion
    let updates: UpdateChecker

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sentence
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                sentence
                HStack(spacing: 12) { buttons }
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairlineColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(UpdateText.notice(version))
        .automationMark("welcomeUpdateLine")
    }

    private var sentence: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(verbatim: UpdateText.notice(version))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(UpdateText.download) { updates.perform(.download) }
            .controlSize(.small)
        Button(UpdateText.releaseNotes) { updates.perform(.releaseNotes) }
            .buttonStyle(.link)
            .font(.callout)
        Button(UpdateText.skipThisVersion) { updates.skip(version) }
            .buttonStyle(.link)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}
#endif
