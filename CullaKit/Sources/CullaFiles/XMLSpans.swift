import Foundation

/// A small XML scanner that keeps the byte range of every tag, attribute value and text run, so a
/// document can be edited by splicing exactly those bytes and nothing else. Made for XMP sidecars:
/// it refuses DOCTYPE declarations and anything it does not understand, and it is only run on
/// documents `XMLParser` has already found well-formed.
struct XMLSpans {
    struct Attribute {
        /// The qualified name as written, such as `xmp:Rating`.
        var name: String
        /// The decoded value.
        var value: String
        /// The value's bytes, between the quotes.
        var valueRange: Range<Int>
        var quote: UInt8
        /// The whitespace before the attribute.
        var leadingSpace: Range<Int>
    }

    final class Element {
        let name: String
        let prefix: String
        let localName: String
        /// The element's namespace, or nil when its prefix is not bound.
        var namespace: String?
        var attributes: [Attribute]
        /// Every prefix bound where the element starts (its own declarations included); "" is
        /// the default namespace.
        var scope: [String: String]
        /// Prefixes the element declares itself.
        var declared: [String: String]
        /// From `<` to just past `>`.
        let startTag: Range<Int>
        /// Where `/>` or `>` closing the start tag begins.
        let startTagClose: Int
        let isEmpty: Bool
        /// Between the start tag and the end tag (empty for an empty element).
        var content: Range<Int>
        var endTag: Range<Int>?
        weak var parent: Element?
        var children: [Element] = []
        /// True when the content holds only character data: no elements, comments, CDATA or
        /// processing instructions.
        var isPlainText = true

        init(
            name: String, attributes: [Attribute], scope: [String: String], declared: [String: String],
            startTag: Range<Int>, startTagClose: Int, isEmpty: Bool
        ) {
            self.name = name
            if let colon = name.firstIndex(of: ":") {
                prefix = String(name[..<colon])
                localName = String(name[name.index(after: colon)...])
            } else {
                prefix = ""
                localName = name
            }
            self.attributes = attributes
            self.scope = scope
            self.declared = declared
            self.startTag = startTag
            self.startTagClose = startTagClose
            self.isEmpty = isEmpty
            content = startTag.upperBound..<startTag.upperBound
            namespace = scope[prefix]
        }

        /// The namespace and local name of an attribute; unprefixed attributes have no namespace.
        func resolve(_ attribute: Attribute) -> (namespace: String?, localName: String) {
            guard let colon = attribute.name.firstIndex(of: ":") else { return (nil, attribute.name) }
            let prefix = String(attribute.name[..<colon])
            if prefix == "xmlns" { return ("http://www.w3.org/2000/xmlns/", String(attribute.name[attribute.name.index(after: colon)...])) }
            return (scope[prefix], String(attribute.name[attribute.name.index(after: colon)...]))
        }
    }

    enum Failure: Error {
        case malformed(String)
        case unsupported(String)
    }

    let bytes: [UInt8]
    /// Bytes skipped at the start: a UTF-8 byte-order mark.
    let start: Int
    private(set) var root: Element!

    init(_ bytes: [UInt8]) throws(Failure) {
        self.bytes = bytes
        start = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        try scan()
    }

    // MARK: Scanning

    private mutating func scan() throws(Failure) {
        var stack: [Element] = []
        var index = start
        let count = bytes.count
        while index < count {
            if bytes[index] != UInt8(ascii: "<") {
                let textStart = index
                while index < count, bytes[index] != UInt8(ascii: "<") { index += 1 }
                let isBlank = bytes[textStart..<index].allSatisfy(Self.isSpace)
                if !isBlank {
                    guard stack.last != nil else { throw .malformed("text outside the root element") }
                }
                continue
            }
            if has("<?", at: index) {
                let end = try find("?>", from: index + 2)
                stack.last?.isPlainText = false
                index = end + 2
            } else if has("<!--", at: index) {
                let end = try find("-->", from: index + 4)
                stack.last?.isPlainText = false
                index = end + 3
            } else if has("<![CDATA[", at: index) {
                let end = try find("]]>", from: index + 9)
                stack.last?.isPlainText = false
                index = end + 3
            } else if has("<!", at: index) {
                throw .unsupported("a DOCTYPE or other declaration")
            } else if has("</", at: index) {
                let end = try find(">", from: index + 2)
                let name = string(index + 2..<end).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let element = stack.popLast(), element.name == name else { throw .malformed("mismatched end tag </\(name)>") }
                element.content = element.startTag.upperBound..<index
                element.endTag = index..<(end + 1)
                index = end + 1
            } else {
                let element = try startTag(at: index, parent: stack.last)
                if let parent = stack.last {
                    parent.children.append(element)
                    parent.isPlainText = false
                    element.parent = parent
                } else {
                    guard root == nil else { throw .malformed("a second root element") }
                    root = element
                }
                if !element.isEmpty { stack.append(element) }
                index = element.startTag.upperBound
            }
        }
        guard stack.isEmpty, root != nil else { throw .malformed("unclosed elements") }
    }

    private func startTag(at begin: Int, parent: Element?) throws(Failure) -> Element {
        var index = begin + 1
        let nameStart = index
        while index < bytes.count, !Self.isSpace(bytes[index]), bytes[index] != UInt8(ascii: ">"), bytes[index] != UInt8(ascii: "/") {
            index += 1
        }
        let name = string(nameStart..<index)
        guard !name.isEmpty else { throw .malformed("an empty tag name") }
        var attributes: [Attribute] = []
        while true {
            let spaceStart = index
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count else { throw .malformed("an unclosed tag") }
            if bytes[index] == UInt8(ascii: ">") || has("/>", at: index) {
                let isEmpty = bytes[index] == UInt8(ascii: "/")
                let close = index
                let end = index + (isEmpty ? 2 : 1)
                var scope = parent?.scope ?? ["xml": "http://www.w3.org/XML/1998/namespace"]
                var declared: [String: String] = [:]
                for attribute in attributes {
                    if attribute.name == "xmlns" {
                        declared[""] = attribute.value
                    } else if attribute.name.hasPrefix("xmlns:") {
                        declared[String(attribute.name.dropFirst(6))] = attribute.value
                    }
                }
                scope.merge(declared) { _, new in new }
                return Element(
                    name: name, attributes: attributes, scope: scope, declared: declared,
                    startTag: begin..<end, startTagClose: close, isEmpty: isEmpty
                )
            }
            guard index > spaceStart else { throw .malformed("attributes without space between them") }
            let attributeStart = index
            while index < bytes.count, !Self.isSpace(bytes[index]), bytes[index] != UInt8(ascii: "=") { index += 1 }
            let attributeName = string(attributeStart..<index)
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { throw .malformed("an attribute without a value") }
            index += 1
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") else {
                throw .malformed("an unquoted attribute value")
            }
            let quote = bytes[index]
            let valueStart = index + 1
            guard let valueEnd = bytes[valueStart...].firstIndex(of: quote) else { throw .malformed("an unclosed attribute value") }
            attributes.append(Attribute(
                name: attributeName,
                value: Self.decode(string(valueStart..<valueEnd)),
                valueRange: valueStart..<valueEnd,
                quote: quote,
                leadingSpace: spaceStart..<attributeStart
            ))
            index = valueEnd + 1
        }
    }

    // MARK: Helpers

    func string(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// The decoded character data of a plain-text element.
    func text(of element: Element) -> String {
        Self.decode(string(element.content))
    }

    private func has(_ text: StaticString, at index: Int) -> Bool {
        let pattern = UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
        guard index + pattern.count <= bytes.count else { return false }
        for offset in 0..<pattern.count where bytes[index + offset] != pattern[offset] { return false }
        return true
    }

    private func find(_ text: StaticString, from index: Int) throws(Failure) -> Int {
        var position = index
        while position < bytes.count {
            if has(text, at: position) { return position }
            position += 1
        }
        throw .malformed("unterminated markup")
    }

    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// Replaces character and entity references.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            guard let semicolon = rest[amp...].firstIndex(of: ";") else {
                result += rest[amp...]
                return result
            }
            let entity = rest[rest.index(after: amp)..<semicolon]
            switch entity {
            case "lt": result += "<"
            case "gt": result += ">"
            case "amp": result += "&"
            case "quot": result += "\""
            case "apos": result += "'"
            default:
                var scalar: Unicode.Scalar?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    scalar = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init)
                } else if entity.hasPrefix("#") {
                    scalar = UInt32(entity.dropFirst(1)).flatMap(Unicode.Scalar.init)
                }
                if let scalar {
                    result.unicodeScalars.append(scalar)
                } else {
                    result += rest[amp...semicolon]
                }
            }
            rest = rest[rest.index(after: semicolon)...]
        }
        result += rest
        return result
    }

    /// Escapes text for an attribute value in the given quotes.
    static func escapeAttribute(_ value: String, quote: UInt8) -> String {
        var result = ""
        for character in value {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"" where quote == UInt8(ascii: "\""): result += "&quot;"
            case "'" where quote == UInt8(ascii: "'"): result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Escapes character data.
    static func escapeText(_ value: String) -> String {
        escapeAttribute(value, quote: 0)
    }
}
