import SwiftUI
import AppKit

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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("QuickFix").font(.title2).bold()
                Spacer()
                Button("Close") {
                    if quickFixResult == nil {
                        onDone(nil)
                    }
                    dismiss()
                }
            }
            Text("Redaction • Inline Find→Replace • OCR repair")
                .foregroundStyle(.secondary)
            
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Source:")
                            .frame(width: 80, alignment: .leading)
                        Text(inputURL?.lastPathComponent ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    QuickFixOptionsForm(model: optionsModel)
                }
                .padding(8)
            }
            
            if isProcessing {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            ScrollView {
                Text(log)
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120)

            if let report = quickFixResult?.redactionReport {
                RedactionReportView(report: report)
            }
            
            HStack {
                Spacer()
                Button("Run QuickFix", action: run)
                .disabled(inputURL == nil || isProcessing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onChange(of: inputURL) { _ in
            guard let inputURL else {
                quickFixResult = nil
                return
            }
            if let outputURL = quickFixResult?.outputURL,
               inputURL.standardizedFileURL == outputURL.standardizedFileURL {
                return
            }
            quickFixResult = nil
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
                let result = try model.runQuickFixResult(
                    inputURL: inputURL,
                    manualRedactions: manualRects
                )
                await MainActor.run {
                    self.quickFixResult = result
                    QuickFixResultStore.shared.set(result)
                    self.log += "✅ Done → \(result.outputURL.path)\n"
                    self.isProcessing = false
                    self.onDone(result.outputURL)
                }
            } catch {
                await MainActor.run {
                    self.log += "❌ Error: \(error.localizedDescription)\n"
                    self.isProcessing = false
                }
            }
        }
    }
}
