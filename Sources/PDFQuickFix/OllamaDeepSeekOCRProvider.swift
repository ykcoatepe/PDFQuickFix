import AppKit
import CoreGraphics
import Foundation
import CryptoKit

enum OllamaDeepSeekOCRError: Error {
    case invalidImage
    case requestFailed
    case invalidResponse
    case noDetections
    case notAvailable
    case inputTooLarge
}

protocol DeepSeekOCRProviding {
    func isAvailable() -> Bool
    func recognizeTextLines(cgImage: CGImage) throws -> [RecognizedRun]
}

final class OllamaDeepSeekOCRProvider: DeepSeekOCRProviding {
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
