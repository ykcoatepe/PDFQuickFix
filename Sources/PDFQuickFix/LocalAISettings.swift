import Foundation

@MainActor
final class LocalAISettings: ObservableObject {
    static let defaultModelKey = "LocalAI.defaultModel"
    static let persistLogsKey = "LocalAI.persistLogs"
    static let overridePrefix = "LocalAI.override."
    static let requestTimeoutKey = "LocalAI.requestTimeoutSeconds"
    static let minRequestTimeoutSeconds = 20
    static let maxRequestTimeoutSeconds = 300
    static let defaultRequestTimeoutSeconds = 120

    @Published private(set) var availableModels: [OllamaModelInfo] = []
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var isRefreshing: Bool = false
    @Published var defaultModel: String {
        didSet {
            defaults.set(defaultModel, forKey: Self.defaultModelKey)
        }
    }
    @Published var persistAIInteractions: Bool {
        didSet {
            defaults.set(persistAIInteractions, forKey: Self.persistLogsKey)
        }
    }
    @Published var requestTimeoutSeconds: Int {
        didSet {
            let clamped = Self.clampTimeout(requestTimeoutSeconds)
            if clamped != requestTimeoutSeconds {
                requestTimeoutSeconds = clamped
                return
            }
            defaults.set(clamped, forKey: Self.requestTimeoutKey)
        }
    }
    @Published private(set) var taskOverrides: [LocalAITask: String] = [:]

    private let client: OllamaClient
    private let defaults: UserDefaults
    private var hasLoadedModels = false

    init(client: OllamaClient = OllamaClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.defaultModel = defaults.string(forKey: Self.defaultModelKey) ?? ""
        self.persistAIInteractions = defaults.bool(forKey: Self.persistLogsKey)
        if defaults.object(forKey: Self.requestTimeoutKey) != nil {
            self.requestTimeoutSeconds = defaults.integer(forKey: Self.requestTimeoutKey)
        } else {
            self.requestTimeoutSeconds = Self.defaultRequestTimeoutSeconds
        }
        self.requestTimeoutSeconds = Self.clampTimeout(self.requestTimeoutSeconds)
        for task in LocalAITask.allCases {
            if let value = defaults.string(forKey: Self.overrideKey(for: task)) {
                taskOverrides[task] = value
            }
        }
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
            var models = try await client.listModels()
            models = models.filter { !Self.isCloudModel($0.name) }
            models.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            availableModels = models
            normalizeModels()
        } catch {
            lastRefreshError = "Ollama not reachable on 127.0.0.1:11434."
        }
    }

    func modelFor(task: LocalAITask) -> String? {
        let names = availableModelNamesLowercased()
        if let override = taskOverrides[task], names.contains(override.lowercased()) {
            return override
        }
        if names.contains(defaultModel.lowercased()) {
            return defaultModel
        }
        return nil
    }

    func setOverride(task: LocalAITask, model: String?) {
        if let model {
            taskOverrides[task] = model
            defaults.set(model, forKey: Self.overrideKey(for: task))
        } else {
            taskOverrides.removeValue(forKey: task)
            defaults.removeObject(forKey: Self.overrideKey(for: task))
        }
    }

    func override(for task: LocalAITask) -> String? {
        taskOverrides[task]
    }

    func displayName(for model: String) -> String {
        if Self.isOCRModel(model) {
            return "\(model) (OCR-only)"
        }
        return model
    }

    var recommendedModelName: String? {
        Self.recommendedModelName(models: availableModels)
    }

    private func normalizeModels() {
        let availableNames = availableModelNamesLowercased()
        if !defaultModel.isEmpty && !availableNames.contains(defaultModel.lowercased()) {
            defaultModel = ""
        }
        let invalidTasks = taskOverrides.filter { !availableNames.contains($0.value.lowercased()) }.map(\.key)
        for task in invalidTasks {
            taskOverrides.removeValue(forKey: task)
            defaults.removeObject(forKey: Self.overrideKey(for: task))
        }
        if defaultModel.isEmpty, let recommended = recommendedModelName {
            defaultModel = recommended
        }
    }

    private func availableModelNamesLowercased() -> Set<String> {
        Set(availableModels.map { $0.name.lowercased() })
    }

    private static func overrideKey(for task: LocalAITask) -> String {
        overridePrefix + task.rawValue
    }

    private static func isCloudModel(_ name: String) -> Bool {
        name.lowercased().contains(":cloud")
    }

    private static func isOCRModel(_ name: String) -> Bool {
        name.lowercased().contains("ocr")
    }

    private static func recommendedModelName(models: [OllamaModelInfo]) -> String? {
        guard !models.isEmpty else { return nil }
        if let deepseek = matchModelName("deepseek-r1:8b", in: models) {
            return deepseek
        }
        let nonOCR = models.filter { !isOCRModel($0.name) }
        let candidates = nonOCR.isEmpty ? models : nonOCR
        let sorted = candidates.sorted { lhs, rhs in
            modelRank(lhs.name) < modelRank(rhs.name)
        }
        return sorted.first?.name
    }

    private static func modelRank(_ name: String) -> (Int, Int, Int, String) {
        let lower = name.lowercased()
        let size = modelSizeHint(lower)
        let instructPenalty = lower.contains("instruct") || lower.contains("chat") ? 0 : 1
        let visionPenalty = lower.contains("vl") ? 1 : 0
        return (instructPenalty, size, visionPenalty, lower)
    }

    private static func modelSizeHint(_ name: String) -> Int {
        let pattern = #"(\d+)\s*b"#
        if let range = name.range(of: pattern, options: .regularExpression) {
            let digits = name[range].filter { $0.isNumber }
            return Int(digits) ?? 999
        }
        return 999
    }

    private static func matchModelName(_ target: String, in models: [OllamaModelInfo]) -> String? {
        models.first { $0.name.lowercased() == target.lowercased() }?.name
    }

    private static func clampTimeout(_ value: Int) -> Int {
        min(max(value, minRequestTimeoutSeconds), maxRequestTimeoutSeconds)
    }
}
