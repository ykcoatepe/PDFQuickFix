import SwiftUI
import AppKit

struct QuickFixSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    @Binding var inputURL: URL?
    var onDone: (URL?) -> Void
    var manualRedactions: [Int: [CGRect]] = [:]
    
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
                    Toggle("Repair OCR / add searchable text layer", isOn: $doOCR)
                    Toggle("Redact defaults (IBAN, TCKN, PNR, tail)", isOn: $useDefaults)
                    HStack {
                        Text("Custom regex")
                            .frame(width: 95, alignment: .leading)
                        TextField(#"(e.g. \bU\d{6,8}\b, \b[A-Z]{2}\d{8}\b)"#, text: $customRegexText)
                            .textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("Find")
                            .frame(width: 95, alignment: .leading)
                        TextField("AYT", text: $findText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                        Text("→ Replace")
                        TextField("ESB", text: $replaceText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
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
                Button("Run QuickFix") {
                    Task { await run() }
                }
                .disabled(inputURL == nil || isProcessing)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
    
    private func run() async {
        guard let inputURL else { return }
        isProcessing = true
        log = "Processing \(inputURL.lastPathComponent)…\n"
        defer { isProcessing = false }
        
        var patterns: [RedactionPattern] = []
        if useDefaults {
            patterns.append(contentsOf: DefaultPatterns.defaults())
        }
        let customs: [NSRegularExpression] = customRegexText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        var rules: [FindReplaceRule] = []
        if !findText.isEmpty {
            rules.append(.init(find: findText, replace: replaceText))
        }
        
        let languages: [String] = {
            var arr: [String] = []
            if langTR { arr.append("tr-TR") }
            if langEN { arr.append("en-US") }
            if arr.isEmpty { arr = ["en-US"] }
            return arr
        }()
        
        let engine = PDFQuickFixEngine(
            options: QuickFixOptions(
                doOCR: doOCR,
                dpi: CGFloat(dpi),
                redactionPadding: CGFloat(padding)
            ),
            languages: languages
        )
        do {
            let output = try engine.process(
                inputURL: inputURL,
                outputURL: nil,
                redactionPatterns: patterns,
                customRegexes: customs,
                findReplace: rules,
                manualRedactions: manualRedactions
            )
            log += "✅ Done → \(output.path)\n"
            onDone(output)
            dismiss()
        } catch {
            log += "❌ Error: \(error.localizedDescription)\n"
        }
    }
}
