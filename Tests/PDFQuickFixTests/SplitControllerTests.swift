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
        let controller = SplitController(defaults: defaults)
        controller.setSource(url: URL(fileURLWithPath: "/tmp/source.pdf"))
        controller.setDestination(url: URL(fileURLWithPath: "/tmp/destination"))
        controller.mode = .explicitBreaks
        controller.explicitBreaksText = "1, 4, 8"
        controller.applyToAllPDFsInFolder = true
        controller.savePreset(named: "Chapter Split")

        let reloaded = SplitController(defaults: defaults)
        XCTAssertEqual(reloaded.presets.count, 1)
        XCTAssertEqual(reloaded.presets.first?.name, "Chapter Split")
        XCTAssertEqual(reloaded.presets.first?.settings.explicitBreaksText, "1, 4, 8")
        XCTAssertEqual(reloaded.presets.first?.settings.applyToAllPDFsInFolder, true)
    }

    @MainActor
    func testHistoryPersistsAfterSplit() throws {
        let source = try TestPDFBuilder.makeMultipagePDF(pageCount: 2, textPrefix: "Split")
        let outputDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDir) }

        let controller = SplitController(defaults: defaults)
        controller.setSource(url: source)
        controller.setDestination(url: outputDir)
        controller.mode = .maxPagesPerFile
        controller.maxPagesPerFile = 1

        controller.split()
        waitForSplit(controller)

        XCTAssertEqual(controller.history.count, 1)
        XCTAssertEqual(controller.history.first?.destinationFolder, outputDir.lastPathComponent)
        XCTAssertEqual(controller.history.first?.outputCount, 2)

        let reloaded = SplitController(defaults: defaults)
        XCTAssertEqual(reloaded.history.count, 1)
        XCTAssertEqual(reloaded.history.first?.destinationFolder, outputDir.lastPathComponent)
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
