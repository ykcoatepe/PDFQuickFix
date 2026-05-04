import Foundation
import UniformTypeIdentifiers

struct AIInteractionEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: AIInteractionKind
    let model: String
    let prompt: String
    let response: String
    let sourceName: String?
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, kind, task, model, prompt, response, sourceName, inputCharacterCount, inputWasTrimmed
    }

    init(id: UUID,
         timestamp: Date,
         kind: AIInteractionKind,
         model: String,
         prompt: String,
         response: String,
         sourceName: String?,
         inputCharacterCount: Int,
         inputWasTrimmed: Bool)
    {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.model = model
        self.prompt = prompt
        self.response = response
        self.sourceName = sourceName
        self.inputCharacterCount = inputCharacterCount
        self.inputWasTrimmed = inputWasTrimmed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        if let kind = try container.decodeIfPresent(AIInteractionKind.self, forKey: .kind) {
            self.kind = kind
        } else {
            let task = try container.decode(LocalAITask.self, forKey: .task)
            kind = .quickFix(task: task)
        }
        model = try container.decode(String.self, forKey: .model)
        prompt = try container.decode(String.self, forKey: .prompt)
        response = try container.decode(String.self, forKey: .response)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        inputCharacterCount = try container.decode(Int.self, forKey: .inputCharacterCount)
        inputWasTrimmed = try container.decode(Bool.self, forKey: .inputWasTrimmed)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(kind, forKey: .kind)
        try container.encode(model, forKey: .model)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(response, forKey: .response)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encode(inputCharacterCount, forKey: .inputCharacterCount)
        try container.encode(inputWasTrimmed, forKey: .inputWasTrimmed)
    }
}

enum AIActivityExportFormat: String, CaseIterable, Codable, Hashable {
    case json
    case markdown

    var fileExtension: String {
        switch self {
        case .json:
            "json"
        case .markdown:
            "md"
        }
    }

    var displayName: String {
        switch self {
        case .json:
            "JSON"
        case .markdown:
            "Markdown"
        }
    }

    var contentType: UTType {
        switch self {
        case .json:
            .json
        case .markdown:
            UTType(filenameExtension: "md") ?? .plainText
        }
    }
}

struct AIActivityExportDocument {
    let fileName: String
    let data: Data
    let contentType: UTType
}

@MainActor
final class AIInteractionStore: ObservableObject {
    @Published private(set) var entries: [AIInteractionEntry] = []

    private let maxEntries = 200
    private let maxPromptCharacters = 4000
    private let maxResponseCharacters = 8000
    static let exportSchemaVersion = 2
    private var persistToDisk: Bool
    private let fileURL: URL

    init(persistToDisk: Bool = UserDefaults.standard.bool(forKey: "LocalAI.persistLogs")) {
        self.persistToDisk = persistToDisk
        fileURL = AIInteractionStore.makeFileURL()
        if persistToDisk {
            load()
        }
    }

    func setPersistence(enabled: Bool) {
        guard enabled != persistToDisk else { return }
        persistToDisk = enabled
        if enabled {
            let persisted = loadPersistedEntries()
            if !persisted.isEmpty {
                mergePersistedEntries(persisted)
            }
            save()
        } else {
            deletePersisted()
        }
    }

    func record(_ entry: AIInteractionEntry) {
        let sanitized = sanitize(entry)
        entries.insert(sanitized, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        if persistToDisk {
            save()
        }
    }

    func clear() {
        entries = []
        if persistToDisk {
            save()
        } else {
            deletePersisted()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            // Best-effort persistence; ignore failures in UI flow.
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = Self.decodePersistedEntries(from: data)
        else {
            return
        }
        entries = decoded
    }

    private func loadPersistedEntries() -> [AIInteractionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = Self.decodePersistedEntries(from: data)
        else {
            return []
        }
        return decoded
    }

    private func mergePersistedEntries(_ persisted: [AIInteractionEntry]) {
        let combined = entries + persisted
        let sorted = combined.sorted { $0.timestamp > $1.timestamp }
        var seen = Set<UUID>()
        var merged: [AIInteractionEntry] = []
        for entry in sorted where seen.insert(entry.id).inserted {
            merged.append(entry)
            if merged.count >= maxEntries {
                break
            }
        }
        entries = merged
    }

    private func deletePersisted() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    func exportDocument(for entries: [AIInteractionEntry],
                        format: AIActivityExportFormat) throws -> AIActivityExportDocument
    {
        guard !entries.isEmpty else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileName = Self.makeExportFileName(entries: entries, format: format)
        switch format {
        case .json:
            let data = try Self.makeJSONExportData(entries: entries)
            return AIActivityExportDocument(fileName: fileName, data: data, contentType: format.contentType)
        case .markdown:
            let text = Self.makeMarkdownExport(entries: entries)
            guard let data = text.data(using: .utf8) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return AIActivityExportDocument(fileName: fileName, data: data, contentType: format.contentType)
        }
    }

    static func makeExportFileName(entries: [AIInteractionEntry],
                                   format: AIActivityExportFormat) -> String
    {
        let base = entries.count == 1 ? "ai-activity-\(entries[0].kind.exportSlug)" : "ai-activity-session"
        return "\(base).\(format.fileExtension)"
    }

    static func makeJSONExportData(entries: [AIInteractionEntry]) throws -> Data {
        struct Payload: Codable {
            let exportedAt: Date
            let formatVersion: Int
            let entries: [AIInteractionEntry]
        }

        let payload = Payload(exportedAt: Date(), formatVersion: exportSchemaVersion, entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func makeMarkdownExport(entries: [AIInteractionEntry]) -> String {
        var output: [String] = []
        output.append("# AI Activity Export")
        output.append("")
        output.append("Entries: \(entries.count)")
        output.append("")
        for (index, entry) in entries.enumerated() {
            output.append("## Entry \(index + 1)")
            output.append("")
            output.append("- Kind: \(entry.kind.displayName)")
            output.append("- Model: \(entry.model)")
            output.append("- Timestamp: \(entry.timestamp.formatted(date: .abbreviated, time: .standard))")
            if let sourceName = entry.sourceName {
                output.append("- Source: \(sourceName)")
            }
            if entry.inputWasTrimmed {
                output.append("- Input trimmed: \(entry.inputCharacterCount) characters")
            }
            output.append("")
            output.append("### Prompt")
            output.append("")
            output.append("```text")
            output.append(entry.prompt)
            output.append("```")
            output.append("")
            output.append("### Response")
            output.append("")
            output.append("```text")
            output.append(entry.response)
            output.append("```")
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    private func sanitize(_ entry: AIInteractionEntry) -> AIInteractionEntry {
        let prompt = truncate(entry.prompt, limit: maxPromptCharacters)
        let response = truncate(entry.response, limit: maxResponseCharacters)
        guard prompt != entry.prompt || response != entry.response else { return entry }
        return AIInteractionEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            kind: entry.kind,
            model: entry.model,
            prompt: prompt,
            response: response,
            sourceName: entry.sourceName,
            inputCharacterCount: entry.inputCharacterCount,
            inputWasTrimmed: entry.inputWasTrimmed
        )
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "... (truncated)"
    }

    static func decodePersistedEntries(from data: Data) -> [AIInteractionEntry]? {
        let decoder = Self.makeDecoder()

        if let decoded = try? decoder.decode([AIInteractionEntry].self, from: data) {
            return decoded
        }

        guard let rawArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var decoded: [AIInteractionEntry] = []
        decoded.reserveCapacity(rawArray.count)
        for item in rawArray {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item),
                  let entry = try? decoder.decode(AIInteractionEntry.self, from: itemData)
            else {
                continue
            }
            decoded.append(entry)
        }
        return decoded
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let timestamp = try? container.decode(Double.self) {
                return Self.decodeNumericDate(timestamp)
            }
            if let timestamp = try? container.decode(Int.self) {
                return Self.decodeNumericDate(TimeInterval(timestamp))
            }
            let string = try container.decode(String.self)
            if let date = Self.decodeISO8601Date(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported date encoding: \(string)")
        }
        return decoder
    }

    nonisolated private static func decodeNumericDate(_ timestamp: TimeInterval) -> Date {
        if timestamp > 1_000_000_000 {
            return Date(timeIntervalSince1970: timestamp)
        }
        return Date(timeIntervalSinceReferenceDate: timestamp)
    }

    nonisolated private static func decodeISO8601Date(_ string: String) -> Date? {
        let fractionalISO8601Formatter = ISO8601DateFormatter()
        fractionalISO8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalISO8601Formatter.date(from: string) {
            return date
        }

        let plainISO8601Formatter = ISO8601DateFormatter()
        plainISO8601Formatter.formatOptions = [.withInternetDateTime]
        return plainISO8601Formatter.date(from: string)
    }

    private static func makeFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("PDFQuickFix", isDirectory: true)
        if !FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        return folder.appendingPathComponent("ai-interactions.json")
    }
}
