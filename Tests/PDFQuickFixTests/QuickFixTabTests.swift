@testable import PDFQuickFix
import XCTest

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

    func testCopyResultPreservingExistingFileReplacesDestination() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.pdf")
        let destinationURL = directory.appendingPathComponent("destination.pdf")
        try Data("new".utf8).write(to: sourceURL, options: [.atomic])
        try Data("old".utf8).write(to: destinationURL, options: [.atomic])

        try QuickFixTab.copyResultPreservingExistingFile(from: sourceURL, to: destinationURL)

        XCTAssertEqual(try Data(contentsOf: destinationURL), Data("new".utf8))
    }

    func testCopyResultPreservingExistingFileKeepsDestinationWhenCopyFails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("missing.pdf")
        let destinationURL = directory.appendingPathComponent("destination.pdf")
        let originalData = Data("old".utf8)
        try originalData.write(to: destinationURL, options: [.atomic])

        XCTAssertThrowsError(try QuickFixTab.copyResultPreservingExistingFile(from: sourceURL, to: destinationURL))
        XCTAssertEqual(try Data(contentsOf: destinationURL), originalData)
    }
}
