@testable import PDFQuickFix
import XCTest

final class QuickFixTabTests: XCTestCase {
    @MainActor
    func testDelayedOldDocumentCallbacksCannotReplaceNewProgressResultOrOCRCache() async throws {
        let lifetime = QuickFixRequestLifetime()
        let oldRequest = lifetime.begin()
        var release: CheckedContinuation<Void, Never>?
        var progress = "B started"
        var output = "B output"
        var cachedOCR = "B OCR"
        let oldCompletion = Task {
            await withCheckedContinuation { release = $0 }
            // Deliberately ignore cancellation, as a callback-based OCR/backend can do.
            guard lifetime.accepts(oldRequest) else { return }
            progress = "A finished"
            output = "A output"
            cachedOCR = "A OCR"
        }
        lifetime.task = oldCompletion
        while release == nil { await Task.yield() }
        let replacementRequest = lifetime.begin()
        release?.resume()
        await oldCompletion.value
        XCTAssertEqual(progress, "B started")
        XCTAssertEqual(output, "B output")
        XCTAssertEqual(cachedOCR, "B OCR")
        XCTAssertTrue(lifetime.accepts(replacementRequest))
        XCTAssertTrue(oldCompletion.isCancelled)
        lifetime.invalidate()
        XCTAssertFalse(lifetime.accepts(replacementRequest))
    }

    func testAIExportSnapshotKeepsCompletedTaskAndDocument() {
        let source = URL(fileURLWithPath: "/synthetic/A.pdf")
        let snapshot = QuickFixAIOutputSnapshot(sourceURL: source, task: .summarize)
        var selectedTask = LocalAITask.summarize
        selectedTask = .translate
        XCTAssertEqual(snapshot.task, .summarize)
        XCTAssertEqual(snapshot.sourceURL, source)
        XCTAssertNotEqual(snapshot.task, selectedTask)
    }

    func testCleanupEvidenceSuggestedFileNameUsesOutputBaseName() {
        let outputURL = URL(fileURLWithPath: "/tmp/contract-fixed.pdf")

        XCTAssertEqual(
            QuickFixTab.cleanupEvidenceSuggestedFileName(outputURL: outputURL),
            "contract-fixed-cleanup-evidence.json"
        )
    }

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

    func testSavedReceiptUsesActualDestinationAndPreservesWrittenContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("quickfix-output-uuid.pdf")
        let destination = directory.appendingPathComponent("outbound/renamed.pdf")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("synthetic reviewed copy".utf8)
        try bytes.write(to: source)
        let result = QuickFixResult(
            outputURL: source, isTemporaryOutput: true, previewPageIndex: nil,
            redactionReport: RedactionReport(pagesWithRedactions: [], totalRedactionRectCount: 0, suppressedOCRRunCount: 0),
            ocrReport: OCRReport(totalPages: 1, localOCRPages: 0, cloudOCRPages: 0, visionOCRPages: 0,
                                 ocrDisabledPages: 1, emptyOCRPages: 0, emptyOCRPageIndices: [], localOCRFallbackCount: 0)
        )
        let saved = try QuickFixTab.saveResult(result, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(saved.displayOutputURL.lastPathComponent, "renamed.pdf")
        XCTAssertEqual(saved.displayOutputURL.deletingLastPathComponent(), destination.deletingLastPathComponent())
        XCTAssertFalse(saved.isTemporaryOutput)
        XCTAssertNotEqual(saved.displayOutputURL, source)
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
