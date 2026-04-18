import SwiftUI

struct RedactionReportView: View {
    let report: RedactionReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Redaction Report", systemImage: "checkmark.shield")
                .appFont(.headline)
                .foregroundStyle(AppTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 10) {
                metricRow(label: "Pages with redactions", value: pagesWithRedactionsText)
                metricRow(label: "Total redaction boxes", value: "\(report.totalRedactionRectCount)")
                metricRow(label: "Suppressed OCR runs", value: "\(report.suppressedOCRRunCount)")

                if report.suppressedOCRRunCount > 0 {
                    Divider()
                    Label("Searchable OCR text was removed under redactions.", systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(AppTheme.Colors.warning)
                        .appFont(.subheadline, weight: .semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .paperPanelStyle()
        }
        .cardStyle()
    }

    private var pagesWithRedactionsText: String {
        guard !report.pagesWithRedactions.isEmpty else { return "None" }
        let pages = report.pagesWithRedactions.map { $0 + 1 }
        let maxShown = 24
        if pages.count <= maxShown {
            return pages.map(String.init).joined(separator: ", ")
        }
        let shown = pages.prefix(maxShown).map(String.init).joined(separator: ", ")
        return "\(shown), … (+\(pages.count - maxShown) more)"
    }

    @ViewBuilder
    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(AppTheme.Colors.paperText.opacity(0.72))
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(AppTheme.Colors.paperText)
        }
        .font(.caption)
    }
}
