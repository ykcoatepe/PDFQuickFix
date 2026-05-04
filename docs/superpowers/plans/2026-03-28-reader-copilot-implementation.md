# Reader Copilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Reader-first copilot that summarizes and answers questions about the open PDF without pushing the user out of Reader, while keeping the internals reusable by QuickFix later.

**Architecture:** Introduce a shared document-intelligence core that handles text extraction, bounded retrieval, prompt assembly, citations, and AI activity logging. Keep Reader as the primary UI surface for lightweight copilot interactions and leave QuickFix as the heavier AI workspace. Generalize activity logging so Reader copilot and existing QuickFix tasks share one audit trail without forcing QuickFix UI to expose Reader-only task types.

**Tech Stack:** Swift 5.9, SwiftUI, PDFKit, XCTest, Ollama-backed local text generation, XcodeGen/xcodebuild.

---

## File Structure

### New files

- `Sources/PDFQuickFix/AIInteractionKind.swift`
  General-purpose AI activity kind metadata shared by QuickFix and Reader copilot.
- `Sources/PDFQuickFix/DocumentTextSession.swift`
  Shared PDF text extraction, page selection parsing, and selection/page scoping helpers.
- `Sources/PDFQuickFix/DocumentCopilotModels.swift`
  Request/response models, citation structs, and task-specific enums for Reader copilot.
- `Sources/PDFQuickFix/DocumentCopilotService.swift`
  Shared document-intelligence service: chunking, bounded retrieval, prompt assembly, model calls, and AI activity recording.
- `Sources/PDFQuickFix/ReaderCopilotView.swift`
  Reader-side SwiftUI panel for summary, ask, explain selection, page digest, and citations.
- `Tests/PDFQuickFixTests/DocumentTextSessionTests.swift`
  Tests for page parsing, page extraction, and selection scoping.
- `Tests/PDFQuickFixTests/DocumentCopilotServiceTests.swift`
  Tests for retrieval, citation generation, and AI activity recording.
- `Tests/PDFQuickFixTests/ReaderCopilotStateTests.swift`
  Tests for Reader controller state transitions and citation navigation.

### Modified files

- `Sources/PDFQuickFix/AIInteractionStore.swift`
  Replace `LocalAITask`-only logging with a broader activity kind payload.
- `Sources/PDFQuickFix/AIActivityView.swift`
  Render generalized activity labels and source metadata for Reader copilot entries.
- `Sources/PDFQuickFix/LocalAITaskRunner.swift`
  Record `AIInteractionKind.quickFix(task)` instead of raw `LocalAITask`.
- `Sources/PDFQuickFix/QuickFixTab.swift`
  Stop owning `PDFTextExtractor`; reuse `DocumentTextSession`.
- `Sources/PDFQuickFix/ReaderProView.swift`
  Add Reader controller copilot state, right-panel tab expansion, citation jump plumbing, and view integration.
- `Tests/PDFQuickFixTests/AIInteractionStoreTests.swift`
  Update activity model assertions to use generalized kinds.
- `Tests/PDFQuickFixTests/LocalAITaskRunnerTests.swift`
  Assert QuickFix activity kind recording still works after refactor.
- `Tests/PDFQuickFixTests/QuickFixTabTests.swift`
  Point existing text extraction expectations at the shared service if needed.
- `README.md`
  Document the new Reader copilot surface and its local-first behavior.

### Existing files worth reading before implementation

- `Sources/PDFQuickFix/ReaderProView.swift`
- `Sources/PDFQuickFix/QuickFixTab.swift`
- `Sources/PDFQuickFix/LocalAITask.swift`
- `Sources/PDFQuickFix/LocalAITaskRunner.swift`
- `Sources/PDFQuickFix/AIInteractionStore.swift`
- `Tests/PDFQuickFixTests/ReaderLogicTests.swift`
- `Tests/PDFQuickFixTests/AIInteractionStoreTests.swift`
- `Tests/PDFQuickFixTests/LocalAITaskRunnerTests.swift`

## Task 1: Generalize AI Activity Logging

**Files:**
- Create: `Sources/PDFQuickFix/AIInteractionKind.swift`
- Modify: `Sources/PDFQuickFix/AIInteractionStore.swift`
- Modify: `Sources/PDFQuickFix/AIActivityView.swift`
- Modify: `Sources/PDFQuickFix/LocalAITaskRunner.swift`
- Test: `Tests/PDFQuickFixTests/AIInteractionStoreTests.swift`
- Test: `Tests/PDFQuickFixTests/LocalAITaskRunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testExportDocumentUsesGeneralizedActivityKindFileName() throws {
    let store = AIInteractionStore(persistToDisk: false)
    let entry = AIInteractionEntry(
        id: UUID(),
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        kind: .documentQuestion,
        model: "stub-model",
        prompt: "What is the contract term?",
        response: "Page 4 says 12 months.",
        sourceName: "contract.pdf",
        inputCharacterCount: 120,
        inputWasTrimmed: false
    )

    let document = try store.exportDocument(for: [entry], format: .json)
    XCTAssertEqual(document.fileName, "ai-activity-document-question.json")
}

func testQuickFixRunnerRecordsQuickFixActivityKind() async throws {
    let generator = StubGenerator(response: "summary")
    let store = AIInteractionStore(persistToDisk: false)
    let runner = LocalAITaskRunner(interactionStore: store, client: generator)

    _ = try await runner.run(
        task: .summarize,
        text: "Test",
        parameters: LocalAITaskParameters(),
        sourceName: "source.pdf",
        modelName: "stub-model"
    )

    XCTAssertEqual(store.entries.first?.kind, .quickFix(task: .summarize))
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/AIInteractionStoreTests -only-testing:PDFQuickFixTests/LocalAITaskRunnerTests
```

Expected: FAIL because `AIInteractionEntry` does not have `kind`, export naming is still `LocalAITask`-based, and `LocalAITaskRunner` records the old model.

- [ ] **Step 3: Implement the generalized activity kind model**

```swift
enum AIInteractionKind: Codable, Hashable {
    case quickFix(task: LocalAITask)
    case documentQuestion
    case quickSummary
    case explainSelection
    case currentPageDigest
    case keySections

    var rawExportName: String {
        switch self {
        case .quickFix(let task):
            return task.rawValue
        case .documentQuestion:
            return "document-question"
        case .quickSummary:
            return "quick-summary"
        case .explainSelection:
            return "explain-selection"
        case .currentPageDigest:
            return "current-page-digest"
        case .keySections:
            return "key-sections"
        }
    }

    var displayName: String {
        switch self {
        case .quickFix(let task):
            return task.displayName
        case .documentQuestion:
            return "Ask This Document"
        case .quickSummary:
            return "Quick Summary"
        case .explainSelection:
            return "Explain Selection"
        case .currentPageDigest:
            return "Current Page Digest"
        case .keySections:
            return "Key Sections"
        }
    }
}
```

```swift
struct AIInteractionEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: AIInteractionKind
    let model: String
    let prompt: String
    let response: String
    let sourceName: String?
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
}
```

```swift
let entry = AIInteractionEntry(
    id: UUID(),
    timestamp: Date(),
    kind: .quickFix(task: task),
    model: modelName,
    prompt: prompt.text,
    response: response,
    sourceName: sourceName,
    inputCharacterCount: trimmed.originalCount,
    inputWasTrimmed: trimmed.wasTrimmed
)
```

- [ ] **Step 4: Re-run the targeted tests and verify they pass**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/AIInteractionStoreTests -only-testing:PDFQuickFixTests/LocalAITaskRunnerTests
```

Expected: PASS. JSON/Markdown export reflects generalized activity kinds, and QuickFix logging remains intact.

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFQuickFix/AIInteractionKind.swift Sources/PDFQuickFix/AIInteractionStore.swift Sources/PDFQuickFix/AIActivityView.swift Sources/PDFQuickFix/LocalAITaskRunner.swift Tests/PDFQuickFixTests/AIInteractionStoreTests.swift Tests/PDFQuickFixTests/LocalAITaskRunnerTests.swift
git commit -m "refactor: generalize ai activity kinds"
```

## Task 2: Extract Shared PDF Text Session Helpers

**Files:**
- Create: `Sources/PDFQuickFix/DocumentTextSession.swift`
- Modify: `Sources/PDFQuickFix/QuickFixTab.swift`
- Test: `Tests/PDFQuickFixTests/DocumentTextSessionTests.swift`
- Test: `Tests/PDFQuickFixTests/QuickFixTabTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testPageSelectionParsesDisjointRanges() throws {
    let selection = try DocumentTextSession.PageSelectionParser.parse("1-2, 4", pageCount: 5)
    XCTAssertEqual(selection, [0, 1, 3])
}

func testExtractTextIncludesPageHeaders() throws {
    let url = try TestPDFBuilder.makePDF([
        "First page text",
        "Second page text"
    ])

    let session = try DocumentTextSession(url: url)
    let text = try session.extractText(scope: .pages([1]))

    XCTAssertTrue(text.contains("--- Page 2 ---"))
    XCTAssertTrue(text.contains("Second page text"))
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/DocumentTextSessionTests -only-testing:PDFQuickFixTests/QuickFixTabTests
```

Expected: FAIL because `DocumentTextSession` does not exist and `QuickFixTab` still depends on the embedded `PDFTextExtractor`.

- [ ] **Step 3: Implement the shared text session and reuse it from QuickFix**

```swift
struct DocumentTextSession {
    enum Scope: Equatable {
        case wholeDocument
        case pages([Int])
        case currentPage(Int)
        case selection(pageIndex: Int, text: String)
    }

    let document: PDFDocument
    let sourceURL: URL

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else {
            throw PDFTextExtractorError.missingInput
        }
        self.document = document
        self.sourceURL = url
    }

    func extractText(scope: Scope) throws -> String {
        switch scope {
        case .wholeDocument:
            return try extract(pages: Array(0..<document.pageCount))
        case .pages(let indexes):
            return try extract(pages: indexes)
        case .currentPage(let index):
            return try extract(pages: [index])
        case .selection(_, let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
```

```swift
let session = try DocumentTextSession(url: sourceURL)
let scope: DocumentTextSession.Scope = task == .summarize
    ? .pages(try DocumentTextSession.PageSelectionParser.parse(aiPageSelection, pageCount: session.document.pageCount))
    : .wholeDocument
let text = try session.extractText(scope: scope)
```

- [ ] **Step 4: Re-run the targeted tests and verify they pass**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/DocumentTextSessionTests -only-testing:PDFQuickFixTests/QuickFixTabTests
```

Expected: PASS. Shared page parsing/extraction is covered and QuickFix compiles against the new service.

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFQuickFix/DocumentTextSession.swift Sources/PDFQuickFix/QuickFixTab.swift Tests/PDFQuickFixTests/DocumentTextSessionTests.swift Tests/PDFQuickFixTests/QuickFixTabTests.swift
git commit -m "refactor: extract shared document text session"
```

## Task 3: Build the Shared Document Copilot Service

**Files:**
- Create: `Sources/PDFQuickFix/DocumentCopilotModels.swift`
- Create: `Sources/PDFQuickFix/DocumentCopilotService.swift`
- Modify: `Sources/PDFQuickFix/AIInteractionStore.swift`
- Test: `Tests/PDFQuickFixTests/DocumentCopilotServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testAskDocumentReturnsCitationsFromMatchingPages() async throws {
    let generator = StubGenerator(response: "The renewal notice appears on page 3.")
    let store = AIInteractionStore(persistToDisk: false)
    let service = DocumentCopilotService(generator: generator, interactionStore: store)
    let url = try TestPDFBuilder.makePDF([
        "Cover page",
        "Payment terms",
        "Renewal notice: customer must notify 30 days early."
    ])

    let response = try await service.run(
        request: .ask(question: "When is the renewal notice due?"),
        session: try DocumentTextSession(url: url),
        modelName: "stub-model",
        sourceName: "contract.pdf"
    )

    XCTAssertEqual(response.citations.map(\\.pageIndex), [2])
    XCTAssertEqual(store.entries.first?.kind, .documentQuestion)
}

func testQuickSummaryBatchesLongInputInsteadOfUsingSingleTrimmedBlob() async throws {
    let generator = StubGenerator(response: "summary")
    let store = AIInteractionStore(persistToDisk: false)
    let service = DocumentCopilotService(generator: generator, interactionStore: store)
    let url = try TestPDFBuilder.makePDF(Array(repeating: String(repeating: "A", count: 2500), count: 8))

    _ = try await service.run(
        request: .quickSummary(pageRange: nil),
        session: try DocumentTextSession(url: url),
        modelName: "stub-model",
        sourceName: "large.pdf"
    )

    XCTAssertLessThanOrEqual(generator.lastPrompt.count, 12000)
    XCTAssertTrue(generator.lastPrompt.contains("--- Page"))
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/DocumentCopilotServiceTests
```

Expected: FAIL because the shared copilot service, request models, and citation types do not exist.

- [ ] **Step 3: Implement request models, bounded retrieval, and activity recording**

```swift
enum DocumentCopilotRequest: Equatable {
    case quickSummary(pageRange: String?)
    case ask(question: String)
    case explainSelection(text: String, pageIndex: Int?)
    case currentPageDigest(pageIndex: Int)
    case keySections
}

struct DocumentCopilotCitation: Codable, Hashable {
    let pageIndex: Int
    let snippet: String
}

struct DocumentCopilotResponse: Equatable {
    let kind: AIInteractionKind
    let output: String
    let citations: [DocumentCopilotCitation]
    let model: String
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
}
```

```swift
final class DocumentCopilotService {
    static let maxPromptCharacters = 12_000
    static let chunkSize = 1_500
    static let maxRetrievedChunks = 6

    func run(request: DocumentCopilotRequest,
             session: DocumentTextSession,
             modelName: String,
             sourceName: String?) async throws -> DocumentCopilotResponse {
        let scopedText = try makeScopedText(for: request, session: session)
        let retrieved = retrieveChunks(for: request, from: scopedText)
        let prompt = makePrompt(for: request, chunks: retrieved)
        let raw = try await generator.generateText(model: modelName, prompt: prompt, format: nil)
        let citations = retrieved.map { DocumentCopilotCitation(pageIndex: $0.pageIndex, snippet: $0.snippet) }

        await interactionStore.record(
            AIInteractionEntry(
                id: UUID(),
                timestamp: Date(),
                kind: request.activityKind,
                model: modelName,
                prompt: prompt,
                response: raw,
                sourceName: sourceName,
                inputCharacterCount: scopedText.characterCount,
                inputWasTrimmed: scopedText.wasTrimmed
            )
        )

        return DocumentCopilotResponse(
            kind: request.activityKind,
            output: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            citations: citations,
            model: modelName,
            inputCharacterCount: scopedText.characterCount,
            inputWasTrimmed: scopedText.wasTrimmed
        )
    }
}
```

- [ ] **Step 4: Re-run the targeted tests and verify they pass**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/DocumentCopilotServiceTests
```

Expected: PASS. Requests return normalized responses, citations point to the correct pages, and prompt assembly stays bounded.

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFQuickFix/DocumentCopilotModels.swift Sources/PDFQuickFix/DocumentCopilotService.swift Tests/PDFQuickFixTests/DocumentCopilotServiceTests.swift
git commit -m "feat: add shared document copilot service"
```

## Task 4: Add Reader Controller Copilot State and Actions

**Files:**
- Modify: `Sources/PDFQuickFix/ReaderProView.swift`
- Modify: `Sources/PDFQuickFix/DocumentCopilotModels.swift`
- Test: `Tests/PDFQuickFixTests/ReaderCopilotStateTests.swift`
- Test: `Tests/PDFQuickFixTests/ReaderLogicTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testRunQuickSummarySetsCopilotResponse() async throws {
    let controller = ReaderControllerPro()
    controller.document = try TestPDFBuilder.makeDocument(["Alpha", "Beta"])
    controller.sourceURLForTests = URL(fileURLWithPath: "/tmp/test.pdf")
    controller.copilotService = StubReaderCopilotService(
        response: .init(
            kind: .quickSummary,
            output: "Short summary",
            citations: [.init(pageIndex: 0, snippet: "Alpha")],
            model: "stub-model",
            inputCharacterCount: 10,
            inputWasTrimmed: false
        )
    )

    await controller.runCopilot(.quickSummary(pageRange: nil))

    XCTAssertEqual(controller.copilotResponse?.output, "Short summary")
    XCTAssertFalse(controller.isCopilotRunning)
}

@MainActor
func testJumpToCitationNavigatesCurrentPage() {
    let controller = ReaderControllerPro()
    let document = try! TestPDFBuilder.makeDocument(["One", "Two", "Three"])
    let pdfView = PDFView()
    pdfView.document = document
    controller.pdfView = pdfView
    controller.document = document

    controller.jumpToCitation(.init(pageIndex: 2, snippet: "Three"))

    XCTAssertEqual(controller.currentPageIndex, 2)
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/ReaderCopilotStateTests -only-testing:PDFQuickFixTests/ReaderLogicTests
```

Expected: FAIL because Reader has no copilot state, no action methods, and no citation navigation helper.

- [ ] **Step 3: Add Reader-owned copilot state and action methods**

```swift
@Published var copilotQuery: String = ""
@Published var copilotResponse: DocumentCopilotResponse?
@Published var copilotError: String?
@Published var isCopilotRunning: Bool = false
@Published var selectedRightPanelTab: RightTab = .info

var copilotService: DocumentCopilotServing = DocumentCopilotService(
    generator: OllamaClient(requestTimeout: 120),
    interactionStore: AIInteractionStore.shared
)

func runCopilot(_ request: DocumentCopilotRequest) async {
    guard let sourceURL else { return }
    isCopilotRunning = true
    copilotError = nil
    do {
        let session = try DocumentTextSession(url: sourceURL)
        let response = try await copilotService.run(
            request: request,
            session: session,
            modelName: LocalAISettings.shared.modelForReaderCopilot(),
            sourceName: sourceURL.lastPathComponent
        )
        copilotResponse = response
    } catch {
        copilotError = error.localizedDescription
    }
    isCopilotRunning = false
}

func jumpToCitation(_ citation: DocumentCopilotCitation) {
    guard let page = document?.page(at: citation.pageIndex) else { return }
    pdfView?.go(to: page)
    currentPageIndex = citation.pageIndex
}
```

- [ ] **Step 4: Re-run the targeted tests and verify they pass**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/ReaderCopilotStateTests -only-testing:PDFQuickFixTests/ReaderLogicTests
```

Expected: PASS. Reader manages copilot lifecycle without regressing page navigation behavior.

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFQuickFix/ReaderProView.swift Sources/PDFQuickFix/DocumentCopilotModels.swift Tests/PDFQuickFixTests/ReaderCopilotStateTests.swift Tests/PDFQuickFixTests/ReaderLogicTests.swift
git commit -m "feat: add reader copilot controller state"
```

## Task 5: Build the Reader Copilot UI

**Files:**
- Create: `Sources/PDFQuickFix/ReaderCopilotView.swift`
- Modify: `Sources/PDFQuickFix/ReaderProView.swift`
- Modify: `Sources/PDFQuickFix/AIActivityView.swift`
- Test: `Tests/PDFQuickFixTests/ReaderCopilotStateTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testReaderRightPanelExposesCopilotTab() {
    XCTAssertTrue(ReaderSidebarRight.RightTab.allCases.contains(.copilot))
}

@MainActor
func testExplainSelectionUsesCurrentPDFSelectionText() async throws {
    let controller = ReaderControllerPro()
    let document = try TestPDFBuilder.makeDocument(["Selected text lives here"])
    let pdfView = PDFView()
    pdfView.document = document
    controller.document = document
    controller.pdfView = pdfView
    controller.copilotService = CapturingReaderCopilotService()

    let selection = document.page(at: 0)!.selection(for: CGRect(x: 0, y: 0, width: 200, height: 200))!
    pdfView.setCurrentSelection(selection, animate: false)

    await controller.runExplainSelection()

    XCTAssertEqual((controller.copilotService as! CapturingReaderCopilotService).lastRequest, .explainSelection(text: selection.string ?? "", pageIndex: 0))
}
```

- [ ] **Step 2: Run the targeted tests and verify they fail**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/ReaderCopilotStateTests
```

Expected: FAIL because the right sidebar only supports `info/comments`, and Reader has no explain-selection helper.

- [ ] **Step 3: Implement the Reader copilot panel and right-panel integration**

```swift
struct ReaderCopilotView: View {
    @ObservedObject var controller: ReaderControllerPro

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Copilot").font(.headline)
                Spacer()
                if controller.isCopilotRunning {
                    ProgressView().controlSize(.small)
                }
            }

            Button("Quick Summary") {
                Task { await controller.runCopilot(.quickSummary(pageRange: nil)) }
            }

            Button("Current Page Digest") {
                Task { await controller.runCopilot(.currentPageDigest(pageIndex: controller.currentPageIndex)) }
            }

            Button("Explain Selection") {
                Task { await controller.runExplainSelection() }
            }
            .disabled(controller.currentSelectionText?.isEmpty ?? true)

            TextField("Ask this document", text: $controller.copilotQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    Task { await controller.runCopilot(.ask(question: controller.copilotQuery)) }
                }

            if let response = controller.copilotResponse {
                ScrollView {
                    Text(response.output)
                    ForEach(response.citations, id: \.self) { citation in
                        Button("Page \(citation.pageIndex + 1)") {
                            controller.jumpToCitation(citation)
                        }
                    }
                }
            }
        }
        .padding(12)
    }
}
```

```swift
enum RightTab: Int, CaseIterable {
    case info
    case comments
    case copilot
}
```

- [ ] **Step 4: Re-run the targeted tests and verify they pass**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/ReaderCopilotStateTests
```

Expected: PASS. Reader exposes the new tab and explain-selection wiring uses current PDF selection text.

- [ ] **Step 5: Commit**

```bash
git add Sources/PDFQuickFix/ReaderCopilotView.swift Sources/PDFQuickFix/ReaderProView.swift Sources/PDFQuickFix/AIActivityView.swift Tests/PDFQuickFixTests/ReaderCopilotStateTests.swift
git commit -m "feat: add reader copilot panel"
```

## Task 6: Documentation and Regression Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-03-28-reader-copilot-design.md` (only if implementation forced a design correction)

- [ ] **Step 1: Add the README update**

```md
**Reader tab**
- Copilot side panel for quick summary, ask-this-document, explain-selection, and page-digest flows
- Citation-based answers that jump back to source pages

**AI Tools tab**
- Heavy OCR, extraction, redaction, and longer-running AI jobs remain here
```

- [ ] **Step 2: Run focused regression tests**

Run:

```bash
xcodebuild test -scheme PDFQuickFix -only-testing:PDFQuickFixTests/AIInteractionStoreTests -only-testing:PDFQuickFixTests/DocumentTextSessionTests -only-testing:PDFQuickFixTests/DocumentCopilotServiceTests -only-testing:PDFQuickFixTests/ReaderCopilotStateTests -only-testing:PDFQuickFixTests/QuickFixTabTests -only-testing:PDFQuickFixTests/ReaderLogicTests
```

Expected: PASS. Shared AI logging, shared text extraction, copilot service, Reader state, and QuickFix integration all stay green together.

- [ ] **Step 3: Run the broader app validation**

Run:

```bash
make sanity-fast
```

Expected: PASS. No Reader/QuickFix regressions in the existing sanity suite.

- [ ] **Step 4: Manually verify the interactive Reader flow**

Run:

```bash
make run
```

Expected:

- Reader opens a normal PDF without regressions
- Right panel shows `Info`, `Comments`, and `Copilot`
- `Quick Summary` returns a response with clickable page citations
- `Explain Selection` works only when text is selected
- `Current Page Digest` tracks the active page
- `AI Activity` shows both old QuickFix tasks and new Reader copilot interactions

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: describe reader copilot workflow"
```

## Self-Review Checklist

- Spec coverage:
  - Reader right-panel copilot UI: Task 4 and Task 5
  - Shared AI core: Task 2 and Task 3
  - Chunked retrieval and citations: Task 3
  - AI activity logging: Task 1 and Task 3
  - QuickFix remains heavy workspace: Task 2 preserves QuickFix usage while moving only shared extraction logic
  - Validation and docs: Task 6
- Placeholder scan:
  - No `TODO`, `TBD`, or “implement later” placeholders remain.
  - Every task has explicit file paths, code snippets, commands, and expected outcomes.
- Type consistency:
  - `AIInteractionKind`, `DocumentTextSession`, `DocumentCopilotRequest`, `DocumentCopilotResponse`, and `DocumentCopilotCitation` are introduced once and reused consistently across later tasks.
