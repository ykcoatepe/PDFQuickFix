import XCTest
@testable import PDFQuickFixKit

final class PDFRepairServiceTests: XCTestCase {
    
    func testRepairForExport_SmallFile() throws {
        // Create a dummy PDF
        let pdfData = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /MediaBox [0 0 612 792] /Parent 2 0 R >>\nendobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n185\n%%EOF".data(using: .utf8)!
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_small.pdf")
        try pdfData.write(to: tempURL)
        
        let service = PDFRepairService()
        let repairedURL = try service.repairForExport(inputURL: tempURL)
        
        XCTAssertTrue(FileManager.default.fileExists(atPath: repairedURL.path))
        XCTAssertNotEqual(tempURL, repairedURL)
        
        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: repairedURL)
    }
    
    func testRepairForExport_Failure() {
        // Create an invalid file
        let invalidData = "Not a PDF".data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_invalid.pdf")
        try? invalidData.write(to: tempURL)
        
        let service = PDFRepairService()
        XCTAssertThrowsError(try service.repairForExport(inputURL: tempURL))
        
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testRepairForCLI_DryRun() throws {
        // Create a dummy PDF
        let pdfData = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /MediaBox [0 0 612 792] /Parent 2 0 R >>\nendobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n185\n%%EOF".data(using: .utf8)!
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_cli_dry.pdf")
        try pdfData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let service = PDFRepairService()
        // Dry run (outputURL: nil)
        let result = service.repairForCLI(inputURL: tempURL, outputURL: nil)
        
        XCTAssertEqual(result.mode, .cli)
        XCTAssertEqual(result.outcome, .repaired)
        XCTAssertNil(result.outputPath)
        XCTAssertGreaterThan(result.originalSize, 0)
        XCTAssertGreaterThan(result.repairedSize ?? 0, 0)
        XCTAssertGreaterThan(result.pageCount ?? 0, 0)
    }
    
    func testRepairForCLI_WithOutput() throws {
        let pdfData = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n3 0 obj\n<< /Type /Page /MediaBox [0 0 612 792] /Parent 2 0 R >>\nendobj\nxref\n0 4\n0000000000 65535 f \n0000000009 00000 n \n0000000058 00000 n \n0000000115 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R >>\nstartxref\n185\n%%EOF".data(using: .utf8)!
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_cli_in.pdf")
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_cli_out.pdf")
        try pdfData.write(to: tempURL)
        defer {
            try? FileManager.default.removeItem(at: tempURL)
            try? FileManager.default.removeItem(at: outURL)
        }
        
        let service = PDFRepairService()
        let result = service.repairForCLI(inputURL: tempURL, outputURL: outURL)
        
        XCTAssertEqual(result.outcome, .repaired)
        XCTAssertEqual(result.outputPath, outURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }
    
    func testRepairForCLI_Failure() {
        let invalidData = "Not a PDF".data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_cli_fail.pdf")
        try? invalidData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        let service = PDFRepairService()
        let result = service.repairForCLI(inputURL: tempURL, outputURL: nil)
        
        XCTAssertEqual(result.outcome, .parseFailed)
        XCTAssertNotNil(result.reason)
    }
}
