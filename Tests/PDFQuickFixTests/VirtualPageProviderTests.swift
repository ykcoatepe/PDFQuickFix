import XCTest
@testable import PDFQuickFix

@MainActor
final class VirtualPageProviderTests: XCTestCase {
    
    private var thumbnailCache: NSCache<NSNumber, CGImage>!
    private var provider: VirtualPageProvider!
    
    override func setUp() {
        super.setUp()
        thumbnailCache = NSCache<NSNumber, CGImage>()
        thumbnailCache.countLimit = 200
        provider = VirtualPageProvider(thumbnailCache: thumbnailCache, windowSize: 50)
    }
    
    override func tearDown() {
        provider = nil
        thumbnailCache = nil
        super.tearDown()
    }
    
    // MARK: - Configuration Tests
    
    func testConfigureSmallDocument() {
        // Small doc should NOT be virtualized
        provider.configure(pageCount: 100)
        
        XCTAssertFalse(provider.isVirtualized)
        XCTAssertEqual(provider.totalCount, 100)
        XCTAssertEqual(provider.visibleSnapshots.count, 100)
        XCTAssertEqual(provider.materializedRange, 0..<100)
    }
    
    func testConfigureMassiveDocument() {
        // Massive doc should be virtualized
        provider.configure(pageCount: 7000)
        
        XCTAssertTrue(provider.isVirtualized)
        XCTAssertEqual(provider.totalCount, 7000)
        // Window of 50 centered at 0 means 0..<25 (half window each side, clamped to start)
        XCTAssertEqual(provider.visibleSnapshots.count, 25)
        XCTAssertEqual(provider.materializedRange, 0..<25)
    }
    
    func testForceVirtualize() {
        // Force virtualization even for small doc
        provider.configure(pageCount: 100, forceVirtualize: true)
        
        XCTAssertTrue(provider.isVirtualized)
        // Window of 50 centered at 0 in 100-page doc means 0..<25
        XCTAssertEqual(provider.visibleSnapshots.count, 25)
    }
    
    // MARK: - Window Movement Tests
    
    func testUpdateCenterMovesWindow() {
        provider.configure(pageCount: 7000)
        // Initially centered at 0, so 0..<25
        XCTAssertEqual(provider.materializedRange, 0..<25)
        
        // Move to page 500
        provider.updateCenter(500)
        
        // Window should be centered around 500 (500 - 25...500 + 25)
        XCTAssertEqual(provider.materializedRange.lowerBound, 475)
        XCTAssertEqual(provider.materializedRange.upperBound, 525)
        XCTAssertEqual(provider.visibleSnapshots.count, 50)
    }
    
    func testUpdateCenterClampsAtStart() {
        provider.configure(pageCount: 7000)
        
        provider.updateCenter(10)
        
        // Should clamp to start
        XCTAssertEqual(provider.materializedRange.lowerBound, 0)
        XCTAssertLessThanOrEqual(provider.materializedRange.upperBound, 50)
    }
    
    func testUpdateCenterClampsAtEnd() {
        provider.configure(pageCount: 7000)
        
        provider.updateCenter(6990)
        
        // Should clamp to end
        XCTAssertEqual(provider.materializedRange.upperBound, 7000)
        XCTAssertGreaterThanOrEqual(provider.materializedRange.lowerBound, 6950)
    }
    
    // MARK: - Eviction Tests
    
    func testEvictionOnWindowMove() {
        provider.configure(pageCount: 7000)
        
        // Get snapshot at page 0 (should be cached)
        let snap0 = provider.snapshot(at: 0)
        XCTAssertNotNil(snap0)
        XCTAssertTrue(provider.isMaterialized(0))
        
        // Move window far away
        provider.updateCenter(3000)
        
        // Page 0 should no longer be materialized
        XCTAssertFalse(provider.isMaterialized(0))
        // But page 3000 should be
        XCTAssertTrue(provider.isMaterialized(3000))
    }
    
    // MARK: - Snapshot Retrieval Tests
    
    func testSnapshotRetrieval() {
        provider.configure(pageCount: 7000)
        
        let snap = provider.snapshot(at: 25)
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.index, 25)
        XCTAssertEqual(snap?.label, "Page 26")
    }
    
    func testSnapshotOutOfBounds() {
        provider.configure(pageCount: 100)
        
        XCTAssertNil(provider.snapshot(at: -1))
        XCTAssertNil(provider.snapshot(at: 100))
        XCTAssertNil(provider.snapshot(at: 1000))
    }
    
    // MARK: - Thumbnail Update Tests
    
    func testThumbnailUpdate() {
        provider.configure(pageCount: 100, forceVirtualize: true)
        
        // Create a dummy thumbnail
        let context = CGContext(data: nil, width: 10, height: 10,
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let thumbnail = context.makeImage()!
        
        // Update thumbnail
        provider.updateThumbnail(at: 5, thumbnail: thumbnail)
        
        // Retrieve and verify
        let snap = provider.snapshot(at: 5)
        XCTAssertNotNil(snap?.thumbnail)
    }
    
    // MARK: - Reset Tests
    
    func testReset() {
        provider.configure(pageCount: 7000)
        XCTAssertEqual(provider.totalCount, 7000)
        
        provider.reset()
        
        XCTAssertEqual(provider.totalCount, 0)
        XCTAssertFalse(provider.isVirtualized)
        XCTAssertTrue(provider.visibleSnapshots.isEmpty)
    }
    
    // MARK: - Helper Tests
    
    func testDistanceFromCenter() {
        provider.configure(pageCount: 7000)
        provider.updateCenter(100)
        
        XCTAssertEqual(provider.distanceFromCenter(100), 0)
        XCTAssertEqual(provider.distanceFromCenter(50), 50)
        XCTAssertEqual(provider.distanceFromCenter(150), 50)
    }
}
