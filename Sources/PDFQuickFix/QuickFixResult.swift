import Combine
import Foundation

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

struct QuickFixResult {
    let outputURL: URL
    let isTemporaryOutput: Bool
    let previewPageIndex: Int?
    let redactionReport: RedactionReport
    let ocrReport: OCRReport
    let sourceURL: URL?
    let isTemporarySource: Bool
    let cleanupEvidence: CleanupEvidence?
    let cleanupComparison: CleanupComparisonResult?

    init(outputURL: URL,
         isTemporaryOutput: Bool,
         previewPageIndex: Int?,
         redactionReport: RedactionReport,
         ocrReport: OCRReport,
         sourceURL: URL? = nil,
         isTemporarySource: Bool = false,
         cleanupEvidence: CleanupEvidence? = nil,
         cleanupComparison: CleanupComparisonResult? = nil)
    {
        self.outputURL = outputURL
        self.isTemporaryOutput = isTemporaryOutput
        self.previewPageIndex = previewPageIndex
        self.redactionReport = redactionReport
        self.ocrReport = ocrReport
        self.sourceURL = sourceURL
        self.isTemporarySource = isTemporarySource
        self.cleanupEvidence = cleanupEvidence
        self.cleanupComparison = cleanupComparison
    }

    var displayOutputURL: URL {
        outputURL
    }

    func savedCopy(outputURL newOutputURL: URL) -> QuickFixResult {
        QuickFixResult(
            outputURL: newOutputURL,
            isTemporaryOutput: false,
            previewPageIndex: previewPageIndex,
            redactionReport: redactionReport,
            ocrReport: ocrReport,
            sourceURL: sourceURL,
            isTemporarySource: isTemporarySource,
            cleanupEvidence: cleanupEvidence?.replacingOutputFileName(with: newOutputURL.lastPathComponent),
            cleanupComparison: cleanupComparison
        )
    }

    func retainingSourceSnapshot(at snapshotURL: URL,
                                 displayFileName: String) -> QuickFixResult
    {
        QuickFixResult(
            outputURL: outputURL,
            isTemporaryOutput: isTemporaryOutput,
            previewPageIndex: previewPageIndex,
            redactionReport: redactionReport,
            ocrReport: ocrReport,
            sourceURL: snapshotURL,
            isTemporarySource: true,
            cleanupEvidence: cleanupEvidence?.replacingSourceFileName(with: displayFileName),
            cleanupComparison: cleanupComparison
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

    func result(primaryURL: URL?, fallbackURL: URL?) -> QuickFixResult? {
        if let primaryURL, let result = result(for: primaryURL) {
            return result
        }
        if let fallbackURL {
            return result(for: fallbackURL)
        }
        return nil
    }

    func report(for url: URL) -> RedactionReport? {
        result(for: url)?.redactionReport
    }
}

extension OCRReport {
    var suggestedPreviewPageIndex: Int? {
        emptyOCRPageIndices.first
    }
}

extension RedactionReport {
    var suggestedPreviewPageIndex: Int? {
        pagesWithRedactions.first
    }
}
