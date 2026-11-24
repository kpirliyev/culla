import Foundation

/// The file `https://cullaapp.com/update.json`, as the site publishes it:
///
/// ```json
/// { "version": "1.1", "minimumSystem": "26.0", "date": "2026-12-01" }
/// ```
///
/// `date` is empty while no release is published. Unknown keys are ignored, so the site can add
/// some without breaking older copies of Culla. A missing key reads as empty.
public struct UpdateDocument: Sendable, Equatable, Decodable {
    /// The newest version: "1.1".
    public var version: String
    /// The oldest macOS it runs on: "26.0". Empty: no requirement is stated.
    public var minimumSystem: String
    /// When it was published, "2026-12-01"; empty while nothing is published.
    public var date: String

    public init(version: String, minimumSystem: String, date: String) {
        self.version = version
        self.minimumSystem = minimumSystem
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case version, minimumSystem, date
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        minimumSystem = try container.decodeIfPresent(String.self, forKey: .minimumSystem) ?? ""
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
    }

    /// Reads the file's bytes; throws `UpdateCheckError.invalidDocument` for anything that is not a
    /// JSON object of strings.
    public static func decode(_ data: Data) throws(UpdateCheckError) -> UpdateDocument {
        do {
            return try JSONDecoder().decode(UpdateDocument.self, from: data)
        } catch {
            throw .invalidDocument
        }
    }

    /// True once a release is published: a version and a date.
    public var isPublished: Bool {
        !version.trimmingCharacters(in: .whitespaces).isEmpty && !date.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
