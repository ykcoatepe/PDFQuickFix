import Foundation

enum LocalAITaskRunnerError: LocalizedError {
    case noAvailableModel

    var errorDescription: String? {
        switch self {
        case .noAvailableModel:
            return "No local Ollama model is available."
        }
    }
}

struct LocalAITaskResult {
    let output: String
    let model: String
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
}

final class LocalAITaskRunner {
    static let maxInputCharacters = 12000

    private let client: OllamaTextGenerating
    private let interactionStore: AIInteractionStore

    init(interactionStore: AIInteractionStore, client: OllamaTextGenerating = OllamaClient(requestTimeout: 120)) {
        self.interactionStore = interactionStore
        self.client = client
    }

    func run(task: LocalAITask,
             text: String,
             parameters: LocalAITaskParameters,
             sourceName: String?,
             modelName: String?) async throws -> LocalAITaskResult {
        guard let modelName, !modelName.isEmpty else {
            throw LocalAITaskRunnerError.noAvailableModel
        }

        let trimmed = trimInput(text)
        let prompt = task.prompt(input: trimmed.text, parameters: parameters)
        let response = try await client.generateText(
            model: modelName,
            prompt: prompt.text,
            format: prompt.expectsJSON ? "json" : nil
        )
        let output = normalize(response: response, expectsJSON: prompt.expectsJSON)

        let entry = AIInteractionEntry(
            id: UUID(),
            timestamp: Date(),
            task: task,
            model: modelName,
            prompt: prompt.text,
            response: response,
            sourceName: sourceName,
            inputCharacterCount: trimmed.originalCount,
            inputWasTrimmed: trimmed.wasTrimmed
        )
        await interactionStore.record(entry)

        return LocalAITaskResult(
            output: output,
            model: modelName,
            inputCharacterCount: trimmed.originalCount,
            inputWasTrimmed: trimmed.wasTrimmed
        )
    }

    private func normalize(response: String, expectsJSON: Bool) -> String {
        guard expectsJSON else { return response.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let data = response.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: pretty, encoding: .utf8) {
            return prettyString
        }
        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimInput(_ text: String) -> (text: String, originalCount: Int, wasTrimmed: Bool) {
        let originalCount = text.count
        if originalCount <= Self.maxInputCharacters {
            return (text, originalCount, false)
        }
        let index = text.index(text.startIndex, offsetBy: Self.maxInputCharacters)
        return (String(text[..<index]), originalCount, true)
    }
}
