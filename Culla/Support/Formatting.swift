import CullaAnalysis
import CullaCore
import CullaSession
import Foundation
import UniformTypeIdentifiers

/// Text for numbers and metadata, the way the interface shows them.
enum Formatting {
    /// A number as the language writes it: "1,240", "1 240".
    static func count(_ value: Int) -> String {
        Localization.number(value)
    }

    /// "1 photo", "35 photos".
    static func photos(_ value: Int) -> String {
        localized("\(value) photos")
    }

    static func shutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 {
            let value = seconds.rounded() == seconds
                ? Localization.number(Int(seconds)) : Localization.decimal(seconds, fractionDigits: 1)
            return localized("unit.seconds", default: "\(value) s")
        }
        let denominator = String(Int((1 / seconds).rounded()))
        return localized("unit.fractionOfSecond", default: "1/\(denominator) s")
    }

    static func aperture(_ fNumber: Double) -> String {
        "ƒ/" + (fNumber.rounded() == fNumber ? String(Int(fNumber)) : Localization.decimal(fNumber, fractionDigits: 1))
    }

    static func focalLength(_ millimetres: Double) -> String {
        let value = millimetres.rounded() == millimetres
            ? String(Int(millimetres)) : Localization.decimal(millimetres, fractionDigits: 1)
        return localized("unit.millimetres", default: "\(value) mm")
    }

    static func iso(_ value: Double) -> String {
        "ISO \(Int(value.rounded()))"
    }

    static func bytes(_ value: Int64) -> String {
        Localization.bytes(value)
    }

    static func dimensions(_ metadata: PhotoMetadata) -> String? {
        guard let width = metadata.pixelWidth, let height = metadata.pixelHeight else { return nil }
        return "\(width) × \(height)"
    }

    static func megapixels(_ metadata: PhotoMetadata) -> String? {
        guard let width = metadata.pixelWidth, let height = metadata.pixelHeight else { return nil }
        let value = Localization.decimal(Double(width * height) / 1_000_000, fractionDigits: 1)
        return localized("unit.megapixels", default: "\(value) MP")
    }

    static func captureDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second().locale(Localization.locale))
    }

    static func camera(_ metadata: PhotoMetadata) -> String? {
        let make = metadata.cameraMake ?? ""
        let model = metadata.cameraModel ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        // Many cameras repeat the make in the model name ("Canon Canon EOS R5").
        let makeWord = make.split(separator: " ").first.map { $0.lowercased() } ?? ""
        if makeWord.isEmpty || model.lowercased().hasPrefix(makeWord) { return model }
        return "\(make) \(model)"
    }

    /// The file type, such as "JPEG", or "JPEG + DNG" for a pair.
    static func format(_ file: PhotoFile) -> String {
        var names = [typeName(file.url)]
        names += file.companions.map(typeName)
        return names.joined(separator: " + ")
    }

    private static func typeName(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return "JPEG"
        case "heic", "heif": return "HEIC"
        case "tif", "tiff": return "TIFF"
        default: return ext.uppercased()
        }
    }

    /// The folder a photo sits in, relative to the shoot ("Shoot" for the top folder).
    static func folder(of item: PhotoItem, shootName: String) -> String {
        let parts = item.id.split(separator: "/").dropLast()
        return parts.isEmpty ? shootName : ([shootName] + parts.map(String.init)).joined(separator: " ▸ ")
    }

    static func decision(_ decision: Decision) -> String {
        switch decision {
        case .unreviewed: localized("decision.unreviewed", default: "Unreviewed")
        case .kept: localized("decision.kept", default: "Kept")
        case .rejected: localized("decision.rejected", default: "Rejected")
        }
    }

    /// A flag's name as badges show it.
    static func flag(_ flag: PhotoFlag) -> String {
        switch flag {
        case .eyesClosed: localized("flag.eyesClosed", default: "Eyes closed")
        case .blurry: localized("flag.blurry", default: "Blurry")
        case .clippedHighlights: localized("flag.clippedHighlights", default: "Blown highlights")
        case .clippedShadows: localized("flag.clippedShadows", default: "Crushed shadows")
        case .lowAesthetics: localized("flag.lowAesthetics", default: "Weak shot")
        case .tiltedHorizon: localized("flag.tiltedHorizon", default: "Tilted horizon")
        case .faceCutOff: localized("flag.faceCutOff", default: "Face cut off")
        case .lensSmudge: localized("flag.lensSmudge", default: "Lens smudge")
        case .utility: localized("flag.utility", default: "Accidental shot")
        }
    }

    static func flagSymbol(_ flag: PhotoFlag) -> String {
        switch flag {
        case .eyesClosed: "eye.slash"
        case .blurry: "camera.metering.unknown"
        case .clippedHighlights: "sun.max"
        case .clippedShadows: "moon"
        case .lowAesthetics: "hand.thumbsdown"
        case .tiltedHorizon: "level"
        case .faceCutOff: "person.crop.rectangle"
        case .lensSmudge: "drop"
        case .utility: "hand.raised"
        }
    }

    /// A zoom factor as a percentage, such as "100%" or "38%".
    static func zoom(_ factor: Double) -> String {
        percentText(factor, fractionDigits: factor * 100 < 10 ? 1 : 0)
    }

    static func percent(_ fraction: Double) -> String {
        let value = fraction * 100
        if value == 0 { return percentText(0, fractionDigits: 0) }
        if value < 0.1 {
            let limit = percentText(0.001, fractionDigits: 1)
            return localized("percent.lessThan", default: "<\(limit)")
        }
        return percentText(fraction, fractionDigits: value < 10 ? 1 : 0)
    }

    /// "4.2%", "4,2 %".
    private static func percentText(_ fraction: Double, fractionDigits: Int) -> String {
        fraction.formatted(.percent.precision(.fractionLength(fractionDigits)).locale(Localization.locale))
    }

    /// A reason or message to embed in a sentence that puts its own full stop after it: system
    /// errors are often whole sentences ending in one, which would give "…space.. Culla…".
    static func embedded(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("."), !trimmed.hasSuffix("..") { trimmed.removeLast() }
        return trimmed
    }

    static func stars(_ rating: Int) -> String {
        rating == 0 ? localized("No rating") : localized("\(rating) stars")
    }
}
