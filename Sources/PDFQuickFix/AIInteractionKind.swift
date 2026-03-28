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
    case unknown(family: String, value: String)

    private enum CodingKeys: String, CodingKey {
        case family
        case value
        case task
    }

    private enum Family: String, Codable {
        case quickFix
        case readerCopilot
    }

    var displayName: String {
        switch self {
        case .quickFix(let task):
            return task.displayName
        case .readerCopilot(let action):
            return action.displayName
        case .unknown(let family, let value):
            return "\(family): \(value)"
        }
    }

    var systemImage: String {
        switch self {
        case .quickFix(let task):
            return task.systemImage
        case .readerCopilot:
            return "questionmark.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    var exportSlug: String {
        switch self {
        case .quickFix(let task):
            return task.rawValue
        case .readerCopilot(let action):
            return action.rawValue
        case .unknown(let family, let value):
            return Self.makeFilenameSafeSlug("\(family)-\(value)")
        }
    }

    private static func makeFilenameSafeSlug(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let pieces = rawValue.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
        let collapsed = pieces.joined().replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            if let family = try container.decodeIfPresent(String.self, forKey: .family) {
                let value = (try? container.decode(String.self, forKey: .value)) ?? ""
                switch family {
                case Family.quickFix.rawValue:
                    if let task = LocalAITask(rawValue: value) {
                        self = .quickFix(task: task)
                    } else {
                        self = .unknown(family: family, value: value)
                    }
                case Family.readerCopilot.rawValue:
                    if let action = AIReaderCopilotAction(rawValue: value) {
                        self = .readerCopilot(action: action)
                    } else {
                        self = .unknown(family: family, value: value)
                    }
                default:
                    self = .unknown(family: family, value: value)
                }
                return
            }

            if let taskRaw = try container.decodeIfPresent(String.self, forKey: .task),
               let task = LocalAITask(rawValue: taskRaw) {
                self = .quickFix(task: task)
                return
            }
        }

        let container = try decoder.singleValueContainer()
        let slug = try container.decode(String.self)
        if let task = LocalAITask(rawValue: slug) {
            self = .quickFix(task: task)
        } else if let action = AIReaderCopilotAction(rawValue: slug) {
            self = .readerCopilot(action: action)
        } else {
            self = .unknown(family: "legacy", value: slug)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .quickFix(let task):
            try container.encode(Family.quickFix, forKey: .family)
            try container.encode(task.rawValue, forKey: .value)
        case .readerCopilot(let action):
            try container.encode(Family.readerCopilot, forKey: .family)
            try container.encode(action.rawValue, forKey: .value)
        case .unknown(let family, let value):
            try container.encode(family, forKey: .family)
            try container.encode(value, forKey: .value)
        }
    }
}
