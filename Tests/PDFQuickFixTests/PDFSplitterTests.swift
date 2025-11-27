import XCTest
import PDFKit
@testable import PDFQuickFix

final class PDFSplitterTests: XCTestCase {
    
    var tempDir: URL!
    
    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }
    
    func testSplitMaxPages() throws {
        // Given
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 10)
        let options = PDFSplitOptions(sourceURL: url,
                                      destinationDirectory: tempDir,
                                      mode: .maxPagesPerPart(3))
        let splitter = PDFSplitter()
        
        // When
        let result = try splitter.split(options: options)
        
        // Then
        // 10 pages split by 3 -> 3, 3, 3, 1 -> 4 parts
        XCTAssertEqual(result.outputFiles.count, 4)
        
        let part1 = PDFDocument(url: result.outputFiles[0])!
        XCTAssertEqual(part1.pageCount, 3)
        
        let part4 = PDFDocument(url: result.outputFiles[3])!
        XCTAssertEqual(part4.pageCount, 1)
    }
    
    func testSplitNumberOfParts() throws {
        // Given
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 10)
        let options = PDFSplitOptions(sourceURL: url,
                                      destinationDirectory: tempDir,
                                      mode: .numberOfParts(2))
        let splitter = PDFSplitter()
        
        // When
        let result = try splitter.split(options: options)
        
        // Then
        // 10 pages split into 2 parts -> 5, 5
        XCTAssertEqual(result.outputFiles.count, 2)
        
        let part1 = PDFDocument(url: result.outputFiles[0])!
        XCTAssertEqual(part1.pageCount, 5)
        
        let part2 = PDFDocument(url: result.outputFiles[1])!
        XCTAssertEqual(part2.pageCount, 5)
    }
}
