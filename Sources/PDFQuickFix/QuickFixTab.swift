import SwiftUI
import AppKit

struct QuickFixTab: View {
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var doOCR: Bool = true
    @State private var useDefaults: Bool = true
    @State private var customRegexText: String = ""
    @State private var findText: String = ""
    @State private var replaceText: String = ""
    @State private var isProcessing: Bool = false
    @State private var log: String = ""
    @State private var dpi: Double = 300
    @State private var padding: Double = 2.0
    @State private var langTR: Bool = true
    @State private var langEN: Bool = true
    
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
                Button("Process") {
                    Task { await runProcess() }
                }
                .disabled(inputURL == nil || isProcessing)
            }
            
            GroupBox("Options") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Repair OCR / add searchable text layer", isOn: $doOCR)
                    Toggle("Redact defaults (IBAN, TCKN, PNR, tail)", isOn: $useDefaults)
                    HStack {
                        Text("Custom regex (comma-separated)")
                        TextField(#"(e.g. \bU\d{6,8}\b, \b[A-Z]{2}\d{8}\b)"#, text: $customRegexText)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Find")
                        TextField("AYT", text: $findText).textFieldStyle(.roundedBorder).frame(width: 160)
                        Text("→ Replace")
                        TextField("ESB", text: $replaceText).textFieldStyle(.roundedBorder).frame(width: 160)
                    }
                    HStack {
                        Stepper("DPI: \(Int(dpi))", value: $dpi, in: 150...600, step: 50)
                        Stepper("Redaction padding: \(String(format: "%.1f", padding)) px", value: $padding, in: 0...8, step: 0.5)
                    }
                    HStack {
                        Text("OCR languages:")
                        Toggle("TR", isOn: $langTR)
                        Toggle("EN", isOn: $langEN)
                    }
                }
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
    
    private func runProcess() async {
        guard let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"
        defer { isProcessing = false }
        
        var patterns: [RedactionPattern] = []
        if useDefaults { patterns.append(contentsOf: DefaultPatterns.defaults()) }
        let customs: [NSRegularExpression] = customRegexText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        var rules: [FindReplaceRule] = []
        if !findText.isEmpty {
            rules.append(.init(find: findText, replace: replaceText))
        }
        
        let langs: [String] = {
            var arr: [String] = []
            if langTR { arr.append("tr-TR") }
            if langEN { arr.append("en-US") }
            if arr.isEmpty { arr = ["en-US"] }
            return arr
        }()
        
        let engine = PDFQuickFixEngine(options: QuickFixOptions(doOCR: doOCR, dpi: CGFloat(dpi), redactionPadding: CGFloat(padding)), languages: langs)
        do {
            let out = try engine.process(inputURL: inputURL, outputURL: nil, redactionPatterns: patterns, customRegexes: customs, findReplace: rules)
            outputURL = out
            log += "✅ Done → \(out.path)\n"
        } catch {
            log += "❌ Error: \(error.localizedDescription)\n"
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
