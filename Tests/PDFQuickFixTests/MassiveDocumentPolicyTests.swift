import XCTest
import PDFKit
@testable import PDFQuickFix

@MainActor
final class MassiveDocumentPolicyTests: XCTestCase {
    func testControllerSetsMassiveFlag() {
        let controller = StudioController()
        let threshold = DocumentValidationRunner.massiveDocumentPageThreshold
        let doc = FakePDFDocument(fakePageCount: threshold + 1)

        controller.setDocument(doc, url: nil)

        XCTAssertTrue(controller.isMassiveDocument)
        XCTAssertTrue(controller.isLargeDocument)
    }

    func testPrefetchSkipsWhenMassive() {
        let controller = StudioController()
        let doc = PDFDocument()
        for _ in 0..<20 { doc.insert(PDFPage(), at: doc.pageCount) }
        controller.document = doc
        controller.isMassiveDocument = true

        var requests: [PDFRenderRequest] = []
        #if DEBUG
        PDFRenderService.shared.requestObserver = { requests.append($0) }
        defer { PDFRenderService.shared.requestObserver = nil }
        #endif

        controller.prefetchThumbnails(around: 5, window: 2, farWindow: 6)

        #if DEBUG
        XCTAssertEqual(requests.count, 0)
        #else
        XCTAssertTrue(true) // Observer only in DEBUG
        #endif
    }

    func testPrefetchLimitsWindowForNormalDocs() {
        let controller = StudioController()
        let doc = PDFDocument()
        for _ in 0..<50 { doc.insert(PDFPage(), at: doc.pageCount) }
        controller.document = doc
        controller.isMassiveDocument = false

        var requests: [PDFRenderRequest] = []
        #if DEBUG
        PDFRenderService.shared.requestObserver = { requests.append($0) }
        defer { PDFRenderService.shared.requestObserver = nil }
        #endif

        controller.prefetchThumbnails(around: 10, window: 2, farWindow: 6)

        #if DEBUG
        // Expect near window (5 requests) + far window (8 requests) = 13
        XCTAssertEqual(requests.count, 13)
        #else
        XCTAssertTrue(true)
        #endif
    }
    
    func testDocumentProfileThresholds() {
        // Verify page count thresholds
        let normalProfile = DocumentProfile.from(pageCount: 1999)
        XCTAssertFalse(normalProfile.isMassive, "1999 pages should not be massive")
        
        let massiveProfile = DocumentProfile.from(pageCount: 2000)
        XCTAssertTrue(massiveProfile.isMassive, "2000 pages should be massive")
        
        // Verify large threshold (>1000)
        let notLarge = DocumentProfile.from(pageCount: 1000)
        XCTAssertFalse(notLarge.isLarge, "1000 pages should not be large")
        
        let large = DocumentProfile.from(pageCount: 1001)
        XCTAssertTrue(large.isLarge, "1001 pages should be large")
    }
    
    func testDocumentProfileFileSizeThreshold() {
        // 200 MB threshold
        let smallFile = DocumentProfile.from(pageCount: 100, fileSizeBytes: 199 * 1024 * 1024)
        XCTAssertFalse(smallFile.isMassive, "199 MB should not be massive by size")
        
        let massiveFile = DocumentProfile.from(pageCount: 100, fileSizeBytes: 200 * 1024 * 1024)
        XCTAssertTrue(massiveFile.isMassive, "200 MB should be massive by size")
    }
    
    func testMassiveDocumentFeatureFlags() {
        let profile = DocumentProfile.from(pageCount: 2500)
        
        // Search should still be enabled
        XCTAssertTrue(profile.searchEnabled)
        
        // Thumbnails enabled (lazy loading handled by UI)
        XCTAssertTrue(profile.thumbnailsEnabled)
        
        // Outline enabled (lazy loading handled by UI)
        XCTAssertTrue(profile.outlineEnabled)
        
        // Global annotation scanning disabled
        XCTAssertFalse(profile.globalAnnotationsEnabled)
    }
}
private final class FakePDFDocument: PDFDocument {
    private let fakePageCount: Int
    init(fakePageCount: Int) {
        self.fakePageCount = fakePageCount
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var pageCount: Int {
        fakePageCount
    }
}
