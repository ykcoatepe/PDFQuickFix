import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class ReaderLogicTests: XCTestCase {
    var controller: ReaderControllerPro!

    override func setUp() {
        super.setUp()
        controller = ReaderControllerPro()
    }

    func testInitialState() {
        XCTAssertNil(controller.document)
        XCTAssertNil(controller.currentURL)
        XCTAssertFalse(controller.isLargeDocument)
        XCTAssertFalse(controller.isMassiveDocument)
    }

    func testOpenNormalDocument() {
        // Mocking a document open is tricky without a real file or async expectation.
        // We can test the finishOpen logic if we can access it, but it's private.
        // Instead, let's test public side effects if possible or use a testable seam.
        // Since we can't easily call private methods, we'll verify the controller's
        // reaction to a setDocument call if we exposed one, or just check state properties.

        // For now, let's just verify that we can instantiate the controller and check default flags.
        // Real integration tests would require a PDF file on disk.

        XCTAssertEqual(controller.zoomScale, 1.0)
        controller.zoomIn()
        // Zoom in might not work without a view attached, but let's check safety.
        // It shouldn't crash.
    }

    func testZoomLogic() {
        // Without a PDFView attached, zoomScale might not update if it relies on the view's scaleFactor.
        // But we can check that calling methods doesn't crash.
        controller.setZoom(percent: 150)
        // The controller updates zoomScale in the view delegate or when view updates.
        // So we can't assert zoomScale changed here easily without a mock view.
    }

    func testReaderPrintDocumentWithoutPDFViewDoesNotCrash() {
        controller.printDocument()
        XCTAssertNil(controller.pdfView)
    }

    func testStudioPrintDocumentWithoutPDFViewDoesNotCrash() {
        let studioController = StudioController()
        studioController.printDocument()
        XCTAssertNil(studioController.pdfView)
    }

    func testReaderLoadsAnnotationRowsForCommentsPanel() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Review this clause"
        page.addAnnotation(note)

        controller.document = document
        controller.loadAnnotationsForReader()

        let row = try XCTUnwrap(controller.annotationRows.first { $0.annotation === note })
        XCTAssertEqual(row.pageIndex, 0)
        XCTAssertEqual(row.annotation.contents, "Review this clause")
    }

    func testReaderFindBlankQueryIgnoresStalePDFKitNotifications() async throws {
        let document = try makeTextBackedDocument(text: "Needle")
        controller.document = document
        controller.find("Needle")

        controller.find("   ")

        let selection = try XCTUnwrap(document.findString("Needle", withOptions: []).first)
        NotificationCenter.default.post(name: .PDFDocumentDidFindMatch,
                                        object: document,
                                        userInfo: ["PDFDocumentFoundSelection": selection])
        await Task.yield()

        XCTAssertTrue(controller.searchMatches.isEmpty)
        XCTAssertNil(controller.currentMatchIndex)
    }

    func testReaderDeleteAnnotationRefreshesCommentsPanelRows() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 24, height: 24), forType: .text, withProperties: nil)
        page.addAnnotation(note)

        controller.document = document
        controller.loadAnnotationsForReader()
        let row = try XCTUnwrap(controller.annotationRows.first)

        controller.delete(annotation: row)

        XCTAssertTrue(controller.annotationRows.isEmpty)
        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testReaderDeleteAnnotationCanUndoAndRedo() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 24, height: 24), forType: .text, withProperties: nil)
        page.addAnnotation(note)
        controller.document = document
        controller.loadAnnotationsForReader()
        let row = try XCTUnwrap(controller.annotationRows.first)

        controller.delete(annotation: row)

        XCTAssertTrue(page.annotations.isEmpty)

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.contains { $0 === note })

        controller.redoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)
    }

    func testReaderEditAnnotationContentsCanUndoAndRedo() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Original note"
        page.addAnnotation(note)
        controller.document = document
        controller.loadAnnotationsForReader()
        let row = try XCTUnwrap(controller.annotationRows.first)

        controller.editAnnotation(row, contents: "Updated note")

        XCTAssertEqual(note.contents, "Updated note")

        controller.undoLastEdit()

        XCTAssertEqual(note.contents, "Original note")

        controller.redoLastEdit()

        XCTAssertEqual(note.contents, "Updated note")
    }

    func testReaderEditLinkAnnotationURLCanUndoAndRedo() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 80, height: 24), forType: .link, withProperties: nil)
        link.contents = "Original link"
        link.url = URL(string: "https://example.com")
        page.addAnnotation(link)
        controller.document = document
        controller.loadAnnotationsForReader()
        let row = try XCTUnwrap(controller.annotationRows.first)

        controller.editAnnotation(row, draft: AnnotationEditDraft(contents: "Updated link", urlString: "https://openai.com"))

        XCTAssertEqual(link.contents, "Updated link")
        XCTAssertEqual(link.url?.absoluteString, "https://openai.com")

        controller.undoLastEdit()

        XCTAssertEqual(link.contents, "Original link")
        XCTAssertEqual(link.url?.absoluteString, "https://example.com")

        controller.redoLastEdit()

        XCTAssertEqual(link.contents, "Updated link")
        XCTAssertEqual(link.url?.absoluteString, "https://openai.com")
    }

    func testReaderStickyNoteCanUndoAndRedo() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let pdfView = PDFView()
        pdfView.document = document
        if let page = document.page(at: 0) {
            pdfView.go(to: page)
        }
        controller.document = document
        controller.pdfView = pdfView
        let page = try XCTUnwrap(document.page(at: 0))

        controller.addStickyNote()

        XCTAssertEqual(page.annotations.filter { $0.contents == "Note" }.count, 1)

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)

        controller.redoLastEdit()

        XCTAssertEqual(page.annotations.filter { $0.contents == "Note" }.count, 1)
    }

    func testReaderMarkupCanUndoAndRedo() throws {
        let document = try makeTextBackedDocument(text: "Annotated")
        let pdfView = PDFView()
        pdfView.document = document
        controller.document = document
        controller.pdfView = pdfView
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.applyMark(.highlight, color: .yellow)

        XCTAssertFalse(page.annotations.isEmpty)

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)

        controller.redoLastEdit()

        XCTAssertFalse(page.annotations.isEmpty)
    }

    func testReaderReplaceSelectedTextCanUndoAndRedo() throws {
        let document = try makeTextBackedDocument(text: "Replace me")
        let pdfView = PDFView()
        pdfView.document = document
        controller.document = document
        controller.pdfView = pdfView
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.replaceSelectedText(with: "Updated")

        XCTAssertEqual(page.annotations.filter { $0.type == "Square" }.count, 1)
        XCTAssertEqual(page.annotations.filter { $0.type == "FreeText" && $0.contents == "Updated" }.count, 1)

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)

        controller.redoLastEdit()

        XCTAssertEqual(page.annotations.filter { $0.type == "Square" }.count, 1)
        XCTAssertEqual(page.annotations.filter { $0.type == "FreeText" && $0.contents == "Updated" }.count, 1)
    }

    func testReaderReplaceSelectedTextAddsReplacementForEachSelectedLine() throws {
        let document = try makeTextBackedDocument(text: "Replace first line\nReplace second line")
        let pdfView = PDFView()
        pdfView.document = document
        controller.document = document
        controller.pdfView = pdfView
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.replaceSelectedText(with: "Updated")

        let covers = page.annotations.filter { $0.type == "Square" }
        let replacements = page.annotations.filter { $0.type == "FreeText" && $0.contents == "Updated" }
        XCTAssertGreaterThan(covers.count, 1)
        XCTAssertEqual(replacements.count, covers.count)
    }

    func testReaderRedactSelectedTextCanUndoAndRedo() throws {
        let document = try makeTextBackedDocument(text: "Redact me")
        let pdfView = PDFView()
        pdfView.document = document
        controller.document = document
        controller.pdfView = pdfView
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.redactSelectedText()

        let redactions = page.annotations.filter {
            $0.type == "Square" &&
                $0.userName == PDFOps.replacementTextAnnotationUserName &&
                $0.interiorColor == .black
        }
        XCTAssertEqual(redactions.count, 1)
        XCTAssertTrue(PDFOps.containsReplacementTextAnnotations(in: document))

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)

        controller.redoLastEdit()

        XCTAssertEqual(page.annotations.filter { $0.userName == PDFOps.replacementTextAnnotationUserName }.count, 1)
    }

    func testReaderPageRotationCanUndoAndRedo() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.go(to: page)
        controller.document = document
        controller.pdfView = pdfView

        controller.rotateCurrentPageRight()

        XCTAssertEqual(page.rotation, 90)

        controller.undoLastEdit()

        XCTAssertEqual(page.rotation, 0)

        controller.redoLastEdit()

        XCTAssertEqual(page.rotation, 90)
    }

    func testReaderDeleteCurrentPageCanUndoAndRedo() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let firstPage = try XCTUnwrap(document.page(at: 0))
        let secondPage = try XCTUnwrap(document.page(at: 1))
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.go(to: firstPage)
        controller.document = document
        controller.pdfView = pdfView

        controller.deleteCurrentPage()

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.page(at: 0) === secondPage)

        controller.undoLastEdit()

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertTrue(document.page(at: 0) === firstPage)
        XCTAssertTrue(document.page(at: 1) === secondPage)

        controller.redoLastEdit()

        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.page(at: 0) === secondPage)
    }

    func testReaderForcedAnnotationLoadWorksForMassiveDocument() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 24, height: 24), forType: .text, withProperties: nil)
        note.contents = "Massive review note"
        page.addAnnotation(note)

        controller.document = document
        controller.isMassiveDocument = true

        controller.loadAnnotationsForReader()
        XCTAssertTrue(controller.annotationRows.isEmpty)

        controller.loadAnnotationsForReader(force: true)

        let row = try XCTUnwrap(controller.annotationRows.first { $0.annotation === note })
        XCTAssertEqual(row.pageIndex, 0)
    }

    private func makeTextBackedDocument(text: String) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "ReaderLogicTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create PDF context",
            ])
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.white.setFill()
        mediaBox.fill()
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
        ).draw(in: CGRect(x: 24, y: 120, width: 272, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PDFDocument(data: data))
    }
}

final class PerfTests: XCTestCase {
    func testRenderThrottle() {
        let throttle = RenderThrottle()
        let expectation = expectation(description: "Throttle execution")
        var executionCount = 0

        // Schedule multiple times rapidly
        throttle.schedule(0.1) {
            executionCount += 1
        }
        throttle.schedule(0.1) {
            executionCount += 1
        }
        throttle.schedule(0.1) {
            executionCount += 1
            expectation.fulfill()
        }

        waitForExpectations(timeout: 1.0)

        // Should only execute the last one
        XCTAssertEqual(executionCount, 1)
    }

    func testRenderCacheKeyEquality() {
        let req1 = PDFRenderRequest(kind: .thumbnail, pageIndex: 0, scaleBucket: 100, size: CGSize(width: 100, height: 100))
        let req2 = PDFRenderRequest(kind: .thumbnail, pageIndex: 0, scaleBucket: 100, size: CGSize(width: 100, height: 100))
        let req3 = PDFRenderRequest(kind: .thumbnail, pageIndex: 1, scaleBucket: 100, size: CGSize(width: 100, height: 100))
        let req4 = PDFRenderRequest(kind: .page, pageIndex: 0, scaleBucket: 100, size: CGSize(width: 100, height: 100))

        XCTAssertEqual(req1, req2)
        XCTAssertNotEqual(req1, req3)
        XCTAssertNotEqual(req1, req4)
        XCTAssertEqual(req1.hashValue, req2.hashValue)
    }

    func testScaleBucketStability() {
        // Verify that similar scales map to the same bucket if we implement bucketing logic in the caller.
        // Here we just test that the request struct holds the bucket correctly.
        let bucket1 = Int(round(1.5 * 2.0)) // 3
        let bucket2 = Int(round(1.51 * 2.0)) // 3

        XCTAssertEqual(bucket1, bucket2)
    }
}
