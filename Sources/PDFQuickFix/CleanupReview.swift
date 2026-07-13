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

struct CleanupSanitizeAssessment {
    let verdict: CleanupEvidenceVerdict
    let warnings: [String]

    static func evaluate(sourcePageCount: Int,
                         outputPageCount: Int,
                         remainingMetadataFields: [String]) -> CleanupSanitizeAssessment
    {
        var warnings: [String] = []
        if sourcePageCount != outputPageCount {
            warnings.append("Source and output page counts differ.")
        }
        if !remainingMetadataFields.isEmpty {
            warnings.append(
                "Output metadata fields remain: \(remainingMetadataFields.joined(separator: ", "))."
            )
        }
        let verdict: CleanupEvidenceVerdict = if sourcePageCount != outputPageCount {
            .failed
        } else if warnings.isEmpty {
            .passed
        } else {
            .reviewRequired
        }
        return CleanupSanitizeAssessment(verdict: verdict, warnings: warnings)
    }
}

enum CleanupReviewBuilder {
    static func build(sourceDocument: PDFDocument,
                      sourceFileName: String,
                      outputURL: URL,
                      profile: SanitizeProfile) throws -> CleanupReview
    {
        guard let sourceData = sourceDocument.dataRepresentation() else {
            throw CleanupEvidenceError.unreadablePDF(fileName: sourceFileName)
        }
        return try build(sourceData: sourceData,
                         sourceFileName: sourceFileName,
                         outputURL: outputURL,
                         profile: profile)
    }

    static func build(sourceData: Data,
                      sourceFileName: String,
                      outputURL: URL,
                      profile: SanitizeProfile) throws -> CleanupReview
    {
        let snapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFQuickFix-CleanupReview-\(UUID().uuidString)")
            .appendingPathExtension("pdf")

        do {
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
            let assessment = CleanupSanitizeAssessment.evaluate(
                sourcePageCount: comparison.sourcePageCount,
                outputPageCount: comparison.outputPageCount,
                remainingMetadataFields: comparison.metadataFieldsRemaining
            )
            let evidence = try CleanupEvidenceGenerator.generate(
                sourceURL: snapshotURL,
                outputURL: outputURL,
                operationKind: .sanitize,
                sanitizeProfile: profile.rawValue,
                comparison: comparison.evidenceSummary,
                verdict: assessment.verdict,
                warnings: assessment.warnings
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
