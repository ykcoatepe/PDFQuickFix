import SwiftUI

struct OCRReportView: View {
    let report: OCRReport

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                metricRow(label: "Total pages", value: "\(report.totalPages)")
                metricRow(label: "DeepSeek overlay pages", value: "\(report.deepSeekOverlayPages)")
                metricRow(label: "Vision OCR pages", value: "\(report.visionOCRPages)")
                metricRow(label: "OCR disabled pages", value: "\(report.ocrDisabledPages)")
                metricRow(label: "Empty OCR pages", value: "\(report.emptyOCRPages)")
                metricRow(label: "DeepSeek fallbacks", value: "\(report.deepSeekFallbackCount)")
            }
            .padding(8)
        } label: {
            Label("OCR Report", systemImage: "text.magnifyingglass")
                .appFont(.headline)
        }
    }

    @ViewBuilder
    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
        .font(.caption)
    }
}
