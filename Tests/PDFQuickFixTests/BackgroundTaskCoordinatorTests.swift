import XCTest
@testable import PDFQuickFix

final class BackgroundTaskCoordinatorTests: XCTestCase {
    
    private var coordinator: BackgroundTaskCoordinator!
    
    override func setUp() async throws {
        coordinator = BackgroundTaskCoordinator(maxConcurrentTasks: 2)
    }
    
    override func tearDown() async throws {
        await coordinator.cancelAll()
        coordinator = nil
    }
    
    // MARK: - Schedule Tests
    
    func testScheduleTask() async {
        let expectation = XCTestExpectation(description: "Task completed")
        
        await coordinator.schedule(name: "test", priority: .normal) {
            expectation.fulfill()
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
    }
    
    func testActiveCount() async {
        let startCount = await coordinator.activeCount
        XCTAssertEqual(startCount, 0)
        
        let expectation = XCTestExpectation(description: "Task started")
        await coordinator.schedule(name: "longTask", priority: .normal) {
            expectation.fulfill()
            try? await Task.sleep(for: .milliseconds(500))
        }
        
        await fulfillment(of: [expectation], timeout: 1.0)
        
        // After task completes, count should be 0 again
        try? await Task.sleep(for: .milliseconds(600))
        let endCount = await coordinator.activeCount
        XCTAssertEqual(endCount, 0)
    }
    
    // MARK: - Cancel Tests
    
    func testCancelAll() async {
        var cancelled = false
        
        await coordinator.schedule(name: "task", priority: .low) {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                cancelled = false
            }
        }
        
        await coordinator.cancelAll()
        let count = await coordinator.activeCount
        XCTAssertEqual(count, 0)
    }
    
    // MARK: - Pause Tests
    
    func testPauseAndResume() async {
        let paused1 = await coordinator.paused
        XCTAssertFalse(paused1)
        
        await coordinator.pause()
        let paused2 = await coordinator.paused
        XCTAssertTrue(paused2)
        
        await coordinator.resume()
        let paused3 = await coordinator.paused
        XCTAssertFalse(paused3)
    }
    
    // MARK: - Priority Tests
    
    func testCancelBelowPriority() async {
        await coordinator.schedule(name: "low", priority: .low) {
            try? await Task.sleep(for: .seconds(5))
        }
        await coordinator.schedule(name: "high", priority: .high) {
            try? await Task.sleep(for: .seconds(5))
        }
        
        await coordinator.cancelBelow(priority: .normal)
        
        // Allow some time for cancellation
        try? await Task.sleep(for: .milliseconds(50))
        
        // Only high priority task should remain
        let count = await coordinator.activeCount
        XCTAssertLessThanOrEqual(count, 1)
    }
}
