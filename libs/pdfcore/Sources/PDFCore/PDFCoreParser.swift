import Compression
import Foundation

public enum PDFCoreError: Error, Equatable {
    case invalidHeader
    case missingStartXRef
    case invalidXRef
    case invalidTrailer
    case unsupportedFeature(String)
    case syntax(String)
}

public class PDFCoreParser {
    private static let maxCrossReferenceEntries = 1_000_000
    private static let maxDecompressedStreamBytes = 16 * 1024 * 1024
    private let lexer: PDFCoreLexer
    private let data: Data

    /// Store (objectNumber, stream) for delayed processing
    private var objStmCandidates: [(Int, PDFCoreStream)] = []

    public init(data: Data) {
        self.data = data
        lexer = PDFCoreLexer(data: data)
    }

    public func parseDocument() throws -> PDFCoreDocument {
        // 1. Validate Header
        lexer.seek(to: 0)
        guard let header = lexer.readLine(), header.hasPrefix("%PDF-") else {
            throw PDFCoreError.invalidHeader
        }

        // 2. Find startxref
        let startXrefOffset = try findStartXref()

        // 3. Parse xref chain (Incremental Updates)
        var masterEntries: [PDFCoreObjectRef: Int] = [:]
        var deletedObjects = Set<Int>() // Object numbers freed in newer revisions
        var primaryTrailer: PDFCoreObject?
        var currentOffset = startXrefOffset
        var visitedOffsets = Set<Int>()

        while true {
            // Prevent cycles
            if visitedOffsets.contains(currentOffset) { break }
            visitedOffsets.insert(currentOffset)

            // Parse this section
            let result = try parseXRef(at: currentOffset)

            // Record frees first so older revisions don't revive them
            for freed in result.freedObjects {
                deletedObjects.insert(freed)
                // In case a later section listed an offset for the same object number, drop it
                masterEntries = masterEntries.filter { $0.key.objectNumber != freed }
            }

            // Merge entries (keep existing, as we start from newest)
            for (ref, offset) in result.entries {
                if deletedObjects.contains(ref.objectNumber) { continue }
                if masterEntries[ref] == nil {
                    masterEntries[ref] = offset
                }
            }

            // Keep the first (newest) trailer as primary
            if primaryTrailer == nil {
                primaryTrailer = result.trailer
            }

            // Move to previous
            if let prev = result.prevOffset {
                currentOffset = prev
            } else {
                break
            }
        }

        guard let finalTrailer = primaryTrailer, case let .dict(dict) = finalTrailer else {
            throw PDFCoreError.invalidTrailer
        }

        var rootRef: PDFCoreObjectRef?
        if case let .indirectRef(obj, gen) = dict["Root"] {
            rootRef = PDFCoreObjectRef(objectNumber: obj, generation: gen)
        }

        var infoRef: PDFCoreObjectRef?
        if case let .indirectRef(obj, gen) = dict["Info"] {
            infoRef = PDFCoreObjectRef(objectNumber: obj, generation: gen)
        }

        // 5. Parse Objects
        var objects: [PDFCoreObjectRef: PDFCoreObject] = [:]

        for (objRef, offset) in masterEntries {
            // Safety check for offset
            guard offset >= 0, offset < data.count else {
                throw PDFCoreError.syntax("Object offset out of bounds")
            }

            lexer.seek(to: offset)
            // Expect: num gen obj ... endobj
            guard let t1 = lexer.nextToken(), case let .number(nStr) = t1, Int(nStr) == objRef.objectNumber,
                  let t2 = lexer.nextToken(), case let .number(genStr) = t2,
                  let t3 = lexer.nextToken(), case .keyword("obj") = t3
            else {
                continue // Skip invalid object start
            }

            let obj = try parseObject()

            // Check for ObjStm
            if case let .stream(stream) = obj,
               case let .name(type) = stream.dictionary["Type"],
               type == "ObjStm"
            {
                objStmCandidates.append((objRef.objectNumber, stream))
            }

            let headerGen = Int(genStr) ?? objRef.generation
            let ref = PDFCoreObjectRef(objectNumber: objRef.objectNumber, generation: headerGen)
            objects[ref] = obj
        }

        // 6. Process Object Streams
        try processObjectStreams(into: &objects)

        return PDFCoreDocument(objects: objects, rootRef: rootRef, infoRef: infoRef)
    }

    private struct XRefResult {
        let entries: [PDFCoreObjectRef: Int]
        let freedObjects: Set<Int> // object numbers marked free in this section
        let trailer: PDFCoreObject
        let prevOffset: Int?
    }

    private func parseXRef(at offset: Int) throws -> XRefResult {
        guard offset >= 0, offset < data.count else {
            throw PDFCoreError.invalidXRef
        }
        lexer.seek(to: offset)
        let tokenAtXref = lexer.nextToken()
        lexer.seek(to: offset) // Reset

        var entries: [PDFCoreObjectRef: Int] = [:]
        var trailer: PDFCoreObject
        var prevOffset: Int?
        var freed: Set<Int> = []

        if case .keyword("xref") = tokenAtXref {
            // Classic XRef Table
            guard let token = lexer.nextToken(), case .keyword("xref") = token else {
                throw PDFCoreError.invalidXRef
            }

            var classicEntryCount = 0
            while true {
                guard let firstToken = lexer.nextToken() else { break }
                if case .keyword("trailer") = firstToken { break } // End of xref

                guard case let .number(startStr) = firstToken,
                      let startObj = Int(startStr),
                      let countToken = lexer.nextToken(),
                      case let .number(countStr) = countToken,
                      let count = Int(countStr),
                      startObj >= 0,
                      count >= 0,
                      count <= Self.maxCrossReferenceEntries - classicEntryCount,
                      startObj <= Int.max - count
                else {
                    throw PDFCoreError.invalidXRef
                }
                classicEntryCount += count

                for i in 0 ..< count {
                    guard let offsetToken = lexer.nextToken(), case let .number(offsetStr) = offsetToken,
                          let genToken = lexer.nextToken(), case let .number(genStr) = genToken,
                          let typeToken = lexer.nextToken(), case let .keyword(type) = typeToken
                    else {
                        throw PDFCoreError.invalidXRef
                    }

                    switch type {
                    case "n":
                        guard let offset = Int(offsetStr), offset >= 0,
                              let gen = Int(genStr), gen >= 0
                        else {
                            throw PDFCoreError.invalidXRef
                        }
                        let ref = PDFCoreObjectRef(objectNumber: startObj + i, generation: gen)
                        entries[ref] = offset
                    case "f":
                        freed.insert(startObj + i)
                    default:
                        break
                    }
                }
            }

            // Parse Trailer (Classic)
            guard let trailerToken = lexer.nextToken(), case .dictStart = trailerToken else {
                throw PDFCoreError.invalidTrailer
            }
            trailer = try parseDictContent()

        } else {
            // Assume XRef Stream
            guard let xrefObj = try? parseObjectAt(offset: offset),
                  case let .stream(stream) = xrefObj
            else {
                throw PDFCoreError.invalidXRef
            }

            // Validate Type
            if case let .name(type) = stream.dictionary["Type"], type == "XRef" {
                try parseXRefStream(stream: stream, into: &entries, freed: &freed)
                trailer = .dict(stream.dictionary)
            } else {
                throw PDFCoreError.invalidXRef
            }
        }

        // Extract /Prev
        if case let .dict(dict) = trailer,
           let prevObj = dict["Prev"],
           case let .int(prev) = prevObj
        {
            prevOffset = prev
        }

        return XRefResult(entries: entries, freedObjects: freed, trailer: trailer, prevOffset: prevOffset)
    }

    private func findStartXref() throws -> Int {
        // Search backwards from end
        let searchRange = max(0, data.count - 1024) ..< data.count
        let chunk = data.subdata(in: searchRange)
        guard let string = String(data: chunk, encoding: .isoLatin1),
              let range = string.range(of: "startxref", options: .backwards)
        else {
            throw PDFCoreError.missingStartXRef
        }

        // Parse offset after startxref
        let suffix = string[range.upperBound...]
        let scanner = Scanner(string: String(suffix))
        if let offset = scanner.scanInt() {
            guard offset >= 0, offset < data.count else {
                throw PDFCoreError.missingStartXRef
            }
            return offset
        }
        throw PDFCoreError.missingStartXRef
    }

    private func parseObject() throws -> PDFCoreObject {
        guard let token = lexer.nextToken() else { throw PDFCoreError.syntax("Unexpected EOF") }

        switch token {
        case let .number(s):
            // Check if it's an indirect ref: number number R
            let saved = lexer.currentOffset()
            if let t2 = lexer.nextToken(), case let .number(gStr) = t2,
               let t3 = lexer.nextToken(), case .keyword("R") = t3
            {
                return .indirectRef(object: Int(s) ?? 0, generation: Int(gStr) ?? 0)
            }
            lexer.seek(to: saved)
            return .int(Int(s) ?? 0)
        case let .real(s):
            return .real(Double(s) ?? 0.0)
        case let .name(s):
            return .name(s)
        case let .string(s):
            return .string(s)
        case .keyword("true"):
            return .bool(true)
        case .keyword("false"):
            return .bool(false)
        case .keyword("null"):
            return .null
        case .arrayStart:
            return try parseArray()
        case .dictStart:
            let dictObj = try parseDictContent()
            // Check for stream
            if case let .dict(dict) = dictObj {
                let saved = lexer.currentOffset()
                if let next = lexer.nextToken(), case .keyword("stream") = next {
                    // It's a stream
                    // Determine length if possible
                    var length: Int? = nil
                    if let lenObj = dict["Length"], case let .int(l) = lenObj {
                        length = l
                    }
                    // If Length is indirect, we can't resolve it easily yet without a full object map or a recursive lookup.
                    // For now, if it's indirect, we rely on scanning for endstream.

                    let streamData = lexer.readStreamData(length: length)

                    // Consume 'endstream'
                    if let endToken = lexer.nextToken(), case .keyword("endstream") = endToken {
                        // Good
                    }

                    return .stream(PDFCoreStream(dictionary: dict, data: streamData))
                }
                lexer.seek(to: saved)
                return dictObj
            }
            return dictObj
        case .eof:
            throw PDFCoreError.syntax("Unexpected EOF")
        default:
            return .null
        }
    }

    private func parseArray() throws -> PDFCoreObject {
        var arr: [PDFCoreObject] = []
        while true {
            // Peek next
            let saved = lexer.currentOffset()
            guard let token = lexer.nextToken() else { break }
            if case .arrayEnd = token { break }
            // Handle EOF to prevent infinite loop on malformed PDFs
            if case .eof = token { break }
            lexer.seek(to: saved)

            let obj = try parseObject()
            arr.append(obj)
        }
        return .array(arr)
    }

    private func parseDictContent() throws -> PDFCoreObject {
        var dict: [String: PDFCoreObject] = [:]
        while true {
            guard let keyToken = lexer.nextToken() else { break }
            if case .dictEnd = keyToken { break }

            guard case let .name(key) = keyToken else {
                // Unexpected token in dict key position
                continue
            }

            let value = try parseObject()
            dict[key] = value
        }
        return .dict(dict)
    }

    private func parseObjectAt(offset: Int) throws -> PDFCoreObject {
        lexer.seek(to: offset)
        // Expect: num gen obj
        guard let t1 = lexer.nextToken(), case .number = t1,
              let t2 = lexer.nextToken(), case .number = t2,
              let t3 = lexer.nextToken(), case .keyword("obj") = t3
        else {
            throw PDFCoreError.syntax("Expected object start at offset \(offset)")
        }
        return try parseObject()
    }

    private func parseXRefStream(stream: PDFCoreStream, into offsets: inout [PDFCoreObjectRef: Int], freed: inout Set<Int>) throws {
        // 1. Check Filter - accept bare /FlateDecode or single-element array [/FlateDecode]
        let needsDecompress = Self.isFlateDecode(stream.dictionary["Filter"])
        if let filter = stream.dictionary["Filter"], !Self.isSupportedFilter(filter) {
            throw PDFCoreError.unsupportedFeature("xrefFilter: \(filter)")
        }

        // 2. Get W (Widths)
        guard let wObj = stream.dictionary["W"], case let .array(wArr) = wObj, wArr.count == 3,
              case let .int(w0) = wArr[0],
              case let .int(w1) = wArr[1],
              case let .int(w2) = wArr[2],
              (0 ... 8).contains(w0),
              (0 ... 8).contains(w1),
              (0 ... 8).contains(w2),
              w0 + w1 + w2 > 0
        else {
            throw PDFCoreError.invalidXRef
        }

        // 3. Get Index (Optional, default [0 Size])
        var index: [Int] = []
        if let idxObj = stream.dictionary["Index"], case let .array(idxArr) = idxObj {
            for item in idxArr {
                if case let .int(val) = item { index.append(val) }
            }
        } else {
            if let sizeObj = stream.dictionary["Size"], case let .int(size) = sizeObj {
                index = [0, size]
            } else {
                throw PDFCoreError.invalidXRef
            }
        }
        guard index.count.isMultiple(of: 2) else {
            throw PDFCoreError.invalidXRef
        }
        var totalEntries = 0
        for pairStart in stride(from: 0, to: index.count, by: 2) {
            let start = index[pairStart]
            let count = index[pairStart + 1]
            guard start >= 0,
                  count >= 0,
                  count <= Self.maxCrossReferenceEntries - totalEntries,
                  start <= Int.max - count
            else {
                throw PDFCoreError.invalidXRef
            }
            totalEntries += count
        }

        // 4. Decompress Data
        let decompressedData: Data
        if needsDecompress {
            do {
                decompressedData = try Self.decompressZlib(stream.data)
            } catch {
                throw PDFCoreError.syntax("Failed to decompress XRef stream: \(error)")
            }
        } else {
            decompressedData = stream.data
        }

        // 5. Iterate entries
        let entrySize = w0 + w1 + w2
        var cursor = 0

        // Index array is pairs of [startObj, count]
        var idxPtr = 0
        while idxPtr < index.count {
            let startObj = index[idxPtr]
            let count = index[idxPtr + 1]
            idxPtr += 2

            for i in 0 ..< count {
                guard cursor <= decompressedData.count - entrySize else {
                    throw PDFCoreError.invalidXRef
                }

                let type = if w0 == 0 {
                    1
                } else {
                    try readInt(from: decompressedData, at: cursor, width: w0)
                }
                let field2 = try readInt(from: decompressedData, at: cursor + w0, width: w1)
                let field3 = try readInt(from: decompressedData, at: cursor + w0 + w1, width: w2)

                cursor += entrySize

                let objNum = startObj + i

                switch type {
                case 0: // Free
                    freed.insert(objNum)
                case 1: // Normal
                    // field2 = offset, field3 = gen
                    let offset = field2
                    let gen = field3
                    let ref = PDFCoreObjectRef(objectNumber: objNum, generation: gen)
                    offsets[ref] = offset
                case 2: // Object Stream
                    // We ignore Type 2 entries in the XRef stream because we rely on finding
                    // the Type 1 (ObjStm) object itself in the object list (via standard parsing)
                    // and then decoding it.
                    break
                default:
                    // If w0 == 0, type defaults to 1
                    if w0 == 0 {
                        let offset = field2
                        let gen = field3
                        let ref = PDFCoreObjectRef(objectNumber: objNum, generation: gen)
                        offsets[ref] = offset
                    }
                }
            }
        }
    }

    private func readInt(from data: Data, at offset: Int, width: Int) throws -> Int {
        if width == 0 { return 0 }
        guard offset >= 0, width > 0, offset <= data.count - width else {
            throw PDFCoreError.invalidXRef
        }
        var value: UInt64 = 0
        for i in 0 ..< width {
            value = (value << 8) | UInt64(data[offset + i])
        }
        guard value <= UInt64(Int.max) else { throw PDFCoreError.invalidXRef }
        return Int(value)
    }

    // MARK: - Filter Helpers

    /// Check if filter is FlateDecode (bare name or single-element array)
    private static func isFlateDecode(_ filter: PDFCoreObject?) -> Bool {
        guard let filter else { return false }

        switch filter {
        case let .name(name):
            return name == "FlateDecode"
        case let .array(arr):
            if arr.count == 1, case let .name(name) = arr[0], name == "FlateDecode" {
                return true
            }
        default:
            break
        }
        return false
    }

    /// Check if filter is supported (nil, FlateDecode, or single-element FlateDecode array)
    private static func isSupportedFilter(_ filter: PDFCoreObject) -> Bool {
        switch filter {
        case let .name(name):
            return name == "FlateDecode"
        case let .array(arr):
            // Empty array or single FlateDecode
            if arr.isEmpty { return true }
            if arr.count == 1, case let .name(name) = arr[0], name == "FlateDecode" {
                return true
            }
            return false
        default:
            return false
        }
    }

    private func processObjectStreams(into objects: inout [PDFCoreObjectRef: PDFCoreObject]) throws {
        for (objNum, stream) in objStmCandidates {
            try decodeObjectStream(stream, objNum: objNum, into: &objects)
        }
    }

    private func decodeObjectStream(_ stream: PDFCoreStream, objNum: Int, into objects: inout [PDFCoreObjectRef: PDFCoreObject]) throws {
        // 1. Check Filter - accept bare /FlateDecode or single-element array [/FlateDecode]
        let needsDecompress = Self.isFlateDecode(stream.dictionary["Filter"])
        if let filter = stream.dictionary["Filter"], !Self.isSupportedFilter(filter) {
            throw PDFCoreError.unsupportedFeature("complexObjStm (filter: \(filter))")
        }

        // 2. Decompress
        let decompressedData: Data
        if needsDecompress {
            do {
                decompressedData = try Self.decompressZlib(stream.data)
            } catch {
                throw PDFCoreError.syntax("Failed to decompress ObjStm \(objNum): \(error)")
            }
        } else {
            decompressedData = stream.data
        }

        // 3. Get /N and /First
        guard let nObj = stream.dictionary["N"], case let .int(n) = nObj,
              let firstObj = stream.dictionary["First"], case let .int(first) = firstObj,
              n >= 0,
              n <= Self.maxCrossReferenceEntries,
              first >= 0,
              first <= decompressedData.count
        else {
            // Invalid ObjStm, maybe ignore or throw?
            // Throwing ensures we don't silently fail on corrupt critical data
            throw PDFCoreError.syntax("ObjStm \(objNum) missing /N or /First")
        }

        // 4. Parse Index
        // The first `first` bytes contain N pairs of integers.
        // We can use a temporary lexer on the decompressed data.
        let subLexer = PDFCoreLexer(data: decompressedData)

        var pairs: [(Int, Int)] = [] // (objNum, offset)
        for _ in 0 ..< n {
            guard let t1 = subLexer.nextToken(), case let .number(numStr) = t1, let oNum = Int(numStr),
                  let t2 = subLexer.nextToken(), case let .number(offStr) = t2, let oOff = Int(offStr)
            else {
                throw PDFCoreError.syntax("ObjStm \(objNum) invalid index")
            }
            pairs.append((oNum, oOff))
        }

        // 5. Parse Objects
        for (oNum, oOff) in pairs {
            guard oOff >= 0, oOff <= decompressedData.count - first else {
                throw PDFCoreError.syntax("ObjStm \(objNum) object offset out of bounds")
            }
            let absoluteOffset = first + oOff
            guard absoluteOffset < decompressedData.count else {
                throw PDFCoreError.syntax("ObjStm \(objNum) object offset out of bounds")
            }

            // Re-use subLexer or create new one?
            // Lexer is stateful, so we can just seek.
            subLexer.seek(to: absoluteOffset)

            // Parse single object
            // Note: Objects in ObjStm are NOT followed by 'endobj' usually, just the object itself.
            // But parseObject() expects to parse one full object.
            // The standard says: "The object shall be... a PDF object... The object shall not be followed by endobj"
            // Our parseObject() handles basic types.
            // We need to be careful: parseObject() might consume too much if it expects delimiters that aren't there?
            // Actually, parseObject() just parses one token or structure (dict, array, etc).
            // It does NOT look for 'endobj' unless called by parseDocument loop which checks for it.
            // So calling parseObject() here is correct.

            if let obj = try? parseObject(with: subLexer) {
                let ref = PDFCoreObjectRef(objectNumber: oNum, generation: 0)
                // Only insert if not already present (main body takes precedence)
                if objects[ref] == nil {
                    objects[ref] = obj
                }
            }
        }
    }

    /// Helper to parse using a specific lexer instance
    private func parseObject(with customLexer: PDFCoreLexer) throws -> PDFCoreObject {
        guard let token = customLexer.nextToken() else { throw PDFCoreError.syntax("Unexpected EOF in ObjStm") }

        switch token {
        case let .number(s):
            // Check if it's an indirect ref: number number R
            let saved = customLexer.currentOffset()
            if let t2 = customLexer.nextToken(), case let .number(gStr) = t2,
               let t3 = customLexer.nextToken(), case .keyword("R") = t3
            {
                return .indirectRef(object: Int(s) ?? 0, generation: Int(gStr) ?? 0)
            }
            customLexer.seek(to: saved)
            return .int(Int(s) ?? 0)
        case let .real(s):
            return .real(Double(s) ?? 0.0)
        case let .name(s):
            return .name(s)
        case let .string(s):
            return .string(s)
        case .keyword("true"):
            return .bool(true)
        case .keyword("false"):
            return .bool(false)
        case .keyword("null"):
            return .null
        case .arrayStart:
            return try parseArray(with: customLexer)
        case .dictStart:
            return try parseDictContent(with: customLexer)
        // Check for stream is NOT allowed in ObjStm (streams cannot be inside ObjStm)
        case .eof:
            throw PDFCoreError.syntax("Unexpected EOF in ObjStm")
        default:
            return .null
        }
    }

    private func parseArray(with customLexer: PDFCoreLexer) throws -> PDFCoreObject {
        var arr: [PDFCoreObject] = []
        while true {
            let saved = customLexer.currentOffset()
            guard let token = customLexer.nextToken() else { break }
            if case .arrayEnd = token { break }
            // Handle EOF to prevent infinite loop on malformed PDFs
            if case .eof = token { break }
            customLexer.seek(to: saved)
            let obj = try parseObject(with: customLexer)
            arr.append(obj)
        }
        return .array(arr)
    }

    private func parseDictContent(with customLexer: PDFCoreLexer) throws -> PDFCoreObject {
        var dict: [String: PDFCoreObject] = [:]
        while true {
            guard let keyToken = customLexer.nextToken() else { break }
            if case .dictEnd = keyToken { break }
            guard case let .name(key) = keyToken else { continue }
            let value = try parseObject(with: customLexer)
            dict[key] = value
        }
        return .dict(dict)
    }

    private static func decompressZlib(_ data: Data) throws -> Data {
        guard !data.isEmpty else {
            throw PDFCoreError.syntax("Empty zlib stream")
        }
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { scratch.deallocate() }
        var stream = compression_stream(
            dst_ptr: scratch,
            dst_size: 0,
            src_ptr: UnsafePointer(scratch),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else {
            throw PDFCoreError.syntax("Failed to initialize zlib decoder")
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 64 * 1024
        var output = Data()
        output.reserveCapacity(min(data.count * 4, maxDecompressedStreamBytes))

        return try data.withUnsafeBytes { sourceBuffer in
            guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            stream.src_ptr = source
            stream.src_size = data.count

            var chunk = [UInt8](repeating: 0, count: chunkSize)
            while true {
                let status: compression_status = chunk.withUnsafeMutableBytes { destinationBuffer in
                    stream.dst_ptr = destinationBuffer.bindMemory(to: UInt8.self).baseAddress!
                    stream.dst_size = chunkSize
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = chunkSize - stream.dst_size
                guard produced <= maxDecompressedStreamBytes - output.count else {
                    throw PDFCoreError.syntax("decompressed stream exceeds \(maxDecompressedStreamBytes) bytes")
                }
                output.append(contentsOf: chunk.prefix(produced))

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size > 0 else {
                        throw PDFCoreError.syntax("zlib decoder made no progress")
                    }
                default:
                    throw PDFCoreError.syntax("Failed to decompress zlib stream")
                }
            }
        }
    }
}
