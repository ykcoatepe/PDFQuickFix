import XCTest
@testable import PDFQuickFix

final class StreamingPDFLoaderTests: XCTestCase {
    
    private var loader: StreamingPDFLoader!
    
    override func setUp() {
        super.setUp()
        loader = StreamingPDFLoader()
    }
    
    override func tearDown() {
        loader.close()
        loader = nil
        super.tearDown()
    }
    
    // MARK: - Open/Close Tests
    
    func testOpenValidPDF() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 3)
        let result = loader.open(url: url)
        
        XCTAssertTrue(result)
        XCTAssertTrue(loader.isOpen)
        XCTAssertEqual(loader.pageCount, 3)
        XCTAssertEqual(loader.fileURL, url)
    }
    
    func testOpenInvalidFile() {
        let invalid = URL(fileURLWithPath: "/tmp/nonexistent.pdf")
        let result = loader.open(url: invalid)
        
        XCTAssertFalse(result)
        XCTAssertFalse(loader.isOpen)
        XCTAssertEqual(loader.pageCount, 0)
    }
    
    func testClose() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 5)
        _ = loader.open(url: url)
        XCTAssertTrue(loader.isOpen)
        
        loader.close()
        
        XCTAssertFalse(loader.isOpen)
        XCTAssertEqual(loader.pageCount, 0)
        XCTAssertNil(loader.fileURL)
    }
    
    // MARK: - Page Access Tests
    
    func testCGPageAccess() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 5)
        _ = loader.open(url: url)
        
        let page0 = loader.cgPage(at: 0)
        let page4 = loader.cgPage(at: 4)
        let pageInvalid = loader.cgPage(at: 10)
        
        XCTAssertNotNil(page0)
        XCTAssertNotNil(page4)
        XCTAssertNil(pageInvalid)
    }
    
    func testHasPage() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 3)
        _ = loader.open(url: url)
        
        XCTAssertTrue(loader.hasPage(at: 0))
        XCTAssertTrue(loader.hasPage(at: 2))
        XCTAssertFalse(loader.hasPage(at: 3))
        XCTAssertFalse(loader.hasPage(at: -1))
    }
    
    // MARK: - Thumbnail Rendering Tests
    
    func testRenderThumbnail() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 2)
        _ = loader.open(url: url)
        
        let thumbnail = loader.renderThumbnail(at: 0, size: CGSize(width: 100, height: 150))
        
        XCTAssertNotNil(thumbnail)
        XCTAssertGreaterThan(thumbnail!.width, 0)
        XCTAssertGreaterThan(thumbnail!.height, 0)
    }
    
    func testRenderThumbnailInvalidPage() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 2)
        _ = loader.open(url: url)
        
        let thumbnail = loader.renderThumbnail(at: 10, size: CGSize(width: 100, height: 150))
        
        XCTAssertNil(thumbnail)
    }
    
    // MARK: - Page Size Tests
    
    func testPageSize() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 1)
        _ = loader.open(url: url)
        
        let size = loader.pageSize(at: 0)
        
        XCTAssertNotNil(size)
        XCTAssertGreaterThan(size!.width, 0)
        XCTAssertGreaterThan(size!.height, 0)
    }
    
    // MARK: - Page Resolution Tests
    
    func testResolvePage() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 3)
        _ = loader.open(url: url)
        
        let page = loader.resolvePage(at: 1)
        
        XCTAssertNotNil(page)
    }
    
    func testResolvePageCaching() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 3)
        _ = loader.open(url: url)
        
        let page1 = loader.resolvePage(at: 1)
        let page1Again = loader.resolvePage(at: 1)
        
        // Same page instance should be returned (cached)
        XCTAssertTrue(page1 === page1Again)
    }
    
    func testEvictResolvedPages() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 3)
        _ = loader.open(url: url)
        
        _ = loader.resolvePage(at: 0)
        _ = loader.resolvePage(at: 1)
        
        loader.evictResolvedPages()
        
        // After eviction, pages should be re-resolved
        // (can't directly test cache is empty, but the call shouldn't crash)
        let page = loader.resolvePage(at: 0)
        XCTAssertNotNil(page)
    }
    
    // MARK: - Quick Page Count Tests
    
    func testQuickPageCount() throws {
        let url = try TestPDFBuilder.makeMultipagePDF(pageCount: 10)
        
        let count = StreamingPDFLoader.quickPageCount(at: url)
        
        XCTAssertEqual(count, 10)
    }
    
    func testQuickPageCountInvalid() {
        let invalid = URL(fileURLWithPath: "/tmp/nonexistent.pdf")
        
        let count = StreamingPDFLoader.quickPageCount(at: invalid)
        
        XCTAssertNil(count)
    }
}
