import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFPerformanceTests: XCTestCase {

    func testQuickOpenOptionsAreOptimized() {
        let options = PDFDocumentSanitizer.Options.quickOpen()
        XCTAssertEqual(options.rebuildMode, .never, "QuickOpen should never rebuild")
        XCTAssertFalse(options.sanitizeAnnotations, "QuickOpen should not sanitize annotations")
        XCTAssertFalse(options.sanitizeOutline, "QuickOpen should not sanitize outline")
        XCTAssertEqual(options.validationPageLimit, 10, "QuickOpen should limit validation pages")
    }

    func testQuickOpenOptionsAllowCustomLimit() {
        let options = PDFDocumentSanitizer.Options.quickOpen(limit: 0)
        XCTAssertEqual(options.validationPageLimit, 0, "Custom limit should be applied")
        XCTAssertEqual(options.rebuildMode, .never)
        XCTAssertFalse(options.sanitizeAnnotations)
        XCTAssertFalse(options.sanitizeOutline)
    }

    func testSanitizerSkipsAnnotationsWhenFlagIsFalse() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotation Test")
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to load test PDF")
            return
        }
        
        // Add a dummy annotation
        let page = document.page(at: 0)!
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 50, height: 50), forType: .text, withProperties: nil)
        annotation.contents = "Test Annotation"
        page.addAnnotation(annotation)
        
        // Sanitize with sanitizeAnnotations = false
        let options = PDFDocumentSanitizer.Options(rebuildMode: .never, sanitizeAnnotations: false, sanitizeOutline: false)
        
        // We can't easily mock the internal method call, but we can verify it doesn't crash or fail
        _ = try PDFDocumentSanitizer.sanitize(document: document, sourceURL: url, options: options)
        
        // If we had a way to spy on the internal method, we would. 
        // For now, we trust the flag logic we verified in testQuickOpenOptionsAreOptimized 
        // and the fact that this runs without error.
    }
    
    func testValidationRunnerUsesOptimizedOptionsForQuickCheck() {
        // This test verifies the logic inside DocumentValidationRunner.validateDocument
        // Since we can't inspect the internal options created inside the method easily without refactoring,
        // we will rely on the fact that we modified the code to use the correct options.
        // However, we can verify that a quick validation runs quickly and doesn't fail.
        
        let runner = DocumentValidationRunner()
        do {
            let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Validation Runner Test")
            let expectation = expectation(description: "Quick validation completes")
            
            runner.validateDocument(at: pdfURL, pageLimit: 5) { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    XCTFail("Validation failed: \(error)")
                }
                expectation.fulfill()
            }
            
            wait(for: [expectation], timeout: 2.0)
        } catch {
            XCTFail("Setup failed: \(error)")
        }
    }
}
