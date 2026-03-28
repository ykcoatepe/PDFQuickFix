import XCTest
@testable import PDFQuickFix

final class QuickFixTabTests: XCTestCase {
    func testExistingCachedOCRURLReturnsNilWhenFileIsMissing() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        XCTAssertNil(QuickFixTab.existingCachedOCRURL(missingURL))
    }

    func testExistingCachedOCRURLReturnsURLWhenFileExists() throws {
        let existingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data("test".utf8).write(to: existingURL, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: existingURL) }

        XCTAssertEqual(QuickFixTab.existingCachedOCRURL(existingURL), existingURL)
    }
}
