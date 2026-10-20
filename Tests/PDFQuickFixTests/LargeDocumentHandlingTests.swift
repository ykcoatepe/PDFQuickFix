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

    func testOutlineLoaderHonorsExplicitLimit() throws {
        let document = try makeDocumentWithOutline(pageCount: 1, outlineCount: 500 + 25)

        let result = PDFOutlineLoader.rows(from: document.outlineRoot, limit: 500)

        XCTAssertEqual(result.rows.count, 500)
        XCTAssertTrue(result.isTruncated)
    }

    func testCompleteOutlinePreservesNestedOrderAndLateDestination() throws {
        let document = try makeDocumentWithOutline(pageCount: 2, outlineCount: 600)
        let root = try XCTUnwrap(document.outlineRoot)
        let lastPage = try XCTUnwrap(document.page(at: 1))
        for index in 0 ..< 600 {
            let parent = try XCTUnwrap(root.child(at: index))
            let child = PDFOutline()
            child.label = "Section \(index + 1)"
            child.destination = PDFDestination(page: lastPage, at: .zero)
            parent.insertChild(child, at: 0)
        }

        let reader = ReaderControllerPro()
        reader.document = document
        reader.isMassiveDocument = true
        reader.loadOutlineIfNeeded()
        let studio = StudioController()
        studio.document = document
        studio.isMassiveDocument = true
        studio.loadOutlineIfNeeded()

        for rows in [reader.outlineRows, studio.outlineRows] {
            XCTAssertEqual(rows.count, 1200)
            XCTAssertEqual(Set(rows.map(\.id)).count, 1200)
            for index in 0 ..< 600 {
                XCTAssertEqual(rows[index * 2].outline.label, "Chapter \(index + 1)")
                XCTAssertEqual(rows[index * 2].depth, 0)
                XCTAssertEqual(rows[index * 2 + 1].outline.label, "Section \(index + 1)")
                XCTAssertEqual(rows[index * 2 + 1].depth, 1)
            }
            let destination = try XCTUnwrap(rows.last?.outline.destination)
            XCTAssertTrue(destination.page === lastPage)
            let pdfView = PDFView()
            pdfView.document = document
            pdfView.go(to: destination)
            XCTAssertTrue(pdfView.currentPage === lastPage)
        }
    }

    func testOutlineLoaderHandlesMissingOutlineAndExactLimit() throws {
        XCTAssertTrue(PDFOutlineLoader.rows(from: nil).rows.isEmpty)
        XCTAssertFalse(PDFOutlineLoader.rows(from: nil).isTruncated)
        let document = try makeDocumentWithOutline(pageCount: 1, outlineCount: 500)
        let result = PDFOutlineLoader.rows(from: document.outlineRoot, limit: 500)
        XCTAssertEqual(result.rows.count, 500)
        XCTAssertFalse(result.isTruncated)
    }

    func testOutlineLoaderTraversesDeepChainWithoutUsingCallStack() {
        // Weak synthetic links avoid PDFKit's own tree-construction and teardown
        // recursion. The fixture isolates the loader's traversal of a deep PDF.
        let depth = 50_000
        let nodes = (0 ... depth).map { _ in DeepOutlineNode() }
        for index in 0 ..< depth { nodes[index].next = nodes[index + 1] }

        let result = PDFOutlineLoader.rows(from: nodes[0])

        XCTAssertEqual(result.rows.count, depth)
        XCTAssertFalse(result.isTruncated)
        for (index, row) in result.rows.enumerated() {
            XCTAssertEqual(row.depth, index)
            XCTAssertTrue(row.outline === nodes[index + 1])
        }
        withExtendedLifetime(nodes) {}
    }

    func testOutlineLoaderDeepChainPreservesExplicitLimitSemantics() {
        let nodes = (0 ... 1_000).map { _ in DeepOutlineNode() }
        for index in 0 ..< nodes.count - 1 { nodes[index].next = nodes[index + 1] }

        let limited = PDFOutlineLoader.rows(from: nodes[0], limit: 500)
        XCTAssertEqual(limited.rows.count, 500)
        XCTAssertEqual(limited.rows.last?.depth, 499)
        XCTAssertTrue(limited.rows.last?.outline === nodes[500])
        XCTAssertTrue(limited.isTruncated)

        let exact = PDFOutlineLoader.rows(from: nodes[0], limit: 1_000)
        XCTAssertEqual(exact.rows.count, 1_000)
        XCTAssertFalse(exact.isTruncated)
        XCTAssertTrue(PDFOutlineLoader.rows(from: nodes[0], limit: 0).isTruncated)
        XCTAssertTrue(PDFOutlineLoader.rows(from: nodes[0], limit: -1).isTruncated)
        XCTAssertFalse(PDFOutlineLoader.rows(from: nodes.last, limit: 0).isTruncated)
        withExtendedLifetime(nodes) {}
    }

    func testOutlineLoaderSkipsRootSelfCycleAndPreservesValidSibling() {
        let root = GraphOutlineNode()
        let sibling = GraphOutlineNode()
        root.children = [WeakOutlineLink(root), WeakOutlineLink(sibling)]

        let result = PDFOutlineLoader.rows(from: root)

        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.rows.first?.outline === sibling)
        XCTAssertEqual(result.rows.first?.depth, 0)
        XCTAssertTrue(result.isTruncated, "A repeated edge makes the outline incomplete")
        withExtendedLifetime((root, sibling)) {}
    }

    func testOutlineLoaderSkipsTwoNodeCycleAndPreservesNestedAndRootSiblings() {
        let root = GraphOutlineNode()
        let first = GraphOutlineNode()
        let second = GraphOutlineNode()
        let nestedSibling = GraphOutlineNode()
        let rootSibling = GraphOutlineNode()
        root.children = [WeakOutlineLink(first), WeakOutlineLink(rootSibling)]
        first.children = [WeakOutlineLink(second)]
        second.children = [WeakOutlineLink(first), WeakOutlineLink(nestedSibling)]

        let result = PDFOutlineLoader.rows(from: root)

        XCTAssertEqual(result.rows.map(\.id), [first, second, nestedSibling, rootSibling].map { ObjectIdentifier($0) })
        XCTAssertEqual(result.rows.map(\.depth), [0, 1, 2, 0])
        XCTAssertTrue(result.isTruncated)
        let limited = PDFOutlineLoader.rows(from: root, limit: 3)
        XCTAssertEqual(limited.rows.map(\.id), [first, second, nestedSibling].map { ObjectIdentifier($0) })
        XCTAssertTrue(limited.isTruncated)
        withExtendedLifetime((root, first, second, nestedSibling, rootSibling)) {}
    }

    func testOutlineLoaderSkipsRepeatedSharedNodeAndPreservesValidSibling() {
        let root = GraphOutlineNode()
        let repeated = GraphOutlineNode()
        let sibling = GraphOutlineNode()
        root.children = [WeakOutlineLink(repeated), WeakOutlineLink(repeated), WeakOutlineLink(sibling)]

        let result = PDFOutlineLoader.rows(from: root)

        XCTAssertEqual(result.rows.map(\.id), [repeated, sibling].map { ObjectIdentifier($0) })
        XCTAssertEqual(result.rows.map(\.depth), [0, 0])
        XCTAssertTrue(result.isTruncated)
        withExtendedLifetime((root, repeated, sibling)) {}
    }

    func testReaderLoadsCompleteMassiveOutlineOnDemand() throws {
        let controller = ReaderControllerPro()
        let document = try makeDocumentWithOutline(pageCount: DocumentValidationRunner.massiveDocumentPageThreshold,
                                                   outlineCount: 500 + 10)
        controller.document = document
        controller.isMassiveDocument = true

        XCTAssertFalse(controller.hasLoadedOutline)
        XCTAssertTrue(controller.outlineRows.isEmpty)

        controller.loadOutlineIfNeeded()

        XCTAssertTrue(controller.hasLoadedOutline)
        XCTAssertEqual(controller.outlineRows.count, 500 + 10)
        XCTAssertFalse(controller.isOutlineTruncated)
        XCTAssertEqual(controller.outlineRows.last?.outline.label, "Chapter 510")
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

    func testStudioDefersThenLoadsCompleteMassiveOutline() throws {
        let controller = StudioController()
        let document = try makeDocumentWithOutline(pageCount: DocumentValidationRunner.massiveDocumentPageThreshold,
                                                   outlineCount: 500 + 10)

        controller.setDocument(document)

        XCTAssertTrue(controller.isMassiveDocument)
        XCTAssertTrue(controller.outlineRows.isEmpty)

        controller.loadOutlineIfNeeded()

        XCTAssertEqual(controller.outlineRows.count, 500 + 10)
        XCTAssertFalse(controller.isOutlineTruncated)
        XCTAssertEqual(controller.outlineRows.last?.outline.label, "Chapter 510")
    }

    func testStudioKeepsAddedBookmarkVisibleBeyondFormerCap() throws {
        let controller = StudioController()
        let document = try makeDocumentWithOutline(pageCount: DocumentValidationRunner.massiveDocumentPageThreshold,
                                                   outlineCount: 500)

        controller.setDocument(document)
        controller.loadOutlineIfNeeded()
        XCTAssertEqual(controller.outlineRows.count, 500)

        controller.addOutline(title: "Added Bookmark")

        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 500 + 1)
        XCTAssertEqual(controller.outlineRows.last?.outline.label, "Added Bookmark")
        XCTAssertEqual(controller.outlineRows.count, 500 + 1)
        XCTAssertFalse(controller.isOutlineTruncated)

        controller.refreshOutline()

        let addedRow = try XCTUnwrap(controller.outlineRows.last)
        XCTAssertEqual(addedRow.outline.label, "Added Bookmark")
        XCTAssertEqual(controller.outlineRows.count, 500 + 1)

        controller.renameOutline(addedRow, title: "Renamed Bookmark")

        XCTAssertEqual(controller.outlineRows.last?.outline.label, "Renamed Bookmark")
        XCTAssertEqual(controller.outlineRows.count, 500 + 1)
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

private final class DeepOutlineNode: PDFOutline {
    weak var next: PDFOutline?

    override var numberOfChildren: Int { next == nil ? 0 : 1 }

    override func child(at index: Int) -> PDFOutline? { index == 0 ? next : nil }
}

private final class GraphOutlineNode: PDFOutline {
    var children: [WeakOutlineLink] = []

    override var numberOfChildren: Int { children.count }

    override func child(at index: Int) -> PDFOutline? {
        children.indices.contains(index) ? children[index].outline : nil
    }
}

private final class WeakOutlineLink {
    weak var outline: PDFOutline?

    init(_ outline: PDFOutline) { self.outline = outline }
}
