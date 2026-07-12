@testable import PDFQuickFix
import CoreGraphics
import XCTest

final class PDFRenderServiceCancellationTests: XCTestCase {
    private var service: PDFRenderService!

    override func setUp() {
        super.setUp()
        service = PDFRenderService.shared
    }

    override func tearDown() {
        service.cancelAll()
        service.identityComputationHook = nil
        super.tearDown()
    }

    func testCacheSeparatesDocumentsForOtherwiseIdenticalRequests() throws {
        let first = try makePDFData(gray: 0.15)
        let second = try makePDFData(gray: 0.85)
        let request = PDFRenderRequest(kind: .thumbnail,
                                       pageIndex: 0,
                                       scaleBucket: 120,
                                       size: CGSize(width: 120, height: 120))

        let firstImage = try render(request: request, data: first)
        let secondImage = try render(request: request, data: second)

        XCTAssertNotEqual(pixelSignature(firstImage), pixelSignature(secondImage))
    }

    func testCancelAllClearsCachedImages() throws {
        let data = try makePDFData(gray: 0.4)
        let request = PDFRenderRequest(kind: .thumbnail,
                                       pageIndex: 0,
                                       scaleBucket: 120,
                                       size: CGSize(width: 120, height: 120))
        _ = try render(request: request, data: data)

        service.cancelAll()

        let completion = expectation(description: "invalid document render completes")
        var rendered: CGImage?
        service.image(for: request, documentURL: nil, documentData: Data("not a pdf".utf8)) { image in
            rendered = image
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)
        XCTAssertNil(rendered)
    }

    func testCancelAllRejectsRequestThatWasStillComputingIdentity() {
        let identityStarted = DispatchSemaphore(value: 0)
        let releaseIdentity = DispatchSemaphore(value: 0)
        service.identityComputationHook = {
            identityStarted.signal()
            _ = releaseIdentity.wait(timeout: .now() + 2)
        }
        let completion = expectation(description: "pre-cancel request completes without rendering")
        var rendered: CGImage?

        DispatchQueue.global(qos: .userInitiated).async {
            self.service.image(
                for: PDFRenderRequest(kind: .thumbnail, pageIndex: 0, scaleBucket: 120, size: CGSize(width: 120, height: 120)),
                documentURL: nil,
                documentData: Data("not a pdf".utf8)
            ) { image in
                rendered = image
                completion.fulfill()
            }
        }

        XCTAssertEqual(identityStarted.wait(timeout: .now() + 2), .success)
        service.cancelAll()
        releaseIdentity.signal()
        wait(for: [completion], timeout: 2)
        XCTAssertNil(rendered)
        XCTAssertEqual(service.debugInfo().trackedOperationsCount, 0)
    }

    func testExplicitDocumentIdentitySkipsDataHashing() {
        var identityComputations = 0
        service.identityComputationHook = { identityComputations += 1 }
        let completion = expectation(description: "render completes")

        service.image(
            for: PDFRenderRequest(kind: .thumbnail, pageIndex: 0, scaleBucket: 120, size: CGSize(width: 120, height: 120)),
            documentURL: nil,
            documentData: Data("not a pdf".utf8),
            documentIdentity: "document-revision-1"
        ) { _ in completion.fulfill() }

        wait(for: [completion], timeout: 2)
        XCTAssertEqual(identityComputations, 0)
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

    private func render(request: PDFRenderRequest, data: Data) throws -> CGImage {
        let completion = expectation(description: "render completes")
        var rendered: CGImage?
        service.image(for: request, documentURL: nil, documentData: data) { image in
            rendered = image
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)
        return try XCTUnwrap(rendered)
    }

    private func makePDFData(gray: CGFloat) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 100, height: 100)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private func pixelSignature(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }
}
