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
        
        // 3. Parse xref
        lexer.seek(to: startXrefOffset)
        
        // Check if it's a classic xref table or an XRef stream
        let tokenAtXref = lexer.nextToken()
        lexer.seek(to: startXrefOffset) // Reset
        
        var objectOffsets: [PDFCoreObjectRef: Int] = [:]
        var trailerDict: PDFCoreObject?
        
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
                    
                    if type == "n" {
                        if let offset = Int(offsetStr), let gen = Int(genStr) {
                            let ref = PDFCoreObjectRef(objectNumber: startObj + i, generation: gen)
                            objectOffsets[ref] = offset
                        }
                    }
                }
            }
            
            // 4. Parse Trailer (Classic)
            guard let trailerToken = lexer.nextToken(), case .dictStart = trailerToken else {
                throw PDFCoreError.invalidTrailer
            }
            trailerDict = try parseDictContent()
            
        } else {
            // Assume XRef Stream (starts with object definition: num gen obj)
            // Parse the object at startXrefOffset
            guard let xrefObj = try? parseObjectAt(offset: startXrefOffset),
                  case .stream(let stream) = xrefObj else {
                throw PDFCoreError.invalidXRef
            }
            
            // Validate Type
            if case .name(let type) = stream.dictionary["Type"], type == "XRef" {
                // It is an XRef Stream
                try parseXRefStream(stream: stream, into: &objectOffsets)
                trailerDict = .dict(stream.dictionary)
            } else {
                throw PDFCoreError.invalidXRef
            }
        }
        
        guard case .dict(let dict) = trailerDict else { throw PDFCoreError.invalidTrailer }
        
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
        
        for (objRef, offset) in objectOffsets {
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
            let headerGen = Int(genStr) ?? objRef.generation
            let ref = PDFCoreObjectRef(objectNumber: objRef.objectNumber, generation: headerGen)
            objects[ref] = obj
        }
        
        return PDFCoreDocument(objects: objects, rootRef: rootRef, infoRef: infoRef)
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
    
    private func parseXRefStream(stream: PDFCoreStream, into offsets: inout [PDFCoreObjectRef: Int]) throws {
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
                    // Ignore
                    break
                case 1: // Normal
                    // field2 = offset, field3 = gen
                    let offset = field2
                    let gen = field3
                    let ref = PDFCoreObjectRef(objectNumber: objNum, generation: gen)
                    offsets[ref] = offset
                case 2: // Object Stream
                    throw PDFCoreError.unsupportedFeature("objectStream")
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
}
