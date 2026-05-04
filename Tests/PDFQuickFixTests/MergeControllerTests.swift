@testable import PDFQuickFix
import XCTest

final class MergeControllerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MergeControllerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor
    func testCanMergeRequiresAtLeastTwoSourcesAndDestination() {
        let controller = MergeController(defaults: defaults)
        controller.outputFileName = "Merged.pdf"

        XCTAssertFalse(controller.canMerge)

        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])
        XCTAssertTrue(controller.destinationFolderURL != nil)
        XCTAssertTrue(controller.canMerge)

        controller.clearSources()
        XCTAssertFalse(controller.canMerge)
    }

    @MainActor
    func testCanMergeFalseWhenOutputNameEmpty() {
        let controller = MergeController(defaults: defaults)
        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])
        controller.outputFileName = "   "

        XCTAssertFalse(controller.canMerge)
    }

    @MainActor
    func testUniqueOutputURLAvoidsExistingFileCollisions() throws {
        let controller = MergeController(defaults: defaults)
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

    @MainActor
    func testPresetPersistenceRoundTrip() {
        let controller = MergeController(defaults: defaults, bookmarking: MockBookmarking())
        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])
        controller.destinationFolderURL = URL(fileURLWithPath: "/tmp")
        controller.outputFileName = "Archive.pdf"
        controller.insertBlankPageBetweenDocuments = true
        controller.savePreset(named: "Archive")

        let reloaded = MergeController(defaults: defaults, bookmarking: MockBookmarking())
        XCTAssertEqual(reloaded.presets.count, 1)
        XCTAssertEqual(reloaded.presets.first?.name, "Archive")
        XCTAssertEqual(reloaded.presets.first?.settings.outputFileName, "Archive.pdf")
        XCTAssertEqual(reloaded.presets.first?.settings.sourceBookmarkData.count, 2)
        XCTAssertNotNil(reloaded.presets.first?.settings.destinationFolderBookmarkData)
    }

    @MainActor
    func testHistoryPersistsAfterMerge() throws {
        let source1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "One")
        let source2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "Two")
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let controller = MergeController(defaults: defaults)
        controller.addSourceURLs([source1, source2])
        controller.destinationFolderURL = outputDir
        controller.outputFileName = "Merged.pdf"

        controller.merge()
        waitForMerge(controller)

        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history.first?.destinationFolder, outputDir.lastPathComponent)
        XCTAssertEqual(controller.history.first?.outputFileName, "Merged.pdf")

        let reloaded = MergeController(defaults: defaults)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.destinationFolder, outputDir.lastPathComponent)
    }

    @MainActor
    func testCurrentSettingsUsesSelectedOutputFileName() {
        let controller = MergeController(defaults: defaults)
        controller.addSourceURLs([
            URL(fileURLWithPath: "/tmp/a.pdf"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ])
        controller.destinationFolderURL = URL(fileURLWithPath: "/tmp")
        controller.outputFileName = "Merged.pdf"

        let selectedOutputURL = URL(fileURLWithPath: "/tmp/Chosen Name (2).pdf")
        let settings = controller.currentSettings(with: selectedOutputURL)

        XCTAssertEqual(settings.outputFileName, "Chosen Name (2).pdf")
        XCTAssertEqual(settings.destinationFolderURLString, "/tmp")
    }

    @MainActor
    func testMoveSourceAdjustsDestinationAfterRemovingLowerIndexes() {
        let controller = MergeController(defaults: defaults)
        controller.sourceURLs = [
            URL(fileURLWithPath: "/tmp/1.pdf"),
            URL(fileURLWithPath: "/tmp/2.pdf"),
            URL(fileURLWithPath: "/tmp/3.pdf"),
            URL(fileURLWithPath: "/tmp/4.pdf"),
        ]

        controller.moveSource(from: IndexSet(integer: 1), to: 3)

        XCTAssertEqual(controller.sourceURLs.map(\.lastPathComponent), ["1.pdf", "3.pdf", "2.pdf", "4.pdf"])
    }

    @MainActor
    func testMergeCancellationSetsCancelledStatus() throws {
        let source1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1200, textPrefix: "One")
        let source2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1200, textPrefix: "Two")
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let controller = MergeController(defaults: defaults)
        controller.addSourceURLs([source1, source2])
        controller.destinationFolderURL = outputDir
        controller.outputFileName = "Merged.pdf"

        controller.merge()
        controller.cancel()
        waitForMerge(controller, timeout: 10)

        XCTAssertEqual(controller.status, "Merge cancelled.")
    }

    @MainActor
    func testApplyPresetRestoresURLsFromBookmarksWhenPathsAreUnavailable() throws {
        let bookmarking = MockBookmarking()
        let source1 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "One")
        let source2 = try TestPDFBuilder.makeMultipagePDF(pageCount: 1, textPrefix: "Two")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: source1)
            try? FileManager.default.removeItem(at: source2)
            try? FileManager.default.removeItem(at: destination)
        }

        let preset = try MergeJobPreset(
            id: UUID(),
            name: "Bookmark Restore",
            createdAt: Date(),
            settings: MergeJobSettings(
                sourceURLStrings: ["/tmp/missing-1.pdf", "/tmp/missing-2.pdf"],
                sourceBookmarkData: [
                    bookmarking.bookmarkData(for: source1, includingResourceValuesForKeys: nil, relativeTo: nil),
                    bookmarking.bookmarkData(for: source2, includingResourceValuesForKeys: nil, relativeTo: nil),
                ],
                destinationFolderURLString: "/tmp/missing-destination",
                destinationFolderBookmarkData: bookmarking.bookmarkData(for: destination, includingResourceValuesForKeys: nil, relativeTo: nil),
                outputFileName: "Merged.pdf",
                insertBlankPageBetweenDocuments: false,
                skipUnreadableSources: true,
                deduplicateSources: false,
                outlinePolicy: .addTopLevelPerSource,
                metadataPolicy: .keepFirst
            )
        )

        let controller = MergeController(defaults: defaults, bookmarking: bookmarking)
        controller.applyPreset(preset)

        XCTAssertEqual(controller.sourceURLs, [source1, source2])
        XCTAssertEqual(controller.destinationFolderURL, destination)
    }

    @MainActor
    private func waitForMerge(_ controller: MergeController, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.isWorking, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertFalse(controller.isWorking)
    }
}
