import XCTest
@testable import PDFQuickFix

class MockBookmarking: Bookmarking {
    var storedBookmarks: [URL: Data] = [:]
    var resolvedURLs: [Data: URL] = [:]
    var isStaleMap: [Data: Bool] = [:]
    
    func bookmarkData(for url: URL, includingResourceValuesForKeys keys: Set<URLResourceKey>?, relativeTo relativeURL: URL?) throws -> Data {
        let data = url.path.data(using: .utf8)!
        storedBookmarks[url] = data
        resolvedURLs[data] = url
        return data
    }
    
    func resolveBookmarkData(_ data: Data, options: URL.BookmarkResolutionOptions, relativeTo relativeURL: URL?) throws -> (url: URL, isStale: Bool) {
        // Simple mock: treat data as path string
        guard let url = resolvedURLs[data] else {
            throw NSError(domain: "MockBookmarking", code: 404, userInfo: nil)
        }
        return (url, isStaleMap[data] ?? false)
    }
}

final class RecentFilesManagerTests: XCTestCase {
    
    var defaults: UserDefaults!
    var bookmarking: MockBookmarking!
    var manager: RecentFilesManager!
    
    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TestDefaults")!
        defaults.removePersistentDomain(forName: "TestDefaults")
        bookmarking = MockBookmarking()
        manager = RecentFilesManager(bookmarking: bookmarking, defaults: defaults)
    }
    
    override func tearDown() {
        defaults.removePersistentDomain(forName: "TestDefaults")
        super.tearDown()
    }
    
    func testAddRecentFile() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        
        manager.add(url: url, pageCount: 5)
        
        XCTAssertEqual(manager.recentFiles.count, 1)
        XCTAssertEqual(manager.recentFiles.first?.displayName, "test.pdf")
        XCTAssertEqual(manager.recentFiles.first?.pageCount, 5)
        
        // Check persistence
        let stored = defaults.data(forKey: "PDFQuickFix_RecentFiles")
        XCTAssertNotNil(stored)
    }
    
    func testDeduplication() {
        let url = URL(fileURLWithPath: "/tmp/test.pdf")
        
        manager.add(url: url, pageCount: 5)
        manager.add(url: url, pageCount: 10) // Should simplify update
        
        XCTAssertEqual(manager.recentFiles.count, 1)
        XCTAssertEqual(manager.recentFiles.first?.pageCount, 10)
    }
    
    func testLimitRecentFiles() {
        for i in 0..<15 {
            let url = URL(fileURLWithPath: "/tmp/test\(i).pdf")
            manager.add(url: url, pageCount: 1)
        }
        
        XCTAssertEqual(manager.recentFiles.count, 10)
        XCTAssertEqual(manager.recentFiles.first?.displayName, "test14.pdf")
    }
    
    func testResolveForOpen() throws {
        let url = URL(fileURLWithPath: "/tmp/doc.pdf")
        manager.add(url: url, pageCount: 1)
        
        guard let file = manager.recentFiles.first else {
            XCTFail("Should have a file")
            return
        }
        
        let (resolvedURL, access) = try manager.resolveForOpen(file)
        
        XCTAssertEqual(resolvedURL.path, "/tmp/doc.pdf")
        XCTAssertNotNil(access)
        // Ensure access wraps correct URL
        XCTAssertEqual(access.url.path, "/tmp/doc.pdf")
    }
    
    func testRemoveRecentFile() {
        let url1 = URL(fileURLWithPath: "/tmp/1.pdf")
        let url2 = URL(fileURLWithPath: "/tmp/2.pdf")
        
        manager.add(url: url1, pageCount: 1)
        manager.add(url: url2, pageCount: 1)
        
        XCTAssertEqual(manager.recentFiles.count, 2)
        
        if let file = manager.recentFiles.first(where: { $0.displayName == "1.pdf" }) {
            manager.remove(file)
        }
        
        XCTAssertEqual(manager.recentFiles.count, 1)
        XCTAssertEqual(manager.recentFiles.first?.displayName, "2.pdf")
    }
    
    func testStaleBookmarkUpdates() throws {
        let oldURL = URL(fileURLWithPath: "/tmp/old.pdf")
        let newURL = URL(fileURLWithPath: "/tmp/new.pdf")
        
        // Add file initially
        manager.add(url: oldURL, pageCount: 1)
        guard let file = manager.recentFiles.first else { return }
        
        // Mock the stale resolution:
        // The bookmark data for oldURL typically resolves to oldURL.
        // But here we want to simulate that the system Says "Hey, this data actually resolves to newURL now, and it's Stale (meaning you should update data)".
        // So we need to hack the mock map.
        
        let oldData = try bookmarking.bookmarkData(for: oldURL, includingResourceValuesForKeys: nil, relativeTo: nil)
        
        // Update mock to return newURL + isStale=true for oldData
        bookmarking.resolvedURLs[oldData] = newURL
        bookmarking.isStaleMap[oldData] = true
        
        // Resolve
        let (resolved, _) = try manager.resolveForOpen(file)
        
        XCTAssertEqual(resolved.path, newURL.path)
        
        // Ensure the manager updated its internal list with the NEW bookmark data for newURL
        let newData = try bookmarking.bookmarkData(for: newURL, includingResourceValuesForKeys: nil, relativeTo: nil)
        
        XCTAssertEqual(manager.recentFiles.first?.bookmark, newData)
        XCTAssertEqual(manager.recentFiles.first?.displayName, "new.pdf")
    }
}
