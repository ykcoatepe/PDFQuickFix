import Foundation
import Combine

/// Summary metrics generated during a QuickFix pass.
/// Stored in-memory next to the output PDF for user trust/verification.
struct RedactionReport: Hashable {
    /// 0-based page indices that contain one or more redaction rectangles.
    let pagesWithRedactions: [Int]
    let totalRedactionRectCount: Int
    /// Count of OCR text runs removed to avoid searchable text under redactions.
    let suppressedOCRRunCount: Int
}

/// Summary OCR metrics for a QuickFix run.
struct OCRReport: Hashable {
    let totalPages: Int
    let localOCRPages: Int
    let cloudOCRPages: Int
    let visionOCRPages: Int
    let ocrDisabledPages: Int
    let emptyOCRPages: Int
    let emptyOCRPageIndices: [Int]
    let localOCRFallbackCount: Int
}

struct QuickFixResult: Hashable {
    let outputURL: URL
    let isTemporaryOutput: Bool
    let previewPageIndex: Int?
    let redactionReport: RedactionReport
    let ocrReport: OCRReport

    var displayOutputURL: URL {
        outputURL
    }

    func savedCopy(outputURL newOutputURL: URL) -> QuickFixResult {
        QuickFixResult(
            outputURL: newOutputURL,
            isTemporaryOutput: false,
            previewPageIndex: previewPageIndex,
            redactionReport: redactionReport,
            ocrReport: ocrReport
        )
    }
}

@MainActor
final class QuickFixResultStore: ObservableObject {
    static let shared = QuickFixResultStore()

    @Published private(set) var resultsByURL: [URL: QuickFixResult] = [:]

    func set(_ result: QuickFixResult, previousOutputURL: URL? = nil, sourceURL: URL? = nil) {
        resultsByURL[result.outputURL.standardizedFileURL] = result
        if let previousOutputURL {
            resultsByURL[previousOutputURL.standardizedFileURL] = result
        }
        if let sourceURL {
            resultsByURL[sourceURL.standardizedFileURL] = result
        }
    }

    func result(for url: URL) -> QuickFixResult? {
        resultsByURL[url.standardizedFileURL]
    }

    func report(for url: URL) -> RedactionReport? {
        result(for: url)?.redactionReport
    }
}

extension OCRReport {
    var suggestedPreviewPageIndex: Int? {
        return emptyOCRPageIndices.first
    }
}

extension RedactionReport {
    var suggestedPreviewPageIndex: Int? {
        pagesWithRedactions.first
    }
}
