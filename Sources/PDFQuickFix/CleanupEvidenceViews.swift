import AppKit
import PDFKit
import SwiftUI

struct CleanupEvidenceSheet: View {
    let evidence: CleanupEvidence

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cleanup Evidence")
                        .font(.title2.bold())
                    Text("Schema \(evidence.schemaVersion) · privacy-safe outbound receipt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(verdictTitle, systemImage: verdictIcon)
                    .font(.headline)
                    .foregroundStyle(verdictColor)
                    .accessibilityLabel(verdictTitle)
                    .accessibilityIdentifier("cleanup-evidence-verdict-\(evidence.verdict.rawValue)")
            }

            HStack(spacing: 12) {
                documentCard(title: "Before", facts: evidence.source)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                documentCard(title: "After", facts: evidence.output)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    evidenceSection("Operation", rows: [
                        ("Type", evidence.operationKind == .quickFix ? "Quick Fix" : "Sanitized Export"),
                        ("Profile", evidence.sanitizeProfile ?? "Not applicable"),
                        ("Generated", evidence.generatedAt.formatted(date: .abbreviated, time: .standard)),
                    ])

                    if let comparison = evidence.comparison {
                        evidenceSection("Comparison", rows: [
                            ("Compared pages", "\(comparison.comparedPageCount)"),
                            ("Changed pages", "\(comparison.changedPageCount)"),
                            ("Matching pages", "\(comparison.matchingPageCount)"),
                            ("Maximum visual delta", percentage(comparison.maximumDifferenceRatio)),
                        ])
                    }

                    if let verification = evidence.redactionVerification {
                        evidenceSection("Redaction verification", rows: [
                            ("Status", verification.status.rawValue),
                            ("Candidates checked", "\(verification.checkedCandidateCount)"),
                            ("Candidates detected", "\(verification.detectedCandidateCount)"),
                        ])
                    }

                    if let telemetry = evidence.quickFixTelemetry {
                        evidenceSection("Cleanup telemetry", rows: [
                            ("Redaction regions", "\(telemetry.redactionRectangleCount)"),
                            ("Suppressed OCR runs", "\(telemetry.suppressedOCRRunCount)"),
                            ("Local OCR pages", "\(telemetry.localOCRPageCount)"),
                            ("Cloud OCR pages", "\(telemetry.cloudOCRPageCount)"),
                            ("Vision OCR pages", "\(telemetry.visionOCRPageCount)"),
                            ("OCR disabled pages", "\(telemetry.ocrDisabledPageCount)"),
                            ("Empty OCR pages", "\(telemetry.emptyOCRPageCount)"),
                            ("Local OCR fallbacks", "\(telemetry.localOCRFallbackCount)"),
                        ])
                    }

                    if !evidence.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Review notes").font(.headline)
                            ForEach(evidence.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.Colors.warning)
                            }
                        }
                        .cardStyle()
                    }
                }
            }

            HStack {
                Text("Hashes verify file identity; the receipt contains no extracted text or metadata values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 620)
        .background(AppTheme.Colors.background)
    }

    private func documentCard(title: String, facts: CleanupDocumentFacts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(facts.fileName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(facts.pageCount) pages · \(ByteCountFormatter.string(fromByteCount: Int64(facts.byteCount), countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(facts.sha256)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Text("Metadata: \(facts.metadataFieldLabels.isEmpty ? "none" : facts.metadataFieldLabels.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous))
    }

    private func evidenceSection(_ title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).fontWeight(.medium)
                }
                .font(.caption)
            }
        }
        .cardStyle()
    }

    private var verdictTitle: String {
        switch evidence.verdict {
        case .passed: "Passed"
        case .reviewRequired: "Review required"
        case .failed: "Failed"
        }
    }

    private var verdictIcon: String {
        switch evidence.verdict {
        case .passed: "checkmark.shield.fill"
        case .reviewRequired: "exclamationmark.triangle.fill"
        case .failed: "xmark.shield.fill"
        }
    }

    private var verdictColor: Color {
        switch evidence.verdict {
        case .passed: AppTheme.Colors.success
        case .reviewRequired: AppTheme.Colors.warning
        case .failed: AppTheme.Colors.error
        }
    }

    private func percentage(_ value: Double?) -> String {
        guard let value else { return "Not measured" }
        return value.formatted(.percent.precision(.fractionLength(1)))
    }
}

struct CleanupExportReviewSheet: View {
    private enum ReviewTab: String, CaseIterable, Identifiable {
        case evidence = "Evidence"
        case comparison = "Before / After"

        var id: String {
            rawValue
        }
    }

    let review: CleanupReview

    @State private var selectedTab: ReviewTab = .evidence
    @State private var exportError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Review", selection: $selectedTab) {
                    ForEach(ReviewTab.allCases) { tab in
                        Text(tab.rawValue)
                            .accessibilityIdentifier(tab == .evidence ? "cleanup-review-tab-evidence" : "cleanup-review-tab-comparison")
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                Spacer()

                Button("Export Evidence…") {
                    exportEvidence()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            switch selectedTab {
            case .evidence:
                CleanupEvidenceSheet(evidence: review.evidence)
            case .comparison:
                CleanupComparisonSheet(
                    sourceURL: review.sourceSnapshotURL,
                    outputURL: review.outputURL,
                    comparison: review.comparison
                )
            }
        }
        .alert("Evidence Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: {
                if !$0 {
                    exportError = nil
                }
            }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "Unknown error")
        }
    }

    private func exportEvidence() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = review.outputURL.deletingPathExtension().lastPathComponent + "-cleanup-evidence.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CleanupEvidenceWriter.writeJSON(review.evidence, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = error.localizedDescription
        }
    }
}

struct CleanupComparisonSheet: View {
    let sourceURL: URL
    let outputURL: URL
    let comparison: CleanupComparisonResult

    @State private var selectedPageNumber: Int
    @Environment(\.dismiss) private var dismiss

    private let sourceDocument: PDFDocument?
    private let outputDocument: PDFDocument?

    init(sourceURL: URL, outputURL: URL, comparison: CleanupComparisonResult) {
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.comparison = comparison
        sourceDocument = PDFDocument(url: sourceURL)
        outputDocument = PDFDocument(url: outputURL)
        _selectedPageNumber = State(initialValue: comparison.changedPages.first ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Before / After Cleanup")
                        .font(.title2.bold())
                    Text("Changed pages focus on visible output and extractable text-layer differences.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(spacing: 12) {
                summaryBadge("Changed", value: comparison.changedPages.count, color: AppTheme.Colors.warning)
                summaryBadge("Before pages", value: comparison.sourcePageCount, color: .secondary)
                summaryBadge("After pages", value: comparison.outputPageCount, color: .secondary)
                if !comparison.metadataFieldsRemoved.isEmpty {
                    Label("Removed metadata: \(comparison.metadataFieldsRemoved.joined(separator: ", "))", systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(AppTheme.Colors.success)
                }
            }

            HSplitView {
                changedPagesSidebar
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 240)
                HStack(spacing: 14) {
                    pagePreview(title: "Before", document: sourceDocument)
                    pagePreview(title: "After", document: outputDocument)
                }
                .padding(.leading, 8)
            }
        }
        .padding(18)
        .frame(minWidth: 980, minHeight: 680)
        .background(AppTheme.Colors.background)
    }

    private var changedPagesSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Changed pages").font(.headline)
            if comparison.changedPages.isEmpty {
                Label("No page changes detected", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.success)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(comparison.changedPages, id: \.self) { pageNumber in
                            let page = comparison.pages[pageNumber - 1]
                            Button {
                                selectedPageNumber = pageNumber
                            } label: {
                                HStack {
                                    Text("Page \(pageNumber)")
                                    Spacer()
                                    Text(classificationTitle(page.classification))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(classificationColor(page.classification))
                                }
                                .padding(8)
                                .background(selectedPageNumber == pageNumber ? AppTheme.Colors.accent.opacity(0.18) : AppTheme.Colors.cardBackground)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer()
            if let selected = selectedComparison {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Page evidence").font(.caption.weight(.semibold))
                    Text("Visual delta: \(selected.visualDifferenceRatio.formatted(.percent.precision(.fractionLength(1))))")
                    Text("Text character delta: \(selected.textCharacterCountDelta.formatted(.number.sign(strategy: .always())))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(AppTheme.Colors.cardBackground.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous))
    }

    private func pagePreview(title: String, document: PDFDocument?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("Page \(selectedPageNumber)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let page = document?.page(at: selectedPageNumber - 1) {
                Image(nsImage: page.thumbnail(of: NSSize(width: 760, height: 980), for: .mediaBox))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(8)
                    .background(AppTheme.Colors.paperBackground)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous)
                            .stroke(AppTheme.Colors.paperBorder, lineWidth: 1)
                    )
                    .shadow(color: AppTheme.Shadows.card, radius: 6, x: 0, y: 2)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.largeTitle)
                    Text("Page unavailable")
                        .font(.headline)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var selectedComparison: CleanupPageComparison? {
        comparison.pages.first { $0.pageNumber == selectedPageNumber }
    }

    private func summaryBadge(_ title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(.secondary)
            Text("\(value)").fontWeight(.semibold).foregroundStyle(color)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(AppTheme.Colors.cardBackground)
        .clipShape(Capsule())
    }

    private func classificationTitle(_ classification: CleanupPageClassification) -> String {
        switch classification {
        case .visualChanged: "Visual"
        case .textLayerChanged: "Text layer"
        case .unchanged: "Unchanged"
        }
    }

    private func classificationColor(_ classification: CleanupPageClassification) -> Color {
        switch classification {
        case .visualChanged: AppTheme.Colors.warning
        case .textLayerChanged: AppTheme.Colors.accent
        case .unchanged: AppTheme.Colors.success
        }
    }
}
