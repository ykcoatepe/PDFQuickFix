import CoreGraphics
import CoreText
import PDFCore
import PDFKit
import PDFQuickFixKit
@testable import PDFQuickFix
import XCTest

final class PipelineSafetyTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testExclusivePublicationMovesStagingAndPreservesCollision() throws {
        let staged = directory.appendingPathComponent("staged.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        let content = Data("NEW CONTENT".utf8)
        let sentinel = Data("EXISTING OUTPUT".utf8)
        try content.write(to: staged)
        try sentinel.write(to: output)
        XCTAssertThrowsError(try PDFFilePublication.publish(staged: staged, to: output, overwrite: false)) {
            guard case PDFFilePublication.PublicationError.destinationExists = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: staged), content)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        try FileManager.default.removeItem(at: output)
        let published = try PDFFilePublication.publish(staged: staged, to: output, overwrite: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "Publication must move staging rather than retain a hard link")
        XCTAssertEqual(try Data(contentsOf: output), content)
        XCTAssertTrue(try published.removeIfUnchanged())
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testPublicationRollbackPreservesReplacementAtPublishedPath() throws {
        let staged = directory.appendingPathComponent("staged.pdf")
        let replacement = directory.appendingPathComponent("replacement.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        try Data("NEW CONTENT".utf8).write(to: staged)
        let sentinel = Data("REPLACEMENT".utf8)
        try sentinel.write(to: replacement)
        let published = try PDFFilePublication.publish(staged: staged, to: output, overwrite: false)
        try FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: replacement, to: output)
        XCTAssertFalse(try published.removeIfUnchanged())
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    func testPublicationRollbackPreservesInPlaceEditedOutput() throws {
        let staged = directory.appendingPathComponent("staged.pdf")
        let output = directory.appendingPathComponent("output.pdf")
        try Data("NEW CONTENT".utf8).write(to: staged)
        let published = try PDFFilePublication.publish(staged: staged, to: output, overwrite: false)
        let edited = Data("USER EDITED THE PUBLISHED FILE".utf8)
        let handle = try FileHandle(forWritingTo: output)
        try handle.write(contentsOf: edited)
        try handle.close()
        XCTAssertFalse(try published.removeIfUnchanged())
        XCTAssertEqual(try Data(contentsOf: output), edited)
    }

    private func fixture(_ name: String = "source.pdf", pages: Int = 2) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 1 ... pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 20, y: 150)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica" as CFString, 20, nil)]
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "ALPHA \(index)", attributes: attributes)), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func encryptedFixture(password: String = "secret") throws -> URL {
        let source = try fixture()
        let output = directory.appendingPathComponent("encrypted.pdf")
        let document = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(document.write(to: output, withOptions: [.userPasswordOption: password, .ownerPasswordOption: "owner"]))
        return output
    }

    func testAllProfilesRejectLockedDocumentWithoutMutation() throws {
        let url = try encryptedFixture()
        for profile in SanitizeProfile.allCases {
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertTrue(document.isLocked)
            let attributes = document.documentAttributes as NSDictionary?
            XCTAssertThrowsError(try PDFDocumentSanitizer.sanitize(document: document, options: .from(profile: profile))) {
                guard case PDFDocumentSanitizerError.lockedDocument = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            XCTAssertEqual(document.documentAttributes as NSDictionary?, attributes)
            XCTAssertTrue(document.isLocked)
        }
    }

    func testUnlockedDocumentStillSanitizes() throws {
        let document = try XCTUnwrap(PDFDocument(url: encryptedFixture()))
        XCTAssertTrue(document.unlock(withPassword: "secret"))
        let sanitized = try PDFDocumentSanitizer.sanitize(document: document, options: .from(profile: .privacyClean))
        XCTAssertEqual(sanitized.pageCount, 2)
        XCTAssertFalse(sanitized.isLocked)
    }

    func testEncryptedRepairRefusesLockedAndEmptyUserPasswordWithoutChangingOutput() throws {
        for password in ["secret", ""] {
            let input = try encryptedFixture(password: password)
            let output = directory.appendingPathComponent("repaired.pdf")
            let sentinel = Data("existing output".utf8)
            try sentinel.write(to: output)
            let parsed = try PDFCoreParser(data: Data(contentsOf: input)).parseDocument()
            XCTAssertTrue(parsed.isEncrypted)
            XCTAssertThrowsError(try PDFCoreWriter.write(document: parsed))
            let result = PDFRepairService().repairForCLI(inputURL: input, outputURL: output)
            XCTAssertEqual(result.outcome, .unsupportedFeature)
            XCTAssertEqual(try Data(contentsOf: output), sentinel)
            XCTAssertThrowsError(try PDFRepairService().repairForExport(inputURL: input))
        }
    }

    func testEmptyAndMissingRootGraphsThrowInsteadOfTrapping() throws {
        XCTAssertThrowsError(try PDFCoreWriter.write(document: PDFCoreDocument()))
        let root = PDFCoreObjectRef(objectNumber: 1, generation: 0)
        XCTAssertThrowsError(try PDFCoreWriter.write(document: PDFCoreDocument(objects: [root: .dict([:])])))
        let input = directory.appendingPathComponent("empty.pdf")
        try Data("%PDF-1.4\nxref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 1 >>\nstartxref\n9\n%%EOF\n".utf8).write(to: input)
        let output = directory.appendingPathComponent("output.pdf")
        let sentinel = Data("preserve".utf8)
        try sentinel.write(to: output)
        let result = PDFRepairService().repairForCLI(inputURL: input, outputURL: output)
        XCTAssertEqual(result.outcome, .parseFailed)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    func testIdentityRejectsSamePathSymlinkAndHardlink() throws {
        let input = try fixture()
        let symlink = directory.appendingPathComponent("symbolic.pdf")
        let hardlink = directory.appendingPathComponent("hard.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        try FileManager.default.linkItem(at: input, to: hardlink)
        for output in [input, symlink, hardlink] {
            XCTAssertThrowsError(try PDFFilePublication.requireDistinct(input: input, output: output))
            let result = PDFRepairService().repairForCLI(inputURL: input, outputURL: output)
            XCTAssertEqual(result.outcome, .ioError)
        }
        XCTAssertNoThrow(try PDFFilePublication.requireDistinct(input: input, output: directory.appendingPathComponent("new.pdf")))
    }

    func testPlannerRejectsSameNonrecursiveDirectoryAndHardlinkedDestination() throws {
        let input = try fixture()
        XCTAssertThrowsError(try BatchSanitizePlanner.plan(inputDir: directory, outputDir: directory, recursive: false, overwrite: true))
        let outputDir = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: false)
        try FileManager.default.linkItem(at: input, to: outputDir.appendingPathComponent(input.lastPathComponent))
        XCTAssertThrowsError(try BatchSanitizePlanner.plan(inputDir: directory, outputDir: outputDir, recursive: false, overwrite: true))
    }

    func testBatchRejectsIdentityIntroducedAfterPlanning() throws {
        let input = try fixture()
        let original = try Data(contentsOf: input)
        let outputDir = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: false)
        let plan = try BatchSanitizePlanner.plan(inputDir: directory, outputDir: outputDir, recursive: false, overwrite: true)
        let output = outputDir.appendingPathComponent(input.lastPathComponent)
        let report = BatchSanitizer.run(plan: plan, profile: .lightClean, dryRun: false, writer: { document, staged in
            try? FileManager.default.linkItem(at: input, to: output)
            return document.write(to: staged)
        })
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.processed, 0)
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testBatchLateCollisionIsSkippedAtPublication() throws {
        let input = try fixture()
        let outputDir = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: false)
        let plan = try BatchSanitizePlanner.plan(inputDir: directory, outputDir: outputDir, recursive: false, overwrite: false)
        let output = outputDir.appendingPathComponent(input.lastPathComponent)
        let sentinel = Data("CREATED DURING SERIALIZATION".utf8)
        let report = BatchSanitizer.run(plan: plan, profile: .lightClean, dryRun: false, writer: { document, staged in
            try? sentinel.write(to: output)
            return document.write(to: staged)
        })
        XCTAssertEqual(report.skipped, 1)
        XCTAssertEqual(report.processed, 0)
        XCTAssertEqual(report.failed, 0)
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
    }

    func testBatchLateCancellationPreservesInFlightOutputAndPriorSuccess() throws {
        _ = try fixture("a.pdf")
        _ = try fixture("b.pdf")
        _ = try fixture("c.pdf")
        let outputDir = directory.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: false)
        let output = outputDir.appendingPathComponent("b.pdf")
        let sentinel = Data("KEEP EXISTING IN-FLIGHT OUTPUT".utf8)
        try sentinel.write(to: output)
        let plan = try BatchSanitizePlanner.plan(inputDir: directory, outputDir: outputDir, recursive: false, overwrite: true)
        var cancelled = false
        var writeCount = 0
        let report = BatchSanitizer.run(plan: plan, profile: .lightClean, dryRun: false, shouldCancel: { cancelled }, writer: { document, staged in
            writeCount += 1
            let success = document.write(to: staged)
            if writeCount == 2 { cancelled = true }
            return success
        })
        XCTAssertEqual(report.processed, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.files.count, 2)
        XCTAssertEqual(report.files.last?.status, .failed)
        XCTAssertEqual(report.files.last?.error, "Operation cancelled")
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertNotNil(PDFDocument(url: outputDir.appendingPathComponent("a.pdf")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("c.pdf").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: outputDir.path).contains { $0.hasPrefix(".pdfquickfix") })
    }

    func testBatchCancellationDuringSanitizationDoesNotInvokeWriter() throws {
        _ = try fixture()
        let outputDir = directory.appendingPathComponent("out")
        let plan = try BatchSanitizePlanner.plan(inputDir: directory, outputDir: outputDir, recursive: false, overwrite: false)
        var checks = 0
        var writes = 0
        let report = BatchSanitizer.run(plan: plan, profile: .privacyClean, dryRun: false, shouldCancel: {
            checks += 1
            return checks > 1
        }, writer: { _, _ in writes += 1; return false })
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(report.processed, 0)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.files.first?.error, "Operation cancelled")
    }

    func testBatchLockedInputFailsEveryProfilePreservingExistingOutput() throws {
        let input = try encryptedFixture()
        let output = directory.appendingPathComponent("output.pdf")
        let sentinel = Data("preserve".utf8)
        let item = BatchSanitizePlanner.Item(inputURL: input, outputURL: output, relativePath: "encrypted.pdf", willSkip: false)
        let plan = BatchSanitizePlanner.Plan(items: [item], inputDirectory: directory, outputDirectory: directory, recursive: false, overwrite: true)
        for profile in SanitizeProfile.allCases {
            try sentinel.write(to: output)
            let report = BatchSanitizer.run(plan: plan, profile: profile, dryRun: false)
            XCTAssertEqual(report.failed, 1)
            XCTAssertEqual(report.processed, 0)
            XCTAssertEqual(try Data(contentsOf: output), sentinel)
        }
    }

    func testSplitCollisionPreservesWholeExistingOutputSet() throws {
        let input = try fixture()
        let options = PDFSplitOptions(sourceURL: input, destinationDirectory: directory, mode: .maxPagesPerPart(1))
        let first = try PDFSplitter().split(options: options)
        let sentinel = Data("DO NOT REPLACE".utf8)
        try sentinel.write(to: first.outputFiles[1])
        try FileManager.default.removeItem(at: first.outputFiles[0])
        XCTAssertThrowsError(try PDFSplitter().split(options: options))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.outputFiles[0].path))
        XCTAssertEqual(try Data(contentsOf: first.outputFiles[1]), sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".pdfquickfix") })
    }

    func testSplitCollisionDuringCommitRollsBackOnlyPublishedParts() throws {
        let input = try fixture()
        let first = directory.appendingPathComponent("source_part01-of02_pages0001-0001.pdf")
        let second = directory.appendingPathComponent("source_part02-of02_pages0002-0002.pdf")
        let sentinel = Data("LATE COLLISION".utf8)
        XCTAssertThrowsError(try PDFSplitter().split(options: .init(sourceURL: input, destinationDirectory: directory, mode: .maxPagesPerPart(1)), shouldCancel: {
            if FileManager.default.fileExists(atPath: first.path) {
                try? sentinel.write(to: second)
            }
            return false
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: second), sentinel)
    }

    func testSplitCancellationAfterStagingLeavesNoOutputs() throws {
        let input = try fixture()
        var processed = 0
        XCTAssertThrowsError(try PDFSplitter().split(options: .init(sourceURL: input, destinationDirectory: directory, mode: .maxPagesPerPart(1)), progress: { value, _ in processed = value }, shouldCancel: { processed >= 1 }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [input.lastPathComponent])
    }

    func testNormalRepairPreservesPageCountAndText() throws {
        let input = try fixture()
        let output = directory.appendingPathComponent("output.pdf")
        let result = PDFRepairService().repairForCLI(inputURL: input, outputURL: output)
        XCTAssertEqual(result.outcome, .repaired)
        let repaired = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(repaired.pageCount, 2)
        XCTAssertTrue(repaired.string?.contains("ALPHA 1") == true)
        XCTAssertTrue(repaired.string?.contains("ALPHA 2") == true)
    }

    func testRepairRoundTripPreservesEscapedLiteralMetadataAndPageText() throws {
        let source = try fixture()
        var document = try PDFCoreParser(data: Data(contentsOf: source)).parseDocument()
        let info = PDFCoreObjectRef(objectNumber: (document.objects.keys.map(\.objectNumber).max() ?? 0) + 1, generation: 0)
        document.infoRef = info
        let title = "alpha ) omega (nested) \\ path\nnext\tline"
        document.objects[info] = .dict(["Title": .string(title)])
        let input = directory.appendingPathComponent("literal-input.pdf")
        try PDFCoreWriter.write(document: document).write(to: input)
        XCTAssertEqual(PDFDocument(url: input)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title)
        let output = directory.appendingPathComponent("literal-repaired.pdf")
        let result = PDFRepairService().repairForCLI(inputURL: input, outputURL: output)
        XCTAssertEqual(result.outcome, .repaired)
        let repaired = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(repaired.pageCount, 2)
        XCTAssertEqual(repaired.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title)
        XCTAssertTrue(repaired.string?.contains("ALPHA 1") == true)
        let reparsed = try PDFCoreParser(data: Data(contentsOf: output)).parseDocument()
        let rewritten = try PDFCoreWriter.write(document: reparsed)
        XCTAssertEqual(PDFDocument(data: rewritten)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, title)
    }
}
