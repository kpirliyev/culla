import CullaCore
import CullaSession
import Foundation

/// One shoot the user has opened, identified by its folder.
public struct StoredSession: Sendable, Hashable, Identifiable {
    public var id: Int64
    /// The folder's path when the session was last opened, resolved and standardised.
    public var folderPath: String
    /// Bookmark data for the folder, as `FolderBookmark` makes it. Nil if none was saved.
    public var bookmark: Data?
    public var createdAt: Date
    public var lastOpenedAt: Date
    /// Where the user was when they last left the shoot.
    public var place: SessionPlace
    /// The shoot's own detection settings (JSON of `Tuning`), or nil when it follows the default.
    public var tuning: Data? = nil

    public var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    /// The folder's name, for the recent sessions list.
    public var name: String { folderURL.lastPathComponent }
}

/// A session's photo counts, for the recent sessions list.
public struct SessionPhotoCounts: Sendable, Hashable {
    public var photos: Int
    public var kept: Int
    public var rejected: Int

    public init(photos: Int, kept: Int, rejected: Int) {
        self.photos = photos
        self.kept = kept
        self.rejected = rejected
    }
}

/// Where the user was in a shoot. Plain strings, so the store does not depend on view types:
/// `group` is a `GroupID.rawValue`, `focusedPhotoID` a photo id, and `viewMode` whatever the
/// interface uses to name its views.
public struct SessionPlace: Codable, Sendable, Hashable {
    public var group: String?
    public var focusedPhotoID: String?
    public var viewMode: String?

    public init(group: String? = nil, focusedPhotoID: String? = nil, viewMode: String? = nil) {
        self.group = group
        self.focusedPhotoID = focusedPhotoID
        self.viewMode = viewMode
    }
}

/// A photo of a session as it is saved: enough to rebuild the session without reading the files.
public struct StoredPhoto: Sendable, Hashable, Identifiable {
    /// Path relative to the shoot folder (`PhotoFile.id`).
    public var id: String
    public var fileSize: Int64
    public var modificationDate: Date
    public var isRAW: Bool
    /// File names of the photo's companions, such as the RAW of a RAW+JPEG pair. They always sit
    /// in the same folder as the photo, so names are enough.
    public var companionNames: [String]
    public var decision: Decision
    public var rating: Int
    public var metadata: PhotoMetadata

    public init(
        id: String,
        fileSize: Int64,
        modificationDate: Date,
        isRAW: Bool,
        companionNames: [String] = [],
        decision: Decision = .unreviewed,
        rating: Int = 0,
        metadata: PhotoMetadata = PhotoMetadata()
    ) {
        self.id = id
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isRAW = isRAW
        self.companionNames = companionNames
        self.decision = decision
        self.rating = min(max(rating, 0), 5)
        self.metadata = metadata
    }

    /// The saved form of a session's photo.
    public init(_ item: PhotoItem) {
        self.init(
            id: item.id,
            fileSize: item.file.fileSize,
            modificationDate: item.file.modificationDate,
            isRAW: item.file.isRAW,
            companionNames: item.file.companions.map(\.lastPathComponent),
            decision: item.decision,
            rating: item.rating,
            metadata: item.metadata
        )
    }

    /// The file, with its URL rebuilt inside `folder`.
    public func file(in folder: URL) -> PhotoFile {
        let url = folder.appendingPathComponent(id, isDirectory: false)
        let directory = url.deletingLastPathComponent()
        return PhotoFile(
            id: id,
            url: url,
            companions: companionNames.map { directory.appendingPathComponent($0, isDirectory: false) },
            fileSize: fileSize,
            modificationDate: modificationDate,
            isRAW: isRAW
        )
    }

    /// The photo as a session item, with its decision and rating, not new and without scores.
    public func photoItem(in folder: URL) -> PhotoItem {
        PhotoItem(file: file(in: folder), metadata: metadata, decision: decision, rating: rating)
    }

    /// The photo as a scan would find it, for handing to `ShootLoader` as already-known metadata.
    public func scannedPhoto(in folder: URL) -> ScannedPhoto {
        ScannedPhoto(file: file(in: folder), metadata: metadata)
    }
}

/// What a cached score is filed under: the absolute file path, its size and modification date.
/// The scores version is checked too: entries from another version never match.
public struct ScoreKey: Sendable, Hashable {
    public var path: String
    public var fileSize: Int64
    public var modificationDate: Date

    public init(path: String, fileSize: Int64, modificationDate: Date) {
        self.path = path
        self.fileSize = fileSize
        self.modificationDate = modificationDate
    }

    /// The key for the file that is shown and analysed.
    public init(file: PhotoFile) {
        self.init(path: file.url.path, fileSize: file.fileSize, modificationDate: file.modificationDate)
    }
}
