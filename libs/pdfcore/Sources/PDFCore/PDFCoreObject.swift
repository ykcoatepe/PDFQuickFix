import Foundation

public enum PDFCoreObject: Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case name(String)
    case string(String)
    /// Parsed PDF string bytes whose encoding must be preserved verbatim.
    case byteString(Data)
    case array([PDFCoreObject])
    case dict([String: PDFCoreObject])
    case indirectRef(object: Int, generation: Int)
    case stream(PDFCoreStream)
}

public struct PDFCoreStream: Equatable {
    public let dictionary: [String: PDFCoreObject]
    public let data: Data

    public init(dictionary: [String: PDFCoreObject], data: Data) {
        self.dictionary = dictionary
        self.data = data
    }
}
