import XCTest
import PDFKit
@testable import PDFQuickFix

@MainActor
final class DocumentPrintServiceTests: XCTestCase {
    func testMakePrintOperationReturnsOperationForValidDocument() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Print Test")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let document = PDFDocument(url: url) else {
            XCTFail("Expected test PDFDocument to load")
            return
        }

        let operation = DocumentPrintService.makePrintOperation(for: document, jobTitle: "UnitTestPrint")
        XCTAssertNotNil(operation)
        XCTAssertEqual(operation?.jobTitle, "UnitTestPrint")
        XCTAssertEqual(operation?.showsPrintPanel, true)
        XCTAssertEqual(operation?.showsProgressPanel, true)
    }

    func testPrintReturnsFalseWhenDocumentMissingWithoutAlert() {
        let result = DocumentPrintService.print(document: nil,
                                               jobTitle: "Missing",
                                               source: "test",
                                               showUnavailableAlert: false)
        XCTAssertFalse(result)
    }
}
