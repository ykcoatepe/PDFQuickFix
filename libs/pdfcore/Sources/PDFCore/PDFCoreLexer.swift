import Foundation

public enum PDFCoreToken: Equatable {
    case number(String)
    case real(String)
    case name(String)
    case string(String)
    case keyword(String)
    case arrayStart
    case arrayEnd
    case dictStart
    case dictEnd
    case eof
}

public class PDFCoreLexer {
    private let data: Data
    private var cursor: Int
    
    public init(data: Data) {
        self.data = data
        self.cursor = 0
    }
    
    public func nextToken() -> PDFCoreToken? {
        skipWhitespaceAndComments()
        
        guard cursor < data.count else { return .eof }
        
        let byte = data[cursor]
        
        switch byte {
        case 0x5B: // [
            cursor += 1
            return .arrayStart
        case 0x5D: // ]
            cursor += 1
            return .arrayEnd
        case 0x3C: // <
            if cursor + 1 < data.count && data[cursor + 1] == 0x3C {
                cursor += 2
                return .dictStart
            } else {
                // Hex string start, simplified for now as string
                return readString()
            }
        case 0x3E: // >
            if cursor + 1 < data.count && data[cursor + 1] == 0x3E {
                cursor += 2
                return .dictEnd
            }
            cursor += 1
            return nil // Should be handled within string parsing usually
        case 0x28: // (
            return readString()
        case 0x2F: // /
            return readName()
        case 0x25: // % - Comment, should be handled by skipWhitespaceAndComments but just in case
            skipComment()
            return nextToken()
        default:
            if isDigit(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E { // +, -, .
                return readNumber()
            } else if isAlpha(byte) {
                return readKeyword()
            }
        }
        
        cursor += 1
        return nil // Unknown char
    }
    
    private func skipWhitespaceAndComments() {
        while cursor < data.count {
            let byte = data[cursor]
            if isWhitespace(byte) {
                cursor += 1
            } else if byte == 0x25 { // %
                skipComment()
            } else {
                break
            }
        }
    }
    
    private func skipComment() {
        while cursor < data.count {
            let byte = data[cursor]
            if byte == 0x0A || byte == 0x0D { // Newline
                break
            }
            cursor += 1
        }
    }
    
    private func readName() -> PDFCoreToken {
        cursor += 1 // Skip /
        let start = cursor
        while cursor < data.count {
            let byte = data[cursor]
            if isWhitespace(byte) || isDelimiter(byte) {
                break
            }
            cursor += 1
        }
        let range = start..<cursor
        let str = String(data: data.subdata(in: range), encoding: .utf8) ?? ""
        return .name(str)
    }
    
    private func readString() -> PDFCoreToken {
        // Simplified string reading (parentheses)
        if data[cursor] == 0x28 {
            cursor += 1
            let start = cursor
            var depth = 1
            while cursor < data.count && depth > 0 {
                let byte = data[cursor]
                if byte == 0x28 { depth += 1 }
                else if byte == 0x29 { depth -= 1 }
                // Handle escapes if needed, simplified for now
                if depth > 0 { cursor += 1 }
            }
            let range = start..<cursor
            cursor += 1 // Skip closing )
            let str = String(data: data.subdata(in: range), encoding: .utf8) ?? ""
            return .string(str)
        }
        // Hex string <...>
        if data[cursor] == 0x3C {
            cursor += 1
            let start = cursor
            while cursor < data.count {
                if data[cursor] == 0x3E { break }
                cursor += 1
            }
            let range = start..<cursor
            cursor += 1 // Skip >
            // TODO: Decode hex
            let str = String(data: data.subdata(in: range), encoding: .utf8) ?? ""
            return .string(str)
        }
        return .string("")
    }
    
    private func readNumber() -> PDFCoreToken {
        let start = cursor
        var isReal = false
        while cursor < data.count {
            let byte = data[cursor]
            if byte == 0x2E { isReal = true }
            if !isDigit(byte) && byte != 0x2E && byte != 0x2B && byte != 0x2D {
                break
            }
            cursor += 1
        }
        let range = start..<cursor
        let str = String(data: data.subdata(in: range), encoding: .utf8) ?? "0"
        return isReal ? .real(str) : .number(str)
    }
    
    private func readKeyword() -> PDFCoreToken {
        let start = cursor
        while cursor < data.count {
            let byte = data[cursor]
            if isWhitespace(byte) || isDelimiter(byte) {
                break
            }
            cursor += 1
        }
        let range = start..<cursor
        let str = String(data: data.subdata(in: range), encoding: .utf8) ?? ""
        return .keyword(str)
    }
    
    private func isWhitespace(_ byte: UInt8) -> Bool {
        return byte == 0x00 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }
    
    private func isDelimiter(_ byte: UInt8) -> Bool {
        return byte == 0x28 || byte == 0x29 || byte == 0x3C || byte == 0x3E || byte == 0x5B || byte == 0x5D || byte == 0x7B || byte == 0x7D || byte == 0x2F || byte == 0x25
    }
    
    private func isDigit(_ byte: UInt8) -> Bool {
        return byte >= 0x30 && byte <= 0x39
    }
    
    private func isAlpha(_ byte: UInt8) -> Bool {
        return (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
    
    // Helper to peek/seek for parser
    public func seek(to offset: Int) {
        cursor = offset
    }
    
    public func currentOffset() -> Int {
        return cursor
    }
    
    public func readLine() -> String? {
        let start = cursor
        while cursor < data.count {
            let byte = data[cursor]
            if byte == 0x0A || byte == 0x0D {
                let range = start..<cursor
                // consume newline
                if byte == 0x0D && cursor + 1 < data.count && data[cursor+1] == 0x0A {
                    cursor += 2
                } else {
                    cursor += 1
                }
                return String(data: data.subdata(in: range), encoding: .utf8)
            }
            cursor += 1
        }
        return nil
    }
    
    public func readStreamData(length: Int?) -> Data {
        // Skip newline after 'stream'
        if cursor < data.count {
            if data[cursor] == 0x0D { cursor += 1 }
            if cursor < data.count && data[cursor] == 0x0A { cursor += 1 }
        }
        
        if let len = length {
            let end = min(cursor + len, data.count)
            let chunk = data.subdata(in: cursor..<end)
            cursor = end
            return chunk
        } else {
            // Scan for endstream
            let start = cursor
            // "endstream" is 0x65 0x6E 0x64 0x73 0x74 0x72 0x65 0x61 0x6D
            // We look for it. Naive search.
            while cursor < data.count {
                if data[cursor] == 0x65 { // e
                    if cursor + 9 <= data.count {
                        let potential = data.subdata(in: cursor..<cursor+9)
                        if let s = String(data: potential, encoding: .ascii), s == "endstream" {
                            // Found it.
                            // Backtrack to remove preceding newline if any?
                            // Spec says EOL before endstream is not part of stream.
                            var streamEnd = cursor
                            if streamEnd > start {
                                if data[streamEnd-1] == 0x0A {
                                    streamEnd -= 1
                                    if streamEnd > start && data[streamEnd-1] == 0x0D {
                                        streamEnd -= 1
                                    }
                                } else if data[streamEnd-1] == 0x0D {
                                    streamEnd -= 1
                                }
                            }
                            let chunk = data.subdata(in: start..<streamEnd)
                            return chunk
                        }
                    }
                }
                cursor += 1
            }
            return Data()
        }
    }
}
