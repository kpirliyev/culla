import Foundation

/// One photo on disk. A RAW+JPEG pair is a single photo.
public struct PhotoFile: Codable, Sendable, Hashable, Identifiable {
    /// Path of the shown file relative to the shoot folder. Stable across runs.
    public var id: String
    /// The file that is shown and analysed. For a RAW+JPEG pair this is the JPEG.
    public var url: URL
    /// Other files that belong to the same photo, such as the RAW of a pair.
    public var companions: [URL]
    public var fileSize: Int64
    public var modificationDate: Date
    public var isRAW: Bool

    public init(
        id: String,
        url: URL,
        companions: [URL] = [],
        fileSize: Int64,
        modificationDate: Date,
        isRAW: Bool
    ) {
        self.id = id
        self.url = url
        self.companions = companions
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.isRAW = isRAW
    }

    public var name: String { url.lastPathComponent }
}

/// Capture data read from the file, without decoding the image.
public struct PhotoMetadata: Codable, Sendable, Hashable {
    public var captureDate: Date?
    /// Width and height after applying the stored orientation.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Double?
    public var exposureTime: Double?
    public var fNumber: Double?
    public var focalLength: Double?
    /// The identifier Apple cameras give to all frames of one burst.
    public var burstID: String?

    public init(
        captureDate: Date? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Double? = nil,
        exposureTime: Double? = nil,
        fNumber: Double? = nil,
        focalLength: Double? = nil,
        burstID: String? = nil
    ) {
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.exposureTime = exposureTime
        self.fNumber = fNumber
        self.focalLength = focalLength
        self.burstID = burstID
    }
}

/// Everything known about one photo after analysis.
public struct PhotoRecord: Codable, Sendable, Identifiable {
    public var file: PhotoFile
    public var metadata: PhotoMetadata
    /// Nil when the file could not be decoded or analysed.
    public var scores: PhotoScores?
    public var error: String?

    public init(file: PhotoFile, metadata: PhotoMetadata, scores: PhotoScores?, error: String? = nil) {
        self.file = file
        self.metadata = metadata
        self.scores = scores
        self.error = error
    }

    public var id: String { file.id }

    /// The time used to order photos: capture time, or the file's modification time without one.
    public var sortDate: Date { metadata.captureDate ?? file.modificationDate }
}

/// One photo found by a scan of the shoot folder, with the capture data read from its headers.
/// What a scan hands to a session, and what a session hands back to the next scan so files that
/// have not changed are not read again.
public struct ScannedPhoto: Codable, Sendable, Hashable, Identifiable {
    public var file: PhotoFile
    public var metadata: PhotoMetadata

    public init(file: PhotoFile, metadata: PhotoMetadata) {
        self.file = file
        self.metadata = metadata
    }

    /// The photo's path relative to the shoot folder, as in `PhotoFile.id`.
    public var id: String { file.id }

    /// The time used to order photos: capture time, or the file's modification time without one.
    public var sortDate: Date { metadata.captureDate ?? file.modificationDate }
}
