import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class EditingToolsTests: XCTestCase {
    func testAddFreeTextUsesProvidedText() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Free text target")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let view = PDFView()
        view.document = document

        EditingTools.addFreeText(in: view, text: "Review note")

        let page = try XCTUnwrap(document.page(at: 0))
        let freeText = try XCTUnwrap(page.annotations.first { $0.type == "FreeText" })
        XCTAssertEqual(freeText.contents, "Review note")
    }

    func testAddLinkCreatesEditableLinkAnnotation() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Link target")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let view = PDFView()
        view.document = document

        EditingTools.addLink(in: view, urlString: "https://pdfquickfix.local")

        let page = try XCTUnwrap(document.page(at: 0))
        let link = try XCTUnwrap(page.annotations.first { $0.type == "Link" })
        XCTAssertEqual(link.url?.absoluteString, "https://pdfquickfix.local")
        XCTAssertEqual(page.annotations.count, 1)
    }

    func testAddNoteCreatesTextAnnotation() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Note target")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let view = PDFView()
        view.document = document

        EditingTools.addNote(in: view, text: "Follow up")

        let page = try XCTUnwrap(document.page(at: 0))
        let note = try XCTUnwrap(page.annotations.first { $0.type == "Text" })
        XCTAssertEqual(note.contents, "Follow up")
    }
}
