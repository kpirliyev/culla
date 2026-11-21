import CullaCore
import Foundation

/// Why a sidecar was not read or changed.
public enum XMPSidecarError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Not UTF-8 (with or without a byte-order mark). UTF-16 sidecars are left alone.
    case notUTF8
    /// Not well-formed XML.
    case malformed(String)
    /// Well-formed, but in a shape Culla does not edit safely (no `rdf:RDF`, a DOCTYPE, a rating
    /// or label that is not plain text, ...). The file is left alone.
    case unsupported(String)

    public var description: String {
        switch self {
        case .notUTF8: "The sidecar is not UTF-8 text"
        case .malformed(let detail): "The sidecar is not well-formed XML (\(detail))"
        case .unsupported(let detail): "The sidecar has a layout Culla does not change (\(detail))"
        }
    }

    /// Why a sidecar was left alone, for people, from the English note an apply's journal keeps
    /// for a skipped step (`description`). Nil for a note that is not one of these errors.
    public static func reason(forNote note: String) -> String? {
        if note == XMPSidecarError.notUTF8.description { return localized("not UTF-8 text") }
        if note.hasPrefix("The sidecar is not well-formed XML") { return localized("not well-formed XML") }
        if note.hasPrefix("The sidecar has a layout Culla does not change") { return localized("a layout Culla does not change") }
        return nil
    }
}

/// The fields Culla reads from a sidecar.
public struct XMPSidecarFields: Sendable, Hashable {
    /// `xmp:Rating`: 0 to 5 stars, -1 for rejected. Nil when absent or not a number.
    public var rating: Int?
    /// `xmp:Label`: the colour label's name.
    public var label: String?
    /// Culla's own record of the decision (`culla:Decision`).
    public var decision: SidecarDecision?
    /// Culla's own record of the star rating (`culla:Rating`), kept even for rejects, whose
    /// `xmp:Rating` is -1.
    public var cullaRating: Int?

    public init(rating: Int? = nil, label: String? = nil, decision: SidecarDecision? = nil, cullaRating: Int? = nil) {
        self.rating = rating
        self.label = label
        self.decision = decision
        self.cullaRating = cullaRating
    }

    /// Culla's mark, when the sidecar holds one.
    public var mark: SidecarMark? {
        decision.map { SidecarMark(decision: $0, rating: cullaRating ?? max(rating ?? 0, 0)) }
    }
}

/// XMP sidecars: `<basename>.xmp` beside a photo, holding its rating, colour label and Culla's
/// decision. Culla never changes an image file.
///
/// ## What is written (`SidecarMapping`, defaults in brackets)
///
/// | Photo | `xmp:Rating` | `xmp:Label` | `culla:Decision` | `culla:Rating` |
/// | --- | --- | --- | --- | --- |
/// | Kept, n stars | n when n > 0; 0 when the sidecar had -1; else untouched | `keptLabel` ["Green"] | `kept` | n |
/// | Rejected | `rejectedRating` [-1] | `rejectedLabel` ["Red"] | `rejected` | n |
/// | Unreviewed, n > 0 stars | n | untouched | `unreviewed` | n |
/// | Unreviewed, no stars | no sidecar at all | | | |
///
/// A kept photo with no stars does not write `xmp:Rating` 0 over a rating another program set.
/// With `writesRating` off nothing touches `xmp:Rating`; a nil label leaves `xmp:Label` alone.
/// `culla:` is `http://ns.culla.app/xmp/1.0/`, so Culla reads its own decision back exactly.
///
/// ## What editors read (from Culla's authors' knowledge, not tested against the applications)
///
/// - **Lightroom Classic** reads `<basename>.xmp` beside a proprietary RAW file on import (and
///   with Metadata > Read Metadata from Files): `xmp:Rating` as stars and `xmp:Label` as the
///   colour label, matched by name against the active colour label set, whose default names are
///   Red, Yellow, Green, Blue and Purple (high confidence). Whether it turns `xmp:Rating` -1 into
///   its Rejected flag on import is **uncertain**: -1 is the value Bridge writes for Reject and
///   Lightroom has been reported to read it, but Lightroom never writes its pick flags to XMP.
///   For JPEG, HEIC, TIFF, PSD and DNG it reads metadata embedded in the file and **ignores** a
///   sidecar beside it (high confidence), so for a JPEG-only or HEIC-only photo the sidecar
///   carries nothing into Lightroom. For a RAW+JPEG pair imported as one photo the sidecar
///   belongs to the RAW, which is why it is named after the shared basename.
/// - **Capture One** reads and writes `<basename>.xmp` sidecars for RAW files (Preferences >
///   Image > Metadata, "Auto Sync Sidecar XMP"): `xmp:Rating` as stars (high confidence) and
///   `xmp:Label` mapped to its colour tags by name (medium confidence; its colour names include
///   Red and Green). How it treats `xmp:Rating` -1 is **uncertain**: older versions had no
///   rejected state and may read it as no stars. Whether it reads sidecars beside JPEG or HEIC
///   files is **uncertain**; it is believed to prefer metadata embedded in those files.
/// - **Adobe Bridge / Camera Raw** read the same fields; Bridge shows -1 as Reject (high
///   confidence).
/// - darktable uses `<file name>.<ext>.xmp` sidecars of its own and does not read these.
///
/// ## Merging
///
/// An existing sidecar is edited in place, never rebuilt: only the bytes of the values above
/// change, or a new attribute is added for a field that was missing, with its namespace declared
/// when it is not already. Everything else (other properties and namespaces, comments, unknown
/// elements, whitespace, the `xpacket` wrapper and its padding, a UTF-8 byte-order mark, the
/// quote style) stays byte for byte. Both RDF forms are handled: a property as an attribute of
/// `rdf:Description`, and as a plain-text child element; a field present in several
/// `rdf:Description` blocks is set in each. A sidecar that is not UTF-8, not well-formed, or has a
/// shape the scanner does not edit safely is never touched: the write throws and the caller
/// reports it. Every merge is checked by parsing the result and reading the fields back.
public enum XMPSidecar {
    public static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"
    public static let cullaNamespace = "http://ns.culla.app/xmp/1.0/"
    public static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    struct Property: Hashable {
        var namespace: String
        var localName: String
        var preferredPrefix: String

        static let rating = Property(namespace: xmpNamespace, localName: "Rating", preferredPrefix: "xmp")
        static let label = Property(namespace: xmpNamespace, localName: "Label", preferredPrefix: "xmp")
        static let decision = Property(namespace: cullaNamespace, localName: "Decision", preferredPrefix: "culla")
        static let cullaRating = Property(namespace: cullaNamespace, localName: "Rating", preferredPrefix: "culla")
    }

    /// The sidecar path for a photo's shown file: `<folder>/<basename>.xmp`.
    public static func sidecarURL(for photoURL: URL) -> URL {
        photoURL.deletingPathExtension().appendingPathExtension("xmp")
    }

    // MARK: Reading

    /// The fields of a sidecar's bytes.
    public static func read(_ data: Data) throws(XMPSidecarError) -> XMPSidecarFields {
        let spans = try parse(data)
        let values = try values(in: spans)
        return fields(from: values)
    }

    /// The fields of the sidecar at `url`.
    public static func read(contentsOf url: URL) throws -> XMPSidecarFields {
        try read(Data(contentsOf: url))
    }

    // MARK: Writing

    /// A new sidecar holding only the mark.
    public static func fresh(mark: SidecarMark, mapping: SidecarMapping = SidecarMapping()) -> Data {
        // Shaped like the sidecars Lightroom and Camera Raw write: no xpacket wrapper, one
        // rdf:Description with its namespaces and properties as attributes.
        let skeleton = """
            <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Culla">
             <rdf:RDF xmlns:rdf="\(rdfNamespace)">
              <rdf:Description rdf:about=""
                xmlns:xmp="\(xmpNamespace)"
                xmlns:culla="\(cullaNamespace)"/>
             </rdf:RDF>
            </x:xmpmeta>

            """
        // The skeleton is valid and has no fields, so merging cannot fail.
        return (try? merged(Data(skeleton.utf8), mark: mark, mapping: mapping)) ?? Data(skeleton.utf8)
    }

    /// `existing` with the mark merged in: only Culla's fields change (see the type's notes).
    /// Returns `existing` itself when every field already has its value.
    public static func merged(_ existing: Data, mark: SidecarMark, mapping: SidecarMapping = SidecarMapping()) throws(XMPSidecarError) -> Data {
        let spans = try parse(existing)
        let current = try values(in: spans)
        let wanted = updates(for: mark, mapping: mapping, existing: fields(from: current))
        let edited = try edit(spans, setting: wanted)
        guard edited != Array(existing) else { return existing }
        let result = Data(edited)
        // Belt and braces: the result must parse and read back as intended.
        let check = try values(in: parse(result))
        for (property, value) in wanted where check[property] != value {
            throw .unsupported("the merged sidecar did not read back as written")
        }
        return result
    }

    /// The bytes a write of `mark` to the sidecar at `url` would leave there, and what is there
    /// now. Reads only. Throws `XMPSidecarError` when the existing sidecar cannot be merged.
    public static func prepareWrite(mark: SidecarMark, mapping: SidecarMapping, at url: URL) throws -> (previous: SidecarPrevious, written: Data) {
        guard let stamp = FileOps.stamp(url.path) else {
            return (.absent, fresh(mark: mark, mapping: mapping))
        }
        let data = try Data(contentsOf: url)
        return (.existed(data, stamp), try merged(data, mark: mark, mapping: mapping))
    }

    /// Writes `written` to `url` atomically through `tempPath`, as long as the file is still as
    /// `previous` describes; otherwise throws without touching it. Does nothing when the bytes
    /// are already there.
    public static func commitWrite(_ written: Data, previous: SidecarPrevious, at url: URL, tempPath: String) throws {
        switch previous {
        case .absent:
            try FileOps.writeAtomically(written, to: url.path, tempPath: tempPath, replacing: false)
        case let .existed(data, stamp):
            guard FileOps.stamp(url.path) == stamp, try Data(contentsOf: url) == data else {
                throw XMPSidecarError.unsupported("the sidecar changed while it was being written")
            }
            guard written != data else { return }
            try FileOps.writeAtomically(written, to: url.path, tempPath: tempPath, replacing: true)
        }
    }

    /// The result of `write(mark:mapping:to:)`: enough to put the file back exactly.
    public struct WriteResult: Sendable, Hashable {
        public var previous: SidecarPrevious
        public var written: Data
        /// False when the file already held exactly these bytes and was not touched.
        public var changed: Bool
    }

    /// Writes (or merges) the mark into the sidecar at `url`, atomically.
    @discardableResult
    public static func write(mark: SidecarMark, mapping: SidecarMapping = SidecarMapping(), to url: URL) throws -> WriteResult {
        let (previous, written) = try prepareWrite(mark: mark, mapping: mapping, at: url)
        try commitWrite(written, previous: previous, at: url, tempPath: FileOps.temporaryPath(beside: url.path))
        let changed: Bool
        if case let .existed(data, _) = previous { changed = data != written } else { changed = true }
        return WriteResult(previous: previous, written: written, changed: changed)
    }

    /// Puts a sidecar back as it was before a write: the previous bytes and modification time,
    /// or no file. Only when the file still holds `written` (or is already as it was); otherwise
    /// throws, touching nothing, so a sidecar changed since by another program is not lost.
    /// Returns false when it was already as it was.
    @discardableResult
    public static func restore(_ previous: SidecarPrevious, written: Data, at url: URL, tempPath: String? = nil) throws -> Bool {
        let path = url.path
        let current = FileOps.exists(path) ? try Data(contentsOf: url) : nil
        switch previous {
        case .absent:
            guard let current else { return false }
            guard current == written else { throw RestoreConflict.changedSince }
            try FileOps.removeFile(path)
            return true
        case let .existed(data, stamp):
            if current == data {
                if FileOps.stamp(path) != stamp { try FileOps.setModificationTime(stamp, of: path) }
                return false
            }
            guard let current else { throw RestoreConflict.missing }
            guard current == written else { throw RestoreConflict.changedSince }
            try FileOps.writeAtomically(data, to: path, tempPath: tempPath ?? FileOps.temporaryPath(beside: path), replacing: true)
            try FileOps.setModificationTime(stamp, of: path)
            return true
        }
    }

    /// Why `restore` left a sidecar alone.
    public enum RestoreConflict: Error, Sendable, Hashable {
        /// The file holds something other than what Culla wrote.
        case changedSince
        /// The file is gone.
        case missing
    }

    // MARK: Fields

    static func updates(for mark: SidecarMark, mapping: SidecarMapping, existing: XMPSidecarFields) -> [(Property, String)] {
        var result: [(Property, String)] = []
        if mapping.writesRating {
            if mark.decision == .rejected {
                if let rejected = mapping.rejectedRating { result.append((.rating, String(rejected))) }
            } else if mark.rating > 0 {
                result.append((.rating, String(mark.rating)))
            } else if let rating = existing.rating, rating < 0 {
                // A reject the user took back.
                result.append((.rating, "0"))
            }
        }
        switch mark.decision {
        case .kept: if let label = mapping.keptLabel { result.append((.label, label)) }
        case .rejected: if let label = mapping.rejectedLabel { result.append((.label, label)) }
        case .unreviewed: break
        }
        result.append((.decision, mark.decision.rawValue))
        result.append((.cullaRating, String(mark.rating)))
        return result
    }

    private static func fields(from values: [Property: String]) -> XMPSidecarFields {
        func number(_ text: String?) -> Int? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return Int(text) ?? Double(text).map { Int($0.rounded()) }
        }
        return XMPSidecarFields(
            rating: number(values[.rating]),
            label: values[.label],
            decision: values[.decision].flatMap(SidecarDecision.init(rawValue:)),
            cullaRating: number(values[.cullaRating])
        )
    }

    // MARK: Parsing

    private static func parse(_ data: Data) throws(XMPSidecarError) -> XMLSpans {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xFE, 0xFF]) || bytes.starts(with: [0xFF, 0xFE]) { throw .notUTF8 }
        guard String(validating: bytes, as: UTF8.self) != nil else { throw .notUTF8 }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw .malformed(parser.parserError.map { ($0 as NSError).localizedDescription } ?? "unknown error")
        }
        do {
            return try XMLSpans(bytes)
        } catch {
            switch error {
            case .malformed(let detail): throw .malformed(detail)
            case .unsupported(let detail): throw .unsupported(detail)
            }
        }
    }

    private static func rdfElement(in spans: XMLSpans) throws(XMPSidecarError) -> XMLSpans.Element {
        var queue = [spans.root!]
        while !queue.isEmpty {
            let element = queue.removeFirst()
            if element.namespace == rdfNamespace, element.localName == "RDF" { return element }
            queue += element.children
        }
        throw .unsupported("no rdf:RDF element")
    }

    private static func descriptions(of rdf: XMLSpans.Element) -> [XMLSpans.Element] {
        rdf.children.filter { $0.namespace == rdfNamespace && $0.localName == "Description" }
    }

    private static let properties: [Property] = [.rating, .label, .decision, .cullaRating]

    /// The first value of each of Culla's fields, from attributes and plain-text child elements of
    /// the top-level `rdf:Description` blocks.
    private static func values(in spans: XMLSpans) throws(XMPSidecarError) -> [Property: String] {
        var result: [Property: String] = [:]
        for description in descriptions(of: try rdfElement(in: spans)) {
            for attribute in description.attributes {
                let (namespace, localName) = description.resolve(attribute)
                if let property = properties.first(where: { $0.namespace == namespace && $0.localName == localName }), result[property] == nil {
                    result[property] = attribute.value
                }
            }
            for child in description.children {
                if let property = properties.first(where: { $0.namespace == child.namespace && $0.localName == child.localName }),
                   result[property] == nil, child.isPlainText {
                    result[property] = spans.text(of: child).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        return result
    }

    // MARK: Editing

    private static func edit(_ spans: XMLSpans, setting wanted: [(Property, String)]) throws(XMPSidecarError) -> [UInt8] {
        let rdf = try rdfElement(in: spans)
        let blocks = descriptions(of: rdf)
        var edits: [(range: Range<Int>, text: String)] = []
        var missing: [(Property, String)] = []

        for (property, value) in wanted {
            var found = false
            for description in blocks {
                for attribute in description.attributes {
                    let (namespace, localName) = description.resolve(attribute)
                    guard namespace == property.namespace, localName == property.localName else { continue }
                    found = true
                    if attribute.value != value {
                        edits.append((attribute.valueRange, XMLSpans.escapeAttribute(value, quote: attribute.quote)))
                    }
                }
                for child in description.children where child.namespace == property.namespace && child.localName == property.localName {
                    guard child.isPlainText, child.endTag != nil else {
                        throw .unsupported("\(child.name) is not plain text")
                    }
                    found = true
                    if spans.text(of: child).trimmingCharacters(in: .whitespacesAndNewlines) != value {
                        edits.append((child.content, XMLSpans.escapeText(value)))
                    }
                }
            }
            if !found { missing.append((property, value)) }
        }

        if !missing.isEmpty {
            if let target = blocks.first(where: { block in missing.contains { block.prefix(for: $0.0.namespace) != nil } }) ?? blocks.first {
                edits.append((target.startTagClose..<target.startTagClose, insertion(missing, into: target, spans: spans)))
            } else {
                guard !rdf.prefix.isEmpty, let endTag = rdf.endTag else {
                    throw .unsupported("rdf:RDF has no rdf:Description and cannot take one")
                }
                edits.append((endTag.lowerBound..<endTag.lowerBound, newDescription(missing, in: rdf)))
            }
        }

        var bytes = spans.bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8))
        }
        return bytes
    }

    /// Attributes (and namespace declarations) to add before the end of a description's start tag,
    /// each on its own line when the tag already puts its attributes on lines of their own.
    private static func insertion(_ missing: [(Property, String)], into description: XMLSpans.Element, spans: XMLSpans) -> String {
        var separator = " "
        if let last = description.attributes.last {
            let space = spans.string(last.leadingSpace)
            if space.contains("\n") { separator = space }
        }
        let quote = description.attributes.last?.quote ?? UInt8(ascii: "\"")
        let quoteText = String(UnicodeScalar(quote))
        var scope = description.scope
        var declarations: [String] = []
        var attributes: [String] = []
        for (property, value) in missing {
            var prefix = prefix(for: property.namespace, in: scope)
            if prefix == nil {
                var candidate = property.preferredPrefix
                var number = 1
                while scope[candidate] != nil {
                    candidate = property.preferredPrefix + String(number)
                    number += 1
                }
                scope[candidate] = property.namespace
                declarations.append("xmlns:\(candidate)=\(quoteText)\(XMLSpans.escapeAttribute(property.namespace, quote: quote))\(quoteText)")
                prefix = candidate
            }
            attributes.append("\(prefix!):\(property.localName)=\(quoteText)\(XMLSpans.escapeAttribute(value, quote: quote))\(quoteText)")
        }
        // Text between the last attribute and the tag's end, such as a space before "/>", stays
        // where it is; the new attributes go before it.
        return (declarations + attributes).map { separator + $0 }.joined()
    }

    private static func newDescription(_ missing: [(Property, String)], in rdf: XMLSpans.Element) -> String {
        let rdfPrefix = rdf.prefix
        var scope = rdf.scope
        var parts = ["\(rdfPrefix):about=\"\""]
        var attributes: [String] = []
        for (property, value) in missing {
            var prefix = prefix(for: property.namespace, in: scope)
            if prefix == nil {
                var candidate = property.preferredPrefix
                var number = 1
                while scope[candidate] != nil {
                    candidate = property.preferredPrefix + String(number)
                    number += 1
                }
                scope[candidate] = property.namespace
                parts.append("xmlns:\(candidate)=\"\(XMLSpans.escapeAttribute(property.namespace, quote: UInt8(ascii: "\"")))\"")
                prefix = candidate
            }
            attributes.append("\(prefix!):\(property.localName)=\"\(XMLSpans.escapeAttribute(value, quote: UInt8(ascii: "\"")))\"")
        }
        return " <\(rdfPrefix):Description " + (parts + attributes).joined(separator: " ") + "/>\n "
    }

    /// A non-default prefix bound to `namespace` in `scope`.
    static func prefix(for namespace: String, in scope: [String: String]) -> String? {
        scope.filter { $0.key != "" && $0.value == namespace }.keys.sorted().first
    }
}

extension XMLSpans.Element {
    /// A non-default prefix bound to `namespace` where this element starts.
    func prefix(for namespace: String) -> String? {
        if let own = declared.filter({ $0.key != "" && $0.value == namespace }).keys.sorted().first { return own }
        return XMPSidecar.prefix(for: namespace, in: scope)
    }
}
