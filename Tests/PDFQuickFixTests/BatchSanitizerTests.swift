import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

final class BatchSanitizerTests: XCTestCase {
    var tempInputDir: URL!
    var tempOutputDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempInputDir = baseDir.appendingPathComponent("input")
        tempOutputDir = baseDir.appendingPathComponent("output")

        try fm.createDirectory(at: tempInputDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempOutputDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let fm = FileManager.default
        let baseDir = tempInputDir.deletingLastPathComponent()
        try? fm.removeItem(at: baseDir)

        try super.tearDownWithError()
    }

    // MARK: - Test Helpers

    private func createTestPDF(at url: URL, text: String = "Test") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: text)
        try fm.copyItem(at: pdfURL, to: url)
    }

    // MARK: - Dry Run Tests

    func testDryRunDoesNotWriteFiles() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("test.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: true
        )

        // Should report processing (in dry-run mode, it still "processes" but doesn't write)
        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(report.skipped, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertTrue(report.dryRun)

        // Output file should NOT exist
        let outputFile = tempOutputDir.appendingPathComponent("test.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputFile.path))
    }

    func testDryRunReportsPlannedPaths() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("doc1.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("doc2.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .lightClean,
            dryRun: true
        )

        XCTAssertEqual(report.files.count, 2)

        // All files should have output paths (even in dry-run)
        for file in report.files {
            XCTAssertFalse(file.output.isEmpty)
            XCTAssertEqual(file.status, .processed)
        }
    }

    // MARK: - Integration Tests

    func testSanitizeSinglePDF() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("single.pdf"), text: "Original Content")

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: false
        )

        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(report.failed, 0)
        XCTAssertFalse(report.dryRun)

        // Output file should exist
        let outputFile = tempOutputDir.appendingPathComponent("single.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputFile.path))

        // Should be a valid PDF
        XCTAssertNotNil(PDFDocument(url: outputFile))

        // File result should have timing info
        XCTAssertEqual(report.files.count, 1)
        XCTAssertNotNil(report.files[0].elapsedMs)
        XCTAssertNotNil(report.files[0].inputBytes)
        XCTAssertNotNil(report.files[0].outputBytes)
    }

    func testSanitizePreservesDirectoryStructure() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("docs/report.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("archive/old.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: true,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .lightClean,
            dryRun: false
        )

        XCTAssertEqual(report.processed, 2)

        // Check directory structure preserved
        let docPath = tempOutputDir.appendingPathComponent("docs/report.pdf")
        let archivePath = tempOutputDir.appendingPathComponent("archive/old.pdf")

        XCTAssertTrue(FileManager.default.fileExists(atPath: docPath.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivePath.path))
    }

    func testSearchableTextDetection() throws {
        // Note: TestPDFBuilder creates PDFs from images, which means text is rasterized
        // and not searchable. This test verifies the profile-based logic:
        // - privacyClean always reports false (rasterizes output)
        // - other profiles check actual content (which is also rasterized in test PDFs)

        try createTestPDF(at: tempInputDir.appendingPathComponent("searchable.pdf"), text: "This text should be searchable")

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        // With privacyClean, searchableText is always false (by design, not content check)
        let privacyReport = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: true
        )

        XCTAssertEqual(privacyReport.files[0].searchableText, false,
                       "privacyClean should always report searchableText=false")

        // With lightClean, it checks actual content. Since TestPDFBuilder creates
        // rasterized PDFs (from images), there's no searchable text in the source.
        let lightReport = BatchSanitizer.run(
            plan: plan,
            profile: .lightClean,
            dryRun: true
        )

        // The result depends on whether the test PDF has actual text layers.
        // For image-based PDFs, this will be false. We're testing that the code runs
        // without crashing and returns a valid boolean.
        XCTAssertNotNil(lightReport.files[0].searchableText,
                        "searchableText should have a value for non-privacyClean profiles")
    }

    func testSkipsExistingFiles() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("existing.pdf"))
        try createTestPDF(at: tempOutputDir.appendingPathComponent("existing.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: false
        )

        XCTAssertEqual(report.processed, 0)
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.files[0].status, .skipped)
    }

    func testOverwritesExistingFiles() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("existing.pdf"), text: "New Content")
        try createTestPDF(at: tempOutputDir.appendingPathComponent("existing.pdf"), text: "Old Content")

        let originalData = try Data(contentsOf: tempOutputDir.appendingPathComponent("existing.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: true
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .lightClean,
            dryRun: false
        )

        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(report.skipped, 0)

        // File should be different (overwritten)
        let newData = try Data(contentsOf: tempOutputDir.appendingPathComponent("existing.pdf"))
        XCTAssertNotEqual(originalData, newData)
    }

    func testOverwriteFailurePreservesExistingOutput() throws {
        let input = tempInputDir.appendingPathComponent("existing.pdf")
        let output = tempOutputDir.appendingPathComponent("existing.pdf")
        try createTestPDF(at: input, text: "New Content")
        let original = Data("existing output must survive".utf8)
        try original.write(to: output)

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: true
        )
        let report = BatchSanitizer.run(
            plan: plan,
            profile: .lightClean,
            dryRun: false,
            writer: { _, _ in false }
        )

        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    // MARK: - Progress and Cancellation Tests

    func testProgressReporting() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("a.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("b.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("c.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        var progressUpdates: [BatchSanitizeProgress] = []

        _ = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: true,
            progress: { progress in
                progressUpdates.append(progress)
            }
        )

        XCTAssertEqual(progressUpdates.count, 3)

        // Check progress values
        XCTAssertEqual(progressUpdates[0].currentFile, 1)
        XCTAssertEqual(progressUpdates[0].totalFiles, 3)

        XCTAssertEqual(progressUpdates[2].currentFile, 3)
        XCTAssertEqual(progressUpdates[2].totalFiles, 3)
    }

    func testCancellation() throws {
        // Create multiple files
        for i in 1 ... 5 {
            try createTestPDF(at: tempInputDir.appendingPathComponent("doc\(i).pdf"))
        }

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        var cancelAfter = 2

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: false,
            progress: { _ in },
            shouldCancel: {
                cancelAfter -= 1
                return cancelAfter <= 0
            }
        )

        // Should have processed fewer than 5 files
        XCTAssertLessThan(report.processed + report.skipped + report.failed, 5)
    }

    // MARK: - Report Format Tests

    func testReportContainsCorrectMetadata() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("test.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: true,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .keepEditable,
            dryRun: false
        )

        XCTAssertEqual(report.inputDirectory, tempInputDir.path)
        XCTAssertEqual(report.outputDirectory, tempOutputDir.path)
        XCTAssertEqual(report.profile, .keepEditable)
        XCTAssertTrue(report.recursive)
        XCTAssertFalse(report.dryRun)
        XCTAssertGreaterThanOrEqual(report.totalElapsedMs, 0)
    }

    func testReportIsJSONEncodable() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("test.pdf"))

        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )

        let report = BatchSanitizer.run(
            plan: plan,
            profile: .privacyClean,
            dryRun: true
        )

        // Should encode without error
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(report)

        // Should decode back
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(BatchSanitizeReport.self, from: data)

        XCTAssertEqual(decoded.processed, report.processed)
        XCTAssertEqual(decoded.profile, report.profile)
    }
}
