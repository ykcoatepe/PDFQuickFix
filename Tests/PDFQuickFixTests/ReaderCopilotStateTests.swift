import XCTest
import Combine
import PDFKit
@testable import PDFQuickFix

@MainActor
final class ReaderCopilotStateTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testReaderRightPanelTabsIncludeCopilot() {
        XCTAssertTrue(ReaderRightPanelTab.allCases.contains(.copilot))
    }

    func testReaderRightPanelTabHasCopilotDisplayMetadata() {
        XCTAssertEqual(ReaderRightPanelTab.copilot.displayName, "Copilot")
        XCTAssertEqual(ReaderRightPanelTab.copilot.symbolName, "sparkles")
    }

    func testExplainSelectionUsesCurrentPDFSelectionText() async throws {
        let expectedResponse = DocumentCopilotResponse.makeStub(answer: "Explained")
        let service = StubCopilotService(response: expectedResponse)
        let controller = ReaderControllerPro(copilotService: service)
        let pdfView = PDFView()
        controller.pdfView = pdfView

        let document = try makeTextDocument(text: "Selected text lives here")
        controller.document = document
        pdfView.document = document

        guard let page = document.page(at: 0),
              let pageText = page.string,
              let selection = document.selection(from: page,
                                                 atCharacterIndex: 0,
                                                 to: page,
                                                 atCharacterIndex: pageText.count - 1) else {
            XCTFail("Unable to create selection from text-backed PDF")
            return
        }

        pdfView.setCurrentSelection(selection, animate: false)
        await controller.explainCurrentSelection()

        XCTAssertEqual(
            service.requests,
            [.explainSelection(selection: pageText, scope: .selection(pageText))]
        )
        XCTAssertEqual(controller.copilotResponse, expectedResponse)
    }

    func testQuickSummaryPopulatesControllerResponse() throws {
        let expectedResponse = DocumentCopilotResponse(
            answer: "Summary ready.",
            citations: [
                DocumentCopilotCitation(pageIndex: 0, pageLabel: "Page 1", snippet: "Page 1")
            ],
            grounding: .grounded,
            model: "stub-model",
            promptCharacterCount: 120,
            inputCharacterCount: 80,
            inputWasTrimmed: false,
            requestWasTrimmed: false,
            contextWasTrimmed: false
        )
        let service = StubCopilotService(response: expectedResponse)
        let controller = ReaderControllerPro(copilotService: service)
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Reader copilot")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let loaded = expectation(description: "reader loads document")
        controller.$document
            .compactMap { $0 }
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        XCTAssertEqual(controller.selectedRightPanelTab, .info)

        let responseLoaded = expectation(description: "copilot response loads")
        controller.$copilotResponse
            .compactMap { $0 }
            .first()
            .sink { _ in responseLoaded.fulfill() }
            .store(in: &cancellables)

        Task {
            await controller.runCopilotRequest(.quickSummary(scope: .document))
        }

        wait(for: [responseLoaded], timeout: 5.0)

        XCTAssertEqual(service.requests, [.quickSummary(scope: .document)])
        XCTAssertEqual(controller.copilotResponse, expectedResponse)
        XCTAssertNil(controller.copilotError)
        XCTAssertFalse(controller.isCopilotRunning)
    }

    func testJumpToCitationPageMovesCurrentPage() throws {
        let controller = ReaderControllerPro(copilotService: StubCopilotService(response: .makeStub()))
        let pdfView = PDFView()
        controller.pdfView = pdfView

        let pdfURL = try TestPDFBuilder.makeMultipagePDF(pageCount: 3, textPrefix: "Page")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let loaded = expectation(description: "reader loads document")
        controller.$document
            .compactMap { $0 }
            .first()
            .sink { _ in loaded.fulfill() }
            .store(in: &cancellables)

        controller.open(url: pdfURL)
        wait(for: [loaded], timeout: 5.0)

        let citation = DocumentCopilotCitation(pageIndex: 2, pageLabel: "Page 3", snippet: "Page 3")
        controller.jumpToCitationPage(citation)

        XCTAssertEqual(controller.currentPageIndex, 2)
        XCTAssertEqual(pdfView.currentPage, controller.document?.page(at: 2))
    }

    func testQuickSummaryUsesInMemoryDocumentSession() async throws {
        let expectedResponse = DocumentCopilotResponse.makeStub(answer: "In-memory summary")
        let service = StubCopilotService(response: expectedResponse)
        let controller = ReaderControllerPro(copilotService: service)

        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "In-memory doc")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let data = try Data(contentsOf: pdfURL)
        controller.document = PDFDocument(data: data)

        await controller.runCopilotRequest(.quickSummary(scope: .document))

        XCTAssertEqual(service.requests, [.quickSummary(scope: .document)])
        XCTAssertEqual(controller.copilotResponse, expectedResponse)
        XCTAssertNil(controller.copilotError)
    }

    func testLatestCopilotRequestWinsRace() async throws {
        let firstResponse = DocumentCopilotResponse.makeStub(answer: "Older response")
        let secondResponse = DocumentCopilotResponse.makeStub(answer: "Latest response")
        let service = DelayedCopilotService(
            responses: [
                "first": firstResponse,
                "second": secondResponse
            ],
            delays: [
                "first": 200_000_000,
                "second": 10_000_000
            ]
        )
        let controller = ReaderControllerPro(copilotService: service)

        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Race test")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let data = try Data(contentsOf: pdfURL)
        controller.document = PDFDocument(data: data)

        let firstTask = Task { await controller.runCopilotRequest(.ask(question: "first", scope: .document)) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let secondTask = Task { await controller.runCopilotRequest(.ask(question: "second", scope: .document)) }

        await firstTask.value
        await secondTask.value

        XCTAssertEqual(controller.copilotResponse, secondResponse)
        XCTAssertNil(controller.copilotError)
        XCTAssertFalse(controller.isCopilotRunning)
    }

    func testCloseDocumentIgnoresInFlightCopilotResponse() async throws {
        let service = BlockingCopilotService(response: .makeStub(answer: "Late response"))
        let controller = ReaderControllerPro(copilotService: service)

        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Close document test")
        defer { try? FileManager.default.removeItem(at: pdfURL) }

        let data = try Data(contentsOf: pdfURL)
        controller.document = PDFDocument(data: data)

        let task = Task {
            await controller.runCopilotRequest(.quickSummary(scope: .document))
        }

        await service.waitUntilStarted()
        controller.closeDocument()
        await service.resume()
        await task.value

        XCTAssertNil(controller.copilotResponse)
        XCTAssertNil(controller.copilotError)
        XCTAssertFalse(controller.isCopilotRunning)
        XCTAssertNil(controller.document)
    }

}

private final class StubCopilotService: DocumentCopilotServicing {
    private(set) var requests: [DocumentCopilotRequest] = []
    var response: DocumentCopilotResponse

    init(response: DocumentCopilotResponse) {
        self.response = response
    }

    func respond(to request: DocumentCopilotRequest,
                 using session: DocumentTextSession,
                 sourceName: String?,
                 modelName: String?) async throws -> DocumentCopilotResponse {
        requests.append(request)
        return response
    }
}

private final class DelayedCopilotService: DocumentCopilotServicing {
    let responses: [String: DocumentCopilotResponse]
    let delays: [String: UInt64]

    init(responses: [String: DocumentCopilotResponse], delays: [String: UInt64]) {
        self.responses = responses
        self.delays = delays
    }

    func respond(to request: DocumentCopilotRequest,
                 using session: DocumentTextSession,
                 sourceName: String?,
                 modelName: String?) async throws -> DocumentCopilotResponse {
        guard case .ask(let question, _) = request,
              let response = responses[question] else {
            XCTFail("Unexpected request: \(request)")
            return .makeStub(answer: "unexpected")
        }

        if let delay = delays[question] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return response
    }
}

private actor BlockingCopilotService: DocumentCopilotServicing {
    let response: DocumentCopilotResponse
    private var hasStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<DocumentCopilotResponse, Never>?

    init(response: DocumentCopilotResponse) {
        self.response = response
    }

    func respond(to request: DocumentCopilotRequest,
                 using session: DocumentTextSession,
                 sourceName: String?,
                 modelName: String?) async throws -> DocumentCopilotResponse {
        hasStarted = true
        startContinuation?.resume()
        startContinuation = nil

        return await withCheckedContinuation { continuation in
            responseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func resume() {
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
    }
}

private extension DocumentCopilotResponse {
    static func makeStub(answer: String = "ok") -> DocumentCopilotResponse {
        DocumentCopilotResponse(
            answer: answer,
            citations: [],
            grounding: .ungrounded,
            model: "stub",
            promptCharacterCount: 0,
            inputCharacterCount: 0,
            inputWasTrimmed: false,
            requestWasTrimmed: false,
            contextWasTrimmed: false
        )
    }
}

private func makeTextDocument(text: String) throws -> PDFDocument {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("pdf")

    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
        throw NSError(domain: "ReaderCopilotStateTests", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Unable to create PDF context"
        ])
    }

    context.beginPDFPage(nil)
    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    NSColor.white.setFill()
    mediaBox.fill()
    NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]
    ).draw(in: CGRect(x: 24, y: 120, width: 272, height: 40))
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()

    defer { try? FileManager.default.removeItem(at: url) }

    let data = try Data(contentsOf: url)
    guard let document = PDFDocument(data: data) else {
        throw NSError(domain: "ReaderCopilotStateTests", code: -2, userInfo: [
            NSLocalizedDescriptionKey: "Unable to open generated PDF"
        ])
    }

    return document
}
