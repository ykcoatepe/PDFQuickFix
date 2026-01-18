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
}
