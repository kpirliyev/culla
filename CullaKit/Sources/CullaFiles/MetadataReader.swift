import CullaCore
import Foundation
import ImageIO

/// Reads capture data from a file's headers without decoding the image.
public enum MetadataReader {
    public static func read(url: URL) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any]
        else { return metadata }

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5 to 8 are rotated a quarter turn, so width and height swap.
        let isRotated = (5...8).contains(orientation)
        metadata.pixelWidth = isRotated ? height : width
        metadata.pixelHeight = isRotated ? width : height

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let apple = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]

        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            metadata.captureDate = parseDate(
                text,
                subseconds: exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
                offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String
            )
        } else if let text = tiff[kCGImagePropertyTIFFDateTime] as? String {
            metadata.captureDate = parseDate(text, subseconds: nil, offset: nil)
        }

        metadata.cameraMake = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmed
        metadata.cameraModel = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmed
        metadata.lensModel = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmed
        metadata.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue
        metadata.exposureTime = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        metadata.fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        metadata.focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
        // Key 11 of Apple's maker note is the identifier shared by all frames of one burst.
        metadata.burstID = apple["11"] as? String
        return metadata
    }

    /// Parses an EXIF timestamp such as "2026:11:09 14:32:05", with optional sub-seconds and UTC offset.
    /// Without an offset the time is read in the current time zone, which keeps gaps between photos exact.
    public static func parseDate(_ text: String, subseconds: String?, offset: String?) -> Date? {
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" })
        guard parts.count >= 6 else { return nil }
        let numbers = parts.prefix(6).compactMap { Int($0) }
        guard numbers.count == 6, numbers[0] > 0 else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        // The calendar would quietly roll a month 13 or a 31 February over into a later date, which
        // would put a photo with a damaged timestamp in the wrong place among the others.
        guard components.isValidDate(in: calendar), let date = calendar.date(from: components) else { return nil }

        guard let digits = subseconds?.trimmed, !digits.isEmpty, let fraction = Double("0." + digits) else {
            return date
        }
        return date.addingTimeInterval(fraction)
    }

    /// Reads "+02:00" or "-0530" as a fixed time zone.
    static func timeZone(fromOffset text: String) -> TimeZone? {
        let trimmed = text.trimmed
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let digits = trimmed.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.suffix(2)) else {
            return nil
        }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
