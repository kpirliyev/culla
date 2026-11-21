import Foundation

/// Where the app keeps its data, and whether it runs a UI automation script.
///
/// Automation runs keep their own database, thumbnail cache and settings, so a script that
/// resets them can never touch the sessions of a person using the app.
struct AppEnvironment: Sendable {
    /// True when a debug build was launched with an automation script.
    let isAutomation: Bool
    /// The app's folder in Application Support: the database lives here.
    let dataFolder: URL
    /// The app's folder in Caches: thumbnails live here.
    let cacheFolder: URL
    /// The defaults domain settings are stored in; nil for the standard one.
    let defaultsSuite: String?

    var databaseURL: URL { dataFolder.appendingPathComponent("Culla.sqlite", isDirectory: false) }
    var thumbnailFolder: URL { cacheFolder.appendingPathComponent("Thumbnails", isDirectory: true) }

    /// The name of the defaults domain settings are written to.
    var defaultsDomain: String {
        defaultsSuite ?? Bundle.main.bundleIdentifier ?? "com.kpirliyev.Culla"
    }

    func makeDefaults() -> UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static func make(automation: Bool) -> AppEnvironment {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let name = automation ? "Culla-Automation" : "Culla"
        return AppEnvironment(
            isAutomation: automation,
            dataFolder: support.appendingPathComponent(name, isDirectory: true),
            cacheFolder: caches.appendingPathComponent(name, isDirectory: true),
            defaultsSuite: automation ? "com.kpirliyev.Culla.automation" : nil
        )
    }

    /// The user's real home folder. Inside the sandbox `NSHomeDirectory()` is the container.
    static let realHomeFolder: String = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }()

    /// A path for display, with the home folder shortened to "~".
    static func displayPath(_ path: String) -> String {
        let home = realHomeFolder
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
