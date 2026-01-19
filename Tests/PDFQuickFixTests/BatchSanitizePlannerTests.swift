import XCTest
import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit

final class BatchSanitizePlannerTests: XCTestCase {
    
    var tempInputDir: URL!
    var tempOutputDir: URL!
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        
        // Create temp directories
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        tempInputDir = baseDir.appendingPathComponent("input")
        tempOutputDir = baseDir.appendingPathComponent("output")
        
        try fm.createDirectory(at: tempInputDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: tempOutputDir, withIntermediateDirectories: true)
    }
    
    override func tearDownWithError() throws {
        // Clean up temp directories
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
    
    // MARK: - Basic Planning Tests
    
    func testPlanEmptyDirectory() throws {
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 0)
        XCTAssertEqual(plan.processableCount, 0)
        XCTAssertEqual(plan.skippedCount, 0)
    }
    
    func testPlanSinglePDF() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("test.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].relativePath, "test.pdf")
        XCTAssertEqual(plan.items[0].outputURL.lastPathComponent, "test.pdf")
        XCTAssertFalse(plan.items[0].willSkip)
    }
    
    func testPlanMultiplePDFs() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("a.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("b.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("c.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 3)
        
        // Should be sorted alphabetically
        XCTAssertEqual(plan.items[0].relativePath, "a.pdf")
        XCTAssertEqual(plan.items[1].relativePath, "b.pdf")
        XCTAssertEqual(plan.items[2].relativePath, "c.pdf")
    }
    
    func testPlanIgnoresNonPDFs() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("test.pdf"))
        try "Not a PDF".write(to: tempInputDir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "Image".write(to: tempInputDir.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].relativePath, "test.pdf")
    }
    
    // MARK: - Recursive Tests
    
    func testNonRecursiveIgnoresSubdirectories() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("root.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("subdir/nested.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].relativePath, "root.pdf")
    }
    
    func testRecursiveIncludesSubdirectories() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("root.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("subdir/nested.pdf"))
        try createTestPDF(at: tempInputDir.appendingPathComponent("subdir/deep/deeper.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: true,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 3)
        
        // Check relative paths preserve structure
        let paths = plan.items.map { $0.relativePath }
        XCTAssertTrue(paths.contains("root.pdf"))
        XCTAssertTrue(paths.contains("subdir/nested.pdf"))
        XCTAssertTrue(paths.contains("subdir/deep/deeper.pdf"))
    }
    
    func testRecursivePreservesDirectoryStructure() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("docs/report.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: true,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertEqual(plan.items[0].relativePath, "docs/report.pdf")
        XCTAssertEqual(plan.items[0].outputURL.path, tempOutputDir.path + "/docs/report.pdf")
    }
    
    // MARK: - Skip/Overwrite Tests
    
    func testSkipsExistingWhenOverwriteFalse() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("existing.pdf"))
        try createTestPDF(at: tempOutputDir.appendingPathComponent("existing.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertTrue(plan.items[0].willSkip)
        XCTAssertEqual(plan.skippedCount, 1)
        XCTAssertEqual(plan.processableCount, 0)
    }
    
    func testDoesNotSkipExistingWhenOverwriteTrue() throws {
        try createTestPDF(at: tempInputDir.appendingPathComponent("existing.pdf"))
        try createTestPDF(at: tempOutputDir.appendingPathComponent("existing.pdf"))
        
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: tempOutputDir,
            recursive: false,
            overwrite: true
        )
        
        XCTAssertEqual(plan.items.count, 1)
        XCTAssertFalse(plan.items[0].willSkip)
        XCTAssertEqual(plan.skippedCount, 0)
        XCTAssertEqual(plan.processableCount, 1)
    }
    
    // MARK: - Output Inside Input Guard (Critical)
    
    func testThrowsWhenOutputInsideInputWithRecursive() throws {
        let nestedOutput = tempInputDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: nestedOutput, withIntermediateDirectories: true)
        
        XCTAssertThrowsError(
            try BatchSanitizePlanner.plan(
                inputDir: tempInputDir,
                outputDir: nestedOutput,
                recursive: true,
                overwrite: false
            )
        ) { error in
            guard case BatchPlannerError.outputInsideInput = error else {
                XCTFail("Expected outputInsideInput error, got \(error)")
                return
            }
        }
    }
    
    func testAllowsOutputInsideInputWithNonRecursive() throws {
        // When non-recursive, this is actually safe since we won't enumerate subdirs
        let nestedOutput = tempInputDir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: nestedOutput, withIntermediateDirectories: true)
        try createTestPDF(at: tempInputDir.appendingPathComponent("test.pdf"))
        
        // Should NOT throw for non-recursive
        let plan = try BatchSanitizePlanner.plan(
            inputDir: tempInputDir,
            outputDir: nestedOutput,
            recursive: false,
            overwrite: false
        )
        
        XCTAssertEqual(plan.items.count, 1)
    }
    
    func testThrowsWhenOutputEqualsInputWithRecursive() throws {
        XCTAssertThrowsError(
            try BatchSanitizePlanner.plan(
                inputDir: tempInputDir,
                outputDir: tempInputDir,
                recursive: true,
                overwrite: false
            )
        ) { error in
            guard case BatchPlannerError.outputInsideInput = error else {
                XCTFail("Expected outputInsideInput error, got \(error)")
                return
            }
        }
    }
    
    // MARK: - Error Cases
    
    func testThrowsForNonexistentInput() throws {
        let badInput = tempInputDir.appendingPathComponent("does_not_exist")
        
        XCTAssertThrowsError(
            try BatchSanitizePlanner.plan(
                inputDir: badInput,
                outputDir: tempOutputDir,
                recursive: false,
                overwrite: false
            )
        ) { error in
            guard case BatchPlannerError.inputDirectoryNotFound = error else {
                XCTFail("Expected inputDirectoryNotFound error, got \(error)")
                return
            }
        }
    }
    
    func testThrowsWhenInputIsFile() throws {
        let fileURL = tempInputDir.appendingPathComponent("notadir.pdf")
        try createTestPDF(at: fileURL)
        
        XCTAssertThrowsError(
            try BatchSanitizePlanner.plan(
                inputDir: fileURL,
                outputDir: tempOutputDir,
                recursive: false,
                overwrite: false
            )
        ) { error in
            guard case BatchPlannerError.inputNotDirectory = error else {
                XCTFail("Expected inputNotDirectory error, got \(error)")
                return
            }
        }
    }
}
