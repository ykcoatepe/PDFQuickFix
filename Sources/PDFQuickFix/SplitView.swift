import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SplitView: View {
    @Binding var selectedTab: AppMode
    @StateObject private var controller = SplitController()

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
        VStack(spacing: 0) {
            // Toolbar
            ZStack {
                // Center: Mode Switcher
                AppModeSwitcher(currentMode: $selectedTab)
                
                // Left & Right Controls
                HStack {
                    Spacer()
                    // Add any right-aligned controls here if needed
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
            
            ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                fileSection
                modeSection
                destinationSection
                historySection
                footer
            }
            .padding(24)
            }
            .padding(24)
        }
        .background(AppColors.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split PDF")
                .appFont(.largeTitle, weight: .bold)
            Text("Split large PDFs into smaller parts without opening them in the viewer.")
                .appFont(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Source file")
                    .appFont(.headline, weight: .semibold)
                Spacer()
                Button("Choose…") { chooseSource() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            SplitDropZone(
                sourceURL: controller.sourceURL,
                onTap: { chooseSource() },
                onDropURL: { url in controller.setSource(url: url) }
            )
            .frame(maxWidth: .infinity, minHeight: 160)
        }
        .cardStyle()
    }

    private var historySection: some View {
        Group {
            if !controller.history.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("History")
                        .font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(controller.history.suffix(5))) { job in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(job.sourceDescription)
                                        .font(.subheadline.weight(.semibold))
                                    Text("\(job.fileCount) input file(s) → \(job.outputCount) output(s) in \(job.destinationFolder)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text("\(job.modeDescription) · \(job.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let err = job.errorSummary, !err.isEmpty {
                                        Text("Errors: \(err)")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    }
                                }
                                .padding(6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.secondary.opacity(0.06))
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 140)
                }
                .cardStyle()
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Split mode")
                .appFont(.headline, weight: .semibold)

            Picker("", selection: $controller.mode) {
                ForEach(SplitUIMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            switch controller.mode {
            case .maxPagesPerFile:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Max pages per file")
                            .appFont(.body)
                        Text("Each part will contain up to this many pages.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Pages",
                              value: $controller.maxPagesPerFile,
                              formatter: Self.integerFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
            case .numberOfParts:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Number of parts")
                            .appFont(.body)
                        Text("Split the PDF into evenly sized parts.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("Parts",
                              value: $controller.numberOfParts,
                              formatter: Self.integerFormatter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .multilineTextAlignment(.trailing)
                }
            case .approxSizeMB:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Text("Approx. size per file (MB)")
                            .appFont(.body)
                        Spacer()
                        TextField("MB",
                                  value: $controller.approxSizeMB,
                                  formatter: Self.decimalFormatter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("Uses the current file size to estimate pages per part; actual sizes may vary.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .explicitBreaks:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Page breaks")
                        .appFont(.body)
                    TextField("e.g. 1, 501, 1001", text: $controller.explicitBreaksText)
                        .textFieldStyle(.roundedBorder)
                    Text("Enter comma-separated start pages (1-based) where a new part should begin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            case .outlineChapters:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chapters from outline")
                        .appFont(.body)
                    Text("Splits at top-level outline entries (chapters).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("If the PDF has no outline, the split will fail with an error.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .cardStyle()
    }

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Destination")
                .appFont(.headline, weight: .semibold)

            HStack(spacing: 12) {
                if let dest = controller.destinationURL {
                    Text(dest.path)
                        .font(.subheadline)
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("Same folder as source")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                Spacer()
                Button("Choose…") { chooseDestination() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            Toggle(isOn: $controller.applyToAllPDFsInFolder) {
                Text("Apply to all PDFs in this folder")
            }
            .disabled(controller.sourceURL == nil)
        }
        .cardStyle()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(controller.status)
                    .font(.footnote)
                if let progress = controller.progressText {
                    Text(progress)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if controller.isWorking {
                    if let value = controller.progressValue {
                        ProgressView(value: value)
                            .progressViewStyle(.linear)
                            .tint(AppColors.primary)
                    } else {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .tint(AppColors.primary)
                    }
                }
            }

            HStack(spacing: 12) {
                if !controller.lastOutputFiles.isEmpty {
                    Button("Show in Finder") {
                        revealInFinder()
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Spacer()

                Button(action: controller.split) {
                    if controller.isWorking {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Splitting…")
                        }
                    } else {
                        Label("Split", systemImage: "scissors")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isDisabled: !controller.canSplit || controller.isWorking))
                .disabled(!controller.canSplit || controller.isWorking)
            }
        }
        .cardStyle()
    }

    private func chooseSource() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.setSource(url: url)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            controller.setDestination(url: url)
        }
    }

    private func revealInFinder() {
        guard !controller.lastOutputFiles.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(controller.lastOutputFiles)
    }
}

struct SplitDropZone: View {
    let sourceURL: URL?
    let onTap: () -> Void
    let onDropURL: (URL) -> Void

    @State private var isDragging = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AppLayout.cornerRadius)
                .stroke(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isDragging ? AppColors.primary : AppColors.border)
                .background(isDragging ? AppColors.primary.opacity(0.05) : AppColors.surface)
                .cornerRadius(AppLayout.cornerRadius)

            VStack(spacing: 8) {
                if let url = sourceURL {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 28))
                        .foregroundStyle(AppColors.primary)
                    Text(url.lastPathComponent)
                        .appFont(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(url.deletingLastPathComponent().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 28))
                        .foregroundStyle(isDragging ? AppColors.primary : .secondary)
                    Text("Drop a PDF here")
                        .appFont(.headline)
                    Text("or click to choose a file")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onDrop(of: [.fileURL, .url, .pdf], isTargeted: $isDragging) { providers in
            handlePDFDrop(providers) { url in
                onDropURL(url)
            }
        }
        .animation(.easeInOut, value: isDragging)
    }
}
