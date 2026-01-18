import SwiftUI

struct AIActivityView: View {
    @EnvironmentObject private var aiInteractions: AIInteractionStore
    @State private var selection: AIInteractionEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                listView
                detailView
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var header: some View {
        HStack {
            Text("AI Activity")
                .font(.title2)
                .bold()
            Spacer()
            Button("Clear") {
                aiInteractions.clear()
            }
            .disabled(aiInteractions.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var listView: some View {
        List(selection: $selection) {
            ForEach(aiInteractions.entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(entry.task.displayName)
                            .font(.headline)
                        Spacer()
                        Text(entry.timestamp, style: .time)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Text(entry.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let source = entry.sourceName {
                        Text(source)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .tag(entry.id)
            }
        }
        .frame(minWidth: 260)
    }

    private var detailView: some View {
        let entry = aiInteractions.entries.first { $0.id == selection }
        return VStack(alignment: .leading, spacing: 12) {
            if let entry {
                HStack {
                    Label(entry.task.displayName, systemImage: entry.task.systemImage)
                        .font(.headline)
                    Spacer()
                    Text(entry.timestamp, style: .date)
                        .foregroundStyle(.secondary)
                }
                Text("Model: \(entry.model)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let source = entry.sourceName {
                    Text("Source: \(source)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if entry.inputWasTrimmed {
                    Text("Input trimmed from \(entry.inputCharacterCount) characters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GroupBox("Prompt") {
                    Text(entry.prompt)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(4)
                }

                GroupBox("Response") {
                    ScrollView {
                        Text(entry.response)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(4)
                    }
                    .frame(minHeight: 200)
                }

                Spacer()
            } else {
                Text("Select an interaction to inspect details.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }
}
