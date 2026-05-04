import PDFKit
@testable import PDFQuickFix
import XCTest

final class PDFMergeTests: XCTestCase {
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

    func testMergeDefault() throws {
        let url1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 3, textPrefix: "Doc1")
        let url2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Doc2")

        let outputURL = tempPDFURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let resultURL = try PDFMerge.merge(urls: [url1, url2], outputURL: outputURL)
        let mergedDoc = try XCTUnwrap(PDFDocument(url: resultURL))
        XCTAssertEqual(mergedDoc.pageCount, 5)
    }

    func testMergeWithBlankPageBetweenDocuments() throws {
        let url1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "A")
        let url2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "B")

        let outputURL = tempPDFURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let options = PDFMergeOptions(insertBlankPageBetweenDocuments: true)
        let result = try PDFMerge.merge(urls: [url1, url2], outputURL: outputURL, options: options)

        XCTAssertEqual(result.insertedSeparatorPageCount, 1)
        XCTAssertEqual(result.mergedPageCount, 3)
    }

    func testMergeSkipsUnreadableSourceWhenEnabled() throws {
        let goodURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Good")
        let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).pdf")
        try "not a pdf".data(using: .utf8)?.write(to: badURL)

        let outputURL = tempPDFURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: badURL)
        }

        let options = PDFMergeOptions(skipUnreadableSources: true)
        let result = try PDFMerge.merge(urls: [goodURL, badURL], outputURL: outputURL, options: options)

        XCTAssertEqual(result.mergedDocumentCount, 1)
        XCTAssertEqual(result.skippedSources.count, 1)
        XCTAssertEqual(result.skippedSources.first?.lastPathComponent, badURL.lastPathComponent)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testMergeFailsOnUnreadableSourceWhenSkipDisabled() throws {
        let goodURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Good")
        let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("bad-\(UUID().uuidString).pdf")
        try "not a pdf".data(using: .utf8)?.write(to: badURL)

        let outputURL = tempPDFURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: badURL)
        }

        let options = PDFMergeOptions(skipUnreadableSources: false)
        XCTAssertThrowsError(try PDFMerge.merge(urls: [goodURL, badURL], outputURL: outputURL, options: options)) { error in
            guard case PDFMergeError.cannotOpenSource = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    func testMergeMetadataPolicyKeepLast() throws {
        let first = try makeTitledPDF(title: "FIRST")
        let last = try makeTitledPDF(title: "LAST")
        let outputURL = tempPDFURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: last)
        }

        var options = PDFMergeOptions.default
        options.metadataPolicy = .keepLast

        _ = try PDFMerge.merge(urls: [first, last], outputURL: outputURL, options: options)
        let merged = try XCTUnwrap(PDFDocument(url: outputURL))
        let attrs = merged.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        XCTAssertEqual(title, "LAST")
    }

    func testMergeMetadataPolicyClear() throws {
        let first = try makeTitledPDF(title: "FIRST")
        let second = try makeTitledPDF(title: "SECOND")
        let outputURL = tempPDFURL()
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        var options = PDFMergeOptions.default
        options.metadataPolicy = .clear

        _ = try PDFMerge.merge(urls: [first, second], outputURL: outputURL, options: options)
        let merged = try XCTUnwrap(PDFDocument(url: outputURL))
        let attrs = merged.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        XCTAssertNil(title)
    }

    func testMergeAddsTopLevelOutlinePerSource() throws {
        let url1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "A")
        let url2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "B")
        let url3 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "C")

        let outputURL = tempPDFURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let result = try PDFMerge.merge(urls: [url1, url2, url3], outputURL: outputURL, options: .default)
        let merged = try XCTUnwrap(PDFDocument(url: outputURL))
        let root = try XCTUnwrap(merged.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, result.mergedDocumentCount)
    }

    func testMergeCancellationBeforeLoad() throws {
        let url1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "A")
        let outputURL = tempPDFURL()
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertThrowsError(
            try PDFMerge.merge(urls: [url1], outputURL: outputURL, shouldCancel: { true })
        ) { error in
            guard case PDFMergeError.cancelled = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        }
    }

    @MainActor
    func testMergeHistorySettingsUsesSelectedOutputFolder() {
        let controller = MergeController()
        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])
        controller.destinationFolderURL = tempDir.appendingPathComponent("selected", isDirectory: true)
        controller.outputFileName = "Merged.pdf"

        let actualOutputURL = tempDir.appendingPathComponent("chosen", isDirectory: true)
            .appendingPathComponent("Result.pdf")
        let settings = controller.currentSettings(with: actualOutputURL)

        XCTAssertEqual(settings.destinationFolderURLString, actualOutputURL.deletingLastPathComponent().standardizedFileURL.path)
    }

    private func tempPDFURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
    }

    private func makeTitledPDF(title: String) throws -> URL {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: title)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: title]
        XCTAssertTrue(doc.write(to: url))
        return url
    }
}
