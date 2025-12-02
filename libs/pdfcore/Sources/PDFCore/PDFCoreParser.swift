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
    private let lexer: PDFCoreLexer
    private let data: Data
    
    // Store (objectNumber, stream) for delayed processing
    private var objStmCandidates: [(Int, PDFCoreStream)] = []
    
    public init(data: Data) {
        self.data = data
        self.lexer = PDFCoreLexer(data: data)
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
        
        guard let finalTrailer = primaryTrailer, case .dict(let dict) = finalTrailer else {
            throw PDFCoreError.invalidTrailer
        }
        
        var rootRef: PDFCoreObjectRef?
        if case .indirectRef(let obj, let gen) = dict["Root"] {
            rootRef = PDFCoreObjectRef(objectNumber: obj, generation: gen)
        }
        
        var infoRef: PDFCoreObjectRef?
        if case .indirectRef(let obj, let gen) = dict["Info"] {
            infoRef = PDFCoreObjectRef(objectNumber: obj, generation: gen)
        }
        
        // 5. Parse Objects
        var objects: [PDFCoreObjectRef: PDFCoreObject] = [:]
        
        for (objRef, offset) in masterEntries {
            // Safety check for offset
            guard offset < data.count else {
                throw PDFCoreError.syntax("Object offset out of bounds")
            }
            
            lexer.seek(to: offset)
            // Expect: num gen obj ... endobj
            guard let t1 = lexer.nextToken(), case .number(let nStr) = t1, Int(nStr) == objRef.objectNumber,
                  let t2 = lexer.nextToken(), case .number(let genStr) = t2,
                  let t3 = lexer.nextToken(), case .keyword("obj") = t3 else {
                continue // Skip invalid object start
            }

            let obj = try parseObject()
            
            // Check for ObjStm
            if case .stream(let stream) = obj,
               case .name(let type) = stream.dictionary["Type"],
               type == "ObjStm" {
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
            
            while true {
                guard let firstToken = lexer.nextToken() else { break }
                if case .keyword("trailer") = firstToken { break } // End of xref
                
                guard case .number(let startStr) = firstToken,
                      let startObj = Int(startStr),
                      let countToken = lexer.nextToken(),
                      case .number(let countStr) = countToken,
                      let count = Int(countStr) else {
                    throw PDFCoreError.invalidXRef
                }
                
                for i in 0..<count {
                    guard let offsetToken = lexer.nextToken(), case .number(let offsetStr) = offsetToken,
                          let genToken = lexer.nextToken(), case .number(let genStr) = genToken,
                          let typeToken = lexer.nextToken(), case .keyword(let type) = typeToken else {
                        throw PDFCoreError.invalidXRef
                    }
                    
                    switch type {
                    case "n":
                        if let offset = Int(offsetStr), let gen = Int(genStr) {
                            let ref = PDFCoreObjectRef(objectNumber: startObj + i, generation: gen)
                            entries[ref] = offset
                        }
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
                  case .stream(let stream) = xrefObj else {
                throw PDFCoreError.invalidXRef
            }
            
            // Validate Type
            if case .name(let type) = stream.dictionary["Type"], type == "XRef" {
                try parseXRefStream(stream: stream, into: &entries, freed: &freed)
                trailer = .dict(stream.dictionary)
            } else {
                throw PDFCoreError.invalidXRef
            }
        }
        
        // Extract /Prev
        if case .dict(let dict) = trailer,
           let prevObj = dict["Prev"],
           case .int(let prev) = prevObj {
            prevOffset = prev
        }
        
        return XRefResult(entries: entries, freedObjects: freed, trailer: trailer, prevOffset: prevOffset)
    }
    
    private func findStartXref() throws -> Int {
        // Search backwards from end
        let searchRange = max(0, data.count - 1024)..<data.count
        let chunk = data.subdata(in: searchRange)
        guard let string = String(data: chunk, encoding: .isoLatin1),
              let range = string.range(of: "startxref", options: .backwards) else {
            throw PDFCoreError.missingStartXRef
        }
        
        // Parse offset after startxref
        let suffix = string[range.upperBound...]
        let scanner = Scanner(string: String(suffix))
        if let offset = scanner.scanInt() {
            return offset
        }
        throw PDFCoreError.missingStartXRef
    }
    
    private func parseObject() throws -> PDFCoreObject {
        guard let token = lexer.nextToken() else { throw PDFCoreError.syntax("Unexpected EOF") }
        
        switch token {
        case .number(let s):
            // Check if it's an indirect ref: number number R
            let saved = lexer.currentOffset()
            if let t2 = lexer.nextToken(), case .number(let gStr) = t2,
               let t3 = lexer.nextToken(), case .keyword("R") = t3 {
                return .indirectRef(object: Int(s) ?? 0, generation: Int(gStr) ?? 0)
            }
            lexer.seek(to: saved)
            return .int(Int(s) ?? 0)
        case .real(let s):
            return .real(Double(s) ?? 0.0)
        case .name(let s):
            return .name(s)
        case .string(let s):
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
            if case .dict(let dict) = dictObj {
                let saved = lexer.currentOffset()
                if let next = lexer.nextToken(), case .keyword("stream") = next {
                    // It's a stream
                    // Determine length if possible
                    var length: Int? = nil
                    if let lenObj = dict["Length"], case .int(let l) = lenObj {
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
            
            guard case .name(let key) = keyToken else {
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
        guard let t1 = lexer.nextToken(), case .number(_) = t1,
              let t2 = lexer.nextToken(), case .number(_) = t2,
              let t3 = lexer.nextToken(), case .keyword("obj") = t3 else {
            throw PDFCoreError.syntax("Expected object start at offset \(offset)")
        }
        return try parseObject()
    }
    
    private func parseXRefStream(stream: PDFCoreStream, into offsets: inout [PDFCoreObjectRef: Int], freed: inout Set<Int>) throws {
        // 1. Check Filter
        if let filter = stream.dictionary["Filter"] {
            if case .name(let name) = filter, name == "FlateDecode" {
                // OK
            } else if case .array(let arr) = filter, arr.isEmpty {
                // Empty array OK?
            } else {
                throw PDFCoreError.unsupportedFeature("xrefFilter: \(filter)")
            }
        }
        
        // 2. Get W (Widths)
        guard let wObj = stream.dictionary["W"], case .array(let wArr) = wObj, wArr.count >= 3,
              case .int(let w0) = wArr[0],
              case .int(let w1) = wArr[1],
              case .int(let w2) = wArr[2] else {
            throw PDFCoreError.invalidXRef
        }
        
        // 3. Get Index (Optional, default [0 Size])
        var index: [Int] = []
        if let idxObj = stream.dictionary["Index"], case .array(let idxArr) = idxObj {
            for item in idxArr {
                if case .int(let val) = item { index.append(val) }
            }
        } else {
            if let sizeObj = stream.dictionary["Size"], case .int(let size) = sizeObj {
                index = [0, size]
            } else {
                throw PDFCoreError.invalidXRef
            }
        }
        
        // 4. Decompress Data
        let decompressedData: Data
        if let filter = stream.dictionary["Filter"], case .name("FlateDecode") = filter {
            // Simple zlib inflate
            do {
                decompressedData = try (stream.data as NSData).decompressed(using: .zlib) as Data
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
            let count = index[idxPtr+1]
            idxPtr += 2
            
            for i in 0..<count {
                guard cursor + entrySize <= decompressedData.count else { break }
                
                let type = readInt(from: decompressedData, at: cursor, width: w0)
                let field2 = readInt(from: decompressedData, at: cursor + w0, width: w1)
                let field3 = readInt(from: decompressedData, at: cursor + w0 + w1, width: w2)
                
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
    
    private func readInt(from data: Data, at offset: Int, width: Int) -> Int {
        if width == 0 { return 0 }
        var value = 0
        for i in 0..<width {
            value = (value << 8) | Int(data[offset + i])
        }
        return value
    }
    
    private func processObjectStreams(into objects: inout [PDFCoreObjectRef: PDFCoreObject]) throws {
        for (objNum, stream) in objStmCandidates {
            try decodeObjectStream(stream, objNum: objNum, into: &objects)
        }
    }
    
    private func decodeObjectStream(_ stream: PDFCoreStream, objNum: Int, into objects: inout [PDFCoreObjectRef: PDFCoreObject]) throws {
        // 1. Check Filter (only FlateDecode or nil allowed for Level 1)
        if let filter = stream.dictionary["Filter"] {
            if case .name(let name) = filter, name == "FlateDecode" {
                // OK
            } else if case .array(let arr) = filter, arr.isEmpty {
                // OK
            } else {
                throw PDFCoreError.unsupportedFeature("complexObjStm (filter: \(filter))")
            }
        }
        
        // 2. Decompress
        let decompressedData: Data
        if let filter = stream.dictionary["Filter"], case .name("FlateDecode") = filter {
            do {
                decompressedData = try (stream.data as NSData).decompressed(using: .zlib) as Data
            } catch {
                throw PDFCoreError.syntax("Failed to decompress ObjStm \(objNum): \(error)")
            }
        } else {
            decompressedData = stream.data
        }
        
        // 3. Get /N and /First
        guard let nObj = stream.dictionary["N"], case .int(let n) = nObj,
              let firstObj = stream.dictionary["First"], case .int(let first) = firstObj else {
            // Invalid ObjStm, maybe ignore or throw?
            // Throwing ensures we don't silently fail on corrupt critical data
            throw PDFCoreError.syntax("ObjStm \(objNum) missing /N or /First")
        }
        
        // 4. Parse Index
        // The first `first` bytes contain N pairs of integers.
        // We can use a temporary lexer on the decompressed data.
        let subLexer = PDFCoreLexer(data: decompressedData)
        
        var pairs: [(Int, Int)] = [] // (objNum, offset)
        for _ in 0..<n {
            guard let t1 = subLexer.nextToken(), case .number(let numStr) = t1, let oNum = Int(numStr),
                  let t2 = subLexer.nextToken(), case .number(let offStr) = t2, let oOff = Int(offStr) else {
                throw PDFCoreError.syntax("ObjStm \(objNum) invalid index")
            }
            pairs.append((oNum, oOff))
        }
        
        // 5. Parse Objects
        for (oNum, oOff) in pairs {
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
    
    // Helper to parse using a specific lexer instance
    private func parseObject(with customLexer: PDFCoreLexer) throws -> PDFCoreObject {
        guard let token = customLexer.nextToken() else { throw PDFCoreError.syntax("Unexpected EOF in ObjStm") }
        
        switch token {
        case .number(let s):
            // Check if it's an indirect ref: number number R
            let saved = customLexer.currentOffset()
            if let t2 = customLexer.nextToken(), case .number(let gStr) = t2,
               let t3 = customLexer.nextToken(), case .keyword("R") = t3 {
                return .indirectRef(object: Int(s) ?? 0, generation: Int(gStr) ?? 0)
            }
            customLexer.seek(to: saved)
            return .int(Int(s) ?? 0)
        case .real(let s):
            return .real(Double(s) ?? 0.0)
        case .name(let s):
            return .name(s)
        case .string(let s):
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
            let dictObj = try parseDictContent(with: customLexer)
            // Check for stream is NOT allowed in ObjStm (streams cannot be inside ObjStm)
            return dictObj
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
            guard case .name(let key) = keyToken else { continue }
            let value = try parseObject(with: customLexer)
            dict[key] = value
        }
        return .dict(dict)
    }
}
