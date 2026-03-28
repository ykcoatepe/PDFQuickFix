import Foundation

enum DocumentCopilotScope: Equatable {
    case document
    case pageRange(String)
    case currentPage(index: Int)
    case selection(String)

    var displayLabel: String {
        switch self {
        case .document:
            return "document"
        case .pageRange(let value):
            return "page range \(value)"
        case .currentPage(let index):
            return "current page \(index + 1)"
        case .selection:
            return "selection"
        }
    }
}

enum DocumentCopilotRequest: Equatable {
    case quickSummary(scope: DocumentCopilotScope)
    case ask(question: String, scope: DocumentCopilotScope)
    case explainSelection(selection: String, scope: DocumentCopilotScope)
    case currentPageDigest(scope: DocumentCopilotScope)
    case keySections(scope: DocumentCopilotScope)

    var scope: DocumentCopilotScope {
        switch self {
        case .quickSummary(let scope),
             .ask(_, let scope),
             .explainSelection(_, let scope),
             .currentPageDigest(let scope),
             .keySections(let scope):
            return scope
        }
    }

    var interactionKind: AIInteractionKind {
        switch self {
        case .quickSummary:
            return .readerCopilot(action: .quickSummary)
        case .ask:
            return .readerCopilot(action: .documentQuestion)
        case .explainSelection:
            return .readerCopilot(action: .selectionExplanation)
        case .currentPageDigest:
            return .readerCopilot(action: .currentPageDigest)
        case .keySections:
            return .readerCopilot(action: .keySections)
        }
    }
}

enum DocumentCopilotGrounding: Equatable {
    case grounded
    case ungrounded
}

struct DocumentCopilotCitation: Equatable, Hashable {
    let pageIndex: Int
    let pageLabel: String
    let snippet: String
}

struct DocumentCopilotResponse: Equatable {
    let answer: String
    let citations: [DocumentCopilotCitation]
    let grounding: DocumentCopilotGrounding
    let model: String
    let promptCharacterCount: Int
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
    let requestWasTrimmed: Bool
    let contextWasTrimmed: Bool
}
