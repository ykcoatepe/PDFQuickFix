import XCTest
@testable import PDFQuickFix

@MainActor
final class LocalAITaskRunnerTests: XCTestCase {
    final class StubGenerator: OllamaTextGenerating {
        var response: String
        var lastFormat: String?

        init(response: String) {
            self.response = response
        }

        func generateText(model: String, prompt: String, format: String?) async throws -> String {
            lastFormat = format
            return response
        }
    }

    func testPrettyPrintsValidJSONResponse() async throws {
        let response = "{\"contains_pii\":true,\"items\":[{\"type\":\"email\",\"value\":\"a@b.com\",\"context\":\"header\"}]}"
        let generator = StubGenerator(response: response)
        let store = AIInteractionStore(persistToDisk: false)
        let runner = LocalAITaskRunner(interactionStore: store, client: generator)

        let result = try await runner.run(
            task: .piiDetection,
            text: "Test",
            parameters: LocalAITaskParameters(),
            sourceName: nil,
            modelName: "stub-model"
        )

        let object = try JSONSerialization.jsonObject(with: response.data(using: .utf8)!)
        let expectedData = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let expected = String(data: expectedData, encoding: .utf8)

        XCTAssertEqual(result.output, expected)
        XCTAssertEqual(generator.lastFormat, "json")
    }

    func testFallsBackToRawTextWhenJSONInvalid() async throws {
        let response = "not json"
        let generator = StubGenerator(response: response)
        let store = AIInteractionStore(persistToDisk: false)
        let runner = LocalAITaskRunner(interactionStore: store, client: generator)

        let result = try await runner.run(
            task: .piiDetection,
            text: "Test",
            parameters: LocalAITaskParameters(),
            sourceName: nil,
            modelName: "stub-model"
        )

        XCTAssertEqual(result.output, response)
        XCTAssertEqual(generator.lastFormat, "json")
    }
}
