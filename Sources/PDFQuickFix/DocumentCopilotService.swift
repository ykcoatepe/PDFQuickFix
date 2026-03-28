import Foundation

final class DocumentCopilotService {
    static let defaultMaxPromptCharacters = 3_500
    private static let defaultMaxChunkCharacters = 450
    private static let defaultWindowOverlap = 90
    private static let maxCitations = 3
    private static let maxRetrievedChunks = 4

    private let interactionStore: AIInteractionStore
    private let client: OllamaTextGenerating
    private let maxPromptCharacters: Int
    private let maxChunkCharacters: Int
    private let windowOverlap: Int

    init(interactionStore: AIInteractionStore,
         client: OllamaTextGenerating = OllamaClient(requestTimeout: 120),
         maxPromptCharacters: Int = DocumentCopilotService.defaultMaxPromptCharacters,
         maxChunkCharacters: Int = DocumentCopilotService.defaultMaxChunkCharacters,
         windowOverlap: Int = DocumentCopilotService.defaultWindowOverlap) {
        self.interactionStore = interactionStore
        self.client = client
        self.maxPromptCharacters = max(800, maxPromptCharacters)
        self.maxChunkCharacters = max(160, maxChunkCharacters)
        self.windowOverlap = max(20, min(windowOverlap, maxChunkCharacters / 2))
    }

    func respond(to request: DocumentCopilotRequest,
                 using session: DocumentTextSession,
                 sourceName: String?,
                 modelName: String?) async throws -> DocumentCopilotResponse {
        guard let modelName, !modelName.isEmpty else {
            throw LocalAITaskRunnerError.noAvailableModel
        }

        let preparedRequest = prepare(request)
        let scopeContent = try extractScopeContent(for: preparedRequest.request.scope, using: session)
        let retrieval = retrieveContext(for: preparedRequest, from: scopeContent)
        let prompt = assemblePrompt(for: preparedRequest, retrieval: retrieval)
        let response = try await client.generateText(model: modelName, prompt: prompt, format: nil)
        let normalizedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

        let inputWasTrimmed = preparedRequest.wasTrimmed || retrieval.contextWasTrimmed
        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(),
            kind: preparedRequest.request.interactionKind,
            model: modelName,
            prompt: prompt,
            response: normalizedResponse,
            sourceName: sourceName,
            inputCharacterCount: scopeContent.inputCharacterCount,
            inputWasTrimmed: inputWasTrimmed
        )
        await interactionStore.record(entry)

        return DocumentCopilotResponse(
            answer: normalizedResponse,
            citations: retrieval.citations,
            grounding: retrieval.grounding,
            model: modelName,
            promptCharacterCount: prompt.count,
            inputCharacterCount: scopeContent.inputCharacterCount,
            inputWasTrimmed: inputWasTrimmed,
            requestWasTrimmed: preparedRequest.wasTrimmed,
            contextWasTrimmed: retrieval.contextWasTrimmed
        )
    }

    private func prepare(_ request: DocumentCopilotRequest) -> PreparedRequest {
        let requestBudget = max(120, min(700, maxPromptCharacters / 3))

        switch request {
        case .quickSummary(let scope):
            return PreparedRequest(
                request: .quickSummary(scope: scope),
                instructions: "Provide a concise 5 bullet summary of the requested scope using only the grounded excerpts below.",
                queryTerms: [],
                wasTrimmed: false,
                requiresGroundingSearch: false
            )
        case .ask(let question, let scope):
            let trimmedQuestion = trim(question, limit: requestBudget)
            return PreparedRequest(
                request: .ask(question: trimmedQuestion.text, scope: scope),
                instructions: "Answer the question using only the grounded excerpts below.\nQuestion: \(trimmedQuestion.text)",
                queryTerms: makeQueryTerms(from: trimmedQuestion.text),
                wasTrimmed: trimmedQuestion.wasTrimmed,
                requiresGroundingSearch: true
            )
        case .explainSelection(let selection, let scope):
            let trimmedSelection = trim(selection, limit: requestBudget)
            return PreparedRequest(
                request: .explainSelection(selection: trimmedSelection.text, scope: scope),
                instructions: "Explain the selected passage using only the grounded excerpts below.\nSelected passage: \(trimmedSelection.text)",
                queryTerms: makeQueryTerms(from: trimmedSelection.text),
                wasTrimmed: trimmedSelection.wasTrimmed,
                requiresGroundingSearch: true
            )
        case .currentPageDigest(let scope):
            return PreparedRequest(
                request: .currentPageDigest(scope: scope),
                instructions: "Provide a concise digest of the current page using only the grounded excerpts below.",
                queryTerms: [],
                wasTrimmed: false,
                requiresGroundingSearch: false
            )
        case .keySections(let scope):
            return PreparedRequest(
                request: .keySections(scope: scope),
                instructions: "List the key sections or themes suggested by the grounded excerpts below.",
                queryTerms: [],
                wasTrimmed: false,
                requiresGroundingSearch: false
            )
        }
    }

    private func extractScopeContent(for scope: DocumentCopilotScope,
                                     using session: DocumentTextSession) throws -> ScopeContent {
        let extractedText: String
        let pages: [PageText]
        let citationsAllowed: Bool

        switch scope {
        case .document:
            extractedText = try session.extractText(scope: .wholeDocument)
            pages = parsePageTexts(from: extractedText)
            citationsAllowed = true
        case .pageRange(let selection):
            extractedText = try session.extractText(scope: .pageSelection(selection))
            pages = parsePageTexts(from: extractedText)
            citationsAllowed = true
        case .currentPage(let index):
            extractedText = try session.extractText(scope: .currentPage(index: index))
            pages = parsePageTexts(from: extractedText)
            citationsAllowed = true
        case .selection(let text):
            extractedText = session.extractText(selectionText: text)
            pages = []
            citationsAllowed = false
        }

        let chunks: [DocumentChunk]
        if citationsAllowed {
            chunks = pages.flatMap(makeWindows(for:))
        } else {
            chunks = extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? []
                : [DocumentChunk(pageIndex: nil, text: extractedText.trimmingCharacters(in: .whitespacesAndNewlines), windowIndex: 0)]
        }

        return ScopeContent(
            inputCharacterCount: extractedText.count,
            chunks: chunks,
            citationsAllowed: citationsAllowed
        )
    }

    private func retrieveContext(for preparedRequest: PreparedRequest,
                                 from scopeContent: ScopeContent) -> RetrievalResult {
        let prefix = promptPrefix(for: preparedRequest.instructions)
        let baseBudget = max(0, maxPromptCharacters - prefix.count)
        let groundedMissingMessage = trim(
            ungroundedContextMessage(for: preparedRequest.request.scope),
            limit: max(0, baseBudget)
        ).text

        guard !scopeContent.chunks.isEmpty else {
            return RetrievalResult(
                grounding: .ungrounded,
                selectedChunks: [],
                citations: [],
                contextText: groundedMissingMessage,
                contextWasTrimmed: false
            )
        }

        if preparedRequest.requiresGroundingSearch {
            let scoredChunks = scopeContent.chunks
                .map { chunk in (chunk: chunk, score: score(chunk: chunk, queryTerms: preparedRequest.queryTerms)) }
                .filter { $0.score > 0 }
                .sorted {
                    if $0.score == $1.score {
                        if $0.chunk.pageIndex == $1.chunk.pageIndex {
                            return $0.chunk.windowIndex < $1.chunk.windowIndex
                        }
                        return ($0.chunk.pageIndex ?? -1) < ($1.chunk.pageIndex ?? -1)
                    }
                    return $0.score > $1.score
                }

            guard !scoredChunks.isEmpty else {
                return RetrievalResult(
                    grounding: .ungrounded,
                    selectedChunks: [],
                    citations: [],
                    contextText: groundedMissingMessage,
                    contextWasTrimmed: false
                )
            }

            let selection = fitChunks(scoredChunks.map(\.chunk), budget: baseBudget)
            return RetrievalResult(
                grounding: .grounded,
                selectedChunks: selection.chunks,
                citations: makeCitations(from: selection.chunks, allowCitations: scopeContent.citationsAllowed),
                contextText: selection.contextText,
                contextWasTrimmed: selection.wasTrimmed
            )
        }

        let selection = fitChunks(interleavedChunks(scopeContent.chunks), budget: baseBudget)
        return RetrievalResult(
            grounding: selection.chunks.isEmpty ? .ungrounded : .grounded,
            selectedChunks: selection.chunks,
            citations: makeCitations(from: selection.chunks, allowCitations: scopeContent.citationsAllowed),
            contextText: selection.chunks.isEmpty ? groundedMissingMessage : selection.contextText,
            contextWasTrimmed: selection.wasTrimmed
        )
    }

    private func fitChunks(_ candidateChunks: [DocumentChunk], budget: Int) -> ChunkSelection {
        var remainingBudget = budget
        var selected: [DocumentChunk] = []
        var wasTrimmed = false

        for chunk in candidateChunks {
            if selected.count >= Self.maxRetrievedChunks {
                wasTrimmed = true
                break
            }

            let formattedLength = chunk.formatted.count
            if formattedLength > remainingBudget {
                wasTrimmed = true
                continue
            }

            selected.append(chunk)
            remainingBudget -= formattedLength
            if remainingBudget > 2 {
                remainingBudget -= 2
            }
        }

        if selected.count < candidateChunks.count {
            wasTrimmed = true
        }

        let contextText = selected.map(\.formatted).joined(separator: "\n\n")
        return ChunkSelection(chunks: selected, contextText: contextText, wasTrimmed: wasTrimmed)
    }

    private func assemblePrompt(for preparedRequest: PreparedRequest,
                                retrieval: RetrievalResult) -> String {
        """
You are PDFQuickFix's document copilot.
\(preparedRequest.instructions)

Context:
\(retrieval.contextText)
"""
    }

    private func promptPrefix(for instructions: String) -> String {
        """
You are PDFQuickFix's document copilot.
\(instructions)

Context:
"""
    }

    private func ungroundedContextMessage(for scope: DocumentCopilotScope) -> String {
        "No relevant grounded excerpts were found within the \(scope.displayLabel). Say that the requested scope does not support a cited answer."
    }

    private func makeCitations(from chunks: [DocumentChunk],
                               allowCitations: Bool) -> [DocumentCopilotCitation] {
        guard allowCitations else { return [] }
        return Array(chunks.prefix(Self.maxCitations)).compactMap { chunk in
            guard let pageIndex = chunk.pageIndex else { return nil }
            return DocumentCopilotCitation(
                pageIndex: pageIndex,
                pageLabel: "Page \(pageIndex + 1)",
                snippet: chunk.snippet
            )
        }
    }

    private func parsePageTexts(from extractedText: String) -> [PageText] {
        var pages: [PageText] = []
        var currentPageIndex: Int?
        var currentLines: [String] = []

        func flushCurrentPage() {
            guard let currentPageIndex else { return }
            let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                currentLines = []
                return
            }
            pages.append(PageText(pageIndex: currentPageIndex, text: text))
            currentLines = []
        }

        for line in extractedText.components(separatedBy: .newlines) {
            if let pageIndex = parsePageMarker(line) {
                flushCurrentPage()
                currentPageIndex = pageIndex
            } else if currentPageIndex != nil {
                currentLines.append(line)
            }
        }

        flushCurrentPage()
        return pages
    }

    private func makeWindows(for page: PageText) -> [DocumentChunk] {
        let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        guard text.count > maxChunkCharacters else {
            return [DocumentChunk(pageIndex: page.pageIndex, text: text, windowIndex: 0)]
        }

        var windows: [DocumentChunk] = []
        let step = max(1, maxChunkCharacters - windowOverlap)
        var startOffset = 0
        var windowIndex = 0

        while startOffset < text.count {
            let endOffset = min(text.count, startOffset + maxChunkCharacters)
            let startIndex = text.index(text.startIndex, offsetBy: startOffset)
            let endIndex = text.index(text.startIndex, offsetBy: endOffset)
            let windowText = String(text[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !windowText.isEmpty {
                windows.append(DocumentChunk(pageIndex: page.pageIndex, text: windowText, windowIndex: windowIndex))
            }
            if endOffset >= text.count {
                break
            }
            startOffset += step
            windowIndex += 1
        }

        return windows
    }

    private func interleavedChunks(_ chunks: [DocumentChunk]) -> [DocumentChunk] {
        let grouped = Dictionary(grouping: chunks) { chunk in
            chunk.pageIndex ?? -1
        }
        let orderedKeys = grouped.keys.sorted()
        var result: [DocumentChunk] = []
        var nextWindowIndex = 0

        while true {
            var appended = false
            for key in orderedKeys {
                guard let pageChunks = grouped[key], nextWindowIndex < pageChunks.count else { continue }
                result.append(pageChunks[nextWindowIndex])
                appended = true
            }
            guard appended else { break }
            nextWindowIndex += 1
        }

        return result
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

    private func makeQueryTerms(from rawText: String) -> [String] {
        let stopWords: Set<String> = [
            "a", "about", "an", "and", "are", "discuss", "does", "document", "every",
            "explain", "for", "from", "how", "in", "is", "of", "on", "say", "the",
            "this", "to", "what", "where", "which", "with"
        ]

        return rawText
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private func score(chunk: DocumentChunk, queryTerms: [String]) -> Int {
        let haystack = chunk.text.lowercased()
        return queryTerms.reduce(0) { partial, term in
            partial + occurrenceCount(of: term, in: haystack) * max(1, term.count)
        }
    }

    private func occurrenceCount(of term: String, in haystack: String) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchRange: Range<String.Index>? = haystack.startIndex..<haystack.endIndex

        while let range = haystack.range(of: term, options: [], range: searchRange) {
            count += 1
            searchRange = range.upperBound..<haystack.endIndex
        }

        return count
    }

    private func trim(_ text: String, limit: Int) -> (text: String, wasTrimmed: Bool) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return (normalized, false) }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return (String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines), true)
    }
}

extension DocumentCopilotService: DocumentCopilotServicing {}

private struct PreparedRequest {
    let request: DocumentCopilotRequest
    let instructions: String
    let queryTerms: [String]
    let wasTrimmed: Bool
    let requiresGroundingSearch: Bool
}

private struct ScopeContent {
    let inputCharacterCount: Int
    let chunks: [DocumentChunk]
    let citationsAllowed: Bool
}

private struct RetrievalResult {
    let grounding: DocumentCopilotGrounding
    let selectedChunks: [DocumentChunk]
    let citations: [DocumentCopilotCitation]
    let contextText: String
    let contextWasTrimmed: Bool
}

private struct ChunkSelection {
    let chunks: [DocumentChunk]
    let contextText: String
    let wasTrimmed: Bool
}

private struct PageText {
    let pageIndex: Int
    let text: String
}

private struct DocumentChunk: Equatable {
    let pageIndex: Int?
    let text: String
    let windowIndex: Int

    var marker: String {
        if let pageIndex {
            return "--- Page \(pageIndex + 1) ---"
        }
        return "--- Selection ---"
    }

    var formatted: String {
        "\(marker)\n\(text)"
    }

    var snippet: String {
        let collapsed = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard collapsed.count > 160 else { return collapsed }
        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 160)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
