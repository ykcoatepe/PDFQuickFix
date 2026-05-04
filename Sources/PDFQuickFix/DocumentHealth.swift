import PDFKit
import SwiftUI

enum DocumentHealthSeverity: String, Hashable {
    case info
    case warning
    case critical

    var systemImage: String {
        switch self {
        case .info:
            "info.circle"
        case .warning:
            "exclamationmark.triangle"
        case .critical:
            "exclamationmark.octagon"
        }
    }

    var color: Color {
        switch self {
        case .info:
            .secondary
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}

struct DocumentHealthIssue: Identifiable, Hashable {
    let id = UUID()
    let severity: DocumentHealthSeverity
    let title: String
    let detail: String
}

struct DocumentHealthSummary: Hashable {
    let documentName: String
    let pageCount: Int
    let validationStatus: String?
    let shareReadiness: ShareReadiness
    let issues: [DocumentHealthIssue]
}

enum ShareReadiness: Hashable {
    case ready
    case reviewRecommended
    case blocked

    var title: String {
        switch self {
        case .ready:
            "Ready for outbound review"
        case .reviewRecommended:
            "Review recommended before sharing"
        case .blocked:
            "Resolve risks before sharing"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            "No elevated signals are currently blocking a safer outbound copy."
        case .reviewRecommended:
            "Health signals suggest a targeted review before you send this file."
        case .blocked:
            "Critical document or OCR evidence needs attention before this file leaves your Mac."
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            "checkmark.shield"
        case .reviewRecommended:
            "exclamationmark.triangle"
        case .blocked:
            "xmark.shield"
        }
    }

    var color: Color {
        switch self {
        case .ready:
            AppTheme.Colors.success
        case .reviewRecommended:
            AppTheme.Colors.warning
        case .blocked:
            .red
        }
    }
}

extension DocumentHealthSummary {
    static func build(documentName: String,
                      pageCount: Int,
                      isRepaired: Bool,
                      isLargeDocument: Bool,
                      isMassiveDocument: Bool,
                      skippedQuickValidation: Bool,
                      validationStatus: String?,
                      quickFixResult: QuickFixResult?,
                      documentAttributes: [AnyHashable: Any]? = nil,
                      hasReplacementTextAnnotations: Bool = false) -> DocumentHealthSummary
    {
        var issues: [DocumentHealthIssue] = []

        if isRepaired {
            issues.append(
                DocumentHealthIssue(
                    severity: .info,
                    title: "Document was normalized on open",
                    detail: "The source file needed repair or normalization before it could be safely opened."
                )
            )
        }

        if isMassiveDocument {
            issues.append(
                DocumentHealthIssue(
                    severity: .warning,
                    title: "Massive document mode is active",
                    detail: "Some expensive features are deferred to keep memory and rendering costs under control."
                )
            )
        } else if isLargeDocument {
            issues.append(
                DocumentHealthIssue(
                    severity: .info,
                    title: "Large document profile",
                    detail: "The file is large enough that some operations may take longer than usual."
                )
            )
        }

        if skippedQuickValidation {
            issues.append(
                DocumentHealthIssue(
                    severity: .warning,
                    title: "Quick validation was skipped",
                    detail: "Open-time validation was skipped for this document. Review it manually or validate a sanitized export before sharing."
                )
            )
        } else if let validationStatus, !validationStatus.isEmpty {
            issues.append(
                DocumentHealthIssue(
                    severity: .info,
                    title: "Validation status",
                    detail: validationStatus
                )
            )
        }

        if let quickFixResult {
            let report = quickFixResult.ocrReport
            if report.emptyOCRPages > 0 {
                issues.append(
                    DocumentHealthIssue(
                        severity: .warning,
                        title: "Empty OCR pages detected",
                        detail: "\(report.emptyOCRPages) page(s) produced no OCR text in the last QuickFix run."
                    )
                )
            }

            if report.localOCRFallbackCount > 0 {
                issues.append(
                    DocumentHealthIssue(
                        severity: .warning,
                        title: "OCR fallback occurred",
                        detail: "Local OCR fell back \(report.localOCRFallbackCount) time(s) in the last QuickFix run."
                    )
                )
            }

            if quickFixResult.redactionReport.totalRedactionRectCount > 0 {
                issues.append(
                    DocumentHealthIssue(
                        severity: .info,
                        title: "Redactions applied",
                        detail: "\(quickFixResult.redactionReport.totalRedactionRectCount) redaction region(s) were generated in the last QuickFix run."
                    )
                )
            }
        }

        let metadataFields = outboundMetadataFields(from: documentAttributes)
        if !metadataFields.isEmpty {
            issues.append(
                DocumentHealthIssue(
                    severity: .warning,
                    title: "Outbound metadata present",
                    detail: "Review or sanitize metadata before sharing. Found: \(metadataFields.joined(separator: ", "))."
                )
            )
        }

        if hasReplacementTextAnnotations {
            issues.append(
                DocumentHealthIssue(
                    severity: .critical,
                    title: "Flatten or sanitize text overlays",
                    detail: "Replace Text or Redact Text overlays are present. The original text layer may remain extractable until you save or export a flattened or sanitized copy."
                )
            )
        }

        let shareReadiness = Self.shareReadiness(for: issues, quickFixResult: quickFixResult)

        if issues.isEmpty {
            issues.append(
                DocumentHealthIssue(
                    severity: .info,
                    title: "No active document warnings",
                    detail: "The current document does not expose any elevated health warnings from the signals tracked by the app."
                )
            )
        }

        return DocumentHealthSummary(
            documentName: documentName,
            pageCount: pageCount,
            validationStatus: validationStatus,
            shareReadiness: shareReadiness,
            issues: issues
        )
    }

    private static func shareReadiness(for issues: [DocumentHealthIssue],
                                       quickFixResult: QuickFixResult?) -> ShareReadiness
    {
        if issues.contains(where: { $0.severity == .critical }) {
            return .blocked
        }

        if let quickFixResult,
           quickFixResult.ocrReport.emptyOCRPages > 0,
           quickFixResult.redactionReport.totalRedactionRectCount > 0
        {
            return .blocked
        }

        if issues.contains(where: { $0.severity == .warning }) {
            return .reviewRecommended
        }

        return .ready
    }

    private static func outboundMetadataFields(from attributes: [AnyHashable: Any]?) -> [String] {
        guard let attributes else { return [] }
        let sensitiveKeys: [([AnyHashable], String)] = [
            (["Title", PDFDocumentAttribute.titleAttribute], "title"),
            (["Author", PDFDocumentAttribute.authorAttribute], "author"),
            (["Subject", PDFDocumentAttribute.subjectAttribute], "subject"),
            (["Keywords", PDFDocumentAttribute.keywordsAttribute], "keywords"),
            (["Creator", PDFDocumentAttribute.creatorAttribute], "creator"),
            (["Producer", PDFDocumentAttribute.producerAttribute], "producer"),
        ]

        return sensitiveKeys.compactMap { keys, label in
            guard let value = keys.lazy.compactMap({ attributes[$0] }).first else { return nil }
            if let string = value as? String {
                return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : label
            }
            if let values = value as? [String] {
                return values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ? label : nil
            }
            return label
        }
    }

    func plainTextReport(generatedAt: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var lines: [String] = [
            "PDFQuickFix Document Health Report",
            "Generated: \(formatter.string(from: generatedAt))",
            "",
            "Document: \(documentName)",
            "Pages: \(pageCount)",
            "Share readiness: \(shareReadiness.title)",
            "Readiness detail: \(shareReadiness.detail)",
        ]

        if let validationStatus, !validationStatus.isEmpty {
            lines.append("Validation: \(validationStatus)")
        }

        lines.append("")
        lines.append("Findings:")
        for issue in issues {
            lines.append("- [\(issue.severity.rawValue.uppercased())] \(issue.title): \(issue.detail)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

struct DocumentHealthSheet: View {
    let summary: DocumentHealthSummary
    let onRepairAndSaveAs: (() -> Void)?
    let onExportSanitized: (() -> Void)?
    let onExportReport: (() -> Void)?
    let onOpenQuickFix: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Document Health")
                    .font(.title2.bold())
                Text(summary.documentName)
                    .font(.headline)
                Text("\(summary.pageCount) page(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let validationStatus = summary.validationStatus, !validationStatus.isEmpty {
                Label(validationStatus, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.shareReadiness.title)
                        .font(.subheadline.weight(.semibold))
                    Text(summary.shareReadiness.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: summary.shareReadiness.systemImage)
                    .foregroundStyle(summary.shareReadiness.color)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summary.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.severity.systemImage)
                                .foregroundStyle(issue.severity.color)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(issue.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            HStack {
                if let onRepairAndSaveAs {
                    Button("Repair & Save As…") {
                        dismiss()
                        onRepairAndSaveAs()
                    }
                }

                if let onExportSanitized {
                    Button("Export Sanitized…") {
                        dismiss()
                        onExportSanitized()
                    }
                }

                if let onExportReport {
                    Button("Export Report…") {
                        dismiss()
                        onExportReport()
                    }
                }

                Spacer()

                if let onOpenQuickFix {
                    Button("Open QuickFix") {
                        dismiss()
                        onOpenQuickFix()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }
}
