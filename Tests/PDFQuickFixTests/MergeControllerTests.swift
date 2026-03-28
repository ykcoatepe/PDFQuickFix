import XCTest
@testable import PDFQuickFix

final class MergeControllerTests: XCTestCase {

    @MainActor
    func testCanMergeRequiresAtLeastTwoSourcesAndDestination() {
        let controller = MergeController()
        controller.outputFileName = "Merged.pdf"

        XCTAssertFalse(controller.canMerge)

        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf")
        ])
        XCTAssertTrue(controller.destinationFolderURL != nil)
        XCTAssertTrue(controller.canMerge)

        controller.clearSources()
        XCTAssertFalse(controller.canMerge)
    }

    @MainActor
    func testCanMergeFalseWhenOutputNameEmpty() {
        let controller = MergeController()
        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf")
        ])
        controller.outputFileName = "   "

        XCTAssertFalse(controller.canMerge)
    }

    @MainActor
    func testUniqueOutputURLAvoidsExistingFileCollisions() throws {
        let controller = MergeController()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let requested = dir.appendingPathComponent("Merged.pdf")
        FileManager.default.createFile(atPath: requested.path, contents: Data(), attributes: nil)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Merged (2).pdf").path, contents: Data(), attributes: nil)

        let unique = controller.uniqueOutputURL(for: requested)
        XCTAssertEqual(unique.lastPathComponent, "Merged (3).pdf")
    }
}
