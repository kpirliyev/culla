import CullaCore

/// Text from the app's string catalog, `Culla/Localizable.xcstrings`, in the language of
/// `Localization` (see Localization.swift in CullaCore and docs/localization.md).
///
/// All of the app's text goes through it, SwiftUI's included (`Text(localized("Keep"))` rather than
/// `Text("Keep")`), so one rule picks the language and an entry not yet translated falls back to
/// English with English plurals instead of showing its key. Entries are written by hand
/// (`"extractionState": "manual"`), each with a comment for the translator.
let localized = Localizer(bundle: .main)
