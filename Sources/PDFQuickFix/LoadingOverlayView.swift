import SwiftUI

struct LoadingOverlayView: View {
    var status: String?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.large)
            if let status, !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
