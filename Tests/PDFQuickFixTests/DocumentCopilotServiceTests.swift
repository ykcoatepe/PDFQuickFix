import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import PDFQuickFix

@MainActor
final class DocumentCopilotServiceTests: XCTestCase {
    final class StubGenerator: OllamaTextGenerating {
        var response: String
        private(set) var lastPrompt: String?

        init(response: String) {
            self.response = response
        }

        func generateText(model: String, prompt: String, format: String?) async throws -> String {
            lastPrompt = prompt
            return response
        }
    }

    func testAskUsesMatchingPageForCitationAndRecordsQuestionKind() async throws {
        let url = try makeTextPDF(pages: [
            "Overview page with general context.",
            "Installation steps and prerequisites.",
            "Rocket propulsion guidance covers thruster calibration and nozzle tuning.",
            "Appendix with glossary entries."
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "Page 3 explains thruster calibration.")
        let store = AIInteractionStore(persistToDisk: false)
        let service = DocumentCopilotService(interactionStore: store, client: generator)

        let result = try await service.respond(
            to: .ask(question: "What does the document say about thruster calibration?"),
            using: session,
            sourceName: "sample.pdf",
            modelName: "stub-model"
        )

        XCTAssertEqual(result.citations.map(\.pageIndex), [2])
        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertEqual(entry.kind, .readerCopilot(action: .documentQuestion))
    }

    func testQuickSummaryKeepsPromptBoundedAndIncludesPageMarkers() async throws {
        let longPage = String(repeating: "Long summary input with repeated content for bounding. ", count: 120)
        let url = try makeTextPDF(pages: Array(repeating: longPage, count: 6))
        defer { try? FileManager.default.removeItem(at: url) }

        let session = try DocumentTextSession(documentURL: url)
        let generator = StubGenerator(response: "Summary output")
        let store = AIInteractionStore(persistToDisk: false)
        let service = DocumentCopilotService(
            interactionStore: store,
            client: generator,
            maxPromptCharacters: 1_400
        )

        _ = try await service.respond(
            to: .quickSummary,
            using: session,
            sourceName: "sample.pdf",
            modelName: "stub-model"
        )

        let prompt = try XCTUnwrap(generator.lastPrompt)
        XCTAssertLessThanOrEqual(prompt.count, 1_400)
        XCTAssertTrue(prompt.contains("--- Page 1 ---"))
        XCTAssertTrue(prompt.contains("--- Page 2 ---"))
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
