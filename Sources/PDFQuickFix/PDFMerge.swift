import Foundation
import PDFKit

enum PDFMerge {
    static func merge(urls: [URL], outputURL: URL) throws -> URL {
        guard let firstURL = urls.first else {
            throw NSError(domain: "PDFQuickFix", code: -50, userInfo: [NSLocalizedDescriptionKey: "No PDFs selected"])
        }
        guard let baseDocument = PDFDocument(url: firstURL) else {
            throw NSError(domain: "PDFQuickFix", code: -51, userInfo: [NSLocalizedDescriptionKey: "Unable to open first PDF"])
        }
        
        for url in urls.dropFirst() {
            guard let document = PDFDocument(url: url) else { continue }
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
