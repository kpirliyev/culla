import CryptoKit
import CullaFiles
import Foundation
import Testing

@Suite("MetadataReader.parseDate")
struct ParseDateTests {
    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        ))
    }

    @Test func plainTimestampIsReadInTheCurrentTimeZone() throws {
        let parsed = try #require(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: nil))
        #expect(parsed == localDate(2026, 11, 9, 14, 32, 5))
    }

    @Test func subsecondsAreAdded() throws {
        let whole = try #require(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: nil))
        let parsed = try #require(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: "25", offset: nil))
        #expect(abs(parsed.timeIntervalSince(whole) - 0.25) < 1e-6)
        let three = try #require(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: " 007 ", offset: nil))
        #expect(abs(three.timeIntervalSince(whole) - 0.007) < 1e-6)
    }

    @Test func unreadableSubsecondsAreIgnored() throws {
        let whole = MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: nil)
        #expect(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: "", offset: nil) == whole)
        #expect(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: "ab", offset: nil) == whole)
    }

    @Test func positiveOffsetGivesTheExactInstant() {
        // 14:32:05 at UTC+2 is 12:32:05 UTC.
        let parsed = MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: "+02:00")
        #expect(parsed == Date(timeIntervalSince1970: 1_794_227_525))
    }

    @Test func negativeOffsetWithoutColonGivesTheExactInstant() {
        // 14:32:05 at UTC-5:30 is 20:02:05 UTC.
        let parsed = MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: "5", offset: "-0530")
        #expect(parsed == Date(timeIntervalSince1970: 1_794_254_525.5))
    }

    @Test func isoStyleSeparatorsAreAccepted() {
        let parsed = MetadataReader.parseDate("2024-02-29T23:59:59", subseconds: nil, offset: "+00:00")
        #expect(parsed == Date(timeIntervalSince1970: 1_709_251_199))
    }

    @Test(arguments: [
        "",
        "not a date",
        "2026:11:09",
        "2026:11:09 14:32",
        "2026:11:09 14:32:xx",
        "0000:00:00 00:00:00",
        "    :  :     :  :  ",
        "2026:13:09 14:32:05",
        "2026:00:09 14:32:05",
        "2026:02:30 14:32:05",
        "2026:11:09 25:32:05",
        "2026:11:09 14:61:05",
        "2026:11:09 14:32:75",
    ])
    func malformedTimestampsGiveNil(text: String) {
        #expect(MetadataReader.parseDate(text, subseconds: nil, offset: nil) == nil)
    }

    @Test func unreadableOffsetFallsBackToLocalTime() {
        let local = MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: nil)
        #expect(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: "Z") == local)
        #expect(MetadataReader.parseDate("2026:11:09 14:32:05", subseconds: nil, offset: "+2") == local)
    }

    @Test func fileWithoutImageDataGivesEmptyMetadata() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("fake.jpg", contents: Data("not an image".utf8))
        let metadata = MetadataReader.read(url: url)
        #expect(metadata.captureDate == nil)
        #expect(metadata.pixelWidth == nil)
    }
}

@Suite("FileHasher")
struct FileHasherTests {
    @Test func sha256OfKnownBytes() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("abc.bin", contents: Data("abc".utf8))
        #expect(try FileHasher.sha256(of: url) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256OfAnEmptyFile() throws {
        let folder = try TemporaryFolder()
        let url = try folder.file("empty.bin")
        #expect(try FileHasher.sha256(of: url) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func sha256OfAFileLargerThanOneChunk() throws {
        // A little over three 1 MiB chunks, so the chunked reading is exercised across boundaries.
        let bytes = Data((0..<(3 << 20) + 12_345).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let folder = try TemporaryFolder()
        let url = try folder.file("large.bin", contents: bytes)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try FileHasher.sha256(of: url) == expected)
    }

    @Test func sha256OfAMissingFileThrows() {
        #expect(throws: (any Error).self) {
            try FileHasher.sha256(of: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        }
    }

    @Test func shortKeyIsStableSixteenHexCharacters() {
        let key = FileHasher.shortKey(for: "sub/IMG_0001.JPG")
        #expect(key.count == 16)
        #expect(key.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(FileHasher.shortKey(for: "sub/IMG_0001.JPG") == key)
        #expect(FileHasher.shortKey(for: "sub/IMG_0002.JPG") != key)
        #expect(FileHasher.shortKey(for: "").count == 16)
    }
}
