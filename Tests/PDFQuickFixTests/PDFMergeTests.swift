import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFMergeTests: XCTestCase {
    
    func testMerge() throws {
        // Given
        let url1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 3, textPrefix: "Doc1")
        let url2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Doc2")
        
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        
        // When
        let resultURL = try PDFMerge.merge(urls: [url1, url2], outputURL: outputURL)
        
        // Then
        let mergedDoc = PDFDocument(url: resultURL)!
        XCTAssertEqual(mergedDoc.pageCount, 5)
        
        // Clean up
        try? FileManager.default.removeItem(at: outputURL)
    }
}
