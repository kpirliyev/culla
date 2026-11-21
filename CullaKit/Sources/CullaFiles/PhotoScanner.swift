import CullaCore
import Foundation
import UniformTypeIdentifiers

/// Finds the photos in a shoot folder and pairs RAW files with their rendered twins.
public enum PhotoScanner {
    /// Folders Culla creates itself and must never read back in.
    public static let skippedFolderNames: Set<String> = ["_Rejected"]

    public enum FileKind: Sendable, Equatable {
        case raw
        case rendered
    }

    private static let excludedTypes: [UTType] = [.gif, .svg, .ico, .icns, .pdf]

    /// What a file is, judged by its extension. Nil for videos and anything that is not a photo.
    public static func kind(of url: URL) -> FileKind? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
        if type.conforms(to: .rawImage) { return .raw }
        guard type.conforms(to: .image) else { return nil }
        if excludedTypes.contains(where: { type.conforms(to: $0) }) { return nil }
        return .rendered
    }

    private struct Entry {
        var url: URL
        var kind: FileKind
        var size: Int64
        var modified: Date
    }

    /// - Parameter pairRAWWithRendered: a RAW file and a JPEG or HEIC of the same name are one
    ///   photo (Settings ▸ Duplicates: "Treat RAW+JPEG as one photo"). Off, each file is a photo.
    public static func scan(folder: URL, includeSubfolders: Bool = true, pairRAWWithRendered: Bool = true) throws -> [PhotoFile] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !includeSubfolders { options.insert(.skipsSubdirectoryDescendants) }

        // The enumerator happily lists nothing for a folder that is not there, so a disconnected
        // card would look like an empty shoot. Check first, so it fails instead.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: options
        ) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: root.path])
        }

        var groups: [String: [Entry]] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skippedFolderNames.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, let kind = kind(of: url) else { continue }
            let entry = Entry(
                url: url.standardizedFileURL,
                kind: kind,
                size: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate ?? .distantPast
            )
            // Files pair when they sit in the same folder and share a name, ignoring case and extension.
            let key = url.deletingPathExtension().standardizedFileURL.path.lowercased()
            groups[key, default: []].append(entry)
        }

        var photos: [PhotoFile] = []
        for entries in groups.values {
            let raws = entries.filter { $0.kind == .raw }.sorted { $0.url.path < $1.url.path }
            let rendered = entries.filter { $0.kind == .rendered }.sorted { preference($0) < preference($1) }

            if !pairRAWWithRendered {
                for entry in rendered + raws { photos.append(photo(entry, companions: [], root: root)) }
            } else if let lead = rendered.first {
                // The first rendered file carries the RAWs; any further rendered files are photos of their own.
                photos.append(photo(lead, companions: raws.map(\.url), root: root))
                for extra in rendered.dropFirst() {
                    photos.append(photo(extra, companions: [], root: root))
                }
            } else {
                for raw in raws {
                    photos.append(photo(raw, companions: [], root: root))
                }
            }
        }
        return photos.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// JPEG first, then HEIC, then everything else: the file most likely to be the camera's own twin of a RAW.
    private static func preference(_ entry: Entry) -> String {
        let ext = entry.url.pathExtension.lowercased()
        let rank: Int
        switch ext {
        case "jpg", "jpeg": rank = 0
        case "heic", "heif": rank = 1
        default: rank = 2
        }
        return "\(rank)-\(entry.url.lastPathComponent)"
    }

    private static func photo(_ entry: Entry, companions: [URL], root: URL) -> PhotoFile {
        PhotoFile(
            id: relativePath(of: entry.url, in: root),
            url: entry.url,
            companions: companions,
            fileSize: entry.size,
            modificationDate: entry.modified,
            isRAW: entry.kind == .raw
        )
    }

    static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }
}
