import SwiftUI
import AppKit

struct ContentView: View {
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
                showingCropSheet: $showingCropSheet
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
                        showingCropSheet: $showingCropSheet
                    )
                case .split:
                    SplitView(selectedTab: $currentMode)
                }
            }
        }
        .frame(minWidth: 960, minHeight: 640)
        .environmentObject(documentHub)
    }
}

enum AppMode: String, CaseIterable, Identifiable {
    case reader = "Reader"
    case quickFix = "Quick Fix"
    case studio = "Studio"
    case split = "Split"
    
    var id: String { rawValue }
}

struct AppModeSwitcher: View {
    @Binding var currentMode: AppMode
    var modes: [AppMode] = AppMode.switcherModes
    
    var body: some View {
        Picker("", selection: $currentMode) {
            ForEach(modes) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(minWidth: 260)
    }
}

extension AppMode {
    /// Modes shown in the top segmented control (Quick Fix handled elsewhere).
    static let switcherModes: [AppMode] = [.reader, .studio, .split]
}

// Shared document coordinator so Reader can hand off the current file to Studio.
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
        .frame(height: 52)
        .background(AppTheme.Colors.cardBackground.ignoresSafeArea())
        .overlay(Divider(), alignment: .bottom)
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
                    .foregroundColor(readerController.isSidebarVisible ? .accentColor : AppTheme.Colors.primaryText)
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

                Button(action: { readerController.saveAs() }) {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.plain)
                .help("Save As…")
                .disabled(readerController.document == nil)
                
                Menu {
                    Menu("Images") {
                        Button("JPEG") { readerController.exportToImages(format: .jpeg) }
                        Button("PNG") { readerController.exportToImages(format: .png) }
                        Button("TIFF") { readerController.exportToImages(format: .tiff) }
                    }
                    Button("Text") { readerController.exportToText() }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20, height: 28)
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
                    Label("Open", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())
                
                Button(action: saveStudioFile) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(studioController.document == nil)
                
                Button(action: { studioController.saveAs() }) {
                    Label("Save As", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(studioController.document == nil)
                
                Menu {
                    Menu("Images") {
                        Button("JPEG") { studioController.exportToImages(format: .jpeg) }
                        Button("PNG") { studioController.exportToImages(format: .png) }
                        Button("TIFF") { studioController.exportToImages(format: .tiff) }
                    }
                    Button("Text") { studioController.exportToText() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .frame(height: 28)
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
            EmptyView()
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
            
            // Right Panel Toggle
            Button(action: {
                withAnimation {
                    readerController.isRightPanelVisible.toggle()
                }
            }) {
                Image(systemName: "sidebar.right")
                    .foregroundColor(readerController.isRightPanelVisible ? .accentColor : AppTheme.Colors.primaryText)
            }
            .buttonStyle(.plain)
            .disabled(readerController.document == nil)
        }
    }
    
    private var studioRightControls: some View {
        HStack(spacing: 12) {
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
            } label: {
                Label("Tools", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .frame(height: 28)
            
            // Edit Tools Menu
            Menu("Edit Tools") {
                Button("Add FreeText") { EditingTools.addFreeText(in: studioController.pdfView) }
                Button("Add Rectangle") { EditingTools.addRectangle(in: studioController.pdfView) }
                Button("Add Oval") { EditingTools.addOval(in: studioController.pdfView) }
                Button("Add Line") { EditingTools.addLine(in: studioController.pdfView) }
                Button("Add Arrow") { EditingTools.addArrow(in: studioController.pdfView) }
                Button("Add Ink") { EditingTools.addSampleInk(in: studioController.pdfView) }
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
                Label("QuickFix", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(studioController.currentURL == nil)
            
            // Validate
            Button(action: {
                studioController.runFullValidation()
            }) {
                Label("Validate", systemImage: "checkmark.shield")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(studioController.document == nil || studioController.isFullValidationRunning)
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
    
    private func saveStudioFile() {
        guard let document = studioController.document else { return }
        if let url = studioController.currentURL {
            if document.write(to: url) {
                studioController.pushLog("Saved \(url.lastPathComponent)")
            }
        }
    }
}
