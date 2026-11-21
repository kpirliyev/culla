import CullaCore
import Darwin
import Foundation

/// Whether Culla can change a shoot folder.
public enum ShootFolderAccess {
    public enum Writability: String, Sendable, Hashable {
        case writable
        /// The volume is mounted read-only, such as a memory card with its lock switch on.
        case readOnlyVolume
        /// The volume is writable but the folder is not, for its permissions or the sandbox.
        case folderNotWritable
        /// The folder is not there, for example on a card that was removed.
        case missing

        public var isWritable: Bool { self == .writable }
    }

    /// Checks the volume's read-only flag and whether the process may write into the folder.
    /// Reads only; blocks briefly, so call it off the main thread for folders on slow volumes.
    public static func writability(of folder: URL) -> Writability {
        let path = folder.path
        guard FileOps.isDirectory(path) || FileOps.isDirectory(folder.resolvingSymlinksInPath().path) else { return .missing }
        if let values = try? folder.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return .readOnlyVolume
        }
        var info = statfs()
        if statfs(path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0 { return .readOnlyVolume }
        return access(path, W_OK) == 0 ? .writable : .folderNotWritable
    }
}

/// Finding the sidecars that already sit beside a photo's files.
public enum SidecarFinder {
    /// Names in `names` (one folder's listing) that are sidecars of a photo with these file names:
    /// `<basename>.xmp` of the shown file (unless `includeShared` is false) and
    /// `<file name>.xmp` of any of its files (as darktable writes them), ignoring case.
    public static func sidecars(forFiles fileNames: [String], in names: [String], includeBaseSidecar: Bool = true) -> [String] {
        guard let shown = fileNames.first else { return [] }
        var wanted: Set<String> = Set(fileNames.map { ($0 + ".xmp").lowercased() })
        if includeBaseSidecar {
            wanted.insert(((shown as NSString).deletingPathExtension + ".xmp").lowercased())
        }
        let own = Set(fileNames.map { $0.lowercased() })
        return names.filter { wanted.contains($0.lowercased()) && !own.contains($0.lowercased()) }.sorted()
    }
}

extension ShootFileFacts {
    /// Sizes of every file of these photos and the sidecars that already exist beside them, read
    /// from one listing per folder. Blocks; run it on a `BlockingQueue`.
    ///
    /// Linear in the number of files: each folder is listed once and indexed by lower-case name,
    /// so finding a photo's sidecars is a few lookups rather than a pass over the folder (which
    /// took 0.6 s for 2,000 photos in one folder and grew with the square of the count). The
    /// result is what `SidecarFinder.sidecars(forFiles:in:includeBaseSidecar:)` finds.
    ///
    /// - Parameters:
    ///   - photos: the photos to look at, with ids relative to `folder`.
    ///   - sharedSidecarIDs: photos whose `<basename>.xmp` is shared with another photo; only
    ///     their `<file name>.xmp` sidecars are listed.
    public static func gather(for photos: [PhotoFile], folder: URL, sharedSidecarIDs: Set<String> = []) -> ShootFileFacts {
        struct Listing {
            var stamps: [String: FileStamp] = [:]
            /// Names by their lower-case form.
            var byLowercase: [String: [String]] = [:]
        }
        var listings: [String: Listing] = [:]
        func listing(_ directory: String) -> Listing {
            if let cached = listings[directory] { return cached }
            let absolute = directory.isEmpty ? folder.path : folder.appendingPathComponent(directory).path
            var result = Listing()
            for name in (try? FileManager.default.contentsOfDirectory(atPath: absolute)) ?? [] {
                guard let stamp = FileOps.stamp((absolute as NSString).appendingPathComponent(name)) else { continue }
                result.stamps[name] = stamp
                result.byLowercase[name.lowercased(), default: []].append(name)
            }
            listings[directory] = result
            return result
        }
        var facts = ShootFileFacts()
        for photo in photos {
            let directory = (photo.id as NSString).deletingLastPathComponent
            let names = listing(directory)
            let fileNames = [photo.url.lastPathComponent] + photo.companions.map(\.lastPathComponent)
            for name in fileNames {
                if let stamp = names.stamps[name] { facts.sizes[join(directory, name)] = stamp.size }
            }
            // As `SidecarFinder`: `<file name>.xmp` of any of the photo's files and (unless shared)
            // `<basename>.xmp` of the shown file, ignoring case, never one of its own files.
            var wanted = Set(fileNames.map { ($0 + ".xmp").lowercased() })
            if !sharedSidecarIDs.contains(photo.id) {
                wanted.insert(((fileNames[0] as NSString).deletingPathExtension + ".xmp").lowercased())
            }
            let own = Set(fileNames.map { $0.lowercased() })
            let sidecars = wanted.flatMap { names.byLowercase[$0] ?? [] }.filter { !own.contains($0.lowercased()) }.sorted()
            if !sidecars.isEmpty {
                facts.sidecars[photo.id] = sidecars.map { join(directory, $0) }
                for name in sidecars { facts.sizes[join(directory, name)] = names.stamps[name]?.size }
            }
        }
        return facts
    }

    private static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }
}
