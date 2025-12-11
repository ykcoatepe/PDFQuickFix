import Foundation

public struct PDFCoreWriter {
    public static func write(document: PDFCoreDocument) throws -> Data {
        var data = Data()
        
        // 1. Header
        data.append("%PDF-1.4\n".data(using: .ascii)!)
        
        // 2. Objects
        var offsets: [PDFCoreObjectRef: Int] = [:]
        
        // Sort objects by number
        let sortedObjects = document.objects.sorted {
            if $0.key.objectNumber == $1.key.objectNumber {
                return $0.key.generation < $1.key.generation
            }
            return $0.key.objectNumber < $1.key.objectNumber
        }
        
        for (ref, obj) in sortedObjects {
            offsets[ref] = data.count
            data.append("\(ref.objectNumber) \(ref.generation) obj\n".data(using: .ascii)!)
            data.append(try serialize(object: obj))
            data.append("\nendobj\n".data(using: .ascii)!)
        }
        
        // 3. Xref
        let startXref = data.count
        data.append("xref\n".data(using: .ascii)!)
        
        // Assume single section 0..N
        let maxObjNum = sortedObjects.last?.key.objectNumber ?? 0
        data.append("0 \(maxObjNum + 1)\n".data(using: .ascii)!)
        
        // Entry 0
        data.append("0000000000 65535 f \n".data(using: .ascii)!)
        
        var offsetEntries: [Int: (offset: Int, generation: Int)] = [:]
        for (ref, offset) in offsets {
            offsetEntries[ref.objectNumber] = (offset, ref.generation)
        }

        for i in 1...maxObjNum {
            if let entry = offsetEntries[i] {
                let offsetStr = String(format: "%010d", entry.offset)
                let genStr = String(format: "%05d", entry.generation)
                data.append("\(offsetStr) \(genStr) n \n".data(using: .ascii)!)
            } else {
                // Missing object? Should not happen in valid doc, but handle gracefully
                data.append("0000000000 00000 f \n".data(using: .ascii)!)
            }
        }
        
        // 4. Trailer
        data.append("trailer\n".data(using: .ascii)!)
        var trailerDict: [String: PDFCoreObject] = [:]
        trailerDict["Size"] = .int(maxObjNum + 1)
        
        if let root = document.rootRef {
            trailerDict["Root"] = .indirectRef(object: root.objectNumber, generation: root.generation)
        }
        if let info = document.infoRef {
            trailerDict["Info"] = .indirectRef(object: info.objectNumber, generation: info.generation)
        }
        
        data.append(try serialize(object: .dict(trailerDict)))
        data.append("\n".data(using: .ascii)!)
        
        // 5. Startxref
        data.append("startxref\n".data(using: .ascii)!)
        data.append("\(startXref)\n".data(using: .ascii)!)
        data.append("%%EOF\n".data(using: .ascii)!)
        
        return data
    }
    
    private static func serialize(object: PDFCoreObject) throws -> Data {
        switch object {
        case .null:
            return "null".data(using: .ascii)!
        case .bool(let b):
            return (b ? "true" : "false").data(using: .ascii)!
        case .int(let i):
            return "\(i)".data(using: .ascii)!
        case .real(let d):
            return "\(d)".data(using: .ascii)!
        case .name(let s):
            return "/\(s)".data(using: .utf8)!
        case .string(let s):
            // Simple escaping
            let escaped = s.replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
            return "(\(escaped))".data(using: .utf8)!
        case .array(let arr):
            var d = "[".data(using: .ascii)!
            for (i, item) in arr.enumerated() {
                if i > 0 { d.append(" ".data(using: .ascii)!) }
                d.append(try serialize(object: item))
            }
            d.append("]".data(using: .ascii)!)
            return d
        case .dict(let dict):
            var d = "<<".data(using: .ascii)!
            for (key, val) in dict {
                d.append(" /".data(using: .ascii)!)
                d.append(key.data(using: .utf8)!)
                d.append(" ".data(using: .ascii)!)
                d.append(try serialize(object: val))
            }
            d.append(" >>".data(using: .ascii)!)
            return d
        case .indirectRef(let obj, let gen):
            return "\(obj) \(gen) R".data(using: .ascii)!
        case .stream(let s):
            var dict = s.dictionary
            dict["Length"] = .int(s.data.count)
            var d = try serialize(object: .dict(dict))
            d.append("\nstream\n".data(using: .ascii)!)
            d.append(s.data)
            d.append("\nendstream".data(using: .ascii)!)
            return d
        }
    }
}
