import AppKit
import CullaCommands
import CullaCore
import CullaFiles
import CullaSession
import Foundation

/// Keeps an open shoot in line with its folder on disk.
///
/// - **Rescan** when the window becomes key again (and on Rescan Folder): files added, removed,
///   renamed or moved outside Culla are merged into the session. When nothing changed it costs one
///   listing of the folder off the main thread and a comparison, also off the main thread.
///   Rescans wait while Review and Apply is open or a run is under way, and run once it ends.
/// - **Reachability**: the folder is checked every two seconds and whenever a volume mounts or
///   unmounts. When it cannot be reached (a card pulled, a drive unmounted, the folder deleted or
///   made unreadable) analysis pauses, tiles dim and every decision is kept; when it comes back,
///   analysis resumes and the folder is rescanned. A folder that was moved is followed through
///   its bookmark when the system can tell where it went.
@MainActor
final class ShootDiskMonitor {
    struct RescanReport {
        var trigger: String
        var ms: Double
        /// Of that, the part on the main thread.
        var mainMs: Double
        var changed: Bool
        var result: MergeResult?
        var skipped: String?
        var at: Date
    }

    private weak var owner: SessionModel?
    /// The session this belongs to. Work that finishes after the shoot closed checks
    /// `isAttached` first.
    private var model: SessionModel { owner! }
    var isAttached: Bool { owner != nil }
    private var pollTask: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var rescanning = false
    /// A rescan asked for while one ran, or while applying.
    private var rescanPending: String?
    /// True when this monitor paused analysis because the folder went away.
    private var pausedAnalysis = false
    private var followTried = false
    private(set) var lastRescan: RescanReport?
    private(set) var rescanCount = 0
    /// Set by the automation harness to check reachability more often.
    var pollInterval: Duration = .seconds(2)

    nonisolated private static let queue = DispatchQueue(label: "Culla.disk-monitor", qos: .utility)

    init(model: SessionModel) {
        owner = model
    }

    func start() {
        guard pollTask == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self, self.isAttached { self.checkNow() } }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, self.isAttached, let window, window === self.model.window else { return }
                self.rescan(trigger: "focus")
            }
        })
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.pollInterval ?? .seconds(2)
                try? await Task.sleep(for: interval)
                guard let self, self.isAttached else { return }
                await self.check()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        workspaceObservers = []
    }

    // MARK: - Reachability

    /// Whether the folder can be listed. Blocks briefly; called off the main thread.
    nonisolated static func isReachable(_ path: String) -> Bool {
        guard let directory = opendir(path) else { return false }
        closedir(directory)
        return true
    }

    nonisolated static func reachable(_ folder: URL) async -> Bool {
        let path = folder.path
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: isReachable(path)) }
        }
    }

    func checkNow() {
        Task { await check() }
    }

    /// Looks at the folder once and follows what it finds.
    func check() async {
        guard isAttached else { return }
        let reachable = await Self.reachable(model.folder)
        guard isAttached else { return }
        reachabilityIs(reachable)
    }

    private func reachabilityIs(_ reachable: Bool) {
        if !reachable, !model.folderMissing {
            model.setFolderMissing(true)
            if let analysis = model.analysis, analysis.isRunning {
                analysis.pause()
                pausedAnalysis = true
            }
            if model.apply.isOpen, !model.apply.isRunning { model.apply.close() }
            if !followTried {
                followTried = true
                model.followMovedFolder?()
            }
        } else if reachable, model.folderMissing {
            model.setFolderMissing(false)
            followTried = false
            if pausedAnalysis {
                pausedAnalysis = false
                model.analysis?.resume()
            }
            // Photos whose analysis failed while the folder was away are tried again, though
            // their files did not change (the engine retries failures the app did not believe).
            model.analysis?.update(photos: model.state.photos)
            rescan(trigger: "reconnected")
        }
    }

    // MARK: - Rescan

    /// Looks at the folder again and merges what changed outside Culla. Cheap when nothing did.
    func rescan(trigger: String) {
        guard isAttached else { return }
        if model.apply.isRunning || model.apply.isOpen {
            rescanPending = trigger
            return
        }
        if rescanning {
            rescanPending = trigger
            return
        }
        rescanning = true
        model.activity.begin(.rescan)
        let folder = model.folder
        let options = ScanOptions(includeSubfolders: model.settings.includeSubfolders, pairRAW: model.settings.pairRAWWithRendered)
        let photos = model.state.photos
        let started = CACurrentMediaTime()
        Task { [weak self] in
            let outcome = await Self.look(folder: folder, options: options, photos: photos)
            guard let self, self.isAttached else { return }
            defer {
                self.rescanning = false
                self.model.activity.end(.rescan)
                self.rescanCount += 1
                if let pending = self.rescanPending, !self.model.apply.isOpen, !self.model.apply.isRunning {
                    self.rescanPending = nil
                    self.rescan(trigger: pending)
                }
            }
            switch outcome {
            case .unreachable:
                self.reachabilityIs(false)
                self.lastRescan = RescanReport(trigger: trigger, ms: (CACurrentMediaTime() - started) * 1000, mainMs: 0, changed: false, skipped: "unreachable", at: Date())
            case .unchanged:
                if self.model.folderMissing { self.reachabilityIs(true) }
                self.lastRescan = RescanReport(trigger: trigger, ms: (CACurrentMediaTime() - started) * 1000, mainMs: 0, changed: false, at: Date())
            case .changed(let scanned):
                // The session may have changed meanwhile (an apply started): look again later.
                guard !self.model.apply.isRunning, !self.model.apply.isOpen else {
                    self.rescanPending = trigger
                    return
                }
                if self.model.folderMissing { self.reachabilityIs(true) }
                let mainStarted = CACurrentMediaTime()
                let result = self.model.mergeRescan(scanned)
                let now = CACurrentMediaTime()
                self.lastRescan = RescanReport(trigger: trigger, ms: (now - started) * 1000, mainMs: (now - mainStarted) * 1000, changed: true, result: result, at: Date())
            }
        }
    }

    /// Runs a rescan that was put off while applying.
    func runPendingRescan() {
        guard let pending = rescanPending else { return }
        rescanPending = nil
        rescan(trigger: pending)
    }

    private enum Outcome: Sendable {
        case unreachable
        case unchanged
        case changed([ScannedPhoto])
    }

    /// Lists the folder and compares it with the session's photos, off the main thread; reads
    /// metadata only for files that are new or changed.
    private struct ScanOptions: Sendable {
        var includeSubfolders: Bool
        var pairRAW: Bool
    }

    private nonisolated static func look(folder: URL, options: ScanOptions, photos: [PhotoItem]) async -> Outcome {
        let listing: (files: [PhotoFile], same: Bool)? = await withCheckedContinuation { continuation in
            queue.async {
                guard isReachable(folder.path),
                      let files = try? PhotoScanner.scan(folder: folder, includeSubfolders: options.includeSubfolders, pairRAWWithRendered: options.pairRAW)
                else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: (files, matches(files, photos)))
            }
        }
        guard let listing else { return .unreachable }
        if listing.same { return .unchanged }
        let known = photos.map { ScannedPhoto(file: $0.file, metadata: $0.metadata) }
        guard let scanned = try? await ShootLoader.load(
            folder: folder, includeSubfolders: options.includeSubfolders, pairRAWWithRendered: options.pairRAW, known: known
        ) else {
            return .unreachable
        }
        return .changed(scanned)
    }

    /// The photos a scan with other options would no longer list (a subfolder left out, a RAW
    /// joining its JPEG), without reading any metadata; nil when the folder cannot be listed.
    nonisolated static func photosLeaving(folder: URL, includeSubfolders: Bool, pairRAW: Bool, photos: [PhotoItem]) async -> [String]? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let files = try? PhotoScanner.scan(folder: folder, includeSubfolders: includeSubfolders, pairRAWWithRendered: pairRAW) else {
                    return continuation.resume(returning: nil)
                }
                let listed = Set(files.map(\.id))
                continuation.resume(returning: photos.map(\.id).filter { !listed.contains($0) })
            }
        }
    }

    /// True when the listing holds exactly the session's files, each with its size and date.
    private nonisolated static func matches(_ files: [PhotoFile], _ photos: [PhotoItem]) -> Bool {
        guard files.count == photos.count else { return false }
        var known: [String: PhotoFile] = [:]
        known.reserveCapacity(photos.count)
        for item in photos { known[item.id] = item.file }
        for file in files {
            guard let old = known[file.id], old.fileSize == file.fileSize, old.modificationDate == file.modificationDate,
                  old.companions.map(\.lastPathComponent) == file.companions.map(\.lastPathComponent)
            else { return false }
        }
        return true
    }

    #if DEBUG
    var dumpState: [String: Any] {
        var state: [String: Any] = ["count": rescanCount, "running": rescanning, "pending": rescanPending ?? NSNull(), "pausedAnalysis": pausedAnalysis]
        if let report = lastRescan {
            var last: [String: Any] = [
                "trigger": report.trigger, "ms": (report.ms * 10).rounded() / 10, "mainMs": (report.mainMs * 10).rounded() / 10,
                "changed": report.changed, "skipped": report.skipped ?? NSNull(),
            ]
            if let result = report.result {
                last["added"] = result.added
                last["removed"] = result.removed
                last["modified"] = result.modified
                last["renamed"] = result.renamed.map { ["from": $0.from, "to": $0.to] }
            }
            state["last"] = last
        }
        return state
    }
    #endif
}
