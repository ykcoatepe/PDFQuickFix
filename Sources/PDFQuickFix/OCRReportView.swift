import SwiftUI

struct OCRReportView: View {
    let report: OCRReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("OCR Report", systemImage: "text.magnifyingglass")
                .appFont(.headline)
                .foregroundStyle(AppTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                metricRow(label: "Total pages", value: "\(report.totalPages)")
                metricRow(label: "Local OCR pages", value: "\(report.localOCRPages)")
                metricRow(label: "Cloud OCR pages", value: "\(report.cloudOCRPages)")
                metricRow(label: "Vision OCR pages", value: "\(report.visionOCRPages)")
                metricRow(label: "OCR disabled pages", value: "\(report.ocrDisabledPages)")
                metricRow(label: "Empty OCR pages", value: "\(report.emptyOCRPages)")
                metricRow(label: "Local OCR fallbacks", value: "\(report.localOCRFallbackCount)")
            }
            .paperPanelStyle()
        }
        .cardStyle()
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
