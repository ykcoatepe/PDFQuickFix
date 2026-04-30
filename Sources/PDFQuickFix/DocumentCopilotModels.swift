import Foundation

enum DocumentCopilotScope: Equatable {
    case document
    case pageRange(String)
    case currentPage(index: Int)
    case selection(String)

    var displayLabel: String {
        switch self {
        case .document:
            "document"
        case let .pageRange(value):
            "page range \(value)"
        case let .currentPage(index):
            "current page \(index + 1)"
        case .selection:
            "selection"
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
        case let .quickSummary(scope),
             let .ask(_, scope),
             let .explainSelection(_, scope),
             let .currentPageDigest(scope),
             let .keySections(scope):
            scope
        }
    }

    var interactionKind: AIInteractionKind {
        switch self {
        case .quickSummary:
            .readerCopilot(action: .quickSummary)
        case .ask:
            .readerCopilot(action: .documentQuestion)
        case .explainSelection:
            .readerCopilot(action: .selectionExplanation)
        case .currentPageDigest:
            .readerCopilot(action: .currentPageDigest)
        case .keySections:
            .readerCopilot(action: .keySections)
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

protocol DocumentCopilotServicing {
    func respond(to request: DocumentCopilotRequest,
                 using session: DocumentTextSession,
                 sourceName: String?,
                 modelName: String?) async throws -> DocumentCopilotResponse
}
