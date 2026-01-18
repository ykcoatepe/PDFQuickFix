import Foundation

struct LocalAIPrompt {
    let text: String
    let expectsJSON: Bool
}

struct LocalAITaskParameters {
    var targetLanguage: String
    var extractionFields: [String]

    init(targetLanguage: String = "English", extractionFields: [String] = []) {
        let trimmedLanguage = targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetLanguage = trimmedLanguage.isEmpty ? "English" : trimmedLanguage
        self.extractionFields = extractionFields.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum LocalAITask: String, CaseIterable, Identifiable, Codable {
    case summarize
    case translate
    case piiDetection
    case fieldExtraction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summarize: return "Summary"
        case .translate: return "Translate"
        case .piiDetection: return "PII Scan"
        case .fieldExtraction: return "Field Extraction"
        }
    }

    var systemImage: String {
        switch self {
        case .summarize: return "text.badge.checkmark"
        case .translate: return "character.book.closed"
        case .piiDetection: return "person.crop.circle.badge.exclamationmark"
        case .fieldExtraction: return "list.bullet.rectangle"
        }
    }

    var requiresTargetLanguage: Bool {
        self == .translate
    }

    var requiresFieldList: Bool {
        self == .fieldExtraction
    }

    func prompt(input: String, parameters: LocalAITaskParameters) -> LocalAIPrompt {
        switch self {
        case .summarize:
            return LocalAIPrompt(
                text: """
You are a local assistant running entirely on the user's Mac.
Summarize the document content below in 5-8 concise bullet points.
Then list key entities (people, organizations, dates) in a short list.
Output plain text only.

Document:
\(input)
""",
                expectsJSON: false
            )
        case .translate:
            return LocalAIPrompt(
                text: """
Translate the document text to \(parameters.targetLanguage).
Preserve meaning and tone. Output only the translated text.

Document:
\(input)
""",
                expectsJSON: false
            )
        case .piiDetection:
            return LocalAIPrompt(
                text: """
Analyze the text for personal or sensitive identifiers (names, emails, phone numbers, addresses, IDs).
Return JSON with keys: contains_pii (boolean), items (array).
Each item must include: type, value, context.

Text:
\(input)
""",
                expectsJSON: true
            )
        case .fieldExtraction:
            let fields = parameters.extractionFields.isEmpty ? ["summary"] : parameters.extractionFields
            let fieldList = fields.joined(separator: ", ")
            return LocalAIPrompt(
                text: """
Extract the following fields from the document text.
Return JSON with exactly these keys: \(fieldList).
Use null when a value is unknown.

Document:
\(input)
""",
                expectsJSON: true
            )
        }
    }
}
