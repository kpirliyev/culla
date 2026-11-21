import Foundation

/// Writes a minimal linear DNG by hand, since ImageIO cannot write RAW files: IFD 0 holds an
/// uncompressed 8-bit RGB preview of one colour, and a sub-IFD holds 16-bit linear RAW data of
/// another, so a test can tell from a pixel which of the two it was given. ImageIO reads it as
/// `com.adobe.raw-image`, hands out the preview as the embedded thumbnail, and renders the RAW
/// data when asked to decode the image.
enum TestDNG {
    struct RGB8 {
        var r: UInt8, g: UInt8, b: UInt8
    }

    struct RGB16 {
        var r: UInt16, g: UInt16, b: UInt16
    }

    static func data(
        rawWidth: Int,
        rawHeight: Int,
        rawColour: RGB16,
        previewWidth: Int,
        previewHeight: Int,
        previewColour: RGB8
    ) -> Data {
        var preview = Data(capacity: previewWidth * previewHeight * 3)
        for _ in 0..<(previewWidth * previewHeight) {
            preview.append(contentsOf: [previewColour.r, previewColour.g, previewColour.b])
        }
        var raw = Data(capacity: rawWidth * rawHeight * 6)
        for _ in 0..<(rawWidth * rawHeight) {
            raw.append(shorts([rawColour.r, rawColour.g, rawColour.b]))
        }

        let previewIFD: (UInt32, UInt32) -> [Entry] = { previewOffset, subIFDOffset in
            [
                Entry(254, .long, longs([1])), // NewSubfileType: reduced-resolution preview
                Entry(256, .long, longs([UInt32(previewWidth)])),
                Entry(257, .long, longs([UInt32(previewHeight)])),
                Entry(258, .short, shorts([8, 8, 8])),
                Entry(259, .short, shorts([1])), // no compression
                Entry(262, .short, shorts([2])), // RGB
                Entry(271, .ascii, Data("Culla\0".utf8)),
                Entry(272, .ascii, Data("Test\0".utf8)),
                Entry(273, .long, longs([previewOffset])),
                Entry(274, .short, shorts([1])),
                Entry(277, .short, shorts([3])),
                Entry(278, .long, longs([UInt32(previewHeight)])),
                Entry(279, .long, longs([UInt32(preview.count)])),
                Entry(284, .short, shorts([1])),
                Entry(330, .long, longs([subIFDOffset])), // SubIFDs
                Entry(50706, .byte, Data([1, 4, 0, 0])), // DNGVersion
                Entry(50707, .byte, Data([1, 1, 0, 0])), // DNGBackwardVersion
                Entry(50708, .ascii, Data("Culla Test\0".utf8)), // UniqueCameraModel
                Entry(50721, .srational, rationals([(1, 1), (0, 1), (0, 1), (0, 1), (1, 1), (0, 1), (0, 1), (0, 1), (1, 1)])),
                Entry(50728, .rational, rationals([(1, 1), (1, 1), (1, 1)])), // AsShotNeutral
                Entry(50778, .short, shorts([21])), // CalibrationIlluminant1: D65
            ]
        }
        let rawIFD: (UInt32) -> [Entry] = { rawOffset in
            [
                Entry(254, .long, longs([0])),
                Entry(256, .long, longs([UInt32(rawWidth)])),
                Entry(257, .long, longs([UInt32(rawHeight)])),
                Entry(258, .short, shorts([16, 16, 16])),
                Entry(259, .short, shorts([1])),
                Entry(262, .short, shorts([34892])), // LinearRaw
                Entry(273, .long, longs([rawOffset])),
                Entry(277, .short, shorts([3])),
                Entry(278, .long, longs([UInt32(rawHeight)])),
                Entry(279, .long, longs([UInt32(raw.count)])),
                Entry(284, .short, shorts([1])),
                Entry(50717, .long, longs([65535])), // WhiteLevel
            ]
        }

        // Header, IFD 0, the RAW IFD, out-of-line values, then the preview and the RAW data.
        let firstIFD = 8
        let secondIFD = firstIFD + ifdSize(previewIFD(0, 0).count)
        let valuesStart = secondIFD + ifdSize(rawIFD(0).count)
        let valuesSize = outOfLineSize(previewIFD(0, 0)) + outOfLineSize(rawIFD(0))
        let previewOffset = valuesStart + valuesSize
        let rawOffset = previewOffset + padded(preview.count)

        var values = Data()
        var file = Data([0x49, 0x49]) + shorts([42]) + longs([UInt32(firstIFD)])
        file.append(ifd(previewIFD(UInt32(previewOffset), UInt32(secondIFD)), valuesStart: valuesStart, values: &values))
        file.append(ifd(rawIFD(UInt32(rawOffset)), valuesStart: valuesStart, values: &values))
        file.append(values)
        file.append(preview)
        if preview.count % 2 == 1 { file.append(0) }
        file.append(raw)
        return file
    }

    private enum FieldType: UInt16 {
        case byte = 1, ascii = 2, short = 3, long = 4, rational = 5, srational = 10

        var size: Int {
            switch self {
            case .byte, .ascii: 1
            case .short: 2
            case .long: 4
            case .rational, .srational: 8
            }
        }
    }

    private struct Entry {
        var tag: UInt16
        var type: FieldType
        var payload: Data

        init(_ tag: UInt16, _ type: FieldType, _ payload: Data) {
            self.tag = tag
            self.type = type
            self.payload = payload
        }
    }

    private static func ifdSize(_ count: Int) -> Int { 2 + count * 12 + 4 }

    private static func padded(_ count: Int) -> Int { count + count % 2 }

    private static func outOfLineSize(_ entries: [Entry]) -> Int {
        entries.filter { $0.payload.count > 4 }.reduce(0) { $0 + padded($1.payload.count) }
    }

    /// One IFD with no next IFD. Values longer than four bytes go to `values`, which is written
    /// at `valuesStart` in the file.
    private static func ifd(_ entries: [Entry], valuesStart: Int, values: inout Data) -> Data {
        var data = shorts([UInt16(entries.count)])
        for entry in entries {
            data.append(shorts([entry.tag, entry.type.rawValue]))
            data.append(longs([UInt32(entry.payload.count / entry.type.size)]))
            if entry.payload.count <= 4 {
                data.append(entry.payload + Data(count: 4 - entry.payload.count))
            } else {
                data.append(longs([UInt32(valuesStart + values.count)]))
                values.append(entry.payload)
                if entry.payload.count % 2 == 1 { values.append(0) }
            }
        }
        data.append(longs([0]))
        return data
    }

    private static func shorts(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private static func longs(_ values: [UInt32]) -> Data {
        var data = Data()
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private static func rationals(_ values: [(Int32, Int32)]) -> Data {
        var data = Data()
        for (numerator, denominator) in values {
            withUnsafeBytes(of: numerator.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: denominator.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
