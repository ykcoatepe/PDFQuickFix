import AppKit
import PDFKit
@testable import PDFQuickFix
@testable import PDFQuickFixKit
import XCTest

final class FinderQuickActionSanitizerTests: XCTestCase {
    func testPasteboardExtractsOnlyUniquePDFFileURLs() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfURL = directory.appendingPathComponent("Brief.PDF")
        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("pdf".utf8).write(to: pdfURL)
        try Data("text".utf8).write(to: textURL)

        let pasteboard = NSPasteboard(name: .init("PDFQuickFixFinderAction-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setPropertyList(
            [pdfURL.path, textURL.path, pdfURL.path],
            forType: .init("NSFilenamesPboardType")
        )

        let urls = FinderQuickActionSanitizer.pdfFileURLs(from: pasteboard)

        XCTAssertEqual(urls, [pdfURL.standardizedFileURL])
    }

    func testOutputURLUsesSanitizedSuffixAndAvoidsCollisions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("Contract.pdf")
        let firstCollision = directory.appendingPathComponent("Contract-sanitized.pdf")
        let secondCollision = directory.appendingPathComponent("Contract-sanitized-2.pdf")
        try Data().write(to: sourceURL)
        try Data().write(to: firstCollision)
        try Data().write(to: secondCollision)

        let outputURL = FinderQuickActionSanitizer.outputURL(for: sourceURL)

        XCTAssertEqual(outputURL.lastPathComponent, "Contract-sanitized-3.pdf")
    }

    func testSanitizeFileWritesOutboundCopyWithoutChangingSource() throws {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Private draft")
        let outputURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let originalData = try Data(contentsOf: sourceURL)

        _ = try FinderQuickActionSanitizer.sanitizeFile(
            sourceURL: sourceURL,
            outputURL: outputURL,
            profile: .lightClean
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
        XCTAssertNotNil(PDFDocument(url: outputURL))
    }

    func testSanitizeFileReturnsCleanupReviewForFinderReceipt() throws {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Private finder handoff")
        let outputURL = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let outcome = try FinderQuickActionSanitizer.sanitizeFile(
            sourceURL: sourceURL,
            outputURL: outputURL,
            profile: .lightClean
        )
        let review = try XCTUnwrap(outcome.review)
        defer { review.removeTemporarySource() }

        XCTAssertNil(outcome.reviewErrorDescription)
        XCTAssertEqual(review.outputURL, outputURL)
        XCTAssertEqual(review.evidence.source.fileName, sourceURL.lastPathComponent)
        XCTAssertEqual(review.evidence.sanitizeProfile, SanitizeProfile.lightClean.rawValue)
        XCTAssertNotEqual(review.evidence.verdict, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.sourceSnapshotURL.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFQuickFixFinderAction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
