import PDFKit
@testable import PDFQuickFix
import XCTest

final class PDFSplitterTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testSplitMaxPages() throws {
        // Given
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 10)
        let options = PDFSplitOptions(sourceURL: url,
                                      destinationDirectory: tempDir,
                                      mode: .maxPagesPerPart(3))
        let splitter = PDFSplitter()

        // When
        let result = try splitter.split(options: options)

        // Then
        // 10 pages split by 3 -> 3, 3, 3, 1 -> 4 parts
        XCTAssertEqual(result.outputFiles.count, 4)

        let part1 = try XCTUnwrap(PDFDocument(url: result.outputFiles[0]))
        XCTAssertEqual(part1.pageCount, 3)

        let part4 = try XCTUnwrap(PDFDocument(url: result.outputFiles[3]))
        XCTAssertEqual(part4.pageCount, 1)
    }

    func testSplitNumberOfParts() throws {
        // Given
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 10)
        let options = PDFSplitOptions(sourceURL: url,
                                      destinationDirectory: tempDir,
                                      mode: .numberOfParts(2))
        let splitter = PDFSplitter()

        // When
        let result = try splitter.split(options: options)

        // Then
        // 10 pages split into 2 parts -> 5, 5
        XCTAssertEqual(result.outputFiles.count, 2)

        let part1 = try XCTUnwrap(PDFDocument(url: result.outputFiles[0]))
        XCTAssertEqual(part1.pageCount, 5)

        let part2 = try XCTUnwrap(PDFDocument(url: result.outputFiles[1]))
        XCTAssertEqual(part2.pageCount, 5)
    }

    func testSplitExplicitBreaks() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 10)
        let options = PDFSplitOptions(
            sourceURL: url,
            destinationDirectory: tempDir,
            mode: .explicitBreaks([1, 4, 8])
        )
        let splitter = PDFSplitter()

        let result = try splitter.split(options: options)

        XCTAssertEqual(result.outputFiles.count, 3)
        XCTAssertEqual(PDFDocument(url: result.outputFiles[0])?.pageCount, 3)
        XCTAssertEqual(PDFDocument(url: result.outputFiles[1])?.pageCount, 4)
        XCTAssertEqual(PDFDocument(url: result.outputFiles[2])?.pageCount, 3)
    }

    func testSplitApproxTargetSizeProducesSmallerParts() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 6)
        let options = PDFSplitOptions(
            sourceURL: url,
            destinationDirectory: tempDir,
            mode: .approxTargetSizeMB(0.001)
        )
        let splitter = PDFSplitter()

        let result = try splitter.split(options: options)

        XCTAssertGreaterThan(result.outputFiles.count, 1)
        XCTAssertTrue(result.outputFiles.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
    }

    func testSplitOutlineChaptersUsesTopLevelBookmarks() throws {
        let url = try makeOutlinedPDF(pageCount: 5, breakPages: [1, 4])
        let options = PDFSplitOptions(
            sourceURL: url,
            destinationDirectory: tempDir,
            mode: .outlineChapters
        )
        let splitter = PDFSplitter()

        let result = try splitter.split(options: options)

        XCTAssertEqual(result.outputFiles.count, 2)
        XCTAssertEqual(PDFDocument(url: result.outputFiles[0])?.pageCount, 3)
        XCTAssertEqual(PDFDocument(url: result.outputFiles[1])?.pageCount, 2)
    }

    func testSplitCancellationStopsWork() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 8)
        let options = PDFSplitOptions(
            sourceURL: url,
            destinationDirectory: tempDir,
            mode: .maxPagesPerPart(2)
        )
        let splitter = PDFSplitter()
        var calls = 0

        XCTAssertThrowsError(
            try splitter.split(options: options, shouldCancel: {
                calls += 1
                return calls > 1
            })
        ) { error in
            guard case PDFSplitError.cancelled = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    private func makeOutlinedPDF(pageCount: Int, breakPages: [Int]) throws -> URL {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: pageCount)
        guard let document = PDFDocument(url: url) else {
            XCTFail("Unable to reopen test PDF")
            return url
        }

        let root = PDFOutline()
        root.label = "Outline"
        for pageNumber in breakPages {
            guard pageNumber > 0,
                  pageNumber <= document.pageCount,
                  let page = document.page(at: pageNumber - 1) else { continue }
            let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY))
            let child = PDFOutline()
            child.label = "Page \(pageNumber)"
            child.destination = destination
            root.insertChild(child, at: root.numberOfChildren)
        }
        document.outlineRoot = root
        XCTAssertTrue(document.write(to: url))
        return url
    }
}
