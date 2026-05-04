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
    case redactionCandidates
    case fieldExtraction
    case shareReadinessReview

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .summarize: "Summary"
        case .translate: "Translate"
        case .piiDetection: "PII Scan"
        case .redactionCandidates: "Redaction Candidates"
        case .fieldExtraction: "Field Extraction"
        case .shareReadinessReview: "Share Review"
        }
    }

    var systemImage: String {
        switch self {
        case .summarize: "text.badge.checkmark"
        case .translate: "character.book.closed"
        case .piiDetection: "person.crop.circle.badge.exclamationmark"
        case .redactionCandidates: "highlighter"
        case .fieldExtraction: "list.bullet.rectangle"
        case .shareReadinessReview: "checkmark.shield"
        }
    }

    var requiresTargetLanguage: Bool {
        self == .translate
    }

    var requiresFieldList: Bool {
        self == .fieldExtraction
    }

    var supportsPageSelection: Bool {
        switch self {
        case .summarize, .redactionCandidates, .shareReadinessReview:
            true
        case .translate, .piiDetection, .fieldExtraction:
            false
        }
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
        case .redactionCandidates:
            return LocalAIPrompt(
                text: """
                You are a local PDF redaction assistant running entirely on the user's Mac.
                Review only the provided document text and propose redaction candidates for a human editor.
                Do not claim that text has been redacted. Do not say the PDF is safe to share.
                Return JSON with exactly these keys:
                candidates: array of objects with type, value, reason, confidence, context
                page_hints: array of short strings
                must_review_manually: array of short strings

                Document:
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
        case .shareReadinessReview:
            return LocalAIPrompt(
                text: """
                You are a local PDF sharing review assistant running entirely on the user's Mac.
                Review the document text below for outbound-sharing risk. Use only the provided text.
                Do not claim that the file is safe. Do not override PDFQuickFix's deterministic health status.
                Return JSON with exactly these keys:
                readiness_hint: one of "ready", "review", "blocked"
                reasons: array of short strings
                suggested_checks: array of short strings
                possible_sensitive_items: array of short strings

                Document:
                \(input)
                """,
                expectsJSON: true
            )
        }
    }
}
