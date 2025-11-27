import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFOpsTests: XCTestCase {
    
    func testApplyWatermark() throws {
        // Given
        let url = try TestPDFBuilder.makeSimplePDF(text: "Original")
        let document = PDFDocument(url: url)!
        
        // When
        PDFOps.applyWatermark(document: document,
                              text: "CONFIDENTIAL",
                              fontSize: 24,
                              color: .red,
                              opacity: 0.5,
                              rotation: 45,
                              position: .center,
                              margin: 10)
        
        // Then
        let page = document.page(at: 0)!
        let annotations = page.annotations
        let watermark = annotations.first { $0.contents == "CONFIDENTIAL" }
        
        XCTAssertNotNil(watermark)
        XCTAssertEqual(watermark?.type, "FreeText")
        // Note: Exact color/font checks might be tricky due to PDFKit internals, 
        // but we verified the content and existence.
    }
    
    func testApplyHeaderFooter() throws {
        // Given
        let url = try TestPDFBuilder.makeSimplePDF()
        let document = PDFDocument(url: url)!
        
        // When
        PDFOps.applyHeaderFooter(document: document,
                                 header: "Top Secret",
                                 footer: "Page 1",
                                 margin: 20,
                                 fontSize: 12)
        
        // Then
        let page = document.page(at: 0)!
        let annotations = page.annotations
        
        let header = annotations.first { $0.contents == "Top Secret" }
        let footer = annotations.first { $0.contents == "Page 1" }
        
        XCTAssertNotNil(header)
        XCTAssertNotNil(footer)
    }
    
    func testCrop() throws {
        // Given
        let url = try TestPDFBuilder.makeSimplePDF(size: CGSize(width: 200, height: 200))
        let document = PDFDocument(url: url)!
        let originalBox = document.page(at: 0)!.bounds(for: .mediaBox)
        
        // When
        PDFOps.crop(document: document, inset: 10, target: .allPages)
        
        // Then
        let page = document.page(at: 0)!
        let newBox = page.bounds(for: .mediaBox)
        
        XCTAssertEqual(newBox.width, originalBox.width - 20)
        XCTAssertEqual(newBox.height, originalBox.height - 20)
        XCTAssertEqual(newBox.origin.x, originalBox.origin.x + 10)
        XCTAssertEqual(newBox.origin.y, originalBox.origin.y + 10)
    }
}
