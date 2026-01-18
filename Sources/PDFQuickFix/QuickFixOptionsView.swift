import SwiftUI
import AppKit

final class QuickFixOptionsModel: ObservableObject {
    @Published var doOCR: Bool = true
    @Published var ocrProvider: OCRProviderPreference = .autoDeepSeek
    @Published var useDefaults: Bool = true
    @Published var customRegexText: String = ""
    @Published var findText: String = ""
    @Published var replaceText: String = ""
    @Published var dpi: Double = 300
    @Published var padding: Double = 2.0
    @Published var langTR: Bool = true
    @Published var langEN: Bool = true
    @Published var preprocessImages: Bool = true

    func makeParameters(manualRedactions: [Int: [CGRect]] = [:]) -> QuickFixExecutionParameters {
        var patterns: [RedactionPattern] = []
        if useDefaults {
            patterns.append(contentsOf: DefaultPatterns.defaults())
        }

        let regexes: [NSRegularExpression] = customRegexText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }

        var findReplaceRules: [FindReplaceRule] = []
        if !findText.isEmpty {
            findReplaceRules.append(.init(find: findText, replace: replaceText))
        }

        let languages = preferredLanguages()
        let options = QuickFixOptions(
            doOCR: doOCR,
            dpi: CGFloat(dpi),
            redactionPadding: CGFloat(padding),
            ocrProvider: ocrProvider
        )

        return QuickFixExecutionParameters(
            options: options,
            languages: languages,
            redactionPatterns: patterns,
            customRegexes: regexes,
            findReplace: findReplaceRules,
            manualRedactions: manualRedactions
        )
    }

    func runQuickFix(inputURL: URL,
                     outputURL: URL? = nil,
                     manualRedactions: [Int: [CGRect]] = [:],
                     shouldCancel: QuickFixCancellationChecker? = nil,
                     progress: ((Int, Int) -> Void)? = nil) throws -> URL {
        try runQuickFixResult(inputURL: inputURL,
                              outputURL: outputURL,
                              manualRedactions: manualRedactions,
                              shouldCancel: shouldCancel,
                              progress: progress).outputURL
    }

    func runQuickFixResult(inputURL: URL,
                           outputURL: URL? = nil,
                           manualRedactions: [Int: [CGRect]] = [:],
                           shouldCancel: QuickFixCancellationChecker? = nil,
                           progress: ((Int, Int) -> Void)? = nil) throws -> QuickFixResult {
        let parameters = makeParameters(manualRedactions: manualRedactions)
        let engine = PDFQuickFixEngine(options: parameters.options, languages: parameters.languages)
        return try engine.processResult(
            inputURL: inputURL,
            outputURL: outputURL,
            redactionPatterns: parameters.redactionPatterns,
            customRegexes: parameters.customRegexes,
            findReplace: parameters.findReplace,
            manualRedactions: parameters.manualRedactions,
            shouldCancel: shouldCancel,
            progress: progress
        )
    }

    private func preferredLanguages() -> [String] {
        var languages: [String] = []
        if langTR { languages.append("tr-TR") }
        if langEN { languages.append("en-US") }
        if languages.isEmpty {
            languages = ["en-US"]
        }
        return languages
    }
}

struct QuickFixExecutionParameters {
    let options: QuickFixOptions
    let languages: [String]
    let redactionPatterns: [RedactionPattern]
    let customRegexes: [NSRegularExpression]
    let findReplace: [FindReplaceRule]
    let manualRedactions: [Int: [CGRect]]
}

struct QuickFixOptionsForm: View {
    @ObservedObject var model: QuickFixOptionsModel
    @State private var deepSeekAvailable: Bool?
    @State private var isCheckingDeepSeek: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Repair OCR / add searchable text layer", isOn: $model.doOCR)
            Picker("OCR engine", selection: $model.ocrProvider) {
                Text("Auto (DeepSeek if available)").tag(OCRProviderPreference.autoDeepSeek)
                Text("Vision only").tag(OCRProviderPreference.visionOnly)
            }
            .pickerStyle(.segmented)
            .disabled(!model.doOCR)
            if model.doOCR {
                Text("DeepSeek is used for OCR-only runs; redaction/replace uses Vision.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if model.doOCR, model.ocrProvider == .autoDeepSeek {
                HStack {
                    Text("DeepSeek status")
                    Spacer()
                    Text(deepSeekStatusText)
                        .foregroundStyle(deepSeekStatusColor)
                    Button(isCheckingDeepSeek ? "Checking…" : "Refresh") {
                        refreshDeepSeekStatus()
                    }
                    .buttonStyle(.plain)
                    .disabled(isCheckingDeepSeek)
                }
                .font(.caption)
            }
            Toggle("Auto-crop & deskew images (AI)", isOn: $model.preprocessImages)
                .help("Applies to PNG/JPEG inputs only.")
            Toggle("Redact defaults (IBAN, TCKN, PNR, tail)", isOn: $model.useDefaults)
            HStack {
                Text("Custom regex (comma-separated)")
                TextField(#"(e.g. \bU\d{6,8}\b, \b[A-Z]{2}\d{8}\b)"#, text: $model.customRegexText)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Find")
                TextField("AYT", text: $model.findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                Text("→ Replace")
                TextField("ESB", text: $model.replaceText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }
            HStack {
                Stepper("DPI: \(Int(model.dpi))", value: $model.dpi, in: 150...600, step: 50)
                Stepper(
                    "Redaction padding: \(String(format: "%.1f", model.padding)) px",
                    value: $model.padding,
                    in: 0...8,
                    step: 0.5
                )
            }
            HStack {
                Text("OCR languages:")
                Toggle("TR", isOn: $model.langTR)
                Toggle("EN", isOn: $model.langEN)
            }
        }
        .onAppear {
            refreshDeepSeekStatus()
        }
        .onChange(of: model.ocrProvider) { _ in
            refreshDeepSeekStatus()
        }
        .onChange(of: model.doOCR) { _ in
            refreshDeepSeekStatus()
        }
    }

    private var deepSeekStatusText: String {
        if isCheckingDeepSeek {
            return "Checking…"
        }
        guard let deepSeekAvailable else { return "Unknown" }
        return deepSeekAvailable ? "Available" : "Unavailable"
    }

    private var deepSeekStatusColor: Color {
        guard let deepSeekAvailable else { return .secondary }
        return deepSeekAvailable ? AppColors.success : AppColors.warning
    }

    private func refreshDeepSeekStatus() {
        guard model.doOCR, model.ocrProvider == .autoDeepSeek else {
            deepSeekAvailable = nil
            return
        }
        isCheckingDeepSeek = true
        Task.detached(priority: .utility) {
            let available = OllamaDeepSeekOCRProvider().isAvailable()
            await MainActor.run {
                deepSeekAvailable = available
                isCheckingDeepSeek = false
            }
        }
    }
}
