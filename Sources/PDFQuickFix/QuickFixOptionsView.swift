import SwiftUI
import AppKit

final class QuickFixOptionsModel: ObservableObject {
    @Published var doOCR: Bool = true
    @Published var useDefaults: Bool = true
    @Published var customRegexText: String = ""
    @Published var findText: String = ""
    @Published var replaceText: String = ""
    @Published var dpi: Double = 300
    @Published var padding: Double = 2.0
    @Published var langTR: Bool = true
    @Published var langEN: Bool = true

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
            redactionPadding: CGFloat(padding)
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
                     manualRedactions: [Int: [CGRect]] = [:]) throws -> URL {
        let parameters = makeParameters(manualRedactions: manualRedactions)
        let engine = PDFQuickFixEngine(options: parameters.options, languages: parameters.languages)
        return try engine.process(
            inputURL: inputURL,
            outputURL: outputURL,
            redactionPatterns: parameters.redactionPatterns,
            customRegexes: parameters.customRegexes,
            findReplace: parameters.findReplace,
            manualRedactions: parameters.manualRedactions
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Repair OCR / add searchable text layer", isOn: $model.doOCR)
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
    }
}
