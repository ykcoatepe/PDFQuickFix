import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

final class CleanupReviewBuilderTests: XCTestCase {
    func testSanitizeReviewRecordsProfileAndKeepsTemporarySourcePrivate() throws {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Sensitive source", size: CGSize(width: 200, height: 200))
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        source.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Private Author"]
        let output = try XCTUnwrap(try PDFDocument(data: XCTUnwrap(source.dataRepresentation())))
        output.documentAttributes = [:]
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        XCTAssertTrue(output.write(to: outputURL))

        let review = try CleanupReviewBuilder.build(
            sourceDocument: source,
            sourceFileName: "/private/contracts/contract.pdf",
            outputURL: outputURL,
            profile: .lightClean
        )
        defer { review.removeTemporarySource() }

        XCTAssertEqual(review.evidence.operationKind, .sanitize)
        XCTAssertEqual(review.evidence.sanitizeProfile, SanitizeProfile.lightClean.rawValue)
        XCTAssertEqual(review.evidence.source.fileName, "contract.pdf")
        XCTAssertEqual(review.comparison.metadataFieldsRemoved, ["Author"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: review.sourceSnapshotURL.path))

        let serialized = try XCTUnwrap(String(data: CleanupEvidenceWriter.jsonData(for: review.evidence), encoding: .utf8))
        XCTAssertFalse(serialized.contains("Private Author"))
        XCTAssertFalse(serialized.contains(review.sourceSnapshotURL.path))
    }

    func testRemovingTemporarySourceDeletesSnapshot() throws {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Source", size: CGSize(width: 200, height: 200))
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        let outputURL = try TestPDFBuilder.makeSimplePDF(text: "Source", size: CGSize(width: 200, height: 200))
        let review = try CleanupReviewBuilder.build(
            sourceDocument: source,
            sourceFileName: "source.pdf",
            outputURL: outputURL,
            profile: .privacyClean
        )

        review.removeTemporarySource()

        XCTAssertFalse(FileManager.default.fileExists(atPath: review.sourceSnapshotURL.path))
    }

    func testReviewDeinitDeletesTemporarySnapshot() throws {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Source", size: CGSize(width: 200, height: 200))
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        let outputURL = try TestPDFBuilder.makeSimplePDF(text: "Source", size: CGSize(width: 200, height: 200))
        var review: CleanupReview? = try CleanupReviewBuilder.build(
            sourceDocument: source,
            sourceFileName: "source.pdf",
            outputURL: outputURL,
            profile: .privacyClean
        )
        let snapshotURL = try XCTUnwrap(review?.sourceSnapshotURL)

        review = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshotURL.path))
    }
}
