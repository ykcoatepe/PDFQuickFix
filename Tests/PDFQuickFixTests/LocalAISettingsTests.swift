@testable import PDFQuickFix
import XCTest

final class LocalAISettingsTests: XCTestCase {
    @MainActor
    func testRefreshFailurePreservesSelections() async throws {
        let suiteName = "LocalAISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let client = try OllamaClient(hostURL: XCTUnwrap(URL(string: "http://example.com")))
        let settings = LocalAISettings(client: client, defaults: defaults)
        settings.defaultModel = "gpt-oss:20b"
        settings.setOverride(task: .summarize, model: "deepseek-r1:8b")

        await settings.refreshModels()

        XCTAssertEqual(settings.defaultModel, "gpt-oss:20b")
        XCTAssertEqual(settings.override(for: .summarize), "deepseek-r1:8b")
        XCTAssertNotNil(settings.lastRefreshError)

        defaults.removePersistentDomain(forName: suiteName)
    }
}
