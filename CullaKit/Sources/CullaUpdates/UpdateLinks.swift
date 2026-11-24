import CullaCore
import Foundation

/// The pages a notice about a newer version opens in the browser. Both are built into the app;
/// nothing from the update file is used as an address.
public enum UpdateLinks {
    /// The site's download link, which leads to the newest disk image.
    public static let download = URL(string: "https://cullaapp.com/download")!

    /// The release notes in the app's language, as the site generates them: /en/release-notes/.
    public static func releaseNotes(_ language: AppLanguage) -> URL {
        URL(string: "https://cullaapp.com/\(language.rawValue)/release-notes/")!
    }
}
