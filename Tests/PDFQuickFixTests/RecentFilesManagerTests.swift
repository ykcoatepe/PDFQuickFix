import XCTest
@testable import PDFQuickFix

final class RecentFilesManagerTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Clear existing defaults to start fresh
        UserDefaults.standard.removeObject(forKey: "PDFQuickFix_RecentFiles")
    }
    
    override func tearDown() {
        // Clean up
        UserDefaults.standard.removeObject(forKey: "PDFQuickFix_RecentFiles")
        super.tearDown()
    }
    
    func testAddRecentFile() {
        // Given
        let manager = RecentFilesManager.shared
        // Reset internal state since it's a singleton that loads on init
        manager.recentFiles = []
        
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        
        // When
        manager.add(url: url, pageCount: 5)
        
        // Then
        XCTAssertEqual(manager.recentFiles.count, 1)
        XCTAssertEqual(manager.recentFiles.first?.url, url)
        XCTAssertEqual(manager.recentFiles.first?.pageCount, 5)
    }
    
    func testLimitRecentFiles() {
        // Given
        let manager = RecentFilesManager.shared
        manager.recentFiles = []
        
        // When
        for i in 0..<15 {
            let url = URL(fileURLWithPath: "/tmp/test\(i).pdf")
            manager.add(url: url, pageCount: 1)
        }
        
        // Then
        XCTAssertEqual(manager.recentFiles.count, 10)
        // The last added (test14) should be first
        XCTAssertEqual(manager.recentFiles.first?.url.lastPathComponent, "test14.pdf")
    }
}
