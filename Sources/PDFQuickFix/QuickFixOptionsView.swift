import SwiftUI
import AppKit

enum QuickFixOptionsError: LocalizedError {
    case invalidCustomRegex(String)

    var errorDescription: String? {
        switch self {
        case .invalidCustomRegex(let pattern):
            return "Invalid custom regex: \(pattern)"
        }
    }
}

final class QuickFixOptionsModel: ObservableObject {
    private static let localOCRModelKey = "LocalOCR.defaultModel"
    private static let cloudOcrEnabledKey = "CloudOCR.enabled"
    private static let cloudOcrApiKeyAccount = "CloudOCR.googleVisionApiKey"
    private static let keychainService = "com.yordamkocatepe.PDFQuickFix"
    private let defaults: UserDefaults

    @Published var doOCR: Bool = true
    @Published var ocrProvider: OCRProviderPreference = .autoLocalOCR
    @Published var useDefaults: Bool = true
    @Published var customRegexText: String = ""
    @Published var findText: String = ""
    @Published var replaceText: String = ""
    @Published var dpi: Double = 300
    @Published var padding: Double = 2.0
    @Published var langTR: Bool = true
    @Published var langEN: Bool = true
    @Published var preprocessImages: Bool = true
    @Published var localOCRModel: String = "qwen2.5vl:7b" {
        didSet {
            defaults.set(localOCRModel, forKey: Self.localOCRModelKey)
        }
    }
    @Published var cloudOcrEnabled: Bool = false {
        didSet {
            defaults.set(cloudOcrEnabled, forKey: Self.cloudOcrEnabledKey)
        }
    }
    @Published var cloudOcrApiKey: String = "" {
        didSet {
            KeychainStore.set(service: Self.keychainService,
                              account: Self.cloudOcrApiKeyAccount,
                              value: cloudOcrApiKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedModel = defaults.string(forKey: Self.localOCRModelKey) ?? ""
        self.localOCRModel = storedModel.isEmpty ? "qwen2.5vl:7b" : storedModel
        self.cloudOcrEnabled = defaults.bool(forKey: Self.cloudOcrEnabledKey)
        self.cloudOcrApiKey = KeychainStore.get(service: Self.keychainService,
                                                account: Self.cloudOcrApiKeyAccount) ?? ""
    }

    func makeParameters(manualRedactions: [Int: [CGRect]] = [:]) throws -> QuickFixExecutionParameters {
        let (options, languages) = makeExecutionContext()
        var patterns: [RedactionPattern] = []
        if useDefaults {
            patterns.append(contentsOf: DefaultPatterns.defaults())
        }

        let regexes = try parseCustomRegexes()

        var findReplaceRules: [FindReplaceRule] = []
        if !findText.isEmpty {
            findReplaceRules.append(.init(find: findText, replace: replaceText))
        }

        return QuickFixExecutionParameters(
            options: options,
            languages: languages,
            redactionPatterns: patterns,
            customRegexes: regexes,
            findReplace: findReplaceRules,
            manualRedactions: manualRedactions
        )
    }

    func makeAIImageOCRParameters() -> (options: QuickFixOptions, languages: [String]) {
        makeExecutionContext()
    }

    func runQuickFix(inputURL: URL,
                     outputURL: URL? = nil,
                     isTemporaryOutput: Bool? = nil,
                     manualRedactions: [Int: [CGRect]] = [:],
                     shouldCancel: QuickFixCancellationChecker? = nil,
                     progress: ((Int, Int) -> Void)? = nil) throws -> URL {
        try runQuickFixResult(inputURL: inputURL,
                              outputURL: outputURL,
                              isTemporaryOutput: isTemporaryOutput,
                              manualRedactions: manualRedactions,
                              shouldCancel: shouldCancel,
                              progress: progress).outputURL
    }

    func runQuickFixResult(inputURL: URL,
                           outputURL: URL? = nil,
                           isTemporaryOutput: Bool? = nil,
                           manualRedactions: [Int: [CGRect]] = [:],
                           shouldCancel: QuickFixCancellationChecker? = nil,
                           progress: ((Int, Int) -> Void)? = nil) throws -> QuickFixResult {
        let parameters = try makeParameters(manualRedactions: manualRedactions)
        let engine = PDFQuickFixEngine(options: parameters.options, languages: parameters.languages)
        return try engine.processResult(
            inputURL: inputURL,
            outputURL: outputURL,
            isTemporaryOutput: isTemporaryOutput,
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

    private func makeExecutionContext() -> (options: QuickFixOptions, languages: [String]) {
        let languages = preferredLanguages()
        let options = QuickFixOptions(
            doOCR: doOCR,
            dpi: CGFloat(dpi),
            redactionPadding: CGFloat(padding),
            ocrProvider: ocrProvider,
            localOCRModel: localOCRModel,
            cloudOcrEnabled: cloudOcrEnabled,
            cloudOcrApiKey: cloudOcrApiKey
        )
        return (options, languages)
    }

    private func parseCustomRegexes() throws -> [NSRegularExpression] {
        try customRegexText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { pattern in
                do {
                    return try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                } catch {
                    throw QuickFixOptionsError.invalidCustomRegex(pattern)
                }
            }
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
    @StateObject private var localOCRRegistry = LocalOCRModelRegistry()
    @State private var localOCRAvailable: Bool?
    @State private var isCheckingLocalOCR: Bool = false
    @State private var isQuickVerifying: Bool = false
    @State private var quickVerifyMessage: String?
    @State private var quickVerifySucceeded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Repair OCR / add searchable text layer", isOn: $model.doOCR)
            Picker("OCR engine", selection: $model.ocrProvider) {
                Text("Auto (Local OCR if available)").tag(OCRProviderPreference.autoLocalOCR)
                Text("Vision only").tag(OCRProviderPreference.visionOnly)
            }
            .pickerStyle(.segmented)
            .disabled(!model.doOCR)
            if model.doOCR {
                Text("Local OCR is used for OCR-only runs; redaction/replace uses Vision.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if model.doOCR, model.ocrProvider == .autoLocalOCR {
                HStack {
                    Text("Local OCR status")
                    Spacer()
                    Text(localOCRStatusText)
                        .foregroundStyle(localOCRStatusColor)
                    Button(isCheckingLocalOCR ? "Checking…" : "Refresh") {
                        refreshLocalOCRStatus()
                    }
                    .buttonStyle(.plain)
                    .disabled(isCheckingLocalOCR)
                }
                .font(.caption)
                if let error = localOCRRegistry.lastRefreshError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if localOCRRegistry.availableModels.isEmpty {
                    Text("No local OCR models detected. Install models with Ollama and refresh.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("OCR model", selection: $model.localOCRModel) {
                        Text("Use Recommended").tag("")
                        ForEach(localOCRRegistry.availableModels) { model in
                            Text(model.name).tag(model.name)
                        }
                    }
                    if let recommended = localOCRRegistry.recommendedModelName {
                        Text("Recommended: \(recommended)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Button(isQuickVerifying ? "Verifying…" : "Quick Verify") {
                            runQuickVerify()
                        }
                        .buttonStyle(.plain)
                        .disabled(isQuickVerifying)
                        if let quickVerifyMessage {
                            Text(quickVerifyMessage)
                                .font(.caption)
                                .foregroundColor(quickVerifyStatusColor)
                        }
                    }
                }
                Toggle("Cloud OCR fallback (Google Vision)", isOn: $model.cloudOcrEnabled)
                if model.cloudOcrEnabled {
                    SecureField("Google Vision API key", text: $model.cloudOcrApiKey)
                        .textFieldStyle(.roundedBorder)
                    if model.cloudOcrApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Cloud fallback is enabled but no API key is set.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
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
            refreshLocalOCRStatus()
        }
        .onChange(of: model.ocrProvider) { _ in
            refreshLocalOCRStatus()
        }
        .onChange(of: model.doOCR) { _ in
            refreshLocalOCRStatus()
        }
    }

    private var localOCRStatusText: String {
        if isCheckingLocalOCR {
            return "Checking…"
        }
        guard let localOCRAvailable else { return "Unknown" }
        return localOCRAvailable ? "Available" : "Unavailable"
    }

    private var localOCRStatusColor: Color {
        guard let localOCRAvailable else { return .secondary }
        return localOCRAvailable ? AppTheme.Colors.success : AppTheme.Colors.warning
    }

    private var quickVerifyStatusColor: Color {
        guard let quickVerifySucceeded else { return .secondary }
        return quickVerifySucceeded ? AppTheme.Colors.success : AppTheme.Colors.error
    }

    private func refreshLocalOCRStatus() {
        guard model.doOCR, model.ocrProvider == .autoLocalOCR else {
            localOCRAvailable = nil
            return
        }
        isCheckingLocalOCR = true
        Task.detached(priority: .utility) {
            await localOCRRegistry.refreshModels()
            await MainActor.run {
                localOCRAvailable = !localOCRRegistry.availableModels.isEmpty
                if model.localOCRModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let recommended = localOCRRegistry.recommendedModelName {
                    model.localOCRModel = recommended
                }
                isCheckingLocalOCR = false
            }
        }
    }

    private func runQuickVerify() {
        guard model.doOCR, model.ocrProvider == .autoLocalOCR else {
            quickVerifySucceeded = false
            quickVerifyMessage = "Enable Auto (Local OCR) to verify."
            return
        }
        guard !isQuickVerifying else { return }
        isQuickVerifying = true
        quickVerifyMessage = nil
        quickVerifySucceeded = nil

        let selectedModel = resolvedLocalOCRModelName()
        Task.detached(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    isQuickVerifying = false
                }
            }
            guard !selectedModel.isEmpty else {
                await MainActor.run {
                    quickVerifySucceeded = false
                    quickVerifyMessage = "No local OCR model selected."
                }
                return
            }
            let image = await MainActor.run {
                Self.makeQuickVerifyImage()
            }
            guard let image else {
                await MainActor.run {
                    quickVerifySucceeded = false
                    quickVerifyMessage = "Failed to build verification image."
                }
                return
            }

            let provider: LocalOCRProviding
            if selectedModel.lowercased().contains("deepseek-ocr") {
                provider = OllamaDeepSeekOCRProvider(modelName: selectedModel)
            } else {
                provider = OllamaVisionOCRProvider(modelName: selectedModel)
            }

            do {
                let runs = try provider.recognizeTextLines(cgImage: image)
                let text = Self.extractText(from: runs).lowercased()
                let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let looksCorrect = text.contains("ocr") || text.contains("test")
                await MainActor.run {
                    quickVerifySucceeded = hasText
                    if hasText {
                        quickVerifyMessage = looksCorrect
                            ? "OK (\(runs.count) lines)"
                            : "OK (text detected)"
                    } else {
                        quickVerifyMessage = "No text detected."
                    }
                }
            } catch {
                await MainActor.run {
                    quickVerifySucceeded = false
                    quickVerifyMessage = "Verify failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resolvedLocalOCRModelName() -> String {
        let trimmed = model.localOCRModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return localOCRRegistry.recommendedModelName ?? ""
    }

    private static func makeQuickVerifyImage() -> CGImage? {
        let size = CGSize(width: 960, height: 260)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
        let textRect = NSRect(x: 0, y: (size.height - 80) / 2, width: size.width, height: 80)
        "OCR TEST 1234".draw(in: textRect, withAttributes: attrs)

        image.unlockFocus()
        guard let data = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return rep.cgImage
    }

    nonisolated private static func extractText(from runs: [RecognizedRun]) -> String {
        runs.compactMap { run -> String? in
            switch run.kind {
            case .keep(let text), .replace(let text):
                return text
            case .skip:
                return nil
            }
        }
        .joined(separator: " ")
    }
}
