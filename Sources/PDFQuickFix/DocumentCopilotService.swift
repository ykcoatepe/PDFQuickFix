import Foundation

final class DocumentCopilotService {
    static let defaultMaxPromptCharacters = 3_500
    private static let defaultMaxChunkCharacters = 450
    private static let maxCitations = 3
    private static let maxRetrievedChunks = 4

    private let interactionStore: AIInteractionStore
    private let client: OllamaTextGenerating
    private let maxPromptCharacters: Int
    private let maxChunkCharacters: Int

    init(interactionStore: AIInteractionStore,
         client: OllamaTextGenerating = OllamaClient(requestTimeout: 120),
         maxPromptCharacters: Int = DocumentCopilotService.defaultMaxPromptCharacters,
         maxChunkCharacters: Int = DocumentCopilotService.defaultMaxChunkCharacters) {
        self.interactionStore = interactionStore
        self.client = client
        self.maxPromptCharacters = max(800, maxPromptCharacters)
        self.maxChunkCharacters = max(200, maxChunkCharacters)
    }

    func respond(to request: DocumentCopilotRequest,
                 using session: DocumentTextSession,
                 sourceName: String?,
                 modelName: String?) async throws -> DocumentCopilotResponse {
        guard let modelName, !modelName.isEmpty else {
            throw LocalAITaskRunnerError.noAvailableModel
        }

        let retrieval = try retrieveContext(for: request, using: session)
        let prompt = assemblePrompt(for: request, context: retrieval.selectedChunks)
        let response = try await client.generateText(model: modelName, prompt: prompt, format: nil)
        let normalizedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let citations = makeCitations(from: retrieval.selectedChunks)

        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(),
            kind: request.interactionKind,
            model: modelName,
            prompt: prompt,
            response: normalizedResponse,
            sourceName: sourceName,
            inputCharacterCount: retrieval.inputCharacterCount,
            inputWasTrimmed: retrieval.inputWasTrimmed
        )
        await interactionStore.record(entry)

        return DocumentCopilotResponse(
            answer: normalizedResponse,
            citations: citations,
            model: modelName,
            promptCharacterCount: prompt.count,
            inputCharacterCount: retrieval.inputCharacterCount,
            inputWasTrimmed: retrieval.inputWasTrimmed
        )
    }

    private func retrieveContext(for request: DocumentCopilotRequest,
                                 using session: DocumentTextSession) throws -> RetrievalResult {
        let extractedText: String
        switch request {
        case .currentPageDigest(let pageIndex):
            extractedText = try session.extractText(scope: .currentPage(index: pageIndex))
        case .quickSummary, .ask, .explainSelection, .keySections:
            extractedText = try session.extractText(scope: .wholeDocument)
        }

        let allChunks = parseChunks(from: extractedText)
        let selectedChunks = selectChunks(for: request, from: allChunks)
        return RetrievalResult(
            inputCharacterCount: extractedText.count,
            inputWasTrimmed: selectedChunks.wasTrimmed,
            selectedChunks: selectedChunks.chunks
        )
    }

    private func selectChunks(for request: DocumentCopilotRequest,
                              from allChunks: [DocumentChunk]) -> ChunkSelection {
        guard !allChunks.isEmpty else {
            return ChunkSelection(chunks: [], wasTrimmed: false)
        }

        let queryTerms = makeQueryTerms(for: request)
        let ranked: [DocumentChunk]
        if queryTerms.isEmpty {
            ranked = allChunks
        } else {
            let scored = allChunks
                .map { chunk in (chunk: chunk, score: score(chunk: chunk, queryTerms: queryTerms)) }
                .filter { $0.score > 0 }
                .sorted {
                    if $0.score == $1.score {
                        return $0.chunk.pageIndex < $1.chunk.pageIndex
                    }
                    return $0.score > $1.score
                }
                .map(\.chunk)
            ranked = scored.isEmpty ? Array(allChunks.prefix(Self.maxRetrievedChunks)) : scored
        }

        var remainingBudget = contextBudget(for: request)
        var chunks: [DocumentChunk] = []
        var usedTrimming = false

        for chunk in ranked {
            if chunks.count >= Self.maxRetrievedChunks || remainingBudget <= 0 {
                usedTrimming = true
                break
            }

            let (boundedChunk, wasTrimmed) = chunk.trimmingText(toFit: min(maxChunkCharacters, remainingBudget))
            guard !boundedChunk.text.isEmpty else {
                usedTrimming = true
                continue
            }

            let formattedLength = boundedChunk.formatted.count + 2
            if formattedLength > remainingBudget {
                usedTrimming = true
                continue
            }

            chunks.append(boundedChunk)
            remainingBudget -= formattedLength
            usedTrimming = usedTrimming || wasTrimmed
        }

        if chunks.count < ranked.count {
            usedTrimming = true
        }

        return ChunkSelection(chunks: chunks, wasTrimmed: usedTrimming)
    }

    private func assemblePrompt(for request: DocumentCopilotRequest,
                                context: [DocumentChunk]) -> String {
        let instructions: String
        switch request {
        case .quickSummary:
            instructions = "Provide a concise 5 bullet summary of the document based only on the excerpts below."
        case .ask(let question):
            instructions = "Answer the question using only the excerpts below.\nQuestion: \(question)"
        case .explainSelection(let selection):
            instructions = "Explain the selected passage in the context of the document excerpts below.\nSelected passage: \(selection)"
        case .currentPageDigest:
            instructions = "Provide a concise digest of the current page using the excerpt below."
        case .keySections:
            instructions = "List the key sections or themes suggested by the excerpts below."
        }

        let contextText: String
        if context.isEmpty {
            contextText = "No matching page excerpts were available."
        } else {
            contextText = context.map(\.formatted).joined(separator: "\n\n")
        }

        let prompt = """
You are PDFQuickFix's document copilot.
\(instructions)

Context:
\(contextText)
"""
        if prompt.count <= maxPromptCharacters {
            return prompt
        }
        let endIndex = prompt.index(prompt.startIndex, offsetBy: maxPromptCharacters)
        return String(prompt[..<endIndex])
    }

    private func contextBudget(for request: DocumentCopilotRequest) -> Int {
        let reserved = switch request {
        case .quickSummary:
            220
        case .ask(let question):
            240 + question.count
        case .explainSelection(let selection):
            260 + selection.count
        case .currentPageDigest:
            220
        case .keySections:
            220
        }
        return max(0, maxPromptCharacters - reserved)
    }

    private func makeCitations(from chunks: [DocumentChunk]) -> [DocumentCopilotCitation] {
        Array(chunks.prefix(Self.maxCitations)).map { chunk in
            DocumentCopilotCitation(
                pageIndex: chunk.pageIndex,
                pageLabel: "Page \(chunk.pageIndex + 1)",
                snippet: chunk.snippet
            )
        }
    }

    private func parseChunks(from extractedText: String) -> [DocumentChunk] {
        var chunks: [DocumentChunk] = []
        var currentPageIndex: Int?
        var currentLines: [String] = []

        func flushCurrentChunk() {
            guard let currentPageIndex else { return }
            let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                currentLines = []
                return
            }
            chunks.append(DocumentChunk(pageIndex: currentPageIndex, text: text))
            currentLines = []
        }

        for line in extractedText.components(separatedBy: .newlines) {
            if let pageIndex = parsePageMarker(line) {
                flushCurrentChunk()
                currentPageIndex = pageIndex
                continue
            }
            guard currentPageIndex != nil else { continue }
            currentLines.append(line)
        }
        flushCurrentChunk()
        return chunks
    }

    private func parsePageMarker(_ line: String) -> Int? {
        guard line.hasPrefix("--- Page "), line.hasSuffix(" ---") else { return nil }
        let pageNumberText = line
            .replacingOccurrences(of: "--- Page ", with: "")
            .replacingOccurrences(of: " ---", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pageNumber = Int(pageNumberText), pageNumber > 0 else { return nil }
        return pageNumber - 1
    }

    private func makeQueryTerms(for request: DocumentCopilotRequest) -> [String] {
        let rawText: String
        switch request {
        case .quickSummary, .currentPageDigest, .keySections:
            return []
        case .ask(let question):
            rawText = question
        case .explainSelection(let selection):
            rawText = selection
        }

        let stopWords: Set<String> = [
            "a", "about", "an", "and", "are", "does", "document", "explain",
            "for", "from", "how", "in", "is", "of", "on", "say", "the", "this",
            "to", "what", "where", "which", "with"
        ]

        return rawText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private func score(chunk: DocumentChunk, queryTerms: [String]) -> Int {
        let haystack = chunk.text.lowercased()
        return queryTerms.reduce(0) { partial, term in
            partial + (haystack.contains(term) ? 1 : 0)
        }
    }
}

private struct RetrievalResult {
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
    let selectedChunks: [DocumentChunk]
}

private struct ChunkSelection {
    let chunks: [DocumentChunk]
    let wasTrimmed: Bool
}

private struct DocumentChunk: Equatable {
    let pageIndex: Int
    let text: String

    var marker: String {
        "--- Page \(pageIndex + 1) ---"
    }

    var formatted: String {
        "\(marker)\n\(text)"
    }

    var snippet: String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if collapsed.count <= 160 {
            return collapsed
        }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 160)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    func trimmingText(toFit budget: Int) -> (DocumentChunk, Bool) {
        guard budget > marker.count else {
            return (DocumentChunk(pageIndex: pageIndex, text: ""), true)
        }

        let availableTextBudget = max(0, budget - marker.count - 1)
        guard text.count > availableTextBudget else {
            return (self, false)
        }
        let endIndex = text.index(text.startIndex, offsetBy: availableTextBudget)
        let trimmedText = text[..<endIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        return (DocumentChunk(pageIndex: pageIndex, text: trimmedText), true)
    }
}
