import SwiftUI
import UniformTypeIdentifiers

/// Reusable cards for the Split tab. Pure UI – all business logic stays in SplitController.
struct SplitSourceCard: View {
    let sourceURL: URL?
    let onChooseSource: () -> Void
    let onDropURL: (URL) -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.Colors.cardBorder.opacity(0.7), lineWidth: 0.5)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isTargeted ? AppTheme.Colors.dropZoneFillHighlighted : AppTheme.Colors.cardBackground.opacity(0.6))
                    )

                VStack(spacing: 8) {
                    if let url = sourceURL {
                        VStack(spacing: 4) {
                            Text(url.lastPathComponent)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(AppTheme.Colors.primaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(url.deletingLastPathComponent().path)
                                .font(.caption2)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 26))
                                .foregroundColor(AppTheme.Colors.secondaryText)
                            Text("Drop a PDF here")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(AppTheme.Colors.primaryText)
                            Text("or click to choose a file")
                                .font(.caption)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                        }
                        .padding(.vertical, 22)
                        .padding(.horizontal, 16)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onChooseSource() }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
            }
            .frame(minHeight: 140)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "pdf" else {
                return
            }
            DispatchQueue.main.async {
                onDropURL(url)
            }
        }
        return true
    }
}

struct SplitModeCard: View {
    @Binding var mode: SplitUIMode
    @Binding var maxPagesPerFile: Int
    @Binding var numberOfParts: Int
    @Binding var approxSizeMB: Double
    @Binding var explicitBreaksText: String

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 1
        return formatter
    }()

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximumFractionDigits = 1
        formatter.allowsFloats = true
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split mode")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $mode) {
                        ForEach(SplitUIMode.allCases, id: \.self) { m in
                            Text(m.title)
                                .tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    
                    Spacer()
                }

                switch mode {
                case .maxPagesPerFile:
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Max pages per file")
                                .font(.subheadline)
                            Text("Each part will contain up to this many pages.")
                                .font(.caption)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                        }
                        Spacer()
                        TextField("Pages", value: $maxPagesPerFile, formatter: Self.integerFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }

                case .numberOfParts:
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Number of parts")
                                .font(.subheadline)
                            Text("Split the PDF into evenly sized parts.")
                                .font(.caption)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Stepper(value: $numberOfParts, in: 2...500, step: 1) {
                                EmptyView()
                            }
                            .labelsHidden()

                            TextField("Parts", value: $numberOfParts, formatter: Self.integerFormatter)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }
                    }

                case .approxSizeMB:
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Approx. size per file (MB)")
                            Spacer()
                            TextField("MB", value: $approxSizeMB, formatter: Self.decimalFormatter)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("Uses the source file size to estimate pages per part; actual sizes may vary.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Colors.secondaryText)
                    }

                case .explicitBreaks:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Page breaks")
                        TextField("e.g. 1, 501, 1001", text: $explicitBreaksText)
                            .textFieldStyle(.roundedBorder)
                        Text("Comma-separated start pages (1-based) where a new part should begin.")
                            .font(.caption)
                            .foregroundColor(AppTheme.Colors.secondaryText)
                    }

                case .outlineChapters:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Chapters from outline")
                        Text("Splits at top-level outline entries (chapters).")
                            .font(.caption)
                            .foregroundColor(AppTheme.Colors.secondaryText)
                    }
                }
            }
            .padding(12)
            .foregroundColor(AppTheme.Colors.primaryText)
        }
    }
}

struct SplitDestinationCard: View {
    let destinationURL: URL?
    @Binding var applyToAllPDFsInFolder: Bool
    let onChooseDestination: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(destinationLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") {
                        onChooseDestination()
                    }
                    .buttonStyle(.bordered)
                }

                Toggle(isOn: $applyToAllPDFsInFolder) {
                    Text("Apply to all PDFs in this folder")
                }
            }
            .padding(12)
            .background(AppTheme.Colors.cardBackground.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
            .foregroundColor(AppTheme.Colors.primaryText)
        }
    }

    private var destinationLabel: String {
        if let dest = destinationURL {
            return dest.path
        } else {
            return "Same folder as source"
        }
    }
}

struct SplitHistoryCard: View {
    let history: [SplitJobRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)
            if history.isEmpty {
                Text("No recent jobs.")
                    .font(.footnote)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            } else {
                historyList
                    .padding(10)
                    .background(AppTheme.Colors.cardBackground.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppTheme.Colors.cardBorder.opacity(0.6), lineWidth: 0.5)
                    )
            }
        }
    }

    private var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(history) { job in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.sourceDescription)
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(AppTheme.Colors.primaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(job.fileCount) input → \(job.outputCount) output in \(job.destinationFolder)")
                            .font(.caption2)
                            .foregroundColor(AppTheme.Colors.secondaryText)
                        Text("\(job.modeDescription) · \(job.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundColor(AppTheme.Colors.secondaryText)
                        if let err = job.errorSummary, !err.isEmpty {
                            Text("Errors: \(err)")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground.opacity(0.9))
                    )
                }
            }
            .padding(8)
        }
        .frame(maxHeight: 180)
    }
}

struct MergeSourceListCard: View {
    let sourceURLs: [URL]
    let deduplicateSources: Bool
    let onChooseSources: () -> Void
    let onDropURL: (URL) -> Void
    let onRemoveOffsets: (IndexSet) -> Void
    let onMove: (IndexSet, Int) -> Void
    let onClear: () -> Void

    @State private var isTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sources")
                    .font(.headline)
                    .foregroundColor(AppTheme.Colors.primaryText)
                Spacer()
                Button("Add Files…", action: onChooseSources)
                    .buttonStyle(.bordered)
                Button("Clear", action: onClear)
                    .buttonStyle(.bordered)
                    .disabled(sourceURLs.isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                List {
                    ForEach(Array(sourceURLs.enumerated()), id: \.offset) { index, url in
                        HStack(spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption)
                                .foregroundColor(AppTheme.Colors.secondaryText)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .onDelete(perform: onRemoveOffsets)
                    .onMove(perform: onMove)
                }
                .frame(minHeight: 170, maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isTargeted ? AppTheme.Colors.dropZoneFillHighlighted : AppTheme.Colors.cardBackground.opacity(0.6))
                )
                .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                    handleDroppedFileProviders(providers) { url in
                        onDropURL(url)
                    }
                }

                Text(deduplicateSources
                     ? "Duplicate file paths are automatically removed."
                     : "Order controls merge order. Drag rows to reorder.")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
        }
    }
}

struct MergeOptionsCard: View {
    @Binding var insertBlankPageBetweenDocuments: Bool
    @Binding var skipUnreadableSources: Bool
    @Binding var deduplicateSources: Bool
    @Binding var outlinePolicy: MergeOutlinePolicy
    @Binding var metadataPolicy: MergeMetadataPolicy

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Merge options")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Insert blank page between documents", isOn: $insertBlankPageBetweenDocuments)
                Toggle("Skip unreadable PDFs", isOn: $skipUnreadableSources)
                Toggle("Deduplicate repeated source files", isOn: $deduplicateSources)

                HStack {
                    Text("Outline")
                    Spacer()
                    Picker("", selection: $outlinePolicy) {
                        Text("Top-level per source").tag(MergeOutlinePolicy.addTopLevelPerSource)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                HStack {
                    Text("Metadata")
                    Spacer()
                    Picker("", selection: $metadataPolicy) {
                        Text("Keep first").tag(MergeMetadataPolicy.keepFirst)
                        Text("Keep last").tag(MergeMetadataPolicy.keepLast)
                        Text("Clear").tag(MergeMetadataPolicy.clear)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }
            }
            .padding(12)
            .background(AppTheme.Colors.cardBackground.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
            .foregroundColor(AppTheme.Colors.primaryText)
        }
    }
}

struct MergeDestinationCard: View {
    let destinationFolderURL: URL?
    @Binding var outputFileName: String
    let onChooseDestination: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(destinationLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: onChooseDestination)
                        .buttonStyle(.bordered)
                }

                HStack {
                    Text("Output")
                    TextField("Merged.pdf", text: $outputFileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 260)
                }
            }
            .padding(12)
            .background(AppTheme.Colors.cardBackground.opacity(0.6))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(AppTheme.Colors.cardBorder.opacity(0.6), lineWidth: 0.5)
            )
            .foregroundColor(AppTheme.Colors.primaryText)
        }
    }

    private var destinationLabel: String {
        destinationFolderURL?.path ?? "Choose destination folder"
    }
}

struct MergeHistoryCard: View {
    let history: [MergeJobRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)
            if history.isEmpty {
                Text("No recent merge jobs.")
                    .font(.footnote)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(history) { job in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.outputFileName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(AppTheme.Colors.primaryText)
                                Text("\(job.sourceCount) selected → \(job.mergedDocumentCount) merged, \(job.mergedPageCount) pages")
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                Text("\(job.destinationFolder) · \(job.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                if let warning = job.warningsSummary, !warning.isEmpty {
                                    Text("Warnings: \(warning)")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(AppTheme.Colors.cardBackground.opacity(0.9))
                            )
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 180)
                .padding(10)
                .background(AppTheme.Colors.cardBackground.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppTheme.Colors.cardBorder.opacity(0.6), lineWidth: 0.5)
                )
            }
        }
    }
}

private func handleDroppedFileProviders(_ providers: [NSItemProvider], onResolvedURL: @escaping (URL) -> Void) -> Bool {
    var accepted = false
    for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        accepted = true
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "pdf" else {
                return
            }
            DispatchQueue.main.async {
                onResolvedURL(url)
            }
        }
    }
    return accepted
}
