import XCTest
@testable import PDFQuickFix

final class SplitControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SplitControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testPresetPersistenceRoundTrip() {
        let controller = SplitController(defaults: defaults, bookmarking: MockBookmarking())
        controller.setSource(url: URL(fileURLWithPath: "/tmp/source.pdf"))
        controller.setDestination(url: URL(fileURLWithPath: "/tmp/destination"))
        controller.mode = .explicitBreaks
        controller.explicitBreaksText = "1, 4, 8"
        controller.applyToAllPDFsInFolder = true
        controller.savePreset(named: "Chapter Split")

        let reloaded = SplitController(defaults: defaults, bookmarking: MockBookmarking())
        XCTAssertEqual(reloaded.presets.count, 1)
        XCTAssertEqual(reloaded.presets.first?.name, "Chapter Split")
        XCTAssertEqual(reloaded.presets.first?.settings.explicitBreaksText, "1, 4, 8")
        XCTAssertEqual(reloaded.presets.first?.settings.applyToAllPDFsInFolder, true)
        XCTAssertNotNil(reloaded.presets.first?.settings.sourceBookmarkData)
        XCTAssertNotNil(reloaded.presets.first?.settings.destinationBookmarkData)
    }

    @MainActor
    func testHistoryPersistsAfterSplit() throws {
        let source = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Split")
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let controller = SplitController(defaults: defaults, bookmarking: MockBookmarking())
        controller.setSource(url: source)
        controller.setDestination(url: outputDir)
        controller.mode = .maxPagesPerFile
        controller.maxPagesPerFile = 1

        controller.split()
        waitForSplit(controller)

        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history.first?.destinationFolder, outputDir.lastPathComponent)
        XCTAssertEqual(controller.history.first?.outputCount, 2)

        let reloaded = SplitController(defaults: defaults, bookmarking: MockBookmarking())
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.destinationFolder, outputDir.lastPathComponent)
    }

    @MainActor
    func testFolderSplitSkipsUnreadablePDFAndRecordsWarning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outputDir)
        }

        let validSource = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Batch")
        let copiedValidSource = folder.appendingPathComponent("valid.pdf")
        try FileManager.default.copyItem(at: validSource, to: copiedValidSource)
        let invalidSource = folder.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: invalidSource)

        let controller = SplitController(defaults: defaults, bookmarking: MockBookmarking())
        controller.setSource(url: copiedValidSource)
        controller.setDestination(url: outputDir)
        controller.mode = .maxPagesPerFile
        controller.maxPagesPerFile = 1
        controller.applyToAllPDFsInFolder = true

        controller.split()
        waitForSplit(controller)

        XCTAssertEqual(controller.lastOutputFiles.count, 2)
        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history.first?.fileCount, 2)
        XCTAssertEqual(controller.history.first?.outputCount, 2)
        XCTAssertEqual(controller.status, "Done. 2 file(s) written to \(outputDir.lastPathComponent).")
        XCTAssertEqual(controller.history.first?.errorSummary, "Skipped broken.pdf: unreadable or invalid PDF.")
    }

    @MainActor
    func testApplyPresetRestoresURLsFromBookmarksWhenPathsAreUnavailable() throws {
        let bookmarking = MockBookmarking()
        let source = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "Bookmark")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }

        let preset = SplitJobPreset(
            id: UUID(),
            name: "Bookmark Restore",
            createdAt: Date(),
            settings: SplitJobSettings(
                sourceURLString: "/tmp/missing-source.pdf",
                sourceBookmarkData: try bookmarking.bookmarkData(for: source, includingResourceValuesForKeys: nil, relativeTo: nil),
                destinationURLString: "/tmp/missing-destination",
                destinationBookmarkData: try bookmarking.bookmarkData(for: destination, includingResourceValuesForKeys: nil, relativeTo: nil),
                applyToAllPDFsInFolder: false,
                mode: .maxPagesPerFile,
                maxPagesPerFile: 2,
                numberOfParts: 2,
                approxSizeMB: 50,
                explicitBreaksText: "1"
            )
        )

        let controller = SplitController(defaults: defaults, bookmarking: bookmarking)
        controller.applyPreset(preset)

        XCTAssertEqual(controller.sourceURL, source)
        XCTAssertEqual(controller.destinationURL, destination)
    }

    @MainActor
    private func waitForSplit(_ controller: SplitController, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isWorking && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(controller.isWorking)
    }
}
