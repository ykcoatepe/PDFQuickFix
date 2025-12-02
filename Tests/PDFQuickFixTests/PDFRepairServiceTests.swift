import XCTest
import PDFQuickFixKit
import PDFKit

final class PDFRepairServiceTests: XCTestCase {
    
    func testRepairValidPDF() throws {
        let simplePDF = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>
        endobj
        xref
        0 4
        0000000000 65535 f 
        0000000009 00000 n 
        0000000058 00000 n 
        0000000115 00000 n 
        trailer
        << /Size 4 /Root 1 0 R >>
        startxref
        186
        %%EOF
        """.data(using: .ascii)!
        
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_valid.pdf")
        try simplePDF.write(to: tempURL)
        
        let service = PDFRepairService()
        let resultURL = try service.repairIfNeeded(inputURL: tempURL)
        
        // Should return a new URL (normalized)
        XCTAssertNotEqual(resultURL, tempURL)
        
        // Should be a valid PDF
        XCTAssertNotNil(PDFDocument(url: resultURL))
        
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: resultURL)
    }
    
    func testRepairInvalidPDF() throws {
        let invalidData = "Not a PDF".data(using: .ascii)!
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_invalid.pdf")
        try invalidData.write(to: tempURL)
        
        let service = PDFRepairService()
        let resultURL = try service.repairIfNeeded(inputURL: tempURL)
        
        // Should return original URL (fallback)
        XCTAssertEqual(resultURL, tempURL)
        
        try? FileManager.default.removeItem(at: tempURL)
    }
}
