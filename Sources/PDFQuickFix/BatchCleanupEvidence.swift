import CryptoKit
import Foundation
import PDFQuickFixKit

struct BatchCleanupEvidenceManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    let schemaVersion: String
    let generatedAt: Date
    let sanitizeProfile: String
    let recursive: Bool
    let verdict: CleanupEvidenceVerdict
    let files: [FileEntry]

    init(schemaVersion: String = currentSchemaVersion,
         generatedAt: Date,
         sanitizeProfile: String,
         recursive: Bool,
         verdict: CleanupEvidenceVerdict,
         files: [FileEntry])
    {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.sanitizeProfile = sanitizeProfile
        self.recursive = recursive
        self.verdict = verdict
        self.files = files
    }

    var passedCount: Int {
        files.count(where: { $0.verdict == .passed })
    }

    var reviewRequiredCount: Int {
        files.count(where: { $0.verdict == .reviewRequired })
    }

    var failedCount: Int {
        files.count(where: { $0.verdict == .failed })
    }

    struct FileEntry: Codable, Equatable, Sendable, Identifiable {
        let id: String
        let fileName: String
        let status: Status
        let verdict: CleanupEvidenceVerdict
        let reason: Reason?
        let evidence: CleanupEvidence?
    }

    enum Status: String, Codable, Equatable, Sendable {
        case processed
        case skipped
        case failed
        case notProcessed
    }

    enum Reason: String, Codable, Equatable, Sendable {
        case existingOutputNotEvaluated
        case sanitizeFailed
        case notProcessed
        case evidenceUnavailable
    }
}

enum BatchCleanupEvidenceBuilder {
    static func build(plan: BatchSanitizePlanner.Plan,
                      report: BatchSanitizeReport,
                      generatedAt: Date = Date()) -> BatchCleanupEvidenceManifest
    {
        let resultsByPath = Dictionary(uniqueKeysWithValues: report.files.map { ($0.input, $0) })
        let entries = plan.items.map { item in
            autoreleasepool {
                entry(
                    for: item,
                    result: resultsByPath[item.relativePath],
                    profile: report.profile,
                    generatedAt: generatedAt
                )
            }
        }

        return BatchCleanupEvidenceManifest(
            generatedAt: generatedAt,
            sanitizeProfile: report.profile.rawValue,
            recursive: report.recursive,
            verdict: aggregateVerdict(entries),
            files: entries
        )
    }

    private static func entry(
        for item: BatchSanitizePlanner.Item,
        result: BatchSanitizeReport.FileResult?,
        profile: SanitizeProfile,
        generatedAt: Date
    ) -> BatchCleanupEvidenceManifest.FileEntry {
        let id = stableID(for: item.relativePath)
        let fileName = item.inputURL.lastPathComponent

        guard let result else {
            return .init(
                id: id,
                fileName: fileName,
                status: .notProcessed,
                verdict: .reviewRequired,
                reason: .notProcessed,
                evidence: nil
            )
        }

        switch result.status {
        case .skipped:
            return .init(
                id: id,
                fileName: fileName,
                status: .skipped,
                verdict: .reviewRequired,
                reason: .existingOutputNotEvaluated,
                evidence: nil
            )
        case .failed:
            return .init(
                id: id,
                fileName: fileName,
                status: .failed,
                verdict: .failed,
                reason: .sanitizeFailed,
                evidence: nil
            )
        case .processed:
            do {
                let evidence = try sanitizeEvidence(
                    sourceURL: item.inputURL,
                    outputURL: item.outputURL,
                    profile: profile,
                    generatedAt: generatedAt
                )
                return .init(
                    id: id,
                    fileName: fileName,
                    status: .processed,
                    verdict: evidence.verdict,
                    reason: nil,
                    evidence: evidence
                )
            } catch {
                return .init(
                    id: id,
                    fileName: fileName,
                    status: .processed,
                    verdict: .reviewRequired,
                    reason: .evidenceUnavailable,
                    evidence: nil
                )
            }
        }
    }

    private static func sanitizeEvidence(sourceURL: URL,
                                         outputURL: URL,
                                         profile: SanitizeProfile,
                                         generatedAt: Date) throws -> CleanupEvidence
    {
        let initial = try CleanupEvidenceGenerator.generate(
            sourceURL: sourceURL,
            outputURL: outputURL,
            operationKind: .sanitize,
            sanitizeProfile: profile.rawValue,
            verdict: .passed,
            generatedAt: generatedAt
        )
        let assessment = CleanupSanitizeAssessment.evaluate(
            sourcePageCount: initial.source.pageCount,
            outputPageCount: initial.output.pageCount,
            remainingMetadataFields: initial.output.metadataFieldLabels
        )

        return CleanupEvidence(
            schemaVersion: initial.schemaVersion,
            operationKind: initial.operationKind,
            sanitizeProfile: initial.sanitizeProfile,
            source: initial.source,
            output: initial.output,
            quickFixTelemetry: initial.quickFixTelemetry,
            comparison: initial.comparison,
            redactionVerification: initial.redactionVerification,
            verdict: assessment.verdict,
            warnings: assessment.warnings,
            generatedAt: initial.generatedAt
        )
    }

    private static func aggregateVerdict(
        _ entries: [BatchCleanupEvidenceManifest.FileEntry]
    ) -> CleanupEvidenceVerdict {
        guard !entries.isEmpty else {
            return .reviewRequired
        }
        if entries.contains(where: { $0.verdict == .failed }) {
            return .failed
        }
        if entries.contains(where: { $0.verdict == .reviewRequired }) {
            return .reviewRequired
        }
        return .passed
    }

    private static func stableID(for relativePath: String) -> String {
        SHA256.hash(data: Data(relativePath.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum BatchCleanupEvidenceWriter {
    static func jsonData(for manifest: BatchCleanupEvidenceManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(manifest)
        data.append(0x0A)
        return data
    }

    static func writeJSON(_ manifest: BatchCleanupEvidenceManifest, to url: URL) throws {
        try jsonData(for: manifest).write(to: url, options: .atomic)
    }
}
