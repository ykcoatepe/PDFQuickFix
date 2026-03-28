import Foundation

enum DocumentCopilotRequest: Equatable {
    case quickSummary
    case ask(question: String)
    case explainSelection(String)
    case currentPageDigest(pageIndex: Int)
    case keySections

    var interactionKind: AIInteractionKind {
        .readerCopilot(action: .documentQuestion)
    }
}

struct DocumentCopilotCitation: Equatable, Hashable {
    let pageIndex: Int
    let pageLabel: String
    let snippet: String
}

struct DocumentCopilotResponse: Equatable {
    let answer: String
    let citations: [DocumentCopilotCitation]
    let model: String
    let promptCharacterCount: Int
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
}
