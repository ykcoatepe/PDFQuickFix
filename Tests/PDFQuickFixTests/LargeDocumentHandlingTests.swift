import XCTest
import Combine
import PDFKit
@testable import PDFQuickFix

@MainActor
final class LargeDocumentHandlingTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testReaderProConfiguresForLargeDocument() throws {
        let controller = ReaderControllerPro()
        let pdfView = PDFView()
        controller.pdfView = pdfView

        let largeURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 1100)
        let opened = expectation(description: "ReaderPro opened large document")

        controller.$document
            .compactMap { $0 }
            .first()
            .sink { _ in opened.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: largeURL)
        }

        wait(for: [opened], timeout: 8.0)

        XCTAssertTrue(controller.isLargeDocument, "Large documents should be flagged")
        XCTAssertEqual(pdfView.displayMode, .singlePage, "Large docs use single page mode")
        XCTAssertFalse(pdfView.displaysPageBreaks, "Large docs hide page breaks to reduce layout work")
        XCTAssertTrue(controller.isSidebarVisible, "Sidebar should remain available for navigation")
    }

    func testStudioSkipsThumbnailsAndAnnotationsForLargeDocument() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)

        let largeURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 1100)
        guard let document = PDFDocument(url: largeURL) else {
            XCTFail("Could not load generated large PDF")
            return
        }

        controller.setDocument(document, url: largeURL)

        XCTAssertTrue(controller.isLargeDocument, "Large documents should be flagged")
        XCTAssertEqual(controller.pageSnapshots.count, document.pageCount)
        XCTAssertNil(controller.pageSnapshots.first?.thumbnail, "Thumbnails should start as placeholders for large docs")
        XCTAssertTrue(controller.annotationRows.isEmpty, "Annotations should not be enumerated for large docs")
        XCTAssertFalse(controller.isThumbnailsLoading, "There should be no eager thumbnail background work")
        XCTAssertEqual(pdfView.displayMode, .singlePage)
        XCTAssertFalse(pdfView.displaysPageBreaks)

        let thumbExpectation = expectation(description: "Thumbnail rendered on demand")
        controller.ensureThumbnail(for: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if controller.pageSnapshots.first?.thumbnail != nil {
                thumbExpectation.fulfill()
            }
        }
        wait(for: [thumbExpectation], timeout: 3.0)
    }
}
