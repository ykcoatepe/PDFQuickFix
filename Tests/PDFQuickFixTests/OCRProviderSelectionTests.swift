import XCTest
import PDFKit
@testable import PDFQuickFix

final class OCRProviderSelectionTests: XCTestCase {
    final class StubDeepSeekProvider: DeepSeekOCRProviding {
        let available: Bool
        let runs: [RecognizedRun]
        let error: Error?
        private(set) var recognizeCalls = 0

        init(available: Bool, runs: [RecognizedRun] = [], error: Error? = nil) {
            self.available = available
            self.runs = runs
            self.error = error
        }

        func isAvailable() -> Bool {
            available
        }

        func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun] {
            recognizeCalls += 1
            if let error {
                throw error
            }
            return runs
        }
    }

    func testDeepSeekOverlayUsedWhenAvailableAndNoRedactions() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let run = RecognizedRun(kind: .keep("DEEP"), rectInPixels: CGRect(x: 10, y: 10, width: 120, height: 24))
        let provider = StubDeepSeekProvider(available: true, runs: [run])
        let options = QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0, ocrProvider: .autoDeepSeek)
        let engine = PDFQuickFixEngine(options: options, languages: ["en-US"], deepSeekProvider: provider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(provider.recognizeCalls, 1, "DeepSeek provider should be used when available and no redaction is needed.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("DEEP"), "DeepSeek OCR overlay should be embedded in output text.")
    }

    func testDeepSeekNotUsedWhenManualRedactionsPresent() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let run = RecognizedRun(kind: .keep("DEEP"), rectInPixels: CGRect(x: 10, y: 10, width: 120, height: 24))
        let provider = StubDeepSeekProvider(available: true, runs: [run])
        let options = QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0, ocrProvider: .autoDeepSeek)
        let engine = PDFQuickFixEngine(options: options, languages: ["en-US"], deepSeekProvider: provider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [0: [CGRect(x: 0, y: 0, width: 200, height: 200)]]
        )

        XCTAssertEqual(provider.recognizeCalls, 0, "DeepSeek provider should be skipped when manual redactions exist.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Manual-redaction runs should not rely on DeepSeek overlay.")
    }

    func testFallsBackToVisionWhenDeepSeekFails() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "Hello", size: CGSize(width: 240, height: 120))
        let provider = StubDeepSeekProvider(available: true, runs: [], error: NSError(domain: "DeepSeek", code: -1))
        let options = QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0, ocrProvider: .autoDeepSeek)
        let engine = PDFQuickFixEngine(options: options, languages: ["en-US"], deepSeekProvider: provider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(provider.recognizeCalls, 1, "DeepSeek provider should be attempted when available.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Vision OCR should populate text when DeepSeek fails.")
    }
}
