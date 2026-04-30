import Foundation

enum AIReaderCopilotAction: String, Codable, CaseIterable, Identifiable, Hashable {
    case quickSummary = "quick-summary"
    case documentQuestion = "document-question"
    case selectionExplanation = "selection-explanation"
    case currentPageDigest = "current-page-digest"
    case keySections = "key-sections"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .quickSummary:
            "Quick Summary"
        case .documentQuestion:
            "Document Question"
        case .selectionExplanation:
            "Selection Explanation"
        case .currentPageDigest:
            "Current Page Digest"
        case .keySections:
            "Key Sections"
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
        case let .quickFix(task):
            task.displayName
        case let .readerCopilot(action):
            action.displayName
        case let .unknown(family, value):
            "\(family): \(value)"
        }
    }

    var systemImage: String {
        switch self {
        case let .quickFix(task):
            task.systemImage
        case .readerCopilot:
            "questionmark.circle"
        case .unknown:
            "questionmark.circle"
        }
    }

    var exportSlug: String {
        switch self {
        case let .quickFix(task):
            task.rawValue
        case let .readerCopilot(action):
            action.rawValue
        case let .unknown(family, value):
            Self.makeFilenameSafeSlug("\(family)-\(value)")
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
               let task = LocalAITask(rawValue: taskRaw)
            {
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
        case let .quickFix(task):
            try container.encode(Family.quickFix, forKey: .family)
            try container.encode(task.rawValue, forKey: .value)
        case let .readerCopilot(action):
            try container.encode(Family.readerCopilot, forKey: .family)
            try container.encode(action.rawValue, forKey: .value)
        case let .unknown(family, value):
            try container.encode(family, forKey: .family)
            try container.encode(value, forKey: .value)
        }
    }
}
