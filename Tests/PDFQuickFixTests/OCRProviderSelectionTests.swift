import XCTest
import PDFKit
@testable import PDFQuickFix

final class OCRProviderSelectionTests: XCTestCase {
    final class StubLocalProvider: LocalOCRProviding {
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

    final class StubCloudProvider: CloudOCRProviding {
        let runs: [RecognizedRun]
        let error: Error?
        private(set) var recognizeCalls = 0

        init(runs: [RecognizedRun] = [], error: Error? = nil) {
            self.runs = runs
            self.error = error
        }

        func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun] {
            recognizeCalls += 1
            if let error {
                throw error
            }
            return runs
        }
    }

    func testLocalOCRUsedWhenAvailableAndNoRedactions() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let run = RecognizedRun(kind: .keep("DEEP"), rectInPixels: CGRect(x: 10, y: 10, width: 120, height: 24))
        let provider = StubLocalProvider(available: true, runs: [run])
        let options = QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0, ocrProvider: .autoLocalOCR)
        let engine = PDFQuickFixEngine(options: options, languages: ["en-US"], localOCRProvider: provider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(provider.recognizeCalls, 1, "Local OCR provider should be used when available and no redaction is needed.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("DEEP"), "Local OCR overlay should be embedded in output text.")
    }

    func testLocalOCRNotUsedWhenManualRedactionsPresent() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 200, height: 200))
        let run = RecognizedRun(kind: .keep("DEEP"), rectInPixels: CGRect(x: 10, y: 10, width: 120, height: 24))
        let provider = StubLocalProvider(available: true, runs: [run])
        let options = QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0, ocrProvider: .autoLocalOCR)
        let engine = PDFQuickFixEngine(options: options, languages: ["en-US"], localOCRProvider: provider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [0: [CGRect(x: 0, y: 0, width: 200, height: 200)]]
        )

        XCTAssertEqual(provider.recognizeCalls, 0, "Local OCR provider should be skipped when manual redactions exist.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Manual-redaction runs should not rely on local OCR overlay.")
    }

    func testFallsBackToVisionWhenLocalOCRFailsAndCloudDisabled() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "Hello", size: CGSize(width: 240, height: 120))
        let provider = StubLocalProvider(available: true, runs: [], error: NSError(domain: "LocalOCR", code: -1))
        let options = QuickFixOptions(doOCR: true, dpi: 72, redactionPadding: 0, ocrProvider: .autoLocalOCR)
        let engine = PDFQuickFixEngine(options: options, languages: ["en-US"], localOCRProvider: provider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(provider.recognizeCalls, 1, "Local OCR provider should be attempted when available.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Vision OCR should populate text when local OCR fails.")
    }

    func testFallsBackToCloudWhenLocalOCRFailsAndCloudEnabled() throws {
        let inputURL = try TestPDFBuilder.makeSimplePDF(text: "", size: CGSize(width: 240, height: 120))
        let localProvider = StubLocalProvider(available: true, runs: [], error: NSError(domain: "LocalOCR", code: -1))
        let cloudRun = RecognizedRun(kind: .keep("CLOUD"), rectInPixels: CGRect(x: 10, y: 10, width: 80, height: 18))
        let cloudProvider = StubCloudProvider(runs: [cloudRun])
        let options = QuickFixOptions(
            doOCR: true,
            dpi: 72,
            redactionPadding: 0,
            ocrProvider: .autoLocalOCR,
            localOCRModel: "",
            cloudOcrEnabled: true,
            cloudOcrApiKey: "test-key"
        )
        let engine = PDFQuickFixEngine(options: options,
                                       languages: ["en-US"],
                                       localOCRProvider: localProvider,
                                       cloudOCRProvider: cloudProvider)

        let outputURL = try engine.process(
            inputURL: inputURL,
            outputURL: nil,
            redactionPatterns: [],
            customRegexes: [],
            findReplace: [],
            manualRedactions: [:]
        )

        XCTAssertEqual(localProvider.recognizeCalls, 1, "Local OCR should be attempted first.")
        XCTAssertEqual(cloudProvider.recognizeCalls, 1, "Cloud OCR should be used when local OCR fails and cloud is enabled.")

        let outDoc = PDFDocument(url: outputURL)
        let text = outDoc?.page(at: 0)?.string ?? ""
        XCTAssertTrue(text.contains("CLOUD"), "Cloud OCR overlay should be embedded in output text.")
    }
}
