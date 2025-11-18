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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("QuickFix").font(.title2).bold()
                Spacer()
                Button("Close") {
                    onDone(nil)
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
            
            HStack {
                Spacer()
                Button("Run QuickFix", action: run)
                .disabled(inputURL == nil || isProcessing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
    
    private func run() {
        guard !isProcessing, let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"
        
        let model = optionsModel
        let manualRects = manualRedactions
        Task.detached(priority: .userInitiated) {
            do {
                let output = try model.runQuickFix(
                    inputURL: inputURL,
                    manualRedactions: manualRects
                )
                await MainActor.run {
                    self.log += "✅ Done → \(output.path)\n"
                    self.isProcessing = false
                    self.onDone(output)
                    self.dismiss()
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
