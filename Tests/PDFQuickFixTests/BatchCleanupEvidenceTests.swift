import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

final class BatchCleanupEvidenceTests: XCTestCase {
    func testEmptyBatchRequiresReviewInsteadOfPassing() {
        let input = URL(fileURLWithPath: "/private/empty-batch/input")
        let output = URL(fileURLWithPath: "/private/empty-batch/output")
        let plan = BatchSanitizePlanner.Plan(
            items: [],
            inputDirectory: input,
            outputDirectory: output,
            recursive: false,
            overwrite: false
        )
        let report = BatchSanitizeReport(
            inputDirectory: input.path,
            outputDirectory: output.path,
            profile: .privacyClean,
            recursive: false,
            dryRun: false,
            processed: 0,
            skipped: 0,
            failed: 0,
            totalElapsedMs: 0,
            files: []
        )

        let manifest = BatchCleanupEvidenceBuilder.build(plan: plan, report: report)

        XCTAssertEqual(manifest.verdict, .reviewRequired)
    }

    func testProcessedFileCreatesPrivacySafeEvidenceManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Private Batch Root \(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("input", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceURL = input.appendingPathComponent("contract.pdf")
        try copyTestPDF(text: "TOP SECRET CONTRACT", to: sourceURL)
        let plan = try BatchSanitizePlanner.plan(
            inputDir: input,
            outputDir: output,
            recursive: false,
            overwrite: false
        )
        let report = BatchSanitizer.run(
            plan: plan,
            profile: .lightClean,
            dryRun: false
        )

        let manifest = BatchCleanupEvidenceBuilder.build(
            plan: plan,
            report: report,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertEqual(manifest.schemaVersion, "1.0")
        XCTAssertEqual(manifest.sanitizeProfile, SanitizeProfile.lightClean.rawValue)
        XCTAssertEqual(manifest.files.count, 1)
        XCTAssertEqual(manifest.files[0].status, .processed)
        XCTAssertEqual(manifest.files[0].evidence?.source.fileName, "contract.pdf")
        XCTAssertNotEqual(manifest.files[0].verdict, .failed)
        XCTAssertEqual(manifest.verdict, manifest.files[0].verdict)

        let data = try BatchCleanupEvidenceWriter.jsonData(for: manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains(root.path))
        XCTAssertFalse(json.contains("TOP SECRET CONTRACT"))
    }

    func testManifestRepresentsSkippedFailedAndNotProcessedWithoutRawErrors() throws {
        let root = URL(fileURLWithPath: "/private/batch-root")
        let input = root.appendingPathComponent("input")
        let output = root.appendingPathComponent("output")
        let items = [
            item(named: "skipped.pdf", input: input, output: output, willSkip: true),
            item(named: "failed.pdf", input: input, output: output),
            item(named: "cancelled.pdf", input: input, output: output),
        ]
        let plan = BatchSanitizePlanner.Plan(
            items: items,
            inputDirectory: input,
            outputDirectory: output,
            recursive: true,
            overwrite: false
        )
        let report = BatchSanitizeReport(
            inputDirectory: input.path,
            outputDirectory: output.path,
            profile: .privacyClean,
            recursive: true,
            dryRun: false,
            processed: 0,
            skipped: 1,
            failed: 1,
            totalElapsedMs: 10,
            files: [
                .init(input: "skipped.pdf", output: "skipped.pdf", status: .skipped),
                .init(
                    input: "failed.pdf",
                    output: "failed.pdf",
                    status: .failed,
                    error: "Sensitive raw failure at /private/batch-root/input/failed.pdf"
                ),
            ]
        )

        let manifest = BatchCleanupEvidenceBuilder.build(plan: plan, report: report)

        XCTAssertEqual(manifest.verdict, .failed)
        XCTAssertEqual(manifest.files.map(\.status), [.skipped, .failed, .notProcessed])
        XCTAssertEqual(
            manifest.files.map(\.reason),
            [.existingOutputNotEvaluated, .sanitizeFailed, .notProcessed]
        )
        XCTAssertEqual(Set(manifest.files.map(\.id)).count, 3)

        let data = try BatchCleanupEvidenceWriter.jsonData(for: manifest)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("Sensitive raw failure"))
        XCTAssertFalse(json.contains(root.path))
    }

    func testMissingProcessedOutputKeepsProcessedStatusAndMarksEvidenceUnavailable() {
        let root = URL(fileURLWithPath: "/private/missing-output")
        let input = root.appendingPathComponent("input")
        let output = root.appendingPathComponent("output")
        let plan = BatchSanitizePlanner.Plan(
            items: [item(named: "gone.pdf", input: input, output: output)],
            inputDirectory: input,
            outputDirectory: output,
            recursive: false,
            overwrite: false
        )
        let report = BatchSanitizeReport(
            inputDirectory: input.path,
            outputDirectory: output.path,
            profile: .keepEditable,
            recursive: false,
            dryRun: false,
            processed: 1,
            skipped: 0,
            failed: 0,
            totalElapsedMs: 1,
            files: [.init(input: "gone.pdf", output: "gone.pdf", status: .processed)]
        )

        let manifest = BatchCleanupEvidenceBuilder.build(plan: plan, report: report)

        XCTAssertEqual(manifest.files[0].status, .processed)
        XCTAssertEqual(manifest.files[0].verdict, .reviewRequired)
        XCTAssertEqual(manifest.files[0].reason, .evidenceUnavailable)
        XCTAssertNil(manifest.files[0].evidence)
    }

    func testDuplicateBasenamesUseDistinctIDsWithoutLeakingSubdirectories() throws {
        let root = URL(fileURLWithPath: "/private/duplicate-basenames")
        let input = root.appendingPathComponent("input")
        let output = root.appendingPathComponent("output")
        let relativePaths = ["legal/contract.pdf", "finance/contract.pdf"]
        let items = relativePaths.map { relativePath in
            BatchSanitizePlanner.Item(
                inputURL: input.appendingPathComponent(relativePath),
                outputURL: output.appendingPathComponent(relativePath),
                relativePath: relativePath,
                willSkip: true
            )
        }
        let plan = BatchSanitizePlanner.Plan(
            items: items,
            inputDirectory: input,
            outputDirectory: output,
            recursive: true,
            overwrite: false
        )
        let report = BatchSanitizeReport(
            inputDirectory: input.path,
            outputDirectory: output.path,
            profile: .privacyClean,
            recursive: true,
            dryRun: false,
            processed: 0,
            skipped: 2,
            failed: 0,
            totalElapsedMs: 1,
            files: relativePaths.map {
                .init(input: $0, output: $0, status: .skipped)
            }
        )

        let manifest = BatchCleanupEvidenceBuilder.build(plan: plan, report: report)

        XCTAssertEqual(manifest.files.map(\.fileName), ["contract.pdf", "contract.pdf"])
        XCTAssertEqual(Set(manifest.files.map(\.id)).count, 2)
        let json = try XCTUnwrap(String(
            data: BatchCleanupEvidenceWriter.jsonData(for: manifest),
            encoding: .utf8
        ))
        XCTAssertFalse(json.contains("legal"))
        XCTAssertFalse(json.contains("finance"))
        XCTAssertFalse(json.contains(root.path))
    }

    private func item(named name: String,
                      input: URL,
                      output: URL,
                      willSkip: Bool = false) -> BatchSanitizePlanner.Item
    {
        BatchSanitizePlanner.Item(
            inputURL: input.appendingPathComponent(name),
            outputURL: output.appendingPathComponent(name),
            relativePath: name,
            willSkip: willSkip
        )
    }

    private func copyTestPDF(text: String, to destination: URL) throws {
        let source = try TestPDFBuilder.makeSimplePDF(text: text)
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
