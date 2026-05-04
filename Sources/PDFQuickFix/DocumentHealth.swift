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
    let issues: [DocumentHealthIssue]
}

extension DocumentHealthSummary {
    static func build(documentName: String,
                      pageCount: Int,
                      isRepaired: Bool,
                      isLargeDocument: Bool,
                      isMassiveDocument: Bool,
                      skippedQuickValidation: Bool,
                      validationStatus: String?,
                      quickFixResult: QuickFixResult?) -> DocumentHealthSummary
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
                    detail: "Open-time validation was skipped because the document size exceeded the fast-validation threshold."
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
            issues: issues
        )
    }
}

struct DocumentHealthSheet: View {
    let summary: DocumentHealthSummary
    let onRepairAndSaveAs: (() -> Void)?
    let onExportSanitized: (() -> Void)?
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
