import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

final class OCRFallbackSmokeTests: XCTestCase {
    private final class FailingLocalProvider: LocalOCRProviding {
        private(set) var recognizeCalls = 0

        func isAvailable() -> Bool {
            true
        }

        func recognizeTextLines(cgImage _: CGImage) throws -> [RecognizedRun] {
            recognizeCalls += 1
            throw NSError(domain: "PDFQuickFixSmoke.LocalOCR", code: -1)
        }
    }

    func testQuickVerifySampleFallsBackToRealVisionWhenLocalOCRFails() throws {
        let inputURL = try makeQuickVerifyPDF()
        let localProvider = FailingLocalProvider()
        let options = QuickFixOptions(doOCR: true,
                                      dpi: 144,
                                      redactionPadding: 0,
                                      ocrProvider: .autoLocalOCR)
        let engine = PDFQuickFixEngine(options: options,
                                       languages: ["en-US"],
                                       localOCRProvider: localProvider)

        let result = try engine.processResult(inputURL: inputURL,
                                              redactionPatterns: [],
                                              customRegexes: [],
                                              findReplace: [],
                                              manualRedactions: [:])

        XCTAssertEqual(localProvider.recognizeCalls, 1)
        XCTAssertEqual(result.ocrReport.localOCRFallbackCount, 1)
        XCTAssertEqual(result.ocrReport.localOCRPages, 0)
        XCTAssertEqual(result.ocrReport.cloudOCRPages, 0)
        XCTAssertEqual(result.ocrReport.visionOCRPages, 1)
        XCTAssertEqual(result.ocrReport.emptyOCRPages, 0)

        let text = outputText(from: result.outputURL)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(QuickVerifyOCRSample.looksCorrect(text), "Vision fallback text was: \(text)")
    }

    func testQuickVerifySampleUsesRealLocalOCRWhenOptedIn() throws {
        try skipUnlessEnabled("PDFQF_RUN_LIVE_OCR_SMOKE")

        let model = environment["PDFQF_OCR_MODEL"] ?? "qwen2.5vl:7b"
        let provider: LocalOCRProviding = model.lowercased().contains("deepseek-ocr")
            ? OllamaDeepSeekOCRProvider(modelName: model)
            : OllamaVisionOCRProvider(modelName: model)

        guard provider.isAvailable() else {
            throw XCTSkip("Local OCR model '\(model)' is not available through Ollama.")
        }
        let image = try XCTUnwrap(QuickVerifyOCRSample.makeImage())
        let runs = try provider.recognizeTextLines(cgImage: image)
        let text = QuickVerifyOCRSample.extractText(from: runs)

        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(QuickVerifyOCRSample.looksCorrect(text), "Local OCR text was: \(text)")
    }

    func testQuickVerifySampleUsesRealGoogleVisionCloudFallbackWhenOptedIn() throws {
        try skipUnlessEnabled("PDFQF_RUN_CLOUD_OCR_SMOKE")

        let apiKey = environment["PDFQF_GOOGLE_VISION_API_KEY"] ?? environment["GOOGLE_VISION_API_KEY"] ?? ""
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw XCTSkip("Set PDFQF_GOOGLE_VISION_API_KEY or GOOGLE_VISION_API_KEY to run cloud OCR smoke.")
        }

        let inputURL = try makeQuickVerifyPDF()
        let localProvider = FailingLocalProvider()
        let options = QuickFixOptions(doOCR: true,
                                      dpi: 144,
                                      redactionPadding: 0,
                                      ocrProvider: .autoLocalOCR,
                                      localOCRModel: environment["PDFQF_OCR_MODEL"] ?? "qwen2.5vl:7b",
                                      cloudOcrEnabled: true,
                                      cloudOcrApiKey: apiKey)
        let engine = PDFQuickFixEngine(options: options,
                                       languages: ["en-US"],
                                       localOCRProvider: localProvider)

        let result = try engine.processResult(inputURL: inputURL,
                                              redactionPatterns: [],
                                              customRegexes: [],
                                              findReplace: [],
                                              manualRedactions: [:])

        XCTAssertEqual(localProvider.recognizeCalls, 1)
        XCTAssertEqual(result.ocrReport.localOCRFallbackCount, 1)
        XCTAssertEqual(result.ocrReport.localOCRPages, 0)
        XCTAssertEqual(result.ocrReport.cloudOCRPages, 1)
        XCTAssertEqual(result.ocrReport.visionOCRPages, 0)
        XCTAssertEqual(result.ocrReport.emptyOCRPages, 0)

        let text = outputText(from: result.outputURL)
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(QuickVerifyOCRSample.looksCorrect(text), "Cloud OCR text was: \(text)")
    }

    private var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    private func skipUnlessEnabled(_ name: String) throws {
        let enabledValues = ["1", "true", "yes", "on"]
        guard let value = environment[name]?.lowercased(), enabledValues.contains(value) else {
            throw XCTSkip("Set \(name)=1 to run this live OCR smoke.")
        }
    }

    private func makeQuickVerifyPDF() throws -> URL {
        let image = try XCTUnwrap(QuickVerifyOCRSample.makeImage())
        let nsImage = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
        let page = try XCTUnwrap(PDFPage(image: nsImage))
        let document = PDFDocument()
        document.insert(page, at: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    private func outputText(from url: URL) -> String {
        let document = PDFDocument(url: url)
        return document?.page(at: 0)?.string ?? ""
    }
}
