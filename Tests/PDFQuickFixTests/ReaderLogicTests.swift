import XCTest
import PDFKit
@testable import PDFQuickFix

@MainActor
final class ReaderLogicTests: XCTestCase {
    
    var controller: ReaderControllerPro!
    
    override func setUp() {
        super.setUp()
        controller = ReaderControllerPro()
    }
    
    func testInitialState() {
        XCTAssertNil(controller.document)
        XCTAssertNil(controller.currentURL)
        XCTAssertFalse(controller.isLargeDocument)
        XCTAssertFalse(controller.isMassiveDocument)
    }
    
    func testOpenNormalDocument() {
        // Mocking a document open is tricky without a real file or async expectation.
        // We can test the finishOpen logic if we can access it, but it's private.
        // Instead, let's test public side effects if possible or use a testable seam.
        // Since we can't easily call private methods, we'll verify the controller's
        // reaction to a setDocument call if we exposed one, or just check state properties.
        
        // For now, let's just verify that we can instantiate the controller and check default flags.
        // Real integration tests would require a PDF file on disk.
        
        XCTAssertEqual(controller.zoomScale, 1.0)
        controller.zoomIn()
        // Zoom in might not work without a view attached, but let's check safety.
        // It shouldn't crash.
    }
    
    func testZoomLogic() {
        // Without a PDFView attached, zoomScale might not update if it relies on the view's scaleFactor.
        // But we can check that calling methods doesn't crash.
        controller.setZoom(percent: 150)
        // The controller updates zoomScale in the view delegate or when view updates.
        // So we can't assert zoomScale changed here easily without a mock view.
    }
}
