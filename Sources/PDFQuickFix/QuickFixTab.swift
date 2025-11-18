import SwiftUI
import AppKit

struct QuickFixTab: View {
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @StateObject private var optionsModel = QuickFixOptionsModel()
    @State private var isProcessing: Bool = false
    @State private var log: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("PDF QuickFix").font(.largeTitle).bold()
            Text("Inline edit, secure redaction, and OCR repair. All on your Mac.").foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("Choose PDF…") { pickInput() }
                if let inputURL {
                    Text(inputURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("No file selected").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Process", action: runProcess)
                .disabled(inputURL == nil || isProcessing)
            }
            
            GroupBox("Options") {
                QuickFixOptionsForm(model: optionsModel)
            }
            
            DropAreaView(inputURL: $inputURL)
                .frame(maxWidth: .infinity, minHeight: 120)
            
            if isProcessing {
                ProgressView().progressViewStyle(.linear)
            }
            
            ScrollView {
                Text(log).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 120)
            
            HStack {
                if let outputURL {
                    Button("Reveal Output in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) }
                    Text(outputURL.lastPathComponent).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
        }
        .padding(20)
    }
    
    private func pickInput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK {
            inputURL = panel.url
        }
    }
    
    private func runProcess() {
        guard !isProcessing, let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"
        
        let model = optionsModel
        Task.detached(priority: .userInitiated) {
            do {
                let out = try model.runQuickFix(inputURL: inputURL)
                await MainActor.run {
                    self.outputURL = out
                    self.log += "✅ Done → \(out.path)\n"
                    self.isProcessing = false
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

struct DropAreaView: View {
    @Binding var inputURL: URL?
    @State private var isDragging = false
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isDragging ? Color.accentColor : Color.secondary)
            VStack(spacing: 6) {
                Text("Drop a PDF here")
                Text("or click “Choose PDF…”").foregroundStyle(.secondary).font(.footnote)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            for item in providers {
                _ = item.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.pathExtension.lowercased() == "pdf" {
                        DispatchQueue.main.async {
                            self.inputURL = url
                        }
                    }
                }
            }
            return true
        }
    }
}
