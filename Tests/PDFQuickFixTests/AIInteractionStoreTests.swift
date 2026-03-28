import XCTest
@testable import PDFQuickFix

@MainActor
final class AIInteractionStoreTests: XCTestCase {
    func testRecordTruncatesPromptAndResponse() {
        let store = AIInteractionStore(persistToDisk: false)
        let longPrompt = String(repeating: "p", count: 5000)
        let longResponse = String(repeating: "r", count: 10000)
        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(),
            task: .summarize,
            model: "stub",
            prompt: longPrompt,
            response: longResponse,
            sourceName: nil,
            inputCharacterCount: 10,
            inputWasTrimmed: false
        )

        store.record(entry)

        guard let stored = store.entries.first else {
            XCTFail("Entry should be recorded")
            return
        }
        XCTAssertNotEqual(stored.prompt.count, longPrompt.count)
        XCTAssertNotEqual(stored.response.count, longResponse.count)
        XCTAssertTrue(stored.prompt.hasSuffix("... (truncated)"))
        XCTAssertTrue(stored.response.hasSuffix("... (truncated)"))
    }

    func testMaxEntriesIsCapped() {
        let store = AIInteractionStore(persistToDisk: false)
        for _ in 0..<250 {
            let entry = AIInteractionEntry(
                id: UUID(),
                timestamp: Date(),
                task: .summarize,
                model: "stub",
                prompt: "p",
                response: "r",
                sourceName: nil,
                inputCharacterCount: 1,
                inputWasTrimmed: false
            )
            store.record(entry)
        }
        XCTAssertEqual(store.entries.count, 200)
    }

    func testPersistenceToggleClearsSavedData() {
        let store = AIInteractionStore(persistToDisk: true)
        store.clear()
        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(),
            task: .summarize,
            model: "stub",
            prompt: "p",
            response: "r",
            sourceName: nil,
            inputCharacterCount: 1,
            inputWasTrimmed: false
        )
        store.record(entry)
        store.setPersistence(enabled: false)

        let reloaded = AIInteractionStore(persistToDisk: true)
        XCTAssertTrue(reloaded.entries.isEmpty)
    }

    func testEnablingPersistenceMergesExistingEntries() {
        let persistedStore = AIInteractionStore(persistToDisk: true)
        persistedStore.clear()
        let persistedEntry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date().addingTimeInterval(-60),
            task: .summarize,
            model: "persisted",
            prompt: "p",
            response: "r",
            sourceName: nil,
            inputCharacterCount: 1,
            inputWasTrimmed: false
        )
        persistedStore.record(persistedEntry)

        let sessionStore = AIInteractionStore(persistToDisk: false)
        let sessionEntry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(),
            task: .translate,
            model: "session",
            prompt: "p2",
            response: "r2",
            sourceName: nil,
            inputCharacterCount: 2,
            inputWasTrimmed: false
        )
        sessionStore.record(sessionEntry)
        sessionStore.setPersistence(enabled: true)

        XCTAssertEqual(sessionStore.entries.count, 2)
        XCTAssertTrue(sessionStore.entries.contains(persistedEntry))
        XCTAssertTrue(sessionStore.entries.contains(sessionEntry))
    }

    func testExportDocumentProducesJSONPayload() throws {
        let store = AIInteractionStore(persistToDisk: false)
        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            task: .summarize,
            model: "stub-model",
            prompt: "prompt",
            response: "response",
            sourceName: "source.pdf",
            inputCharacterCount: 42,
            inputWasTrimmed: true
        )

        let document = try store.exportDocument(for: [entry], format: .json)
        XCTAssertEqual(document.fileName, "ai-activity-summarize.json")

        let payloadObject = try JSONSerialization.jsonObject(with: document.data)
        let payload = try XCTUnwrap(payloadObject as? [String: Any])
        XCTAssertEqual(payload["formatVersion"] as? Int, 1)
        XCTAssertNotNil(payload["exportedAt"])
        let entries = try XCTUnwrap(payload["entries"] as? [[String: Any]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["task"] as? String, LocalAITask.summarize.rawValue)
        XCTAssertEqual(entries[0]["model"] as? String, "stub-model")
    }

    func testExportDocumentProducesMarkdownPayload() throws {
        let store = AIInteractionStore(persistToDisk: false)
        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            task: .translate,
            model: "stub-model",
            prompt: "prompt",
            response: "response",
            sourceName: nil,
            inputCharacterCount: 10,
            inputWasTrimmed: false
        )

        let document = try store.exportDocument(for: [entry], format: .markdown)
        XCTAssertEqual(document.fileName, "ai-activity-translate.md")

        let text = try XCTUnwrap(String(data: document.data, encoding: .utf8))
        XCTAssertTrue(text.contains("# AI Activity Export"))
        XCTAssertTrue(text.contains("Task: Translate"))
        XCTAssertTrue(text.contains("Model: stub-model"))
        XCTAssertTrue(text.contains("```text"))
        XCTAssertTrue(text.contains("response"))
    }
}
