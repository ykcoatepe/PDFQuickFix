import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

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

    /// Redaction covers the text until the document is flattened; a print of the
    /// live document would let the print panel's Save as PDF keep that text.
    func testPrintingARedactedDocumentUsesAFlattenedCopy() throws {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.string = "TOPSECRET printable text"
        let document = try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertTrue(document.string?.contains("TOPSECRET") ?? false)
        let cover = PDFAnnotation(bounds: page.bounds(for: .cropBox), forType: .square, withProperties: nil)
        cover.color = .black
        cover.interiorColor = .black
        cover.userName = PDFOps.replacementTextAnnotationUserName
        page.addAnnotation(cover)

        let printable = try DocumentPrintService.documentForPrinting(document)

        XCTAssertFalse(printable === document)
        XCTAssertEqual(printable.pageCount, 1)
        XCTAssertFalse(printable.string?.contains("TOPSECRET") ?? false)
        let written = try XCTUnwrap(printable.dataRepresentation())
        XCTAssertFalse(PDFDocument(data: written)?.string?.contains("TOPSECRET") ?? true)
        XCTAssertNotNil(DocumentPrintService.makePrintOperation(for: document, jobTitle: "Redacted"))
    }

    func testPrintingAnUnredactedDocumentUsesTheDocumentItself() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Plain")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))

        XCTAssertTrue(try DocumentPrintService.documentForPrinting(document) === document)
    }
}
