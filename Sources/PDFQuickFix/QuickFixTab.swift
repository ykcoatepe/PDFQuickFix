import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct QuickFixTab: View {
    @State private var inputURL: URL?
    @State private var quickFixResult: QuickFixResult?
    @StateObject private var optionsModel = QuickFixOptionsModel()
    @State private var isProcessing: Bool = false
    @State private var log: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("PDF QuickFix")
                    .appFont(.largeTitle, weight: .bold)
                Text("Inline edit, secure redaction, and OCR repair. All on your Mac.")
                    .appFont(.body)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    Button(action: pickInput) {
                        Label("Choose PDF…", systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    
                    if let inputURL {
                        HStack {
                            Image(systemName: "doc.fill")
                                .foregroundStyle(AppColors.primary)
                            Text(inputURL.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(AppColors.surface)
                        .cornerRadius(8)
                    } else {
                        Text("No file selected")
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    }
                    
                    Spacer()
                    
                    Button(action: runProcess) {
                        if isProcessing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Process", systemImage: "gearshape.2.fill")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(isDisabled: inputURL == nil || isProcessing))
                    .disabled(inputURL == nil || isProcessing)
                }
                
                DropAreaView(inputURL: $inputURL)
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
            .cardStyle()
            
            GroupBox {
                QuickFixOptionsForm(model: optionsModel)
                    .padding(8)
            } label: {
                Label("Options", systemImage: "slider.horizontal.3")
                    .appFont(.headline)
            }
            
            if !log.isEmpty {
                ScrollView {
                    Text(log)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(height: 120)
                .background(AppColors.surface)
                .cornerRadius(AppLayout.smallCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: AppLayout.smallCornerRadius)
                        .stroke(AppColors.border, lineWidth: 0.5)
                )
            }
            
            if let quickFixResult {
                let outputURL = quickFixResult.outputURL
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AppColors.success)
                        .font(.title2)
                    
                    VStack(alignment: .leading) {
                        Text("Processing Complete")
                            .appFont(.headline)
                        Text(outputURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer()
                    
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding()
                .background(AppColors.success.opacity(0.1))
                .cornerRadius(AppLayout.cornerRadius)
            }

            if let report = quickFixResult?.redactionReport {
                RedactionReportView(report: report)
            }
            
            Spacer()
        }
        .padding(24)
        .background(AppColors.background)
        .onChange(of: inputURL) { _ in
            quickFixResult = nil
        }
    }
    
    private func pickInput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK {
            inputURL = panel.url
            quickFixResult = nil
        }
    }
    
    private func runProcess() {
        guard !isProcessing, let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"
        
        let model = optionsModel
        Task.detached(priority: .userInitiated) {
            do {
                let result = try model.runQuickFixResult(inputURL: inputURL)
                await MainActor.run {
                    self.quickFixResult = result
                    QuickFixResultStore.shared.set(result)
                    self.log += "✅ Done → \(result.outputURL.path)\n"
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
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isDragging ? AppColors.primary : AppColors.border)
                .background(isDragging ? AppColors.primary.opacity(0.05) : Color.clear)
            
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 32))
                    .foregroundStyle(isDragging ? AppColors.primary : .secondary)
                
                VStack(spacing: 4) {
                    Text("Drop a PDF here")
                        .appFont(.headline)
                    Text("or click “Choose PDF…” above")
                        .appFont(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onDrop(of: [.fileURL, .pdf], isTargeted: $isDragging) { providers in
            handlePDFDrop(providers) { url in
                inputURL = url
            }
        }
        .animation(.easeInOut, value: isDragging)
    }
}
