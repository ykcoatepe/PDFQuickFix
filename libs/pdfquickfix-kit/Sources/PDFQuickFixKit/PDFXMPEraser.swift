import CoreGraphics
import Foundation

/// Erases XMP metadata streams from a PDF whose objects are all written out
/// uncompressed, as CoreGraphics' full rewrite produces. PDFKit offers no way to drop the
/// catalog's /Metadata, so each reference and its stream are overwritten in place
/// with bytes of the same length, leaving every object offset valid.
enum PDFXMPEraser {
    /// Why a file was left untouched.
    enum Refusal: String, Error {
        case unreadableSyntax
        case compressedObjects
        case objectOutsideCrossReferenceTable
        case targetIsNotAnUnsharedXMPStream
        case pageCountChanged
    }

    /// Returns nil when the layout is not understood or an erase would be unsafe;
    /// the caller's hidden-data check then decides whether the result is usable.
    static func erasingMetadataStreams(from data: Data) -> Data? {
        try? erase(from: data).get()
    }

    static func erase(from data: Data) -> Result<Data, Refusal> {
        var bytes = [UInt8](data)
        let objects: [ObjectInfo]
        switch scanObjects(in: bytes) {
        case let .success(found): objects = found
        case let .failure(refusal): return .failure(refusal)
        }
        // References inside compressed objects cannot be seen from here.
        guard !objects.contains(where: { $0.names.contains("ObjStm") || $0.names.contains("XRef") }) else {
            return .failure(.compressedObjects)
        }

        let targets = Set(objects.flatMap { $0.metadataReferences.map(\.target) })
        guard !targets.isEmpty else { return .success(data) }
        let otherReferences = objects.reduce(into: Set<Int>()) { $0.formUnion($1.otherReferences) }
        // A file with an update history defines a number more than once; every
        // definition of a target must be an XMP stream that nothing else points to.
        let definitions = objects.filter { targets.contains($0.number) }
        guard targets.isSubset(of: Set(definitions.map(\.number))),
              targets.isDisjoint(with: otherReferences),
              definitions.allSatisfy({ info in
                  info.isStream && info.bodyEnd - info.bodyStart >= 6
                      && (info.topLevelNames.contains("XML") || info.topLevelNames.contains("Metadata"))
              })
        else { return .failure(.targetIsNotAnUnsharedXMPStream) }

        for info in objects {
            for reference in info.metadataReferences {
                for index in reference.span { bytes[index] = 0x20 }
            }
        }
        for info in definitions {
            for index in info.bodyStart ..< info.bodyEnd { bytes[index] = 0x20 }
            bytes.replaceSubrange(info.bodyStart + 1 ..< info.bodyStart + 5, with: Array("null".utf8))
        }

        let erased = Data(bytes)
        guard erased.count == data.count,
              let before = pageCount(of: data), let after = pageCount(of: erased), before == after
        else { return .failure(.pageCountChanged) }
        return .success(erased)
    }

    // MARK: - Structure

    private struct ObjectInfo {
        var number = 0
        /// Bytes between the `obj` and `endobj` keywords.
        var bodyStart = 0
        var bodyEnd = 0
        var isStream = false
        var names: Set<String> = []
        /// Names in the object's own dictionary, not in dictionaries nested inside it.
        var topLevelNames: Set<String> = []
        var metadataReferences: [(target: Int, span: Range<Int>)] = []
        var otherReferences: Set<Int> = []
    }

    private static func pageCount(of data: Data) -> Int? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider)
        else { return nil }
        return document.numberOfPages
    }

    /// Reads every `N G obj … endobj` in file order, which covers the plain and
    /// the linearized layout and files with appended updates. Each one must
    /// start where a cross-reference table says an object starts, so bytes that
    /// only look like an object are never taken for one.
    private static func scanObjects(in bytes: [UInt8]) -> Result<[ObjectInfo], Refusal> {
        var objects: [ObjectInfo] = []
        var headerOffsets: Set<Int> = []
        var tableOffsets: Set<Int> = []
        var lexer = Lexer(bytes: bytes, position: 0, end: bytes.count)
        var recent: [Token] = []
        while let token = lexer.next() {
            switch token.kind {
            case .invalid:
                return .failure(.unreadableSyntax)
            case .keyword("obj"):
                guard recent.count >= 2,
                      case let .integer(number) = recent[recent.count - 2].kind,
                      case .integer = recent[recent.count - 1].kind,
                      var info = objectInfo(lexer: &lexer, bodyStart: token.range.upperBound)
                else { return .failure(.unreadableSyntax) }
                info.number = number
                objects.append(info)
                headerOffsets.insert(recent[recent.count - 2].range.lowerBound)
                recent.removeAll()
            case .keyword("xref"):
                guard readCrossReferenceTable(lexer: &lexer, into: &tableOffsets) else {
                    return .failure(.unreadableSyntax)
                }
                recent.removeAll()
            default:
                recent.append(token)
                if recent.count > 2 { recent.removeFirst() }
            }
        }
        guard !objects.isEmpty else { return .failure(.unreadableSyntax) }
        guard headerOffsets.isSubset(of: tableOffsets) else { return .failure(.objectOutsideCrossReferenceTable) }
        return .success(objects)
    }

    /// Collects the in-use offsets of one classic table, stopping before `trailer`.
    private static func readCrossReferenceTable(lexer: inout Lexer, into offsets: inout Set<Int>) -> Bool {
        while true {
            var lookahead = lexer
            guard case .integer? = lookahead.next()?.kind else { return true }
            guard case .integer? = lexer.next()?.kind,
                  case let .integer(count)? = lexer.next()?.kind, count <= 10_000_000
            else { return false }
            for _ in 0 ..< count {
                guard case let .integer(offset)? = lexer.next()?.kind,
                      case .integer? = lexer.next()?.kind,
                      case let .keyword(state)? = lexer.next()?.kind, state == "n" || state == "f"
                else { return false }
                if state == "n" { offsets.insert(offset) }
            }
        }
    }

    private static func objectInfo(lexer: inout Lexer, bodyStart: Int) -> ObjectInfo? {
        var info = ObjectInfo(bodyStart: bodyStart)
        var recent: [Token] = []
        var directLength: Int?
        var depth = 0
        while let token = lexer.next() {
            switch token.kind {
            case .invalid:
                return nil
            case .dictionaryStart:
                depth += 1
            case .dictionaryEnd:
                depth -= 1
            case .keyword("endobj"):
                info.bodyEnd = token.range.lowerBound
                return info
            case .keyword("stream"):
                info.isStream = true
                guard depth == 0, let directLength, lexer.skipStreamData(length: directLength) else { return nil }
                recent.removeAll()
                continue
            case let .name(name):
                info.names.insert(name)
                if depth == 1 { info.topLevelNames.insert(name) }
            case let .integer(value):
                // Only the stream's own /Length counts, not one in a nested dictionary.
                if depth == 1, let previous = recent.last, case .name("Length") = previous.kind { directLength = value }
            case .keyword("R"):
                guard recent.count >= 2,
                      case let .integer(target) = recent[recent.count - 2].kind,
                      case .integer = recent[recent.count - 1].kind
                else { break }
                let key = recent.count >= 3 ? recent[recent.count - 3] : nil
                if let key, case .name("Metadata") = key.kind {
                    info.metadataReferences.append((target, key.range.lowerBound ..< token.range.upperBound))
                } else {
                    if depth == 1, let key, case .name("Length") = key.kind { directLength = nil }
                    info.otherReferences.insert(target)
                }
            default:
                break
            }
            recent.append(token)
            if recent.count > 3 { recent.removeFirst() }
        }
        return nil
    }

    // MARK: - Tokens

    private struct Token {
        enum Kind {
            case integer(Int)
            case name(String)
            case keyword(String)
            case dictionaryStart
            case dictionaryEnd
            case other
            /// Syntax this lexer cannot delimit with certainty.
            case invalid
        }

        let kind: Kind
        let range: Range<Int>
    }

    /// Tokenizes PDF object syntax far enough to tell keys and references from
    /// string contents; it never enters stream data.
    private struct Lexer {
        let bytes: [UInt8]
        var position: Int
        let end: Int

        private static let whitespace: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        private static let delimiters: Set<UInt8> = Set("()<>[]{}/%".utf8)

        mutating func next() -> Token? {
            while position < end {
                let byte = bytes[position]
                if Self.whitespace.contains(byte) {
                    position += 1
                } else if byte == UInt8(ascii: "%") {
                    while position < end, bytes[position] != 10, bytes[position] != 13 { position += 1 }
                } else {
                    break
                }
            }
            guard position < end else { return nil }
            let start = position
            switch bytes[position] {
            case UInt8(ascii: "("):
                var depth = 0
                while position < end {
                    let byte = bytes[position]
                    position += 1
                    if byte == UInt8(ascii: "\\") { position += 1 }
                    else if byte == UInt8(ascii: "(") { depth += 1 }
                    else if byte == UInt8(ascii: ")") { depth -= 1; if depth == 0 { break } }
                }
                return Token(kind: .other, range: start ..< min(position, end))
            case UInt8(ascii: "<"):
                if position + 1 < end, bytes[position + 1] == UInt8(ascii: "<") {
                    position += 2
                    return Token(kind: .dictionaryStart, range: start ..< position)
                }
                // A hex string holds hex digits and whitespace only; anything else
                // means the closing bracket found here would not be its own.
                position += 1
                while position < end, bytes[position] != UInt8(ascii: ">") {
                    let byte = bytes[position]
                    let isHexDigit = (48 ... 57).contains(byte) || (65 ... 70).contains(byte) || (97 ... 102).contains(byte)
                    guard isHexDigit || Self.whitespace.contains(byte) else {
                        position = end
                        return Token(kind: .invalid, range: start ..< end)
                    }
                    position += 1
                }
                guard position < end else { return Token(kind: .invalid, range: start ..< end) }
                position += 1
                return Token(kind: .other, range: start ..< position)
            case UInt8(ascii: ">"):
                guard position + 1 < end, bytes[position + 1] == UInt8(ascii: ">") else {
                    position = end
                    return Token(kind: .invalid, range: start ..< end)
                }
                position += 2
                return Token(kind: .dictionaryEnd, range: start ..< position)
            case UInt8(ascii: "/"):
                position += 1
                let nameStart = position
                advancePastRegularCharacters()
                let name = String(decoding: bytes[nameStart ..< position], as: UTF8.self)
                return Token(kind: .name(name), range: start ..< position)
            case UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: ")"):
                position += 1
                return Token(kind: .other, range: start ..< position)
            default:
                advancePastRegularCharacters()
                let text = String(decoding: bytes[start ..< position], as: UTF8.self)
                if text.count <= 18, !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let value = Int(text) {
                    return Token(kind: .integer(value), range: start ..< position)
                }
                return Token(kind: .keyword(text), range: start ..< position)
            }
        }

        /// Called right after the `stream` keyword; leaves the position on `endstream`.
        /// Only a declared length that lands there is trusted: searching for the
        /// marker would let stream contents pass for objects.
        mutating func skipStreamData(length: Int) -> Bool {
            if position < end, bytes[position] == 13 { position += 1 }
            if position < end, bytes[position] == 10 { position += 1 }
            let marker = Array("endstream".utf8)
            guard length >= 0, length <= end - position else { return false }
            var candidate = position + length
            while candidate < end, bytes[candidate] == 13 || bytes[candidate] == 10 { candidate += 1 }
            guard candidate + marker.count <= end, Array(bytes[candidate ..< candidate + marker.count]) == marker else {
                return false
            }
            position = candidate
            return true
        }

        private mutating func advancePastRegularCharacters() {
            while position < end, !Self.whitespace.contains(bytes[position]), !Self.delimiters.contains(bytes[position]) {
                position += 1
            }
        }
    }
}
