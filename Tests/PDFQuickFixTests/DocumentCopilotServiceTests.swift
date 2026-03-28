import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFQuickFix

@MainActor
final class DocumentCopilotServiceTests: XCTestCase {
    final class StubGenerator: OllamaTextGenerating {
        var response: String
        private(set) var prompts: [String] = []

        init(response: String) {
            self.response = response
        }

        func generateText(model: String, prompt: String, format: String?) async throws -> String {
            prompts.append(prompt)
            return response
        }
    }

    func testAskUsesRetainedWindowForBottomOfLongPageMatch() async throws {
        let pageOne = "Overview page."
        let pageTwoPrefix = String(repeating: "Top filler without useful matches. ", count: 35)
        let pageTwoSuffix = "The warranty exception appears near the bottom of this page."
        let url = try makeTextPDF(pages: [pageOne, pageTwoPrefix + pageTwoSuffix, "Appendix"])
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "The warranty exception is described near the bottom of page 2.")
        let store = AIInteractionStore(persistToDisk: false)
        let service = DocumentCopilotService(
            interactionStore: store,
            client: generator,
            maxPromptCharacters: 1_500,
            maxChunkCharacters: 180
        )

        let result = try await service.respond(
            to: .ask(
                question: "Where is the warranty exception discussed?",
                scope: .document
            ),
            using: session,
            sourceName: "sample.pdf",
            modelName: "stub-model"
        )

        XCTAssertEqual(result.grounding, .grounded)
        XCTAssertEqual(result.citations.map(\.pageIndex), [1])
        XCTAssertTrue(result.citations[0].snippet.localizedCaseInsensitiveContains("warranty exception"))
        let prompt = try XCTUnwrap(generator.prompts.last)
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("warranty exception"))
    }

    func testAskWithoutRelevantGroundingReturnsNoCitations() async throws {
        let url = try makeTextPDF(pages: ["Apples and pears.", "Bananas and grapes."])
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "I could not find that topic in the document.")
        let service = DocumentCopilotService(interactionStore: AIInteractionStore(persistToDisk: false), client: generator)

        let result = try await service.respond(
            to: .ask(
                question: "What does the document say about rocket engines?",
                scope: .document
            ),
            using: session,
            sourceName: "sample.pdf",
            modelName: "stub-model"
        )

        XCTAssertEqual(result.grounding, .ungrounded)
        XCTAssertTrue(result.citations.isEmpty)
    }

    func testExplainSelectionWithoutRelevantGroundingReturnsNoCitations() async throws {
        let url = try makeTextPDF(pages: ["Invoice total is due on receipt.", "Payment terms net 30."])
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "The selected passage is not supported by the available document scope.")
        let service = DocumentCopilotService(interactionStore: AIInteractionStore(persistToDisk: false), client: generator)

        let result = try await service.respond(
            to: .explainSelection(
                selection: "Discuss the rocket engine diagram.",
                scope: .document
            ),
            using: session,
            sourceName: "sample.pdf",
            modelName: "stub-model"
        )

        XCTAssertEqual(result.grounding, .ungrounded)
        XCTAssertTrue(result.citations.isEmpty)
    }

    func testDistinctRequestsMapToDistinctReaderCopilotActivityKinds() async throws {
        let url = try makeTextPDF(pages: ["Page one content.", "Page two content."])
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "ok")
        let store = AIInteractionStore(persistToDisk: false)
        let service = DocumentCopilotService(interactionStore: store, client: generator)

        let requests: [DocumentCopilotRequest] = [
            .quickSummary(scope: .document),
            .ask(question: "What is on page one?", scope: .document),
            .explainSelection(selection: "Page one content.", scope: .document),
            .currentPageDigest(scope: .currentPage(index: 1)),
            .keySections(scope: .pageRange("1-2"))
        ]

        for request in requests {
            _ = try await service.respond(
                to: request,
                using: session,
                sourceName: "sample.pdf",
                modelName: "stub-model"
            )
        }

        let kinds = store.entries.map(\.kind)
        XCTAssertEqual(
            kinds,
            [
                .readerCopilot(action: .keySections),
                .readerCopilot(action: .currentPageDigest),
                .readerCopilot(action: .selectionExplanation),
                .readerCopilot(action: .documentQuestion),
                .readerCopilot(action: .quickSummary)
            ]
        )
    }

    func testPromptTrimmingMetadataSeparatesRequestAndContextTruncation() async throws {
        let longPage = String(repeating: "Context filler without the exact answer. ", count: 120)
        let url = try makeTextPDF(pages: Array(repeating: longPage, count: 6))
        defer { try? FileManager.default.removeItem(at: url) }

        let longQuestion = String(repeating: "Explain every nuance of this content in detail. ", count: 50)
        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "summary")
        let service = DocumentCopilotService(
            interactionStore: AIInteractionStore(persistToDisk: false),
            client: generator,
            maxPromptCharacters: 1_100,
            maxChunkCharacters: 150
        )

        let result = try await service.respond(
            to: .ask(question: longQuestion, scope: .document),
            using: session,
            sourceName: "sample.pdf",
            modelName: "stub-model"
        )

        XCTAssertTrue(result.requestWasTrimmed)
        XCTAssertTrue(result.contextWasTrimmed)
        XCTAssertTrue(result.inputWasTrimmed)
        XCTAssertLessThanOrEqual(result.promptCharacterCount, 1_100)
    }

    private func makeTextPDF(pages: [String]) throws -> URL {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw NSError(domain: "DocumentCopilotServiceTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF data consumer"])
        }
        var mediaBox = CGRect(x: 0, y: 0, width: 500, height: 700)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "DocumentCopilotServiceTests", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to create PDF context"])
        }

        for pageText in pages {
            let box = CGRect(x: 0, y: 0, width: 500, height: 700)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)

            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            let attributed = NSAttributedString(string: pageText, attributes: attributes)
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: CGRect(x: 24, y: 24, width: 452, height: 652), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributed.length), path, nil)

            context.saveGState()
            context.textMatrix = .identity
            context.translateBy(x: 0, y: box.height)
            context.scaleBy(x: 1, y: -1)
            CTFrameDraw(frame, context)
            context.restoreGState()

            context.endPDFPage()
        }

        context.closePDF()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: url, options: [.atomic])
        return url
    }
}
