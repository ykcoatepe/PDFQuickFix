import AppKit
import CoreGraphics
import Foundation
import CryptoKit
import Combine

enum OllamaDeepSeekOCRError: Error {
    case invalidImage
    case requestFailed
    case invalidResponse
    case noDetections
    case notAvailable
    case inputTooLarge
}

protocol LocalOCRProviding {
    func isAvailable() -> Bool
    func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun]
}

protocol CloudOCRProviding {
    func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun]
}

final class OllamaDeepSeekOCRProvider: LocalOCRProviding {
    private final class CachedRuns: NSObject {
        let runs: [RecognizedRun]

        init(runs: [RecognizedRun]) {
            self.runs = runs
        }
    }

    private static let cache = NSCache<NSString, CachedRuns>()
    private static let maxPixelCount = 12_000_000
    private static let availabilityTTL: TimeInterval = 10
    private static let availabilityTimeout: TimeInterval = 0.8
    private static var availabilityCache: [String: (value: Bool, timestamp: Date)] = [:]
    private static let availabilityLock = NSLock()
    private static let promptVariants = [
        "<image>\n<|grounding|>Extract the text in the image.",
        "<image>\n<|grounding|>Extract all text with bounding boxes.",
        "<image>\n<|grounding|>Free OCR."
    ]

    private let hostURL: URL
    private let modelName: String
    private let requestTimeout: TimeInterval

    init(modelName: String = "deepseek-ocr:3b",
         hostURL: URL = URL(string: "http://127.0.0.1:11434")!,
         requestTimeout: TimeInterval = 25) {
        self.modelName = modelName
        self.hostURL = hostURL
        self.requestTimeout = requestTimeout
        Self.cache.countLimit = 32
    }

    func isAvailable() -> Bool {
        guard isLocalHost(hostURL) else { return false }
        let cacheKey = availabilityCacheKey()
        if let cached = Self.cachedAvailability(for: cacheKey) {
            return cached
        }

        guard let data = try? request(path: "/api/tags", body: nil, timeoutOverride: Self.availabilityTimeout) else {
            Self.storeAvailability(false, for: cacheKey)
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            Self.storeAvailability(false, for: cacheKey)
            return false
        }
        let available = models.contains { ($0["name"] as? String)?.lowercased() == modelName.lowercased() }
        Self.storeAvailability(available, for: cacheKey)
        return available
    }

    func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun] {
        guard isLocalHost(hostURL) else { throw OllamaDeepSeekOCRError.notAvailable }
        guard let pngData = pngData(from: cgImage) else { throw OllamaDeepSeekOCRError.invalidImage }
        let pixelCount = cgImage.width * cgImage.height
        if pixelCount > Self.maxPixelCount {
            throw OllamaDeepSeekOCRError.inputTooLarge
        }

        let cacheKey = Self.cacheKey(for: pngData)
        if let cached = Self.cache.object(forKey: cacheKey) {
            return cached.runs
        }

        var runs: [RecognizedRun] = []
        for prompt in Self.promptVariants {
            let payload: [String: Any] = [
                "model": modelName,
                "prompt": prompt,
                "images": [pngData.base64EncodedString()],
                "stream": false
            ]

            let body = try JSONSerialization.data(withJSONObject: payload)
            let data = try request(path: "/api/generate", body: body)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let response = json["response"] as? String else {
                throw OllamaDeepSeekOCRError.invalidResponse
            }

            runs = DeepSeekOCRParser.parseRuns(response: response,
                                               imageSize: CGSize(width: cgImage.width, height: cgImage.height))
            if !runs.isEmpty {
                break
            }
        }
        guard !runs.isEmpty else { throw OllamaDeepSeekOCRError.noDetections }
        Self.cache.setObject(CachedRuns(runs: runs), forKey: cacheKey)
        return runs
    }

    private func request(path: String, body: Data?, timeoutOverride: TimeInterval? = nil) throws -> Data {
        guard let url = URL(string: path, relativeTo: hostURL) else {
            throw OllamaDeepSeekOCRError.requestFailed
        }
        let effectiveTimeout = timeoutOverride ?? requestTimeout
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = effectiveTimeout
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = effectiveTimeout
        let session = URLSession(configuration: config)
        let semaphore = DispatchSemaphore(value: 0)

        var resultData: Data?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()

        let timeoutResult = semaphore.wait(timeout: .now() + effectiveTimeout + 0.2)
        session.invalidateAndCancel()

        if timeoutResult == .timedOut {
            throw OllamaDeepSeekOCRError.requestFailed
        }
        if let error = resultError {
            throw error
        }
        guard let data = resultData else {
            throw OllamaDeepSeekOCRError.requestFailed
        }
        return data
    }

    private func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func cacheKey(for data: Data) -> NSString {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return NSString(string: hex)
    }

    private func availabilityCacheKey() -> String {
        "\(hostURL.absoluteString.lowercased())|\(modelName.lowercased())"
    }

    private static func cachedAvailability(for key: String) -> Bool? {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        guard let entry = availabilityCache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > availabilityTTL {
            availabilityCache.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    private static func storeAvailability(_ value: Bool, for key: String) {
        availabilityLock.lock()
        availabilityCache[key] = (value, Date())
        availabilityLock.unlock()
    }
}

enum OllamaVisionOCRError: Error {
    case invalidImage
    case requestFailed
    case invalidResponse
    case noDetections
    case notAvailable
    case inputTooLarge
}

final class OllamaVisionOCRProvider: LocalOCRProviding {
    private final class CachedRuns: NSObject {
        let runs: [RecognizedRun]

        init(runs: [RecognizedRun]) {
            self.runs = runs
        }
    }

    private static let cache = NSCache<NSString, CachedRuns>()
    private static let maxPixelCount = 12_000_000
    private static let availabilityTTL: TimeInterval = 10
    private static let availabilityTimeout: TimeInterval = 0.8
    private static var availabilityCache: [String: (value: Bool, timestamp: Date)] = [:]
    private static let availabilityLock = NSLock()
    private static let prompt = """
<image>
Extract all text lines from the image.
Return JSON as an array of objects with keys:
- text: the line text
- bbox: [x1, y1, x2, y2] normalized to 0..1000
Use one entry per text line.
"""
    private static let responseSchema: [String: Any] = [
        "type": "array",
        "items": [
            "type": "object",
            "properties": [
                "text": ["type": "string"],
                "bbox": [
                    "type": "array",
                    "items": ["type": "number"],
                    "minItems": 4,
                    "maxItems": 4
                ]
            ],
            "required": ["text", "bbox"]
        ]
    ]

    private let hostURL: URL
    private let modelName: String
    private let requestTimeout: TimeInterval

    init(modelName: String,
         hostURL: URL = URL(string: "http://127.0.0.1:11434")!,
         requestTimeout: TimeInterval = 25) {
        self.modelName = modelName
        self.hostURL = hostURL
        self.requestTimeout = requestTimeout
        Self.cache.countLimit = 32
    }

    func isAvailable() -> Bool {
        guard isLocalHost(hostURL) else { return false }
        let cacheKey = availabilityCacheKey()
        if let cached = Self.cachedAvailability(for: cacheKey) {
            return cached
        }

        guard let data = try? request(path: "/api/tags", body: nil, timeoutOverride: Self.availabilityTimeout) else {
            Self.storeAvailability(false, for: cacheKey)
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            Self.storeAvailability(false, for: cacheKey)
            return false
        }
        let available = models.contains { ($0["name"] as? String)?.lowercased() == modelName.lowercased() }
        Self.storeAvailability(available, for: cacheKey)
        return available
    }

    func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun] {
        guard isLocalHost(hostURL) else { throw OllamaVisionOCRError.notAvailable }
        guard let pngData = pngData(from: cgImage) else { throw OllamaVisionOCRError.invalidImage }
        let pixelCount = cgImage.width * cgImage.height
        if pixelCount > Self.maxPixelCount {
            throw OllamaVisionOCRError.inputTooLarge
        }

        let cacheKey = Self.cacheKey(for: pngData)
        if let cached = Self.cache.object(forKey: cacheKey) {
            return cached.runs
        }

        let payload: [String: Any] = [
            "model": modelName,
            "prompt": Self.prompt,
            "images": [pngData.base64EncodedString()],
            "stream": false,
            "format": Self.responseSchema
        ]

        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try request(path: "/api/generate", body: body)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = json["response"] as? String else {
            throw OllamaVisionOCRError.invalidResponse
        }

        let runs = LocalOCRJSONParser.parseRuns(response: response,
                                                imageSize: CGSize(width: cgImage.width, height: cgImage.height))
        guard !runs.isEmpty else { throw OllamaVisionOCRError.noDetections }
        Self.cache.setObject(CachedRuns(runs: runs), forKey: cacheKey)
        return runs
    }

    private func request(path: String, body: Data?, timeoutOverride: TimeInterval? = nil) throws -> Data {
        guard let url = URL(string: path, relativeTo: hostURL) else {
            throw OllamaVisionOCRError.requestFailed
        }
        let effectiveTimeout = timeoutOverride ?? requestTimeout
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = effectiveTimeout
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = effectiveTimeout
        let session = URLSession(configuration: config)
        let semaphore = DispatchSemaphore(value: 0)

        var resultData: Data?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()

        let timeoutResult = semaphore.wait(timeout: .now() + effectiveTimeout + 0.2)
        session.invalidateAndCancel()

        if timeoutResult == .timedOut {
            throw OllamaVisionOCRError.requestFailed
        }
        if let error = resultError {
            throw error
        }
        guard let data = resultData else {
            throw OllamaVisionOCRError.requestFailed
        }
        return data
    }

    private func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private func isLocalHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func cacheKey(for data: Data) -> NSString {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return NSString(string: hex)
    }

    private func availabilityCacheKey() -> String {
        "\(hostURL.absoluteString.lowercased())|\(modelName.lowercased())"
    }

    private static func cachedAvailability(for key: String) -> Bool? {
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        guard let entry = availabilityCache[key] else { return nil }
        if Date().timeIntervalSince(entry.timestamp) > availabilityTTL {
            availabilityCache.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    private static func storeAvailability(_ value: Bool, for key: String) {
        availabilityLock.lock()
        availabilityCache[key] = (value, Date())
        availabilityLock.unlock()
    }
}

@MainActor
final class LocalOCRModelRegistry: ObservableObject {
    @Published private(set) var availableModels: [OllamaModelInfo] = []
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var isRefreshing: Bool = false
    private let client: OllamaClient
    private var hasLoadedModels = false

    init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    func refreshModelsIfNeeded() async {
        if !hasLoadedModels {
            await refreshModels()
        }
    }

    func refreshModels() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastRefreshError = nil
        defer {
            isRefreshing = false
            hasLoadedModels = true
        }

        do {
            let models = try await client.listModels()
            var visionModels: [OllamaModelInfo] = []
            for model in models {
                let lower = model.name.lowercased()
                if lower.contains("ocr") {
                    visionModels.append(model)
                    continue
                }
                if let details = try? await client.showModelDetails(model: model.name),
                   details.capabilities.map({ $0.lowercased() }).contains("vision") {
                    visionModels.append(model)
                }
            }
            visionModels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            availableModels = visionModels
        } catch {
            lastRefreshError = "Ollama not reachable on 127.0.0.1:11434."
        }
    }

    var recommendedModelName: String? {
        Self.recommendedModelName(models: availableModels)
    }

    private static func recommendedModelName(models: [OllamaModelInfo]) -> String? {
        guard !models.isEmpty else { return nil }
        let preferred = ["qwen2.5vl:7b", "minicpm-v:8b", "deepseek-ocr:3b"]
        for target in preferred {
            if let match = matchModelName(target, in: models) {
                return match
            }
        }
        return models.first?.name
    }

    private static func matchModelName(_ target: String, in models: [OllamaModelInfo]) -> String? {
        models.first { $0.name.lowercased() == target.lowercased() }?.name
    }
}

enum LocalOCRJSONParser {
    static func parseRuns(response: String, imageSize: CGSize) -> [RecognizedRun] {
        guard let json = parseJSON(response: response) else { return [] }
        guard let items = json as? [[String: Any]] else { return [] }

        var runs: [RecognizedRun] = []
        for item in items {
            guard let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            guard let rect = rectFromBBox(item["bbox"], imageSize: imageSize) else { continue }
            runs.append(RecognizedRun(kind: .keep(text), rectInPixels: rect))
        }
        return runs
    }

    private static func parseJSON(response: String) -> Any? {
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            return json
        }
        guard let start = response.firstIndex(of: "["),
              let end = response.lastIndex(of: "]"),
              start < end else {
            return nil
        }
        let substring = String(response[start...end])
        guard let data = substring.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func rectFromBBox(_ value: Any?, imageSize: CGSize) -> CGRect? {
        guard let rectValues = normalizedRect(from: value) else { return nil }
        var x1 = rectValues.x1
        var y1 = rectValues.y1
        var x2 = rectValues.x2
        var y2 = rectValues.y2
        let maxValue = max(x1, y1, x2, y2)
        if maxValue <= 1.5 {
            x1 *= 1000
            y1 *= 1000
            x2 *= 1000
            y2 *= 1000
        }
        x1 = clamp(x1, min: 0, max: 999)
        y1 = clamp(y1, min: 0, max: 999)
        x2 = clamp(x2, min: 0, max: 999)
        y2 = clamp(y2, min: 0, max: 999)
        guard x2 > x1, y2 > y1 else { return nil }

        let scaleX = imageSize.width / 1000.0
        let scaleY = imageSize.height / 1000.0
        return CGRect(x: CGFloat(x1) * scaleX,
                      y: CGFloat(y1) * scaleY,
                      width: CGFloat(x2 - x1) * scaleX,
                      height: CGFloat(y2 - y1) * scaleY)
    }

    private static func normalizedRect(from value: Any?) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        if let coords = value as? [NSNumber], coords.count == 4 {
            return (coords[0].doubleValue, coords[1].doubleValue, coords[2].doubleValue, coords[3].doubleValue)
        }
        if let list = value as? [[NSNumber]] {
            if let first = list.first, first.count == 4 {
                return (first[0].doubleValue, first[1].doubleValue, first[2].doubleValue, first[3].doubleValue)
            }
            if list.count == 4, list.allSatisfy({ $0.count == 2 }) {
                let xs = list.map { $0[0].doubleValue }
                let ys = list.map { $0[1].doubleValue }
                guard let minX = xs.min(),
                      let maxX = xs.max(),
                      let minY = ys.min(),
                      let maxY = ys.max() else { return nil }
                return (minX, minY, maxX, maxY)
            }
        }
        return nil
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

enum GoogleVisionOCRError: Error {
    case invalidImage
    case requestFailed
    case invalidResponse
    case noDetections
}

final class GoogleVisionOCRProvider: CloudOCRProviding {
    private let apiKey: String
    private let requestTimeout: TimeInterval
    private let languageHints: [String]

    init(apiKey: String, languages: [String], requestTimeout: TimeInterval = 20) {
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.languageHints = Self.buildLanguageHints(languages)
    }

    func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun] {
        guard let pngData = pngData(from: cgImage) else { throw GoogleVisionOCRError.invalidImage }
        let urlString = "https://vision.googleapis.com/v1/images:annotate?key=\(apiKey)"
        guard let url = URL(string: urlString) else { throw GoogleVisionOCRError.requestFailed }

        var requestItem: [String: Any] = [
            "image": ["content": pngData.base64EncodedString()],
            "features": [["type": "DOCUMENT_TEXT_DETECTION"]]
        ]
        if !languageHints.isEmpty {
            requestItem["imageContext"] = ["languageHints": languageHints]
        }
        let payload: [String: Any] = [
            "requests": [requestItem]
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        let session = URLSession(configuration: config)
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultError: Error?

        let task = session.dataTask(with: request) { data, _, error in
            resultData = data
            resultError = error
            semaphore.signal()
        }
        task.resume()

        let timeoutResult = semaphore.wait(timeout: .now() + requestTimeout + 0.5)
        session.invalidateAndCancel()

        if timeoutResult == .timedOut {
            throw GoogleVisionOCRError.requestFailed
        }
        if let error = resultError {
            throw error
        }
        guard let data = resultData else {
            throw GoogleVisionOCRError.requestFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responses = json["responses"] as? [[String: Any]],
              let response = responses.first else {
            throw GoogleVisionOCRError.invalidResponse
        }

        if let runs = parseFullTextAnnotation(response: response), !runs.isEmpty {
            return runs
        }
        if let runs = parseTextAnnotations(response: response), !runs.isEmpty {
            return runs
        }
        throw GoogleVisionOCRError.noDetections
    }

    private func parseFullTextAnnotation(response: [String: Any]) -> [RecognizedRun]? {
        guard let annotation = response["fullTextAnnotation"] as? [String: Any],
              let pages = annotation["pages"] as? [[String: Any]] else {
            return nil
        }
        var runs: [RecognizedRun] = []
        for page in pages {
            guard let blocks = page["blocks"] as? [[String: Any]] else { continue }
            for block in blocks {
                guard let paragraphs = block["paragraphs"] as? [[String: Any]] else { continue }
                for paragraph in paragraphs {
                    guard let words = paragraph["words"] as? [[String: Any]] else { continue }
                    for word in words {
                        guard let symbols = word["symbols"] as? [[String: Any]] else { continue }
                        let text = symbols.compactMap { $0["text"] as? String }.joined()
                        guard !text.isEmpty else { continue }
                        guard let rect = rectFromBoundingBox(word["boundingBox"]) else { continue }
                        runs.append(RecognizedRun(kind: .keep(text), rectInPixels: rect))
                    }
                }
            }
        }
        return runs
    }

    private func parseTextAnnotations(response: [String: Any]) -> [RecognizedRun]? {
        guard let annotations = response["textAnnotations"] as? [[String: Any]],
              annotations.count > 1 else { return nil }
        var runs: [RecognizedRun] = []
        for item in annotations.dropFirst() {
            guard let text = item["description"] as? String, !text.isEmpty else { continue }
            guard let rect = rectFromBoundingBox(item["boundingPoly"]) else { continue }
            runs.append(RecognizedRun(kind: .keep(text), rectInPixels: rect))
        }
        return runs
    }

    private func rectFromBoundingBox(_ value: Any?) -> CGRect? {
        guard let box = value as? [String: Any],
              let vertices = box["vertices"] as? [[String: Any]], !vertices.isEmpty else {
            return nil
        }
        let xs = vertices.compactMap { ($0["x"] as? NSNumber)?.doubleValue }
        let ys = vertices.compactMap { ($0["y"] as? NSNumber)?.doubleValue }
        guard let minX = xs.min(),
              let maxX = xs.max(),
              let minY = ys.min(),
              let maxY = ys.max() else {
            return nil
        }
        return CGRect(x: CGFloat(minX),
                      y: CGFloat(minY),
                      width: CGFloat(maxX - minX),
                      height: CGFloat(maxY - minY))
    }

    private func pngData(from image: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    private static func buildLanguageHints(_ languages: [String]) -> [String] {
        let hints = languages.map { language -> String in
            let parts = language.split(separator: "-")
            return parts.first.map(String.init) ?? language
        }
        return Array(Set(hints)).sorted()
    }
}

enum DeepSeekOCRParser {
    static func parseRuns(response: String, imageSize: CGSize) -> [RecognizedRun] {
        let pattern = #"<\|ref\|>(.*?)<\|/ref\|>\s*<\|det\|>(.*?)<\|/det\|>\s*(.*?)(?=<\|ref\|>|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }

        let nsResponse = response as NSString
        let matches = regex.matches(in: response, range: NSRange(location: 0, length: nsResponse.length))
        var runs: [RecognizedRun] = []

        for match in matches {
            guard match.numberOfRanges >= 4 else { continue }
            let label = nsResponse.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            if label.lowercased() == "image" { continue }

            let det = nsResponse.substring(with: match.range(at: 2))
            let text = nsResponse.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            guard let rect = parseFirstRect(from: det, imageSize: imageSize) else { continue }
            runs.append(RecognizedRun(kind: .keep(text), rectInPixels: rect))
        }
        return runs
    }

    private static func parseFirstRect(from det: String, imageSize: CGSize) -> CGRect? {
        guard let data = det.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        guard let rectValues = normalizedRect(from: json) else { return nil }

        let x1 = clamp(rectValues.x1, min: 0, max: 999)
        let y1 = clamp(rectValues.y1, min: 0, max: 999)
        let x2 = clamp(rectValues.x2, min: 0, max: 999)
        let y2 = clamp(rectValues.y2, min: 0, max: 999)
        guard x2 > x1, y2 > y1 else { return nil }

        let scaleX = imageSize.width / 1000.0
        let scaleY = imageSize.height / 1000.0

        return CGRect(x: CGFloat(x1) * scaleX,
                      y: CGFloat(y1) * scaleY,
                      width: CGFloat(x2 - x1) * scaleX,
                      height: CGFloat(y2 - y1) * scaleY)
    }

    private static func normalizedRect(from json: Any) -> (x1: Double, y1: Double, x2: Double, y2: Double)? {
        if let list = json as? [[NSNumber]] {
            if let first = list.first, first.count == 4 {
                return (first[0].doubleValue, first[1].doubleValue, first[2].doubleValue, first[3].doubleValue)
            }
            if list.count == 4, list.allSatisfy({ $0.count == 2 }) {
                let xs = list.map { $0[0].doubleValue }
                let ys = list.map { $0[1].doubleValue }
                guard let minX = xs.min(),
                      let maxX = xs.max(),
                      let minY = ys.min(),
                      let maxY = ys.max() else { return nil }
                return (minX, minY, maxX, maxY)
            }
        }
        if let coords = json as? [NSNumber], coords.count == 4 {
            return (coords[0].doubleValue, coords[1].doubleValue, coords[2].doubleValue, coords[3].doubleValue)
        }
        return nil
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> Double {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}
