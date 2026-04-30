import AppKit
import SwiftUI

struct QuickFixSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var inputURL: URL?
    var onDone: (URL?) -> Void
    var manualRedactions: [Int: [CGRect]] = [:]

    @StateObject private var optionsModel = QuickFixOptionsModel()
    @State private var isProcessing: Bool = false
    @State private var log: String = ""
    @State private var quickFixResult: QuickFixResult?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cleanup review sheet")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.support)
                        Text("Run QuickFix and inspect the output packet")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.primaryText)
                        Text("Review the source, execute cleanup, and inspect the resulting evidence before handing the file back to Studio.")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                    }
                    Spacer()
                    Button("Close") {
                        if quickFixResult == nil {
                            onDone(nil)
                        }
                        dismiss()
                    }
                    .buttonStyle(GhostButtonStyle())
                }

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Source + controls", detail: "Confirm the source file and adjust cleanup settings before running.")
                    HStack(alignment: .top) {
                        Text("Source")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.Colors.secondaryText)
                            .frame(width: 72, alignment: .leading)
                        Text(inputURL?.lastPathComponent ?? "Choose a file to start the cleanup review")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(AppTheme.Colors.primaryText)
                    }
                    QuickFixOptionsForm(model: optionsModel)
                }
                .cardStyle()

                if isProcessing {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Processing", detail: "QuickFix is preparing a reviewable outbound copy.")
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                    .cardStyle()
                }

                if !log.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Run log", detail: "Use this trace when validating the cleanup path.")
                        ScrollView {
                            Text(log)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.Colors.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 120)
                    }
                    .cardStyle()
                }

                if let result = quickFixResult {
                    resultReceipt(result)
                }

                if let report = quickFixResult?.redactionReport {
                    RedactionReportView(report: report)
                }

                if let report = quickFixResult?.ocrReport {
                    OCRReportView(report: report)
                }

                HStack {
                    Spacer()
                    Button("Run QuickFix", action: run)
                        .buttonStyle(PrimaryButtonStyle(isDisabled: inputURL == nil || isProcessing))
                        .disabled(inputURL == nil || isProcessing)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .background(AppTheme.Colors.background.ignoresSafeArea())
        .onChange(of: inputURL) { _ in
            guard let inputURL else {
                quickFixResult = nil
                return
            }
            if let outputURL = quickFixResult?.outputURL,
               inputURL.standardizedFileURL == outputURL.standardizedFileURL
            {
                return
            }
            quickFixResult = nil
        }
    }

    private func resultReceipt(_ result: QuickFixResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Output packet", detail: "Open the result, review reports, and confirm the file is ready for handoff.")

            VStack(alignment: .leading, spacing: 10) {
                evidenceRow("Input", value: inputURL?.lastPathComponent ?? "Unknown")
                evidenceRow("Output", value: result.outputURL.lastPathComponent)
                evidenceRow("Folder", value: result.outputURL.deletingLastPathComponent().path)
            }
            .paperPanelStyle()

            HStack(spacing: 12) {
                Button("Open Result") {
                    NSWorkspace.shared.open(result.outputURL)
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([result.outputURL])
                }
                .buttonStyle(SecondaryButtonStyle())

                Spacer()

                Text("Ready to review")
                    .font(.caption)
                    .foregroundStyle(AppTheme.Colors.support)
            }
        }
        .cardStyle()
    }

    private func sectionHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .appFont(.headline)
                .foregroundStyle(AppTheme.Colors.primaryText)
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.secondaryText)
        }
    }

    private func evidenceRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.Colors.paperText.opacity(0.72))
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(AppTheme.Colors.paperText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func run() {
        guard !isProcessing, let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"

        let model = optionsModel
        let manualRects = manualRedactions
        Task.detached(priority: .userInitiated) {
            do {
                let defaultOutput = inputURL.deletingPathExtension().appendingPathExtension("fixed.pdf")
                let outputSelection = try await MainActor.run {
                    try resolveQuickFixOutputSelection(defaultOutputURL: defaultOutput)
                }
                let result = try withExtendedLifetime(outputSelection.access) {
                    try model.runQuickFixResult(
                        inputURL: inputURL,
                        outputURL: outputSelection.url,
                        manualRedactions: manualRects,
                        shouldCancel: { Task.isCancelled },
                        progress: { current, total in
                            DispatchQueue.main.async {
                                log += "Progress: \(current)/\(total)\n"
                            }
                        }
                    )
                }
                await MainActor.run {
                    quickFixResult = result
                    QuickFixResultStore.shared.set(result, sourceURL: inputURL)
                    log += "✅ Done → \(result.outputURL.path)\n"
                    isProcessing = false
                    onDone(result.outputURL)
                }
            } catch QuickFixOutputSelectionError.cancelled {
                await MainActor.run {
                    log += "⚠️ Cancelled: output location not selected.\n"
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    log += "❌ Error: \(error.localizedDescription)\n"
                    isProcessing = false
                }
            }
        }
    }
}
