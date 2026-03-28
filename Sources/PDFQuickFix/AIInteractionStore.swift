import Foundation
import UniformTypeIdentifiers

struct AIInteractionEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let timestamp: Date
    let task: LocalAITask
    let model: String
    let prompt: String
    let response: String
    let sourceName: String?
    let inputCharacterCount: Int
    let inputWasTrimmed: Bool
}

enum AIActivityExportFormat: String, CaseIterable, Codable, Hashable {
    case json
    case markdown

    var fileExtension: String {
        switch self {
        case .json:
            return "json"
        case .markdown:
            return "md"
        }
    }

    var displayName: String {
        switch self {
        case .json:
            return "JSON"
        case .markdown:
            return "Markdown"
        }
    }

    var contentType: UTType {
        switch self {
        case .json:
            return .json
        case .markdown:
            return UTType(filenameExtension: "md") ?? .plainText
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
    private var persistToDisk: Bool
    private let fileURL: URL

    init(persistToDisk: Bool = UserDefaults.standard.bool(forKey: "LocalAI.persistLogs")) {
        self.persistToDisk = persistToDisk
        self.fileURL = AIInteractionStore.makeFileURL()
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
              let decoded = try? JSONDecoder().decode([AIInteractionEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func loadPersistedEntries() -> [AIInteractionEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AIInteractionEntry].self, from: data) else {
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
                        format: AIActivityExportFormat) throws -> AIActivityExportDocument {
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
                                   format: AIActivityExportFormat) -> String {
        let base = entries.count == 1 ? "ai-activity-\(entries[0].task.rawValue)" : "ai-activity-session"
        return "\(base).\(format.fileExtension)"
    }

    static func makeJSONExportData(entries: [AIInteractionEntry]) throws -> Data {
        struct Payload: Codable {
            let exportedAt: Date
            let formatVersion: Int
            let entries: [AIInteractionEntry]
        }

        let payload = Payload(exportedAt: Date(), formatVersion: 1, entries: entries)
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
            output.append("- Task: \(entry.task.displayName)")
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
            task: entry.task,
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
