import XCTest
import PDFKit
@testable import PDFQuickFix

final class DocumentValidationRunnerTests: XCTestCase {
    func testThresholdConstants() {
        XCTAssertEqual(DocumentValidationRunner.largeDocumentPageThreshold, 1000)
        XCTAssertEqual(DocumentValidationRunner.massiveDocumentPageThreshold, 2000)
    }

    func testEstimatedPageCountReadsPDF() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 3)
        let count = DocumentValidationRunner.estimatedPageCount(at: url)
        XCTAssertEqual(count, 3)
    }

    func testEstimatedPageCountNilForInvalidURL() {
        let bogus = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        XCTAssertNil(DocumentValidationRunner.estimatedPageCount(at: bogus))
    }

    func testShouldSkipQuickValidationHelper() {
        XCTAssertFalse(DocumentValidationRunner.shouldSkipQuickValidation(estimatedPages: nil,
                                                                          resolvedPageCount: nil))

        XCTAssertFalse(DocumentValidationRunner.shouldSkipQuickValidation(estimatedPages: 1200,
                                                                          resolvedPageCount: 1500))

        XCTAssertTrue(DocumentValidationRunner.shouldSkipQuickValidation(estimatedPages: 2200,
                                                                         resolvedPageCount: 0))

        XCTAssertTrue(DocumentValidationRunner.shouldSkipQuickValidation(estimatedPages: 0,
                                                                         resolvedPageCount: 2000))

        XCTAssertTrue(DocumentValidationRunner.shouldSkipQuickValidation(estimatedPages: 2100,
                                                                         resolvedPageCount: 2500))
    }
}
