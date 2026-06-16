import Combine
import PDFKit
@testable import PDFQuickFix
import XCTest

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
            .compactMap(\.self)
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

    func testOutlineLoaderCapsMassiveOutlineRows() throws {
        let document = try makeDocumentWithOutline(pageCount: 1, outlineCount: PDFOutlineLoader.massiveDocumentRowLimit + 25)

        let result = PDFOutlineLoader.rows(from: document.outlineRoot, limit: PDFOutlineLoader.massiveDocumentRowLimit)

        XCTAssertEqual(result.rows.count, PDFOutlineLoader.massiveDocumentRowLimit)
        XCTAssertTrue(result.isTruncated)
    }

    func testReaderLoadsMassiveOutlineOnDemandWithCap() throws {
        let controller = ReaderControllerPro()
        let document = try makeDocumentWithOutline(pageCount: DocumentValidationRunner.massiveDocumentPageThreshold,
                                                   outlineCount: PDFOutlineLoader.massiveDocumentRowLimit + 10)
        controller.document = document
        controller.isMassiveDocument = true

        XCTAssertFalse(controller.hasLoadedOutline)
        XCTAssertTrue(controller.outlineRows.isEmpty)

        controller.loadOutlineIfNeeded()

        XCTAssertTrue(controller.hasLoadedOutline)
        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit)
        XCTAssertTrue(controller.isOutlineTruncated)
    }

    func testReaderInvalidatesCachedOutlineWhenDocumentIsReplaced() throws {
        let controller = ReaderControllerPro()
        let first = try makeDocumentWithOutline(pageCount: 1, outlineCount: 1, labelPrefix: "Old")
        let replacement = try makeDocumentWithOutline(pageCount: 1, outlineCount: 1, labelPrefix: "New")
        controller.document = first

        controller.loadOutlineIfNeeded()
        XCTAssertEqual(controller.outlineRows.first?.outline.label, "Old 1")

        let resetToken = controller.outlineResetToken
        controller.document = replacement
        controller.invalidateOutlineCache()

        XCTAssertTrue(controller.outlineRows.isEmpty)
        XCTAssertFalse(controller.hasLoadedOutline)
        XCTAssertGreaterThan(controller.outlineResetToken, resetToken)

        controller.loadOutlineIfNeeded()
        XCTAssertEqual(controller.outlineRows.first?.outline.label, "New 1")
    }

    func testStudioDefersThenCapsMassiveOutlineLoading() throws {
        let controller = StudioController()
        let document = try makeDocumentWithOutline(pageCount: DocumentValidationRunner.massiveDocumentPageThreshold,
                                                   outlineCount: PDFOutlineLoader.massiveDocumentRowLimit + 10)

        controller.setDocument(document)

        XCTAssertTrue(controller.isMassiveDocument)
        XCTAssertTrue(controller.outlineRows.isEmpty)

        controller.loadOutlineIfNeeded()

        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit)
        XCTAssertTrue(controller.isOutlineTruncated)
    }

    func testStudioKeepsAddedBookmarkVisibleWhenMassiveOutlineIsCapped() throws {
        let controller = StudioController()
        let document = try makeDocumentWithOutline(pageCount: DocumentValidationRunner.massiveDocumentPageThreshold,
                                                   outlineCount: PDFOutlineLoader.massiveDocumentRowLimit)

        controller.setDocument(document)
        controller.loadOutlineIfNeeded()
        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit)

        controller.addOutline(title: "Added Bookmark")

        XCTAssertEqual(document.outlineRoot?.numberOfChildren, PDFOutlineLoader.massiveDocumentRowLimit + 1)
        XCTAssertEqual(controller.outlineRows.last?.outline.label, "Added Bookmark")
        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit + 1)
        XCTAssertTrue(controller.isOutlineTruncated)

        controller.refreshOutline()

        let addedRow = try XCTUnwrap(controller.outlineRows.last)
        XCTAssertEqual(addedRow.outline.label, "Added Bookmark")
        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit + 1)

        controller.renameOutline(addedRow, title: "Renamed Bookmark")

        XCTAssertEqual(controller.outlineRows.last?.outline.label, "Renamed Bookmark")
        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit + 1)
    }

    private func makeDocumentWithOutline(pageCount: Int, outlineCount: Int, labelPrefix: String = "Chapter") throws -> PDFDocument {
        let document = PDFDocument()
        for _ in 0 ..< pageCount {
            document.insert(PDFPage(), at: document.pageCount)
        }

        let root = PDFOutline()
        let destinationPage = try XCTUnwrap(document.page(at: 0))
        for index in 0 ..< outlineCount {
            let item = PDFOutline()
            item.label = "\(labelPrefix) \(index + 1)"
            item.destination = PDFDestination(page: destinationPage, at: .zero)
            root.insertChild(item, at: root.numberOfChildren)
        }
        document.outlineRoot = root
        return document
    }
}
