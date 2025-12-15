import Foundation
import PDFKit
import PDFQuickFixKit

enum PDFMerge {
    static func merge(urls: [URL], outputURL: URL) throws -> URL {
        guard let firstURL = urls.first else {
            throw NSError(domain: "PDFQuickFix", code: -50, userInfo: [NSLocalizedDescriptionKey: "No PDFs selected"])
        }
        let baseDocument = try PDFDocumentSanitizer.loadDocument(at: firstURL)

        for url in urls.dropFirst() {
            guard let document = try? PDFDocumentSanitizer.loadDocument(at: url) else { continue }
            var insertionIndex = baseDocument.pageCount
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                baseDocument.insert(page, at: insertionIndex)
                insertionIndex += 1
            }
        }
        
        baseDocument.write(to: outputURL)
        return outputURL
    }
}
