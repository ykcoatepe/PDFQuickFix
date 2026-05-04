import Foundation

enum OllamaClientError: Error {
    case invalidHost
    case requestFailed
    case invalidResponse
    case modelUnavailable
}

struct OllamaModelInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

struct OllamaModelDetails: Hashable {
    let name: String
    let capabilities: [String]
}

protocol OllamaTextGenerating {
    func generateText(model: String, prompt: String, format: String?) async throws -> String
}

final class OllamaClient: OllamaTextGenerating {
    private let hostURL: URL
    private let requestTimeout: TimeInterval

    init(hostURL: URL = URL(string: "http://127.0.0.1:11434")!, requestTimeout: TimeInterval = 20) {
        self.hostURL = hostURL
        self.requestTimeout = requestTimeout
    }

    func listModels() async throws -> [OllamaModelInfo] {
        guard isLocalHost(hostURL) else { throw OllamaClientError.invalidHost }
        let data = try await request(path: "/api/tags", body: nil)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else {
            throw OllamaClientError.invalidResponse
        }

        return models.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return OllamaModelInfo(id: name, name: name)
        }
    }

    func showModelDetails(model: String) async throws -> OllamaModelDetails {
        guard isLocalHost(hostURL) else { throw OllamaClientError.invalidHost }
        let payload: [String: Any] = ["name": model]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "/api/show", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaClientError.invalidResponse
        }

        let capabilities = Self.parseCapabilities(from: json)
        return OllamaModelDetails(name: model, capabilities: capabilities)
    }

    func generateText(model: String, prompt: String, format: String? = nil) async throws -> String {
        guard isLocalHost(hostURL) else { throw OllamaClientError.invalidHost }

        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
        ]
        if let format {
            payload["format"] = format
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "/api/generate", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String
        else {
            throw OllamaClientError.invalidResponse
        }
        return response
    }

    func generateVision(model: String, prompt: String, images: [String], format: Any? = nil) async throws -> String {
        guard isLocalHost(hostURL) else { throw OllamaClientError.invalidHost }

        var payload: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "images": images,
            "stream": false,
        ]
        if let format {
            payload["format"] = format
        }

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request(path: "/api/generate", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String
        else {
            throw OllamaClientError.invalidResponse
        }
        return response
    }

    private func request(path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: hostURL) else {
            throw OllamaClientError.requestFailed
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
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func parseCapabilities(from json: [String: Any]) -> [String] {
        if let capabilities = json["capabilities"] as? [String] {
            return capabilities
        }
        if let details = json["details"] as? [String: Any],
           let capabilities = details["capabilities"] as? [String]
        {
            return capabilities
        }
        return []
    }
}
