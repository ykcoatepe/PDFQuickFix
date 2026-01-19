import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var aiSettings: LocalAISettings
    @EnvironmentObject private var aiInteractions: AIInteractionStore

    private let autoTag = "__default__"

    var body: some View {
        Form {
            Section("Local AI") {
                HStack {
                    Text("Ollama host")
                    Spacer()
                    Text("127.0.0.1:11434")
                        .foregroundStyle(.secondary)
                }

                Toggle("Persist AI interactions between launches", isOn: $aiSettings.persistAIInteractions)
                    .onChange(of: aiSettings.persistAIInteractions) { enabled in
                        aiInteractions.setPersistence(enabled: enabled)
                    }

                Stepper(
                    value: $aiSettings.requestTimeoutSeconds,
                    in: LocalAISettings.minRequestTimeoutSeconds...LocalAISettings.maxRequestTimeoutSeconds,
                    step: 10
                ) {
                    Text("AI request timeout: \(aiSettings.requestTimeoutSeconds)s")
                }

                HStack(spacing: 12) {
                    Button(aiSettings.isRefreshing ? "Refreshing…" : "Refresh Models") {
                        Task { await aiSettings.refreshModels() }
                    }
                    .disabled(aiSettings.isRefreshing)

                    if let error = aiSettings.lastRefreshError {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Default Model") {
                if aiSettings.availableModels.isEmpty {
                    Text("No local Ollama models detected. Install models with ollama and refresh.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Default model", selection: $aiSettings.defaultModel) {
                        ForEach(aiSettings.availableModels) { model in
                            Text(aiSettings.displayName(for: model.name)).tag(model.name)
                        }
                    }

                    if let recommended = aiSettings.recommendedModelName {
                        Text("Recommended: \(aiSettings.displayName(for: recommended))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Task Overrides") {
                if aiSettings.availableModels.isEmpty {
                    Text("Load models to configure per-task overrides.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(LocalAITask.allCases) { task in
                        Picker(task.displayName, selection: overrideBinding(for: task)) {
                            Text("Use Default (\(aiSettings.displayName(for: aiSettings.defaultModel)))")
                                .tag(autoTag)
                            ForEach(aiSettings.availableModels) { model in
                                Text(aiSettings.displayName(for: model.name)).tag(model.name)
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            await aiSettings.refreshModelsIfNeeded()
        }
        .onAppear {
            aiInteractions.setPersistence(enabled: aiSettings.persistAIInteractions)
        }
    }

    private func overrideBinding(for task: LocalAITask) -> Binding<String> {
        Binding<String>(
            get: {
                aiSettings.override(for: task) ?? autoTag
            },
            set: { newValue in
                let value = newValue == autoTag ? nil : newValue
                aiSettings.setOverride(task: task, model: value)
            }
        )
    }
}
