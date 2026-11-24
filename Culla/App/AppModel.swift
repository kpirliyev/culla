import AppKit
import CullaAnalysis
import CullaCommands
import CullaCore
import CullaFiles
import CullaSession
import CullaStore
import Foundation
import ImageIO
import Observation
import os

/// A shoot in the welcome view's recent list.
struct RecentSession: Identifiable, Hashable {
    var stored: StoredSession
    var counts: SessionPhotoCounts?

    var id: Int64 { stored.id }
    var name: String { stored.name }
    var displayPath: String { AppEnvironment.displayPath(stored.folderPath) }
}

/// How far opening a shoot has got, for the loading view.
struct LoadingInfo: Equatable {
    var name: String
    var phase: ShootLoadProgress.Phase
    var done: Int
    var total: Int
}

/// Something that stopped a shoot from opening, said plainly, with a way out.
struct OpenProblem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    /// The session whose folder could not be found, so the person can locate it.
    var session: StoredSession?
}

/// How long the last open took, for the automation harness and diagnostics.
struct OpenTimings: Equatable {
    var startedAt: Date
    /// When the photos were scanned, read and put in capture order.
    var photosKnownAt: Date?
    /// When the shoot window was shown.
    var shownAt: Date?
    var photoCount = 0
    var metadataRead = 0
}

/// The app: what the window shows (welcome, loading or a shoot), the recent sessions, and the
/// commands that are not about one shoot.
@MainActor
@Observable
final class AppModel {
    enum Screen {
        case welcome
        case loading(LoadingInfo)
        case shoot(SessionModel)
    }

    private(set) var screen: Screen = .welcome
    private(set) var recents: [RecentSession] = []
    var problem: OpenProblem?
    /// True while a folder is dragged over the window, for the welcome view's drop target.
    var isDropTargeted = false
    private(set) var lastOpenTimings: OpenTimings?
    /// Set when the open shoot was followed to the place its folder moved to, for the notice.
    @ObservationIgnored private var followedFolder: (from: String, to: URL)?

    var session: SessionModel? {
        if case .shoot(let model) = screen { return model }
        return nil
    }

    var isLoading: Bool {
        if case .loading = screen { return true }
        return false
    }

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let activity = ActivityTracker()
    @ObservationIgnored let thumbnails: ThumbnailCache
    /// The power source and memory pressure, which set how many photos are analysed at once.
    @ObservationIgnored let power = PowerMonitor()
    @ObservationIgnored weak var window: NSWindow?
    #if !APP_STORE
    /// Check for updates: the welcome view's notice, Culla ▸ Check for Updates… and Settings.
    /// Made at first use (the automatic check at launch). The App Store variant has none: the
    /// store updates the app.
    @ObservationIgnored private(set) lazy var updates = UpdateChecker(
        settings: settings, isAutomation: environment.isAutomation, mainWindow: { [weak self] in self?.window })
    #endif
    /// Shows the Settings window (⌘,); set by the app delegate.
    @ObservationIgnored var showSettings: (() -> Void)?
    /// Shows Help ▸ Keyboard Shortcuts; set by the app delegate.
    @ObservationIgnored var showKeyboardShortcuts: (() -> Void)?
    /// Called when the key map changed, so menus show the new keys; set by the app delegate.
    @ObservationIgnored var keyBindingsChanged: (() -> Void)?
    @ObservationIgnored private var databaseTask: Task<CullaDatabase, any Error>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.kpirliyev.Culla", category: "open")
    static let thumbnailMemoryLimit = 64 << 20

    init(environment: AppEnvironment) {
        self.environment = environment
        settings = AppSettings(defaults: environment.makeDefaults(), domain: environment.defaultsDomain)
        do {
            // About 90 thumbnails: two screens of tiles at the default size. Each thumbnail on
            // screen also costs Core Animation a copy of about the same size, held as long as the
            // image lives, so this budget counts twice; scrolling back further reads the disk
            // cache, a few milliseconds off the main thread.
            thumbnails = try ThumbnailCache(folder: environment.thumbnailFolder, memoryLimit: Self.thumbnailMemoryLimit)
        } catch {
            // The cache folder could not be made; thumbnails then live in memory only.
            let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("CullaThumbnails")
            thumbnails = try! ThumbnailCache(folder: fallback)
        }
        settings.changed = { [weak self] change in self?.settingsChanged(change) }
    }

    // MARK: - First run

    /// The welcome view's introduction shows until it is dismissed or a first shoot is opened.
    var showsIntroduction: Bool { !settings.introductionDismissed }

    func dismissIntroduction() {
        settings.introductionDismissed = true
    }

    // MARK: - Settings

    /// Every setting takes effect at once, in the open shoot too.
    private func settingsChanged(_ change: AppSettings.Change) {
        switch change {
        case .defaultTuning: session?.defaultTuningChanged()
        case .keyBindings: keyBindingsChanged?()
        case .scanOptions: session?.disk.rescan(trigger: "settings")
        case .collapseStacks: session?.setStacksExpanded(!settings.collapseStacksInAllPhotos)
        case .cacheLimit: pruneCache()
        }
    }

    // MARK: - Cache

    /// What the caches take, for Settings ▸ Performance.
    struct CacheUsage: Equatable {
        var thumbnailBytes: Int64
        var cachedScores: Int
        var databaseBytes: Int64
    }

    /// The last measured usage; refreshed by `measureCache()`.
    private(set) var cacheUsage: CacheUsage?
    @ObservationIgnored private var pruneTask: Task<Void, Never>?

    func measureCache() async {
        let thumbnailBytes = (try? await thumbnails.diskUsage()) ?? 0
        let scores = (try? await database().cachedScoreCount()) ?? 0
        let url = environment.databaseURL
        let databaseBytes = await BlockingQueue.shared.run {
            ["", "-wal", "-shm"].reduce(Int64(0)) { total, suffix in
                let path = url.path + suffix
                let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
                return total + size
            }
        }
        cacheUsage = CacheUsage(thumbnailBytes: thumbnailBytes, cachedScores: scores, databaseBytes: databaseBytes)
    }

    /// Keeps the thumbnail cache under the limit in Settings, least recently used first. Runs at
    /// launch, when the limit changes and when a shoot closes.
    func pruneCache() {
        let limit = settings.cacheLimitBytes
        let previous = pruneTask
        pruneTask = Task {
            await previous?.value
            _ = try? await thumbnails.pruneDisk(toBytes: limit)
            await measureCache()
        }
    }

    /// Clear Cache in Settings: every thumbnail on disk (they are made again as photos are shown),
    /// and, when asked, every cached score (each shoot is then analysed again when next opened).
    func clearCache(scores: Bool) async {
        await pruneTask?.value
        _ = try? await thumbnails.pruneDisk(toBytes: 0)
        if scores, let database = try? await database() {
            _ = try? await database.deleteStaleScores(savedBefore: .distantFuture)
        }
        await measureCache()
    }

    // MARK: - Database

    /// The database, opened off the main thread the first time it is needed.
    func database() async throws -> CullaDatabase {
        if let databaseTask { return try await databaseTask.value }
        let url = environment.databaseURL
        let task = Task.detached(priority: .userInitiated) { try await CullaDatabase.open(at: url) }
        databaseTask = task
        return try await task.value
    }

    func reloadRecents() async {
        do {
            let database = try await database()
            let clearedAt = settings.recentsClearedAt ?? .distantPast
            let sessions = try await database.recentSessions(limit: 12).filter { $0.lastOpenedAt > clearedAt }
            let counts = try await database.photoCounts(sessionIDs: sessions.map(\.id))
            recents = sessions.map { RecentSession(stored: $0, counts: counts[$0.id]) }
        } catch {
            Self.log.error("Loading recent sessions failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Empties the recent list (File ▸ Open Recent ▸ Clear Menu). Sessions and their decisions
    /// stay in the database, so opening a folder again brings them back.
    func clearRecents() {
        settings.recentsClearedAt = Date()
        recents = []
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    // MARK: - Commands

    func isEnabled(_ command: Command) -> Bool {
        switch command {
        case .openSettings: return true
        // Nothing leaves the shoot while its files are being moved.
        case .openFolder: return !isLoading && session?.apply.isRunning != true
        case .closeShoot: return (session != nil || isLoading) && session?.apply.isRunning != true
        default: return session?.isEnabled(command) ?? false
        }
    }

    @discardableResult
    func perform(_ command: Command) -> Bool {
        guard isEnabled(command) else { return false }
        switch command {
        case .openSettings:
            showSettings?()
            return true
        case .openFolder:
            chooseFolder()
            return true
        case .closeShoot:
            closeShoot()
            return true
        default:
            return session?.perform(command) ?? false
        }
    }

    // MARK: - Opening

    /// Asks for a folder with the open panel. The panel grants the sandbox access to it.
    func chooseFolder(completion: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = localized("openPanel.open", default: "Open")
        panel.message = localized("Choose a shoot folder or a memory card.")
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            if let completion {
                completion(url)
            } else {
                self?.openFolder(at: url)
            }
        }
        if let window, window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    /// Opens a folder the app was given access to: from the open panel, a drop on the window or
    /// the Dock icon, or (in automation) its own container.
    func openFolder(at url: URL) {
        let timing = MainThreadTiming.begin("app.openFolder")
        defer { timing.end() }
        let folder = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            problem = OpenProblem(
                title: localized("“\(folder.lastPathComponent)” is not a folder"),
                message: localized("Drop or choose a folder of photos, or a memory card.")
            )
            return
        }
        let access = FolderAccess(url: folder)
        // An app-scoped bookmark lets the app reach the folder again after a relaunch.
        let bookmark = try? FolderBookmark.create(for: folder, securityScoped: true)
        startLoading(folder: folder, access: access, bookmark: bookmark)
    }

    /// Reopens a recent session through its saved bookmark.
    func openRecent(_ recent: RecentSession) {
        let stored = recent.stored
        guard let bookmark = stored.bookmark else {
            // No bookmark (the folder was reachable without one): try the saved path.
            openSavedPath(stored)
            return
        }
        let resolved: FolderBookmark.Resolved
        do {
            resolved = try FolderBookmark.resolve(bookmark, securityScoped: true)
        } catch {
            reportMissing(stored)
            return
        }
        let access = FolderAccess(url: resolved.url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            access.stop()
            reportMissing(stored)
            return
        }
        var newBookmark: Data?
        if resolved.isStale {
            // Made again while access is started, and saved in place of the old one.
            newBookmark = try? FolderBookmark.create(for: resolved.url, securityScoped: true)
        }
        let moved = CullaDatabase.folderPath(resolved.url) != stored.folderPath
        guard moved else {
            startLoading(folder: resolved.url, access: access, bookmark: newBookmark, known: stored)
            return
        }
        // The folder moved since: the session follows it, so its decisions come along rather than
        // a new, empty session starting at the new path.
        Task {
            await self.moveSession(stored.id, to: resolved.url)
            self.startLoading(folder: resolved.url, access: access, bookmark: newBookmark, known: stored)
        }
    }

    /// Points a session at its folder's new place, unless another session already has that path.
    private func moveSession(_ sessionID: Int64, to folder: URL) async {
        do {
            let database = try await database()
            if try await database.session(forFolder: folder) == nil {
                try await database.updateFolder(folder, sessionID: sessionID)
            }
        } catch {
            Self.log.error("Updating the folder failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The open shoot's folder cannot be reached: when its bookmark says it moved (renamed or
    /// moved on the same volume), the session follows it there and the shoot opens again.
    func followMovedShoot(_ model: SessionModel) {
        guard session === model, !model.apply.isRunning else { return }
        let folder = model.folder
        let sessionID = model.sessionID
        Task {
            guard let database = try? await database(), let stored = try? await database.session(id: sessionID),
                  let bookmark = stored.bookmark, let resolved = try? FolderBookmark.resolve(bookmark, securityScoped: true),
                  CullaDatabase.folderPath(resolved.url) != CullaDatabase.folderPath(folder)
            else { return }
            let access = FolderAccess(url: resolved.url)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  self.session === model
            else {
                access.stop()
                return
            }
            await self.moveSession(sessionID, to: resolved.url)
            self.followedFolder = (from: folder.lastPathComponent, to: resolved.url)
            self.startLoading(folder: resolved.url, access: access, bookmark: try? FolderBookmark.create(for: resolved.url, securityScoped: true))
        }
    }

    private func openSavedPath(_ stored: StoredSession) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: stored.folderPath, isDirectory: &isDirectory), isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: stored.folderPath)
        else {
            reportMissing(stored)
            return
        }
        startLoading(folder: stored.folderURL, access: nil, bookmark: nil, known: stored)
    }

    private func reportMissing(_ stored: StoredSession) {
        problem = OpenProblem(
            title: localized("“\(stored.name)” can’t be found"),
            message: localized("It may have been moved or renamed, or its drive or card is not connected. Your decisions are kept."),
            session: stored
        )
    }

    /// Lets the person point at a session's folder after it moved, then opens it.
    func locate(_ stored: StoredSession) {
        chooseFolder { [weak self] url in
            guard let self else { return }
            Task {
                do {
                    let database = try await self.database()
                    if try await database.session(forFolder: url) == nil {
                        try await database.updateFolder(url, sessionID: stored.id)
                    }
                } catch {
                    Self.log.error("Updating the folder failed: \(String(describing: error), privacy: .public)")
                }
                self.openFolder(at: url)
            }
        }
    }

    private func startLoading(folder: URL, access: FolderAccess?, bookmark: Data?, known: StoredSession? = nil) {
        let timing = MainThreadTiming.begin("app.startLoading")
        defer { timing.end() }
        loadTask?.cancel()
        let previous = session
        screen = .loading(LoadingInfo(name: folder.lastPathComponent, phase: .scanning, done: 0, total: 0))
        activity.begin(.loading)
        loadTask = Task {
            defer { activity.end(.loading) }
            if let previous {
                await previous.stopAnalysis()
                await previous.saver.flush()
                previous.close()
            }
            await load(folder: folder, access: access, bookmark: bookmark, known: known)
        }
    }

    private func load(folder: URL, access: FolderAccess?, bookmark: Data?, known: StoredSession?) async {
        var timings = OpenTimings(startedAt: Date())
        lastOpenTimings = timings
        do {
            let database = try await database()
            let stored = try await database.openSession(folder: folder, bookmark: bookmark)
            if let known, stored.id != known.id {
                Self.log.info("The folder resolved to another session’s path; opening that one")
            }
            let storedPhotos = try await database.photos(sessionID: stored.id)
            let knownPhotos = storedPhotos.map { $0.scannedPhoto(in: folder) }

            let name = folder.lastPathComponent
            let scanned = try await ShootLoader.load(
                folder: folder,
                includeSubfolders: settings.includeSubfolders,
                pairRAWWithRendered: settings.pairRAWWithRendered,
                known: knownPhotos
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, case .loading = self.screen else { return }
                    self.screen = .loading(LoadingInfo(name: name, phase: progress.phase, done: progress.done, total: progress.total))
                }
            }
            try Task.checkCancellation()

            // The shoot's own tuning, if it was adjusted from its tuning panel; else the default.
            let ownTuning = stored.tuning.flatMap { try? JSONDecoder().decode(Tuning.self, from: $0) }
            let tuning = ownTuning ?? settings.defaultTuning
            var built = await BlockingQueue.shared.run {
                Self.buildState(folder: folder, stored: storedPhotos, scanned: scanned, tuning: tuning)
            }
            try Task.checkCancellation()
            // The person's stack corrections and hand-chosen picks, applied to every grouping.
            let edits = try await database.stackEdits(sessionID: stored.id)
            built.state.setStackEdits(edits)
            timings.photosKnownAt = Date()
            timings.photoCount = built.state.count
            timings.metadataRead = scanned.count - storedPhotos.count

            let saver = SessionSaver(database: database, sessionID: stored.id, activity: activity)
            if storedPhotos.isEmpty || !(built.merge?.isEmpty ?? true) {
                saver.savePhotos(built.state.photos)
            }
            let modelTiming = MainThreadTiming.begin("open.sessionModel")
            let model = SessionModel(
                folder: folder,
                sessionID: stored.id,
                state: built.state,
                place: stored.place,
                mergeResult: built.merge,
                access: access,
                settings: settings,
                thumbnails: thumbnails,
                saver: saver,
                activity: activity,
                hasOwnTuning: ownTuning != nil && ownTuning != settings.defaultTuning
            )
            modelTiming.end()
            model.requestOpenFolder = { [weak self] in self?.perform(.openFolder) }
            model.window = window
            model.followMovedFolder = { [weak self, weak model] in
                guard let self, let model else { return }
                self.followMovedShoot(model)
            }
            let screenTiming = MainThreadTiming.begin("open.screenChange")
            screen = .shoot(model)
            screenTiming.end()
            if !settings.introductionDismissed { settings.introductionDismissed = true }
            if let followed = followedFolder, followed.to.standardizedFileURL == folder.standardizedFileURL {
                let path = AppEnvironment.displayPath(folder.path)
                model.showNotice(localized("“\(followed.from)” moved to \(path); Culla followed it. Every decision is kept."), symbol: "folder")
            }
            followedFolder = nil
            model.disk.start()
            // Runs a crash interrupted are offered for undo; Undo Apply finds its run.
            model.apply.shootOpened()
            timings.shownAt = Date()
            lastOpenTimings = timings
            // Analysis starts without being asked, and never holds up the shoot appearing.
            model.startAnalysis(database: database, power: power, openStartedAt: timings.startedAt)
            NSDocumentController.shared.noteNewRecentDocumentURL(folder)
            Task { await reloadRecents() }
        } catch is CancellationError {
            access?.stop()
        } catch {
            access?.stop()
            screen = .welcome
            let missing = !FileManager.default.fileExists(atPath: folder.path)
            problem = OpenProblem(
                title: missing
                    ? localized("“\(folder.lastPathComponent)” can’t be found")
                    : localized("“\(folder.lastPathComponent)” can’t be opened"),
                message: missing
                    ? localized("The folder may have been moved, or it is on a drive or card that is not connected.")
                    : localized("Culla could not read the folder. \(error.localizedDescription)")
            )
            Self.log.error("Opening \(folder.path, privacy: .private) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The session for a scan: a fresh one for a first open, else the saved one merged with the
    /// scan so decisions come back and new files are marked new. Files that cannot be read are
    /// marked. Runs off the main thread.
    nonisolated private static func buildState(
        folder: URL, stored: [StoredPhoto], scanned: [ScannedPhoto], tuning: Tuning
    ) -> (state: SessionState, merge: MergeResult?) {
        var state: SessionState
        var merge: MergeResult?
        if stored.isEmpty {
            state = SessionState(scanned: scanned, tuning: tuning)
        } else {
            state = SessionState(photos: stored.map { $0.photoItem(in: folder) }, tuning: tuning)
            merge = state.merge(scanned: scanned)
        }
        // A file ImageIO can read always has pixel dimensions; check the ones without.
        for item in state.photos where item.metadata.pixelWidth == nil {
            if let reason = unreadableReason(item.file.url) {
                state.markUnreadable(item.id, reason: reason)
            }
        }
        return (state, merge)
    }

    nonisolated private static func unreadableReason(_ url: URL) -> String? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetType(source) != nil, CGImageSourceGetCount(source) > 0
        else {
            return localized("The file is not an image Culla can open.")
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        if properties?[kCGImagePropertyPixelWidth] == nil {
            return localized("The image data is damaged or incomplete.")
        }
        return nil
    }

    // MARK: - Closing

    func closeShoot() {
        loadTask?.cancel()
        guard let session else {
            screen = .welcome
            return
        }
        screen = .welcome
        Task {
            await session.stopAnalysis()
            await session.saver.flush()
            session.close()
            await reloadRecents()
            pruneCache()
        }
    }

    /// Set by `quitAndReopen()`: the app opens again once it has quit.
    @ObservationIgnored private(set) var reopensAfterQuit = false
    /// Automation records the request instead of quitting.
    @ObservationIgnored private(set) var quitAndReopenRequested = false

    /// Settings ▸ General ▸ Language: quits through the normal path (every decision is saved
    /// first) and opens Culla again, which then starts in the chosen language.
    func quitAndReopen() {
        if environment.isAutomation {
            quitAndReopenRequested = true
            return
        }
        reopensAfterQuit = true
        NSApp.terminate(nil)
    }

    /// Waits for every save, before the app quits.
    func prepareToQuit() async {
        loadTask?.cancel()
        if let session {
            // A run under way stops after the current file; what it did stays undoable.
            await session.apply.stopRunForQuit()
            await session.stopAnalysis()
            await session.saver.flush()
        }
    }
}
