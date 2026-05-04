import Foundation

enum LMStudioClientError: Error {
    case invalidHost
    case requestFailed
    case invalidResponse
    case modelUnavailable
}

final class LMStudioClient: LocalAITextGenerating, LocalAIModelListing {
    private let hostURL: URL
    private let requestTimeout: TimeInterval

    init(hostURL: URL = URL(string: "http://127.0.0.1:1234")!, requestTimeout: TimeInterval = 20) {
        self.hostURL = hostURL
        self.requestTimeout = requestTimeout
    }

    func listModels() async throws -> [OllamaModelInfo] {
        guard isLocalHost(hostURL) else { throw LMStudioClientError.invalidHost }
        let data = try await request(path: "/v1/models", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]]
        else {
            throw LMStudioClientError.invalidResponse
        }

        return models.compactMap { item in
            guard let name = item["id"] as? String else { return nil }
            return OllamaModelInfo(id: name, name: name)
        }
    }

    func generateText(model: String, prompt: String, format: String? = nil) async throws -> String {
        guard isLocalHost(hostURL) else { throw LMStudioClientError.invalidHost }

        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt],
            ],
            "stream": false,
        ]
        if format == "json" {
            payload["response_format"] = ["type": "json_object"]
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "/v1/chat/completions", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LMStudioClientError.invalidResponse
        }
        return content
    }

    private func request(path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: hostURL) else {
            throw LMStudioClientError.requestFailed
        }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = requestTimeout
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, _) = try await session.data(for: request)
        return data
    }

    private func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        guard host == "127.0.0.1" || host == "localhost" else { return false }
        return url.port == nil || url.port == LocalAIProvider.lmStudio.defaultPort
    }
}
