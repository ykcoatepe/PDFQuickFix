import Foundation
import PDFKit
import PDFQuickFixKit

final class CleanupReview: Identifiable, Sendable {
    let id = UUID()
    let sourceSnapshotURL: URL
    let outputURL: URL
    let evidence: CleanupEvidence
    let comparison: CleanupComparisonResult

    init(sourceSnapshotURL: URL,
         outputURL: URL,
         evidence: CleanupEvidence,
         comparison: CleanupComparisonResult)
    {
        self.sourceSnapshotURL = sourceSnapshotURL
        self.outputURL = outputURL
        self.evidence = evidence
        self.comparison = comparison
    }

    func removeTemporarySource() {
        try? FileManager.default.removeItem(at: sourceSnapshotURL)
    }

    deinit {
        removeTemporarySource()
    }
}

enum CleanupReviewBuilder {
    static func build(sourceDocument: PDFDocument,
                      sourceFileName: String,
                      outputURL: URL,
                      profile: SanitizeProfile) throws -> CleanupReview
    {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFQuickFix-CleanupReview-\(UUID().uuidString)")
            .appendingPathExtension("pdf")

        do {
            guard let sourceData = sourceDocument.dataRepresentation() else {
                throw CleanupEvidenceError.unreadablePDF(fileName: sourceFileName)
            }
            try sourceData.write(to: snapshotURL, options: .atomic)
            guard let sourceSnapshot = PDFDocument(data: sourceData),
                  let outputDocument = PDFDocument(url: outputURL)
            else {
                throw CleanupEvidenceError.unreadablePDF(fileName: outputURL.lastPathComponent)
            }

            let comparison = try CleanupComparisonEngine().compare(
                source: sourceSnapshot,
                output: outputDocument
            )
            var warnings: [String] = []
            if comparison.sourcePageCount != comparison.outputPageCount {
                warnings.append("Source and output page counts differ.")
            }
            if !comparison.metadataFieldsRemaining.isEmpty {
                warnings.append("Output metadata fields remain: \(comparison.metadataFieldsRemaining.joined(separator: ", ")).")
            }
            let verdict: CleanupEvidenceVerdict = if comparison.sourcePageCount != comparison.outputPageCount {
                .failed
            } else if warnings.isEmpty {
                .passed
            } else {
                .reviewRequired
            }
            let evidence = try CleanupEvidenceGenerator.generate(
                sourceURL: snapshotURL,
                outputURL: outputURL,
                operationKind: .sanitize,
                sanitizeProfile: profile.rawValue,
                comparison: comparison.evidenceSummary,
                verdict: verdict,
                warnings: warnings
            )
            .replacingSourceFileName(with: URL(fileURLWithPath: sourceFileName).lastPathComponent)

            return CleanupReview(
                sourceSnapshotURL: snapshotURL,
                outputURL: outputURL,
                evidence: evidence,
                comparison: comparison
            )
        } catch {
            try? FileManager.default.removeItem(at: snapshotURL)
            throw error
        }
    }
}
