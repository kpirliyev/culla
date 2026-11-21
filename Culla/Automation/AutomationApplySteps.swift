#if DEBUG
import AppKit
import CryptoKit
import CullaCommands
import CullaCore
import CullaFiles
import Foundation

/// A listing of a folder on disk, read off the main thread.
struct FolderListing: Sendable {
    struct File: Sendable {
        var path: String
        var size: Int64
        var stamp: String
    }

    var files: [File] = []
    var dirs: [String] = []
    var hash = ""
    var stampsHash = ""

    var dictionary: [String: Any] {
        [
            "files": files.map { ["path": $0.path, "size": $0.size] as [String: Any] },
            "stamps": files.map { "\($0.path) \($0.stamp)" },
            "dirs": dirs, "fileCount": files.count, "hash": hash, "stampsHash": stampsHash,
        ]
    }

    /// Every file under the folder (relative path and size, `.DS_Store` left out), its folders, a
    /// hash over all paths, sizes and contents, and one over paths and modification times.
    static func read(_ folder: URL) async -> FolderListing {
        await Task.detached(priority: .userInitiated) { () -> FolderListing in
            var listing = FolderListing()
            let root = folder.resolvingSymlinksInPath().path
            if let enumerator = FileManager.default.enumerator(atPath: root) {
                while let relative = enumerator.nextObject() as? String {
                    let full = (root as NSString).appendingPathComponent(relative)
                    if (relative as NSString).lastPathComponent == ".DS_Store" { continue }
                    if FileOps.isDirectory(full) {
                        listing.dirs.append(relative)
                    } else if let stamp = FileOps.stamp(full) {
                        listing.files.append(File(path: relative, size: stamp.size, stamp: "\(stamp.seconds).\(stamp.nanoseconds)"))
                    }
                }
            }
            listing.files.sort { $0.path < $1.path }
            listing.dirs.sort()
            var content = SHA256()
            var stamps = SHA256()
            for file in listing.files {
                content.update(data: Data("\(file.path)\u{0}\(file.size)\u{0}".utf8))
                if let data = try? Data(contentsOf: URL(fileURLWithPath: (root as NSString).appendingPathComponent(file.path)), options: .mappedIfSafe) {
                    content.update(data: data)
                }
                stamps.update(data: Data("\(file.path)\u{0}\(file.stamp)\u{0}".utf8))
            }
            func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
            listing.hash = hex(content.finalize())
            listing.stampsHash = hex(stamps.finalize())
            return listing
        }.value
    }
}

/// The harness's steps for Review and Apply, Undo Apply, faults, and changes to the shoot folder
/// made while the app is open. See Scripts/README.md.
extension AutomationRunner {
    /// Runs one of these steps. Returns nil when the action is not one of them.
    func performApplyStep(_ action: String, _ step: [String: Any]) async throws -> String? {
        switch action {
        case "applyScreen":
            guard let session = app.session else { throw Failure("No shoot is open") }
            switch step["applyScreen"] as? String {
            case "open":
                guard !session.apply.isOpen else { return "already open" }
                guard app.perform(.reviewAndApply) else { throw Failure("Review and Apply is not available now") }
                try await waitFor(timeout: step["timeout"] as? Double ?? 60, "the plan") { !session.apply.isPreparing }
                _ = try await waitUntilIdle(timeout: 60)
                return "open, \(session.apply.readyMs.map { String(format: "plan in %.0f ms", $0) } ?? "")"
            case "close":
                guard session.apply.isOpen else { return "already closed" }
                guard app.perform(.reviewAndApply) else { throw Failure("Review and Apply cannot be left now") }
                return "closed"
            default:
                throw Failure("\"applyScreen\" is \"open\" or \"close\"")
            }

        case "applyAction":
            guard let apply = app.session?.apply, apply.isOpen else { throw Failure("Review and Apply is not open") }
            if let name = step["applyAction"] as? String {
                guard let action = RejectAction(rawValue: name) else { throw Failure("applyAction is moveToRejectedFolder, markOnly or moveToTrash") }
                apply.setRejectAction(action)
            }
            if let sidecars = step["sidecars"] as? Bool { apply.setWriteSidecars(sidecars) }
            if step["makeDefault"] as? Bool == true { apply.makeDefault() }
            try await Task.sleep(for: .milliseconds(30))
            return apply.primaryTitle

        case "applyFocus":
            guard let apply = app.session?.apply, apply.isOpen else { throw Failure("Review and Apply is not open") }
            guard let id = step["applyFocus"] as? String else { throw Failure("\"applyFocus\" needs a photo id") }
            guard apply.rejectOrder.contains(id) else { throw Failure("\(id) is not among the rejects: \(apply.rejectOrder.ids)") }
            let modifiers = (step["modifiers"] as? String ?? "").lowercased()
            apply.click(id, kind: modifiers.contains("shift") ? .extend : modifiers.contains("cmd") ? .toggle : .plain)
            try await Task.sleep(for: .milliseconds(30))
            return id

        case "fault":
            guard let session = app.session else { throw Failure("No shoot is open") }
            guard let spec = step["fault"] as? [String: Any] else { throw Failure("\"fault\" needs an object") }
            var fault = ApplyCoordinator.Fault()
            fault.failAt = spec["failAt"] as? Int
            fault.crashAt = spec["crashAt"] as? Int
            fault.cancelAt = spec["cancelAt"] as? Int
            fault.holdAt = spec["holdAt"] as? Int
            fault.delayMs = spec["delayMs"] as? Int ?? 0
            if let crash = fault.crashAt {
                // The app ends abruptly in the middle of the run, as if it crashed: the result is
                // written first, so the run counts as passed.
                var results = stepResults
                results.append(["index": results.count, "action": "fault", "ok": true, "detail": "crash at step \(crash)"])
                let result: [String: Any] = [
                    "ok": true, "script": scriptURL.path, "output": outputFolder.path, "steps": results,
                    "crashedOnPurpose": true, "crashAtStep": crash,
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                let url = outputFolder.appendingPathComponent("result.json")
                fault.beforeCrash = {
                    try? data.write(to: url)
                    FileHandle.standardError.write(Data("[automation] Crashing on purpose at step \(crash)\n".utf8))
                }
            }
            session.apply.fault = fault
            return spec.keys.sorted().map { "\($0) \(spec[$0] ?? "")" }.joined(separator: ", ")

        case "releaseHold":
            guard let apply = app.session?.apply else { throw Failure("No shoot is open") }
            guard apply.isHeld.isSet else { throw Failure("No run is held") }
            apply.hold.signal()
            try await Task.sleep(for: .milliseconds(30))
            return "released"

        case "undoApply":
            guard let session = app.session else { throw Failure("No shoot is open") }
            guard session.apply.canUndoApply else { throw Failure("Nothing to undo: \(session.apply.undoable.map { "\($0.state)" } ?? "no undoable run")") }
            session.apply.undoLatest()
            if step["wait"] as? Bool != false { _ = try await waitForDisk("undone", timeout: step["timeout"] as? Double ?? 120) }
            return session.apply.lastUndo?["headline"] as? String

        case "bannerAction":
            guard let apply = app.session?.apply else { throw Failure("No shoot is open") }
            guard let name = step["bannerAction"] as? String else { throw Failure("\"bannerAction\" needs a name") }
            switch (name, apply.banner) {
            case ("undo", .result), ("retryUndo", .undo), ("recoveryUndo", .recovery):
                if case .recovery = apply.banner { apply.undoRecovered() } else { apply.undoLatest() }
                _ = try await waitForDisk("undone", timeout: step["timeout"] as? Double ?? 120)
            case ("reveal", .result(let info)): apply.revealKeepers(info)
            case ("openKeepers", .result(let info)): apply.openKeepers(info)
            case ("done", _), ("keepAsIs", .recovery): apply.dismissBanner()
            default: throw Failure("No banner action \(name) on \(String(describing: apply.banner))")
            }
            try await Task.sleep(for: .milliseconds(30))
            return name

        case "copyKeepersTo":
            guard let apply = app.session?.apply, apply.isOpen else { throw Failure("Review and Apply is not open") }
            guard let path = step["copyKeepersTo"] as? String else { throw Failure("\"copyKeepersTo\" needs a folder") }
            let url = resolve(path, directory: true)
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            apply.setCopyDestination(url)
            try await waitFor(timeout: 10, "the copy plan") { apply.copyPlan != nil }
            return apply.primaryTitle

        case "fixture":
            guard let changes = step["fixture"] as? [String: Any] else { throw Failure("\"fixture\" needs an object") }
            return try changeFixture(changes)

        case "rescan":
            guard let session = app.session else { throw Failure("No shoot is open") }
            let before = session.disk.rescanCount
            if step["rescan"] as? String == "focus" {
                // As when the window becomes key again; automation never activates the app.
                NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: windowController?.window)
            } else {
                guard app.perform(.rescanFolder) else { throw Failure("Rescan Folder is not available now") }
            }
            if step["wait"] as? Bool != false {
                try await waitFor(timeout: step["timeout"] as? Double ?? 30, "the rescan") { session.disk.rescanCount > before }
                _ = try await waitUntilIdle(timeout: 60)
            }
            let report = session.disk.lastRescan
            return report.map { String(format: "%@ %@ in %.1f ms (main %.1f ms)", $0.trigger, $0.changed ? "changed" : "unchanged", $0.ms, $0.mainMs) }

        case "saveHash":
            guard let name = step["saveHash"] as? String, let session = app.session else { throw Failure("\"saveHash\" needs a name and an open shoot") }
            let listing = await Self.listing(of: session.folder)
            let url = Self.hashFolder.appendingPathComponent("\(name).json")
            try FileManager.default.createDirectory(at: Self.hashFolder, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: listing, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            return "\(name): \(listing["hash"] ?? "") over \(listing["fileCount"] ?? 0) files"

        case "expectHash":
            guard let name = step["expectHash"] as? String, let session = app.session else { throw Failure("\"expectHash\" needs a name and an open shoot") }
            let url = Self.hashFolder.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: url), let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure("No saved hash \(name)")
            }
            let now = await Self.listing(of: session.folder)
            if step["stamps"] as? Bool != false, let a = saved["stampsHash"] as? String, let b = now["stampsHash"] as? String, a != b {
                throw Failure("Modification dates differ from \(name): \(Self.difference(saved, now, key: "stamps"))")
            }
            guard (saved["hash"] as? String) == (now["hash"] as? String) else {
                throw Failure("The folder differs from \(name): \(Self.difference(saved, now, key: "files"))")
            }
            if let dirs = saved["dirs"] as? [String], let nowDirs = now["dirs"] as? [String], dirs != nowDirs {
                throw Failure("Folders differ from \(name): \(dirs) then, \(nowDirs) now")
            }
            return "\(name): equal (\(now["fileCount"] ?? 0) files)"

        case "fileContains":
            // {"fileContains": "a.xmp", "text": ["Jane", "xmp:Rating>3<"], "absent": ["Red"]}
            guard let session = app.session, let relative = step["fileContains"] as? String else { throw Failure("\"fileContains\" needs a path in the shoot") }
            let url = session.folder.appendingPathComponent(relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure("Cannot read \(relative)") }
            for needle in step["text"] as? [String] ?? [] where !text.contains(needle) {
                throw Failure("\(relative) does not contain \(needle): \(text.prefix(600))")
            }
            for needle in step["absent"] as? [String] ?? [] where text.contains(needle) {
                throw Failure("\(relative) contains \(needle)")
            }
            return relative

        case "fileAction":
            return app.session?.apply.lastFileAction ?? app.session?.lastFileAction

        default:
            return nil
        }
    }

    // MARK: - Waiting

    func waitForDisk(_ what: String, timeout: Double) async throws -> String {
        guard let session = app.session else { throw Failure("No shoot is open") }
        let apply = session.apply!
        let started = Date()
        switch what {
        case "apply":
            try await waitFor(timeout: timeout, "the plan") { apply.isOpen && !apply.isPreparing }
        case "applied", "undone":
            try await waitFor(timeout: timeout, "the run to end") { !apply.isRunning }
        case "held":
            try await waitFor(timeout: timeout, "the run to be held") { apply.isHeld.isSet }
        case "disconnected":
            try await waitFor(timeout: timeout, "the shoot to be found disconnected") { session.folderMissing }
        case "reconnected":
            try await waitFor(timeout: timeout, "the shoot to be back") { !session.folderMissing }
        case "rescan":
            try await waitFor(timeout: timeout, "the rescan") { session.disk.lastRescan != nil && session.disk.dumpState["running"] as? Bool == false }
        case "undoable":
            try await waitFor(timeout: timeout, "an undoable run") { apply.undoable != nil }
        case "recovery":
            try await waitFor(timeout: timeout, "the recovery offer") {
                if case .recovery = apply.banner { return true }
                return false
            }
        default:
            throw Failure("Unknown wait \(what)")
        }
        if what != "held" { _ = try await waitUntilIdle(timeout: timeout) }
        return String(format: "%@ after %.0f ms", what, Date().timeIntervalSince(started) * 1000)
    }

    // MARK: - Changing the fixture

    /// Changes the shoot folder while the app is open, as a person would in the Finder:
    /// `{"rename": ["a.jpg", "b.jpg"]}`, `{"add": ["from.jpg", "new.jpg"]}` (copied, then made newer),
    /// `{"delete": "a.jpg"}`, `{"modify": "_Rejected/a.jpg"}` (appends a byte), `{"write": ["a.xmp", "text"]}`,
    /// `{"readOnly": true}` (the folder's permissions), `{"disconnect": true}` (the folder made
    /// unreadable, as a card that was pulled) and `{"disconnect": false}`, `{"move": "NewName"}`.
    /// Only the shoot copy inside the app's container is ever touched.
    private func changeFixture(_ changes: [String: Any]) throws -> String {
        guard let session = app.session else { throw Failure("No shoot is open") }
        let folder = session.folder
        let fileManager = FileManager.default
        // The harness's shoots live in the container's temporary folder; nothing else is touched.
        let container = fileManager.temporaryDirectory.resolvingSymlinksInPath().path
        guard folder.resolvingSymlinksInPath().path.hasPrefix(container + "/") || folder.path.hasPrefix(fileManager.temporaryDirectory.path) else {
            throw Failure("Fixture changes are only made in the container's shoots, not \(folder.path)")
        }
        func path(_ relative: String) -> String { folder.appendingPathComponent(relative).path }
        var done: [String] = []
        if let pair = changes["rename"] as? [String], pair.count == 2 {
            try fileManager.createDirectory(atPath: (path(pair[1]) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fileManager.moveItem(atPath: path(pair[0]), toPath: path(pair[1]))
            done.append("renamed \(pair[0]) to \(pair[1])")
        }
        if let pair = changes["add"] as? [String], pair.count == 2 {
            try fileManager.copyItem(atPath: path(pair[0]), toPath: path(pair[1]))
            try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: path(pair[1]))
            done.append("added \(pair[1])")
        }
        if let name = changes["delete"] as? String {
            try fileManager.removeItem(atPath: path(name))
            done.append("deleted \(name)")
        }
        if let name = changes["modify"] as? String {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path(name)))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            done.append("modified \(name)")
        }
        if let pair = changes["write"] as? [String], pair.count == 2 {
            try Data(pair[1].utf8).write(to: URL(fileURLWithPath: path(pair[0])))
            done.append("wrote \(pair[0])")
        }
        if let readOnly = changes["readOnly"] as? Bool {
            try fileManager.setAttributes([.posixPermissions: readOnly ? 0o555 : 0o755], ofItemAtPath: folder.path)
            done.append(readOnly ? "made read-only" : "made writable")
        }
        if let disconnect = changes["disconnect"] as? Bool {
            try fileManager.setAttributes([.posixPermissions: disconnect ? 0o000 : 0o755], ofItemAtPath: folder.path)
            if disconnect { session.disk.pollInterval = .milliseconds(250) }
            done.append(disconnect ? "disconnected" : "reconnected")
        }
        if let name = changes["move"] as? String {
            let target = folder.deletingLastPathComponent().appendingPathComponent(name)
            try? fileManager.removeItem(at: target)
            try fileManager.moveItem(at: folder, to: target)
            session.disk.pollInterval = .milliseconds(250)
            done.append("moved to \(name)")
        }
        guard !done.isEmpty else { throw Failure("Unknown fixture change \(changes.keys.sorted())") }
        return done.joined(separator: ", ")
    }

    // MARK: - The folder on disk

    static var hashFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("CullaAutomation/hashes", isDirectory: true)
    }

    /// Every file under the folder (relative path and size, `.DS_Store` left out), its folders, a
    /// hash over all paths, sizes and contents, and one over paths and modification times.
    static func listing(of folder: URL) async -> [String: Any] {
        await FolderListing.read(folder).dictionary
    }

    /// The first few differences between two listings, for a failure message.
    private static func difference(_ a: [String: Any], _ b: [String: Any], key: String) -> String {
        func entries(_ listing: [String: Any]) -> Set<String> {
            if key == "stamps" { return Set(listing["stamps"] as? [String] ?? []) }
            return Set((listing["files"] as? [[String: Any]] ?? []).map { "\($0["path"] ?? "") \($0["size"] ?? "")" })
        }
        let before = entries(a), after = entries(b)
        let gone = before.subtracting(after).sorted().prefix(5)
        let new = after.subtracting(before).sorted().prefix(5)
        if gone.isEmpty, new.isEmpty { return "same paths and sizes, different contents" }
        return "then \(Array(gone)), now \(Array(new))"
    }
}
#endif
