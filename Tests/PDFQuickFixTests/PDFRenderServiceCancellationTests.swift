import XCTest
@testable import PDFQuickFix

final class PDFRenderServiceCancellationTests: XCTestCase {
    
    private var service: PDFRenderService!
    
    override func setUp() {
        super.setUp()
        service = PDFRenderService.shared
    }
    
    override func tearDown() {
        service.cancelAll()
        super.tearDown()
    }
    
    // MARK: - Cancel Outside Window Tests
    
    func testCancelRequestsOutsideWindow_NoRequests() {
        // Should not crash with no pending requests
        let cancelled = service.cancelRequestsOutsideWindow(center: 100, window: 25)
        XCTAssertEqual(cancelled, 0)
    }
    
    func testReprioritizeRequests_NoRequests() {
        // Should not crash with no pending requests
        service.reprioritizeRequests(center: 100)
        // Just verify no crash
    }
    
    // MARK: - Debug Info Tests
    
    func testDebugInfoReturnsValues() {
        let info = service.debugInfo()
        XCTAssertGreaterThanOrEqual(info.queueOperationCount, 0)
        XCTAssertGreaterThanOrEqual(info.trackedOperationsCount, 0)
    }
}
