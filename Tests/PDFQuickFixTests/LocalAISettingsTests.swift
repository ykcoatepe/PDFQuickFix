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
        XCTAssertEqual(settings.lastRefreshError, "Ollama not reachable on 127.0.0.1:11434.")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testProviderSwitchUsesProviderSpecificSelections() async throws {
        let suiteName = "LocalAISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("ollama-model", forKey: "LocalAI.defaultModel.ollama")
        defaults.set("lmstudio-model", forKey: "LocalAI.defaultModel.lmStudio")
        defaults.set("ollama-translate", forKey: "LocalAI.override.ollama.translate")
        defaults.set("lmstudio-translate", forKey: "LocalAI.override.lmStudio.translate")

        let settings = LocalAISettings(defaults: defaults)

        XCTAssertEqual(settings.selectedProvider, .ollama)
        XCTAssertEqual(settings.defaultModel, "ollama-model")
        XCTAssertEqual(settings.override(for: .translate), "ollama-translate")

        settings.selectedProvider = .lmStudio

        XCTAssertEqual(settings.defaultModel, "lmstudio-model")
        XCTAssertEqual(settings.override(for: .translate), "lmstudio-translate")

        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    func testLMStudioRefreshFailureIsProviderSpecific() async throws {
        let suiteName = "LocalAISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let lmStudioClient = try LMStudioClient(hostURL: XCTUnwrap(URL(string: "http://example.com")))
        let settings = LocalAISettings(lmStudioClient: lmStudioClient, defaults: defaults)
        settings.selectedProvider = .lmStudio

        await settings.refreshModels()

        XCTAssertEqual(settings.lastRefreshError, "LM Studio not reachable on 127.0.0.1:1234.")

        defaults.removePersistentDomain(forName: suiteName)
    }
}
