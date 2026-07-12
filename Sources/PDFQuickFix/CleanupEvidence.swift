import CryptoKit
import Foundation
import PDFKit

enum CleanupEvidenceVerdict: String, Codable, Equatable, Sendable {
    case passed
    case reviewRequired
    case failed
}

enum CleanupOperationKind: String, Codable, Equatable, Sendable {
    case quickFix
    case sanitize
}

enum CleanupRedactionVerificationStatus: String, Codable, Equatable, Sendable {
    case notApplicable
    case passed
    case reviewRequired
    case failed
}

struct CleanupDocumentFacts: Codable, Equatable, Sendable {
    let fileName: String
    let sha256: String
    let byteCount: Int
    let pageCount: Int
    let searchableTextPageCount: Int
    let searchableTextCharacterCount: Int
    let isEncrypted: Bool
    let metadataFieldLabels: [String]
    let annotationCount: Int
    let outlineCount: Int

    func replacingFileName(with newFileName: String) -> CleanupDocumentFacts {
        CleanupDocumentFacts(
            fileName: newFileName,
            sha256: sha256,
            byteCount: byteCount,
            pageCount: pageCount,
            searchableTextPageCount: searchableTextPageCount,
            searchableTextCharacterCount: searchableTextCharacterCount,
            isEncrypted: isEncrypted,
            metadataFieldLabels: metadataFieldLabels,
            annotationCount: annotationCount,
            outlineCount: outlineCount
        )
    }
}

/// Privacy-safe counters from a QuickFix run. This DTO intentionally has no provider,
/// model, credential, extracted-text, or metadata-value fields.
struct CleanupQuickFixTelemetry: Codable, Equatable, Sendable {
    let redactionRectangleCount: Int
    let suppressedOCRRunCount: Int
    let localOCRPageCount: Int
    let cloudOCRPageCount: Int
    let visionOCRPageCount: Int
    let ocrDisabledPageCount: Int
    let emptyOCRPageCount: Int
    let localOCRFallbackCount: Int

    init(redactionRectangleCount: Int,
         suppressedOCRRunCount: Int,
         localOCRPageCount: Int,
         cloudOCRPageCount: Int,
         visionOCRPageCount: Int = 0,
         ocrDisabledPageCount: Int = 0,
         emptyOCRPageCount: Int,
         localOCRFallbackCount: Int)
    {
        self.redactionRectangleCount = redactionRectangleCount
        self.suppressedOCRRunCount = suppressedOCRRunCount
        self.localOCRPageCount = localOCRPageCount
        self.cloudOCRPageCount = cloudOCRPageCount
        self.visionOCRPageCount = visionOCRPageCount
        self.ocrDisabledPageCount = ocrDisabledPageCount
        self.emptyOCRPageCount = emptyOCRPageCount
        self.localOCRFallbackCount = localOCRFallbackCount
    }
}

/// Aggregate visual-comparison facts supplied by the comparison engine.
struct CleanupComparisonSummary: Codable, Equatable, Sendable {
    let comparedPageCount: Int
    let matchingPageCount: Int
    let changedPageCount: Int
    let maximumDifferenceRatio: Double?
}

/// Contains counts only. Candidate strings and extracted output text are used transiently
/// by `verifyRedactions` and are never retained by the evidence model.
struct CleanupRedactionVerification: Codable, Equatable, Sendable {
    let status: CleanupRedactionVerificationStatus
    let checkedCandidateCount: Int
    let detectedCandidateCount: Int
}

struct CleanupEvidence: Codable, Equatable, Sendable {
    static let currentSchemaVersion = "1.0"

    let schemaVersion: String
    let operationKind: CleanupOperationKind
    let sanitizeProfile: String?
    let source: CleanupDocumentFacts
    let output: CleanupDocumentFacts
    let quickFixTelemetry: CleanupQuickFixTelemetry?
    let comparison: CleanupComparisonSummary?
    let redactionVerification: CleanupRedactionVerification?
    let verdict: CleanupEvidenceVerdict
    let warnings: [String]
    let generatedAt: Date

    init(schemaVersion: String = CleanupEvidence.currentSchemaVersion,
         operationKind: CleanupOperationKind = .quickFix,
         sanitizeProfile: String? = nil,
         source: CleanupDocumentFacts,
         output: CleanupDocumentFacts,
         quickFixTelemetry: CleanupQuickFixTelemetry?,
         comparison: CleanupComparisonSummary?,
         redactionVerification: CleanupRedactionVerification?,
         verdict: CleanupEvidenceVerdict,
         warnings: [String],
         generatedAt: Date = Date())
    {
        self.schemaVersion = schemaVersion
        self.operationKind = operationKind
        self.sanitizeProfile = sanitizeProfile
        self.source = source
        self.output = output
        self.quickFixTelemetry = quickFixTelemetry
        self.comparison = comparison
        self.redactionVerification = redactionVerification
        self.verdict = verdict
        self.warnings = warnings
        self.generatedAt = generatedAt
    }

    func replacingOutputFileName(with newFileName: String) -> CleanupEvidence {
        CleanupEvidence(
            schemaVersion: schemaVersion,
            operationKind: operationKind,
            sanitizeProfile: sanitizeProfile,
            source: source,
            output: output.replacingFileName(with: newFileName),
            quickFixTelemetry: quickFixTelemetry,
            comparison: comparison,
            redactionVerification: redactionVerification,
            verdict: verdict,
            warnings: warnings,
            generatedAt: generatedAt
        )
    }

    func replacingSourceFileName(with newFileName: String) -> CleanupEvidence {
        CleanupEvidence(
            schemaVersion: schemaVersion,
            operationKind: operationKind,
            sanitizeProfile: sanitizeProfile,
            source: source.replacingFileName(with: newFileName),
            output: output,
            quickFixTelemetry: quickFixTelemetry,
            comparison: comparison,
            redactionVerification: redactionVerification,
            verdict: verdict,
            warnings: warnings,
            generatedAt: generatedAt
        )
    }
}

enum CleanupEvidenceError: LocalizedError {
    case unreadablePDF(fileName: String)

    var errorDescription: String? {
        switch self {
        case let .unreadablePDF(fileName):
            "Unable to read PDF facts for \(fileName)."
        }
    }
}

enum CleanupEvidenceGenerator {
    static func generate(sourceURL: URL,
                         outputURL: URL,
                         operationKind: CleanupOperationKind = .quickFix,
                         sanitizeProfile: String? = nil,
                         quickFixTelemetry: CleanupQuickFixTelemetry? = nil,
                         comparison: CleanupComparisonSummary? = nil,
                         redactionVerification: CleanupRedactionVerification? = nil,
                         verdict: CleanupEvidenceVerdict,
                         warnings: [String] = [],
                         generatedAt: Date = Date()) throws -> CleanupEvidence
    {
        try CleanupEvidence(
            operationKind: operationKind,
            sanitizeProfile: sanitizeProfile,
            source: documentFacts(at: sourceURL),
            output: documentFacts(at: outputURL),
            quickFixTelemetry: quickFixTelemetry,
            comparison: comparison,
            redactionVerification: redactionVerification,
            verdict: verdict,
            warnings: warnings,
            generatedAt: generatedAt
        )
    }

    /// Automatic matches can be unrelated occurrences elsewhere in the document, so they
    /// require review by default. Set `confirmedLeak` only after a positional/manual check.
    static func verifyRedactions(candidates: [String],
                                 outputExtractedText: String,
                                 confirmedLeak: Bool = false) -> CleanupRedactionVerification
    {
        let normalizedCandidates = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedCandidates.isEmpty else {
            return CleanupRedactionVerification(
                status: .notApplicable,
                checkedCandidateCount: 0,
                detectedCandidateCount: 0
            )
        }

        let detectedCount = normalizedCandidates.reduce(into: 0) { count, candidate in
            if outputExtractedText.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                count += 1
            }
        }
        let status: CleanupRedactionVerificationStatus = if confirmedLeak, detectedCount > 0 {
            .failed
        } else if detectedCount > 0 {
            .reviewRequired
        } else {
            .passed
        }
        return CleanupRedactionVerification(
            status: status,
            checkedCandidateCount: normalizedCandidates.count,
            detectedCandidateCount: detectedCount
        )
    }

    private static func documentFacts(at url: URL) throws -> CleanupDocumentFacts {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let document = PDFDocument(data: data) else {
            throw CleanupEvidenceError.unreadablePDF(fileName: url.lastPathComponent)
        }

        var searchablePageCount = 0
        var searchableCharacterCount = 0
        var annotationCount = 0
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = page.string ?? ""
            let searchableText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !searchableText.isEmpty {
                searchablePageCount += 1
                searchableCharacterCount += searchableText.count
            }
            annotationCount += page.annotations.count
        }

        let metadataLabels = document.documentAttributes?
            .keys
            .compactMap { $0.base as? String }
            .sorted() ?? []
        return CleanupDocumentFacts(
            fileName: url.lastPathComponent,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            byteCount: data.count,
            pageCount: document.pageCount,
            searchableTextPageCount: searchablePageCount,
            searchableTextCharacterCount: searchableCharacterCount,
            isEncrypted: document.isEncrypted,
            metadataFieldLabels: metadataLabels,
            annotationCount: annotationCount,
            outlineCount: outlineItemCount(document.outlineRoot)
        )
    }

    private static func outlineItemCount(_ item: PDFOutline?) -> Int {
        guard let item else { return 0 }
        return (0 ..< item.numberOfChildren).reduce(into: 0) { count, index in
            guard let child = item.child(at: index) else { return }
            count += 1 + outlineItemCount(child)
        }
    }
}

enum CleanupEvidenceWriter {
    static func jsonData(for evidence: CleanupEvidence) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(evidence)
        data.append(0x0A)
        return data
    }

    static func text(for evidence: CleanupEvidence) -> String {
        var lines = [
            "PDFQuickFix Cleanup Evidence",
            "Schema version: \(evidence.schemaVersion)",
            "Generated: \(ISO8601DateFormatter().string(from: evidence.generatedAt))",
            "Operation: \(evidence.operationKind.rawValue)",
            "Verdict: \(evidence.verdict.rawValue)",
            "",
        ]
        if let sanitizeProfile = evidence.sanitizeProfile {
            lines.insert("Sanitization profile: \(sanitizeProfile)", at: 4)
        }
        append(evidence.source, heading: "Source", to: &lines)
        append(evidence.output, heading: "Output", to: &lines)
        if let telemetry = evidence.quickFixTelemetry {
            lines += [
                "QuickFix telemetry",
                "Redaction rectangles: \(telemetry.redactionRectangleCount)",
                "Suppressed OCR runs: \(telemetry.suppressedOCRRunCount)",
                "Local OCR pages: \(telemetry.localOCRPageCount)",
                "Cloud OCR pages: \(telemetry.cloudOCRPageCount)",
                "Vision OCR pages: \(telemetry.visionOCRPageCount)",
                "OCR disabled pages: \(telemetry.ocrDisabledPageCount)",
                "Empty OCR pages: \(telemetry.emptyOCRPageCount)",
                "Local OCR fallbacks: \(telemetry.localOCRFallbackCount)",
                "",
            ]
        }
        if let comparison = evidence.comparison {
            lines += [
                "Comparison",
                "Compared pages: \(comparison.comparedPageCount)",
                "Matching pages: \(comparison.matchingPageCount)",
                "Changed pages: \(comparison.changedPageCount)",
                "Maximum difference ratio: \(comparison.maximumDifferenceRatio.map { String($0) } ?? "not measured")",
                "",
            ]
        }
        if let verification = evidence.redactionVerification {
            lines += [
                "Redaction verification",
                "Status: \(verification.status.rawValue)",
                "Checked candidates: \(verification.checkedCandidateCount)",
                "Detected candidates: \(verification.detectedCandidateCount)",
                "",
            ]
        }
        lines.append("Warnings")
        lines += evidence.warnings.isEmpty ? ["None"] : evidence.warnings.map { "- \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    static func writeJSON(_ evidence: CleanupEvidence, to url: URL) throws {
        try jsonData(for: evidence).write(to: url, options: [.atomic])
    }

    static func writeText(_ evidence: CleanupEvidence, to url: URL) throws {
        try Data(text(for: evidence).utf8).write(to: url, options: [.atomic])
    }

    private static func append(_ facts: CleanupDocumentFacts, heading: String, to lines: inout [String]) {
        lines += [
            heading,
            "File: \(facts.fileName)",
            "SHA-256: \(facts.sha256)",
            "Bytes: \(facts.byteCount)",
            "Pages: \(facts.pageCount)",
            "Searchable-text pages: \(facts.searchableTextPageCount)",
            "Searchable-text characters: \(facts.searchableTextCharacterCount)",
            "Encrypted: \(facts.isEncrypted)",
            "Metadata fields: \(facts.metadataFieldLabels.joined(separator: ", "))",
            "Annotations: \(facts.annotationCount)",
            "Outline items: \(facts.outlineCount)",
            "",
        ]
    }
}
