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

struct QuickFixResult: Hashable {
    let outputURL: URL
    let redactionReport: RedactionReport
}

@MainActor
final class QuickFixResultStore: ObservableObject {
    static let shared = QuickFixResultStore()

    @Published private(set) var resultsByURL: [URL: QuickFixResult] = [:]

    func set(_ result: QuickFixResult) {
        resultsByURL[result.outputURL.standardizedFileURL] = result
    }

    func result(for url: URL) -> QuickFixResult? {
        resultsByURL[url.standardizedFileURL]
    }

    func report(for url: URL) -> RedactionReport? {
        result(for: url)?.redactionReport
    }
}

