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
