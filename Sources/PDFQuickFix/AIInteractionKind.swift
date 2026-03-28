import Foundation

enum AIReaderCopilotAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case documentQuestion = "document-question"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .documentQuestion:
            return "Document Question"
        }
    }
}

enum AIInteractionKind: Codable, Hashable {
    case quickFix(task: LocalAITask)
    case readerCopilot(action: AIReaderCopilotAction)

    var displayName: String {
        switch self {
        case .quickFix(let task):
            return task.displayName
        case .readerCopilot(let action):
            return action.displayName
        }
    }

    var systemImage: String {
        switch self {
        case .quickFix(let task):
            return task.systemImage
        case .readerCopilot:
            return "questionmark.circle"
        }
    }

    var exportSlug: String {
        switch self {
        case .quickFix(let task):
            return task.rawValue
        case .readerCopilot(let action):
            return action.rawValue
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let slug = try container.decode(String.self)
        if let task = LocalAITask(rawValue: slug) {
            self = .quickFix(task: task)
            return
        }
        if let action = AIReaderCopilotAction(rawValue: slug) {
            self = .readerCopilot(action: action)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown AI interaction kind: \(slug)")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(exportSlug)
    }
}
