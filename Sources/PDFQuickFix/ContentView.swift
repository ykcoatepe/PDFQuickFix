import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var aiSettings: LocalAISettings
    @EnvironmentObject private var aiInteractions: AIInteractionStore
    @State private var currentMode: AppMode = .reader
    @StateObject private var documentHub = SharedDocumentHub()
    @StateObject private var readerController = ReaderControllerPro()
    @StateObject private var studioController = StudioController()

    // Studio State (Lifted for Toolbar access)
    @State private var showQuickFix: Bool = false
    @State private var quickFixURL: URL?
    @State private var showingWatermarkSheet = false
    @State private var showingHeaderFooterSheet = false
    @State private var showingBatesSheet = false
    @State private var showingCropSheet = false
    @State private var showingMetadataSheet = false

    #if DEBUG
        private let cleanupReviewUITestMode: AppMode?
        @State private var cleanupReviewUITestFixtureURL: URL?
        @State private var batchEvidenceUITestWindowController: BatchSanitizeWindowController?
    #endif

    init() {
        var initialMode: AppMode = .reader
        #if DEBUG
            let requestedMode = CleanupReviewUITestSupport.requestedMode()
            cleanupReviewUITestMode = requestedMode
            initialMode = requestedMode ?? .reader
        #endif
        _currentMode = State(initialValue: initialMode)
    }

    var body: some View {
        VStack(spacing: 0) {
            UnifiedToolbar(
                selectedTab: $currentMode,
                readerController: readerController,
                studioController: studioController,
                readerSyncEnabled: $documentHub.syncEnabled,
                studioSelectedTool: $studioController.selectedTool,
                showQuickFix: $showQuickFix,
                quickFixURL: $quickFixURL,
                showingWatermarkSheet: $showingWatermarkSheet,
                showingHeaderFooterSheet: $showingHeaderFooterSheet,
                showingBatesSheet: $showingBatesSheet,
                showingCropSheet: $showingCropSheet,
                showingMetadataSheet: $showingMetadataSheet
            )
            .environmentObject(documentHub)

            ZStack {
                switch currentMode {
                case .reader:
                    ReaderProView(
                        controller: readerController,
                        selectedTab: $currentMode
                    )
                case .quickFix:
                    QuickFixTab()
                case .studio:
                    StudioView(
                        controller: studioController,
                        selectedTab: $currentMode,
                        selectedTool: $studioController.selectedTool,
                        showQuickFix: $showQuickFix,
                        quickFixURL: $quickFixURL,
                        showingWatermarkSheet: $showingWatermarkSheet,
                        showingHeaderFooterSheet: $showingHeaderFooterSheet,
                        showingBatesSheet: $showingBatesSheet,
                        showingCropSheet: $showingCropSheet,
                        showingMetadataSheet: $showingMetadataSheet
                    )
                case .split:
                    SplitView(selectedTab: $currentMode)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .environmentObject(documentHub)
        .task {
            readerController.configureCopilotAI(settings: aiSettings, interactionStore: aiInteractions)
            #if DEBUG
                prepareCleanupReviewUITestFixtureIfNeeded()
                prepareBatchEvidenceUITestWindowIfNeeded()
            #endif
        }
        .onChange(of: aiSettings.selectedProvider) { _ in
            readerController.configureCopilotAI(settings: aiSettings, interactionStore: aiInteractions)
        }
        .onChange(of: aiSettings.requestTimeoutSeconds) { _ in
            readerController.configureCopilotAI(settings: aiSettings, interactionStore: aiInteractions)
        }
        .onOpenURL { url in
            // When launched via "Open With" or file double-click
            readerController.open(url: url)
        }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
                if isCleanupReviewUITestFixtureReady {
                    Text("UI Test Fixture Ready")
                        .font(.caption2)
                        .accessibilityIdentifier("ui-test-fixture-ready")
                        .padding(4)
                }
            }
        #endif
    }

    #if DEBUG
        private var isCleanupReviewUITestFixtureReady: Bool {
            switch cleanupReviewUITestMode {
            case .reader:
                readerController.document != nil
            case .studio:
                studioController.document != nil
            case nil, .quickFix, .split:
                false
            }
        }

        private func prepareCleanupReviewUITestFixtureIfNeeded() {
            guard let mode = cleanupReviewUITestMode,
                  cleanupReviewUITestFixtureURL == nil
            else {
                return
            }
            do {
                let fixtureURL = try CleanupReviewUITestSupport.makeFixturePDF()
                cleanupReviewUITestFixtureURL = fixtureURL
                switch mode {
                case .reader:
                    readerController.open(url: fixtureURL)
                case .studio:
                    studioController.open(url: fixtureURL)
                case .quickFix, .split:
                    break
                }
            } catch {
                assertionFailure("Unable to create cleanup review UI fixture: \(error)")
            }
        }

        @MainActor
        private func prepareBatchEvidenceUITestWindowIfNeeded() {
            guard CleanupReviewUITestSupport.batchEvidenceRequested(),
                  batchEvidenceUITestWindowController == nil
            else {
                return
            }
            do {
                let viewModel = try CleanupReviewUITestSupport.makeBatchEvidenceViewModel()
                let controller = BatchSanitizeWindowController(viewModel: viewModel)
                controller.window?.level = .floating
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.window?.orderFrontRegardless()
                batchEvidenceUITestWindowController = controller
            } catch {
                assertionFailure("Unable to create batch evidence UI fixture: \(error)")
            }
        }
    #endif
}

enum AppMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case quickFix = "QuickFix"
    case studio = "Studio"
    case split = "Split"

    var id: String {
        rawValue
    }
}

struct AppModeSwitcher: View {
    @Binding var currentMode: AppMode
    var modes: [AppMode] = AppMode.switcherModes

    var body: some View {
        HStack(spacing: 6) {
            ForEach(modes) { mode in
                Button {
                    currentMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(AppTheme.Typography.bodySmall.weight(.semibold))
                        .foregroundColor(currentMode == mode ? AppTheme.Colors.primaryText : AppTheme.Colors.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minWidth: 84)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous)
                                .fill(currentMode == mode ? AppTheme.Colors.accentSoft : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.Metrics.smallCornerRadius, style: .continuous)
                                .stroke(currentMode == mode ? AppTheme.Colors.accent.opacity(0.55) : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .fill(AppTheme.Colors.elevatedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.Colors.cardBorder, lineWidth: 1)
        )
    }
}

extension AppMode {
    /// Modes shown in the top segmented control (Quick Fix handled elsewhere).
    static let switcherModes: [AppMode] = [.reader, .quickFix, .studio, .split]
}

/// Shared document coordinator so Reader can hand off the current file to Studio.
final class SharedDocumentHub: ObservableObject {
    enum Source { case reader, studio }

    @Published private(set) var currentURL: URL?
    @Published private(set) var lastSource: Source?
    @Published var syncEnabled: Bool = true

    func update(url: URL?, from source: Source) {
        if currentURL != url {
            currentURL = url
        }
        lastSource = source
    }
}

// MARK: - Unified Toolbar

struct UnifiedToolbar: View {
    @Binding var selectedTab: AppMode
    @ObservedObject var readerController: ReaderControllerPro
    @ObservedObject var studioController: StudioController
    @EnvironmentObject var documentHub: SharedDocumentHub

    // Reader State
    @Binding var readerSyncEnabled: Bool
    @State private var zoomInput: String = ""

    // Studio State
    @Binding var studioSelectedTool: StudioTool
    @Binding var showQuickFix: Bool
    @Binding var quickFixURL: URL?
    @Binding var showingWatermarkSheet: Bool
    @Binding var showingHeaderFooterSheet: Bool
    @Binding var showingBatesSheet: Bool
    @Binding var showingCropSheet: Bool
    @Binding var showingMetadataSheet: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Left Controls (Expands to push center)
            HStack {
                leftContent
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, 16)

            // Center: App Mode Switcher (Fixed center)
            AppModeSwitcher(currentMode: $selectedTab)
                .fixedSize()
                .layoutPriority(1)

            // Right Controls (Expands to push center)
            HStack {
                Spacer(minLength: 0)
                rightContent
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, 16)
        }
        .frame(height: 56)
        .background(AppTheme.Colors.sidebarBackground.ignoresSafeArea())
        .overlay(
            Rectangle()
                .fill(AppTheme.Colors.cardBorder)
                .frame(height: 1),
            alignment: .bottom
        )
    }

    // MARK: - Left Content

    @ViewBuilder
    private var leftContent: some View {
        switch selectedTab {
        case .reader:
            readerLeftControls
        case .studio:
            studioLeftControls
        case .split, .quickFix:
            EmptyView()
        }
    }

    private var readerLeftControls: some View {
        HStack(spacing: 16) {
            // Sidebar Toggle
            Button(action: {
                withAnimation {
                    readerController.isSidebarVisible.toggle()
                }
            }) {
                Image(systemName: "sidebar.left")
                    .foregroundColor(readerController.isSidebarVisible ? AppTheme.Colors.accent : AppTheme.Colors.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(readerController.document == nil)

            Divider().frame(height: 16)

            // File Operations
            Group {
                Button(action: openReaderFile) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("Open PDF…")

                Button(action: { readerController.saveDocument() }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Save")
                .disabled(readerController.document == nil)

                Button(action: { readerController.printDocument() }) {
                    Image(systemName: "printer")
                }
                .buttonStyle(.plain)
                .help("Print…")
                .disabled(readerController.document == nil)

                Menu {
                    Menu("Images") {
                        Button("JPEG") { readerController.exportToImages(format: .jpeg) }
                        Button("PNG") { readerController.exportToImages(format: .png) }
                        Button("TIFF") { readerController.exportToImages(format: .tiff) }
                    }
                    Button("Text") { readerController.exportToText() }
                    Button("Optimized PDF…") { readerController.exportOptimized() }
                    Button("Metadata-Clean PDF…") { readerController.exportMetadataCleaned() }
                    Button("Flattened PDF…") { readerController.exportFlattened() }
                    Button("Encrypted PDF…") { readerController.exportEncrypted() }
                    Divider()
                    Button("Sanitized PDF…") { readerController.exportSanitized() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 28)
                .disabled(readerController.document == nil)

                Button(action: { readerController.closeDocument() }) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Close Document")
                .disabled(readerController.document == nil)
            }

            Divider().frame(height: 16)

            // Zoom Controls
            HStack(spacing: 8) {
                Button(action: { readerController.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(readerController.document == nil)

                TextField("", text: $zoomInput)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .frame(width: 48)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { zoomInput = zoomPercentage }
                    .onChange(of: readerController.zoomScale) { _ in
                        zoomInput = zoomPercentage
                    }
                    .onSubmit { applyZoom() }
                    .disabled(readerController.document == nil)

                Button(action: { readerController.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
                .disabled(readerController.document == nil)
            }

            Divider().frame(height: 16)

            // Rotation Controls
            HStack(spacing: 8) {
                Button(action: { readerController.rotateCurrentPageLeft() }) {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(.plain)
                .help("Rotate Left")
                .disabled(readerController.document == nil)

                Button(action: { readerController.rotateCurrentPageRight() }) {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(.plain)
                .help("Rotate Right")
                .disabled(readerController.document == nil)
            }
        }
    }

    private var studioLeftControls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $documentHub.syncEnabled) {
                Image(systemName: documentHub.syncEnabled ? "link" : "link.slash")
            }
            .toggleStyle(.button)
            .help(documentHub.syncEnabled ? "Turn off Reader↔Studio sync" : "Turn on Reader↔Studio sync")

            Divider().frame(height: 16)

            // File Operations
            Group {
                Button(action: openStudioFile) {
                    Image(systemName: "folder")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Open PDF…")
                .accessibilityLabel("Open PDF")

                Button(action: { studioController.saveDocument() }) {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Save")
                .accessibilityLabel("Save")
                .disabled(studioController.document == nil)

                Button(action: { studioController.saveAs() }) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Save As…")
                .accessibilityLabel("Save As")
                .disabled(studioController.document == nil)

                Button(action: { studioController.printDocument() }) {
                    Image(systemName: "printer")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Print…")
                .accessibilityLabel("Print")
                .disabled(studioController.document == nil)

                Menu {
                    Menu("Images") {
                        Button("JPEG") { studioController.exportToImages(format: .jpeg) }
                        Button("PNG") { studioController.exportToImages(format: .png) }
                        Button("TIFF") { studioController.exportToImages(format: .tiff) }
                    }
                    Button("Text") { studioController.exportToText() }
                    Button("Optimized PDF…") { studioController.exportOptimized() }
                    Button("Metadata-Clean PDF…") { studioController.exportMetadataCleaned() }
                    Button("Flattened PDF…") { studioController.exportFlattened() }
                    Button("Encrypted PDF…") { studioController.exportEncrypted() }
                    Divider()
                    Button("Sanitized PDF…") { studioController.exportSanitized() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28, height: 28)
                .help("Export")
                .accessibilityLabel("Export")
                .disabled(studioController.document == nil)

                Button(action: { studioController.closeDocument() }) {
                    Image(systemName: "xmark.circle")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Close Document")
                .accessibilityLabel("Close Document")
                .disabled(studioController.document == nil)
            }
        }
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch selectedTab {
        case .reader:
            readerRightControls
        case .studio:
            studioRightControls
        case .split, .quickFix:
            BatchSanitizeLaunchButton(tone: .ghost)
        }
    }

    private var readerRightControls: some View {
        HStack(spacing: 16) {
            // Page Navigation
            HStack(spacing: 4) {
                Text("Page")
                TextField("", value: pageBinding, formatter: NumberFormatter())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 40)
                    .multilineTextAlignment(.center)
                    .onSubmit {
                        let target = max(pageBinding.wrappedValue - 1, 0)
                        if let page = readerController.document?.page(at: target) {
                            readerController.pdfView?.go(to: page)
                        }
                    }
                    .disabled(readerController.document == nil)
                Text("/ \(readerController.document?.pageCount ?? 0)")
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            .font(.subheadline)

            Divider().frame(height: 16)

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.Colors.secondaryText)
                TextField(
                    "Search",
                    text: Binding(
                        get: { readerController.searchQuery },
                        set: { readerController.searchQuery = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .frame(width: 120)
                .onSubmit {
                    readerController.find(readerController.searchQuery)
                }
                .onChange(of: readerController.searchQuery) { query in
                    readerController.updateSearchQueryDebounced(query)
                }

                if !readerController.searchMatches.isEmpty {
                    Text("\(readerController.currentMatchIndex.map { $0 + 1 } ?? 0)/\(readerController.searchMatches.count)")
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)

                    // Navigation arrows
                    HStack(spacing: 2) {
                        Button(action: { readerController.findPrev() }) {
                            Image(systemName: "chevron.up")
                        }
                        Button(action: { readerController.findNext() }) {
                            Image(systemName: "chevron.down")
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(AppTheme.Colors.background)
            .cornerRadius(6)

            Divider().frame(height: 16)

            Button(action: { readerController.showDocumentHealth() }) {
                Image(systemName: "cross.case")
                    .frame(width: 28, height: 28)
                    .foregroundColor(AppTheme.Colors.primaryText)
            }
            .buttonStyle(.plain)
            .help("Document Health")
            .disabled(readerController.document == nil)

            // Right Panel Toggle
            Button(action: {
                withAnimation {
                    readerController.isRightPanelVisible.toggle()
                }
            }) {
                Image(systemName: "sidebar.right")
                    .foregroundColor(readerController.isRightPanelVisible ? AppTheme.Colors.accent : AppTheme.Colors.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(readerController.document == nil)

            Divider().frame(height: 16)

            BatchSanitizeLaunchButton(tone: .ghost)
        }
    }

    private var studioRightControls: some View {
        HStack(spacing: 12) {
            Button(action: { studioController.showDocumentHealth() }) {
                Image(systemName: "cross.case")
            }
            .buttonStyle(.plain)
            .help("Document Health")
            .accessibilityLabel("Document Health")
            .disabled(studioController.document == nil)

            // Tools Menu
            Menu {
                Button("Watermark…") { showingWatermarkSheet = true }
                    .disabled(studioController.document == nil)
                Button("Header & Footer…") { showingHeaderFooterSheet = true }
                    .disabled(studioController.document == nil)
                Button("Bates Numbering…") { showingBatesSheet = true }
                    .disabled(studioController.document == nil)
                Button("Crop Pages…") { showingCropSheet = true }
                    .disabled(studioController.document == nil)
                Button("Edit Metadata…") { showingMetadataSheet = true }
                    .disabled(studioController.document == nil)
                Button("Replace Selected Text…") { studioController.replaceSelectedTextWithPrompt() }
                    .disabled(!studioController.canReplaceSelectedText)
                Button("Redact Selected Text") { studioController.redactSelectedTextWithConfirmation() }
                    .disabled(!studioController.canReplaceSelectedText)
                Divider()
                Button("Optimize Copy…") { studioController.exportOptimized() }
                    .disabled(studioController.document == nil)
                Button("Remove Metadata Copy…") { studioController.exportMetadataCleaned() }
                    .disabled(studioController.document == nil)
                Button("Flatten Copy…") { studioController.exportFlattened() }
                    .disabled(studioController.document == nil)
                Button("Encrypt Copy…") { studioController.exportEncrypted() }
                    .disabled(studioController.document == nil)
            } label: {
                Label("Tools", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .frame(height: 28)

            // Edit Tools Menu
            Menu("Edit Tools") {
                Button("Add Free Text…") {
                    if let annotation = EditingTools.addFreeTextWithPrompt(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Free Text")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Note…") {
                    if let annotation = EditingTools.addNoteWithPrompt(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Note")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Rectangle") {
                    if let annotation = EditingTools.addRectangle(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Rectangle")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Oval") {
                    if let annotation = EditingTools.addOval(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Oval")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Line") {
                    if let annotation = EditingTools.addLine(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Line")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Arrow") {
                    if let annotation = EditingTools.addArrow(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Arrow")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Link…") {
                    if let annotation = EditingTools.addLinkWithPrompt(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Link")
                    }
                    studioController.refreshAnnotations()
                }
                Button("Add Ink") {
                    if let annotation = EditingTools.addSampleInk(in: studioController.pdfView) {
                        studioController.registerAnnotationAddition(annotation, actionName: "Add Ink")
                    }
                    studioController.refreshAnnotations()
                }
            }
            .menuStyle(.borderlessButton)
            .disabled(studioController.pdfView == nil)
            .frame(height: 28)

            Divider().frame(height: 16)

            // QuickFix
            Button(action: {
                quickFixURL = studioController.currentURL
                showQuickFix = true
            }) {
                Image(systemName: "wand.and.sparkles")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Open in QuickFix")
            .accessibilityLabel("Open in QuickFix")
            .disabled(studioController.currentURL == nil)

            // Validate
            Button(action: {
                studioController.runFullValidation()
            }) {
                Image(systemName: "checkmark.shield")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Validate Document")
            .accessibilityLabel("Validate Document")
            .disabled(studioController.document == nil || studioController.isFullValidationRunning)

            Divider().frame(height: 16)

            BatchSanitizeLaunchButton(tone: .ghost)
        }
    }

    // MARK: - Helpers

    private var zoomPercentage: String {
        let scale = readerController.zoomScale
        return "\(Int(scale * 100))%"
    }

    private func applyZoom() {
        let trimmed = zoomInput.replacingOccurrences(of: "%", with: "")
        if let value = Double(trimmed) {
            readerController.setZoom(percent: value)
        }
        zoomInput = zoomPercentage
    }

    private func openReaderFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            readerController.open(url: url)
        }
    }

    private var pageBinding: Binding<Int> {
        Binding<Int>(
            get: { (readerController.currentPageIndex) + 1 },
            set: { readerController.currentPageIndex = max(0, $0 - 1) }
        )
    }

    private func openStudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            studioController.open(url: url)
        }
    }
}
