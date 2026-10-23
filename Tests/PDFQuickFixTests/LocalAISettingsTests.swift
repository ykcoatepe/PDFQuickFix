@testable import PDFQuickFix
import XCTest

final class LocalAISettingsTests: XCTestCase {
    @MainActor
    func testStaleRefreshCannotReplaceNewProviderSelectionsOrLoadingState() async throws {
        let suite = "LocalAISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldProvider = DeferredModelListing()
        let newProvider = DeferredModelListing()
        let settings = LocalAISettings(client: oldProvider, lmStudioClient: newProvider, defaults: defaults)
        let oldRefresh = Task { await settings.refreshModels() }
        while oldProvider.continuation == nil { await Task.yield() }
        settings.selectedProvider = .lmStudio
        settings.defaultModel = "lm-model"
        settings.setOverride(task: .summarize, model: "lm-model")
        let newRefresh = Task { await settings.refreshModels() }
        while newProvider.continuation == nil { await Task.yield() }
        oldProvider.continuation?.resume(returning: [OllamaModelInfo(id: "ollama-model", name: "ollama-model")])
        await oldRefresh.value
        XCTAssertTrue(settings.isRefreshing, "Old completion must not finish the new refresh")
        XCTAssertTrue(settings.availableModels.isEmpty)
        XCTAssertEqual(settings.defaultModel, "lm-model")
        XCTAssertEqual(settings.override(for: .summarize), "lm-model")
        XCTAssertEqual(defaults.string(forKey: "LocalAI.defaultModel.lmStudio"), "lm-model")
        newProvider.continuation?.resume(returning: [OllamaModelInfo(id: "lm-model", name: "lm-model")])
        await newRefresh.value
        XCTAssertEqual(settings.availableModels.map(\.name), ["lm-model"])
        XCTAssertFalse(settings.isRefreshing)
    }

    @MainActor
    func testStaleRefreshErrorIsNotAttributedToReplacementProvider() async throws {
        let suite = "LocalAISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldProvider = DeferredModelListing()
        let settings = LocalAISettings(client: oldProvider, defaults: defaults)
        let refresh = Task { await settings.refreshModels() }
        while oldProvider.continuation == nil { await Task.yield() }
        settings.selectedProvider = .lmStudio
        oldProvider.continuation?.resume(throwing: URLError(.timedOut))
        await refresh.value
        XCTAssertNil(settings.lastRefreshError)
        XCTAssertFalse(settings.isRefreshing)
    }

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
    func testProviderSwitchPreservesLegacyOllamaDefaultModel() async throws {
        let suiteName = "LocalAISettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("legacy-ollama-model", forKey: LocalAISettings.defaultModelKey)

        let settings = LocalAISettings(defaults: defaults)

        XCTAssertEqual(settings.defaultModel, "legacy-ollama-model")

        settings.selectedProvider = .lmStudio
        settings.selectedProvider = .ollama

        XCTAssertEqual(settings.defaultModel, "legacy-ollama-model")

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

private final class DeferredModelListing: LocalAIModelListing {
    var continuation: CheckedContinuation<[OllamaModelInfo], Error>?
    func listModels() async throws -> [OllamaModelInfo] {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
