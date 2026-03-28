import SwiftUI

struct ReaderCopilotView: View {
    @ObservedObject var controller: ReaderControllerPro
    private var hasDocument: Bool { controller.document != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        Task { await controller.runCopilotRequest(.quickSummary(scope: .document)) }
                    } label: {
                        Label("Quick Summary", systemImage: "text.alignleft")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!hasDocument)

                    Button {
                        Task { await controller.runCurrentPageDigest() }
                    } label: {
                        Label("Current Page Digest", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!hasDocument)

                    Button {
                        Task { await controller.explainCurrentSelection() }
                    } label: {
                        Label("Explain Selection", systemImage: "quote.bubble")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(controller.currentSelectionText == nil)

                    HStack(spacing: 8) {
                        TextField("Ask this document", text: $controller.copilotQuery)
                            .textFieldStyle(.roundedBorder)
                            .disabled(!hasDocument)
                            .onSubmit {
                                Task { await controller.runCopilotQuery() }
                            }

                        Button {
                            Task { await controller.runCopilotQuery() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle(isDisabled: controller.copilotQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                        .disabled(!hasDocument || controller.copilotQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .cardStyle()

                if let error = controller.copilotError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                responseView
            }
            .padding(12)
        }
        .background(AppTheme.Colors.sidebarBackground)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Copilot")
                    .appFont(.headline, weight: .semibold)
                    .foregroundColor(AppTheme.Colors.primaryText)
                Text("Local answers grounded in the open PDF.")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }

            Spacer()

            if controller.isCopilotRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var responseView: some View {
        if let response = controller.copilotResponse {
            VStack(alignment: .leading, spacing: 12) {
                Text(response.answer)
                    .font(.body)
                    .foregroundColor(AppTheme.Colors.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !response.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Citations")
                            .appFont(.caption, weight: .semibold)
                            .foregroundColor(AppTheme.Colors.secondaryText)

                        ForEach(response.citations, id: \.self) { citation in
                            Button {
                                controller.jumpToCitationPage(citation)
                            } label: {
                                HStack {
                                    Text(citation.pageLabel)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                    }
                }

                HStack(spacing: 8) {
                    Text(response.model)
                    Spacer()
                    if response.requestWasTrimmed || response.contextWasTrimmed || response.inputWasTrimmed {
                        Text("Trimmed")
                    }
                }
                .font(.caption)
                .foregroundColor(AppTheme.Colors.secondaryText)
            }
            .cardStyle()
        } else {
            Text(hasDocument ? "Run a copilot action to get a grounded answer." : "Open a PDF to use copilot.")
                .font(.caption)
                .foregroundColor(AppTheme.Colors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
        }
    }
}
