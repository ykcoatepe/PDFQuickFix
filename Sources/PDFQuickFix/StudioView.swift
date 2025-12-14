import SwiftUI
import PDFKit
import UniformTypeIdentifiers
import Combine
import AppKit

enum StudioTool: String, CaseIterable, Identifiable {
    case organize = "Organize"
    case bookmarks = "Bookmarks"
    case comments = "Comments"
    case forms = "Forms"
    case measure = "Measure"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .organize:
            return "square.grid.2x2"
        case .bookmarks:
            return "bookmark"
        case .comments:
            return "text.bubble"
        case .forms:
            return "rectangle.and.pencil.and.ellipsis"
        case .measure:
            return "ruler"
        }
    }
}

struct StudioView: View, Equatable {
    @ObservedObject var controller: StudioController
    @Binding var selectedTab: AppMode
    @EnvironmentObject private var documentHub: SharedDocumentHub
    @Binding var selectedTool: StudioTool
    @Binding var showQuickFix: Bool
    @Binding var quickFixURL: URL?
    @State private var navSelection: Int = 0 // 0 = Pages, 1 = Outline
    
    @Binding var showingWatermarkSheet: Bool
    @Binding var showingHeaderFooterSheet: Bool
    @Binding var showingBatesSheet: Bool
    @Binding var showingCropSheet: Bool

    @State private var watermarkOptions = WatermarkOptions()
    @State private var headerFooterOptions = HeaderFooterOptions()
    @State private var batesOptions = BatesOptions()
    @State private var cropOptions = CropOptions()
    @State private var alertMessage: String?
    
    static func == (lhs: StudioView, rhs: StudioView) -> Bool {
        return lhs.controller === rhs.controller &&
               lhs.selectedTab == rhs.selectedTab &&
               lhs.selectedTool == rhs.selectedTool &&
               lhs.showQuickFix == rhs.showQuickFix &&
               lhs.quickFixURL == rhs.quickFixURL &&
               lhs.showingWatermarkSheet == rhs.showingWatermarkSheet &&
               lhs.showingHeaderFooterSheet == rhs.showingHeaderFooterSheet &&
               lhs.showingBatesSheet == rhs.showingBatesSheet &&
               lhs.showingCropSheet == rhs.showingCropSheet
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Toolbar handled by UnifiedToolbar in ContentView

                GeometryReader { proxy in
                    let layout = StudioLayout(width: proxy.size.width)

                    HStack(spacing: 0) {
                        if layout.showsLeftColumn {
                            leftColumn
                                .frame(width: layout.leftColumnWidth)
                                .background(AppTheme.Colors.sidebarBackground)
                        }

                        Divider().overlay(AppTheme.Colors.cardBorder.opacity(0.6))

                        centerColumn
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                        if layout.showsRightColumn {
                            Divider().overlay(AppTheme.Colors.cardBorder.opacity(0.6))
                            rightColumn
                                .frame(width: layout.rightColumnWidth)
                                .background(AppTheme.Colors.sidebarBackground)
                        }
                    }
                    .background(AppTheme.Colors.background)
                }

                if !controller.logMessages.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(controller.logMessages.enumerated().map({ $0 }), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.caption.monospaced())
                                    .foregroundColor(AppTheme.Colors.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .frame(height: 140)
                    .background(AppTheme.Colors.cardBackground)
                }
            }

#if DEBUG
            debugHUD
#endif
        }
        .sheet(isPresented: $showQuickFix) {
            QuickFixSheet(inputURL: Binding(
                get: { quickFixURL },
                set: { quickFixURL = $0 }
            )) { url in
                if let url {
                    controller.open(url: url)
                }
            }
            .frame(minWidth: 720, minHeight: 520)
        }
        .sheet(isPresented: $showingWatermarkSheet) {
            WatermarkSheet(options: $watermarkOptions) {
                applyWatermark()
                showingWatermarkSheet = false
            } onCancel: {
                showingWatermarkSheet = false
            }
            .frame(width: 420)
        }
        .sheet(isPresented: $showingHeaderFooterSheet) {
            HeaderFooterSheet(options: $headerFooterOptions) {
                applyHeaderFooter()
                showingHeaderFooterSheet = false
            } onCancel: {
                showingHeaderFooterSheet = false
            }
            .frame(width: 420)
        }
        .sheet(isPresented: $showingBatesSheet) {
            BatesSheet(options: $batesOptions) {
                applyBates()
                showingBatesSheet = false
            } onCancel: {
                showingBatesSheet = false
            }
            .frame(width: 420)
        }
        .sheet(isPresented: $showingCropSheet) {
            CropSheet(options: $cropOptions) {
                applyCrop()
                showingCropSheet = false
            } onCancel: {
                showingCropSheet = false
            }
            .frame(width: 360)
        }
        .alert("Studio",
               isPresented: Binding(
                    get: { alertMessage != nil },
                    set: { if !$0 { alertMessage = nil } }
               ),
               presenting: alertMessage) { _ in
            Button("OK", role: .cancel) {
                alertMessage = nil
            }
        } message: { message in
            Text(message)
        }
        .environmentObject(controller)
        .onDrop(of: [.fileURL, .pdf], isTargeted: nil) { providers in
            handlePDFDrop(providers) { url in
                controller.open(url: url)
            }
        }
        .onAppear {
            syncFromHub()
        }
        .onChange(of: documentHub.currentURL) { _ in
            syncFromHub()
        }
        .onChange(of: controller.sourceURL) { url in
            guard let url, url != documentHub.currentURL else { return }
            if documentHub.syncEnabled {
                documentHub.update(url: url, from: .studio)
            }
        }
        .focusedSceneValue(\.fileExportable, controller)
        .focusedSceneValue(\.pdfActionable, controller)
        .focusedSceneValue(\.studioToolSwitchable, controller)
    }

    private var modeBar: some View {
        ZStack {
            AppModeSwitcher(currentMode: $selectedTab)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.Colors.cardBackground)
        .overlay(Divider(), alignment: .bottom)
    }

    private func syncFromHub() {
        guard documentHub.syncEnabled,
              documentHub.lastSource == .reader,
              let target = documentHub.currentURL,
              controller.sourceURL != target else { return }
        
        // Anti-Gravity: Try to resolve a security scope from Recents if available,
        // to ensure we have long-lived access.
        if let recent = RecentFilesManager.shared.find(url: target),
           let resolved = try? RecentFilesManager.shared.resolveForOpen(recent) {
            // Use the resolved URL and scope
            controller.open(url: resolved.url, access: resolved.access)
        } else {
            // Fallback (might fail sandbox check if not already open)
            controller.open(url: target)
        }
    }

    // MARK: - Columns

    private var leftColumn: some View {
        VStack(spacing: 10) {
            Picker("", selection: $navSelection) {
                Text("Pages").tag(0)
                Text("Outline").tag(1)
            }
            .pickerStyle(.segmented)

            if navSelection == 0 {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(controller.pageSnapshots) { snapshot in
                            pageRow(for: snapshot)
                                .onAppear { controller.ensureThumbnail(for: snapshot.index) }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                outlineList
            }

            if controller.isMassiveDocument {
                Text("Thumbnails disabled for massive documents.")
                    .font(.caption2)
                    .foregroundColor(AppTheme.Colors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Spacer()
        }
        .padding(10)
        .foregroundColor(AppTheme.Colors.primaryText)
    }

    private var centerColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            centerHeader

            Group {
                if let doc = controller.document {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                                    .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
                            )

                        StudioPDFViewRepresented(document: doc, controller: controller) { view in
                            controller.attach(pdfView: view)
                        }
                        .background(AppTheme.Colors.background)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous))
                        .contextMenu {
                            Button {
                                controller.rotateCurrentPageLeft()
                            } label: {
                                Label("Rotate Left", systemImage: "rotate.left")
                            }
                            
                            Button {
                                controller.rotateCurrentPageRight()
                            } label: {
                                Label("Rotate Right", systemImage: "rotate.right")
                            }
                            
                            if controller.selectedAnnotation != nil {
                                Divider()
                                Button(role: .destructive) {
                                    controller.deleteSelectedAnnotation()
                                } label: {
                                    Label("Delete Annotation", systemImage: "trash")
                                }
                            }
                        }

                        if selectedTool == .measure {
                            MeasureOverlay()
                                .padding()
                        }

                        if controller.isDocumentLoading {
                            Color.black.opacity(0.08)
                            LoadingOverlayView(status: controller.loadingStatus ?? "Loading…")
                        }
                        
                        // Performance mode banner for massive documents
                        if controller.isMassiveDocument {
                            VStack {
                                HStack(spacing: 8) {
                                    Image(systemName: "bolt.fill")
                                        .foregroundColor(.yellow)
                                    Text("Performance Mode • \(doc.pageCount) pages")
                                        .font(.caption.weight(.medium))
                                    Spacer()
                                    if let url = controller.currentURL {
                                        Button("Open in Preview") {
                                            NSWorkspace.shared.open(url)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial)
                                .cornerRadius(8)
                                .padding(12)
                                
                                Spacer()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    emptyPlaceholder
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.Colors.background)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Annotations")
                    .font(.headline)
                Spacer()
            }

            if controller.isLargeDocument {
                Text("Annotation listing disabled for large documents. Navigate to pages to inspect.")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.annotationRows) { row in
                            annotationRow(row)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(12)
        .foregroundColor(AppTheme.Colors.primaryText)
    }

    // MARK: - Pieces

    private func pageRow(for snapshot: PageSnapshot) -> some View {
        let isSelected = controller.selectedPageIDs.contains(snapshot.index)
        return HStack(spacing: 10) {
            if let thumb = snapshot.thumbnail {
                Image(decorative: thumb, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 52, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(AppTheme.Colors.cardBorder, lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.Colors.cardBackground.opacity(0.8))
                    Text("Pg \(snapshot.index + 1)")
                        .font(.caption2)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                        .padding(4)
                }
                .frame(width: 52, height: 72)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if controller.isThumbnailsLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? AppTheme.Colors.cardBackground.opacity(0.8) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.6) : AppTheme.Colors.cardBorder, lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            controller.selectedPageIDs = [snapshot.index]
            controller.goTo(page: snapshot.index)
        }
    }

    @ViewBuilder
    private var outlineList: some View {
        if controller.outlineRows.isEmpty {
            VStack(spacing: 12) {
                if controller.isMassiveDocument {
                    Text("Outline loading deferred for performance")
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                    Button("Load Outline") {
                        controller.loadOutlineIfNeeded()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("No outline available.")
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)
        } else {
            OutlineTreeView(rows: controller.outlineRows, pdfView: controller.pdfView)
        }
    }

    private var centerHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle)
                    .font(.headline)
                if let status = controller.validationStatus {
                    Text(status)
                        .font(.caption)
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }
            }

            Spacer()

            Button {
                selectedTool = (selectedTool == .measure ? .organize : .measure)
            } label: {
                Label(selectedTool == .measure ? "Exit Measure" : "Measure", systemImage: "ruler")
            }
            .buttonStyle(.bordered)
            .tint(.accentColor)
            .disabled(controller.document == nil)
            
            // Rotation Buttons
            HStack(spacing: 0) {
                Button {
                    controller.rotateCurrentPageLeft()
                } label: {
                    Image(systemName: "rotate.left")
                }
                .buttonStyle(.bordered)
                .disabled(controller.document == nil)
                
                Button {
                    controller.rotateCurrentPageRight()
                } label: {
                    Image(systemName: "rotate.right")
                }
                .buttonStyle(.bordered)
                .disabled(controller.document == nil)
            }
        }
        .foregroundColor(AppTheme.Colors.primaryText)
    }

    private func annotationRow(_ row: AnnotationRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Page \(row.pageIndex + 1)")
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
            }
            if let contents = row.annotation.contents, !contents.isEmpty {
                Text(contents)
                    .font(.caption)
                    .foregroundColor(AppTheme.Colors.secondaryText)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                Button {
                    controller.focus(annotation: row)
                } label: {
                    Label("Go", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    controller.delete(annotation: row)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.Colors.cardBackground)
        )
    }

    private var pageTitle: String {
        guard let doc = controller.document else { return "No document" }
        let current: Int? = {
            if let selected = controller.selectedPageIDs.sorted().first { return selected }
            if let view = controller.pdfView, let page = view.currentPage {
                let idx = doc.index(for: page)
                return idx >= 0 ? idx : nil
            }
            return nil
        }()
        if let idx = current {
            return "Page \(idx + 1) of \(doc.pageCount)"
        } else {
            return "Page 1 of \(doc.pageCount)"
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.badge.gearshape")
                .font(.system(size: 48))
                .foregroundColor(AppTheme.Colors.secondaryText)
            Text("Open or drop a PDF to begin")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)
            Button("Open File", action: openFile)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Toolbar handled by UnifiedToolbar

    @ViewBuilder
    private var inspectorPanel: some View {
        switch selectedTool {
        case .organize:
            PageOrganizerView()
        case .bookmarks:
            OutlinePanel()
        case .comments:
            CommentsPanel()
        case .forms:
            FormsDesigner()
        case .measure:
            EmptyView()
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.open(url: url)
        }
    }

    private func save() {
        guard let document = controller.document else { return }
        if let url = controller.currentURL {
            if document.write(to: url) {
                controller.pushLog("Saved \(url.lastPathComponent)")
            } else {
                alertMessage = "Could not save to \(url.path)."
            }
        } else {
            saveAs()
        }
    }

    private func saveAs() {
        guard let document = controller.document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = controller.currentURL?.lastPathComponent ?? "PDFQuickFix.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            if document.write(to: url) {
                controller.setDocument(document, url: url)
                controller.pushLog("Exported to \(url.lastPathComponent)")
            } else {
                alertMessage = "Unable to export document."
            }
        }
    }

    private func applyWatermark() {
        do {
            try controller.applyWatermark(text: watermarkOptions.text,
                                          fontSize: CGFloat(watermarkOptions.fontSize),
                                          color: NSColor(watermarkOptions.color),
                                          opacity: CGFloat(watermarkOptions.opacity),
                                          rotation: CGFloat(watermarkOptions.rotation),
                                          position: watermarkOptions.position,
                                          margin: CGFloat(watermarkOptions.margin))
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyHeaderFooter() {
        do {
            try controller.applyHeaderFooter(header: headerFooterOptions.header,
                                             footer: headerFooterOptions.footer,
                                             margin: CGFloat(headerFooterOptions.margin),
                                             fontSize: CGFloat(headerFooterOptions.fontSize))
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyBates() {
        do {
            try controller.applyBatesNumbers(prefix: batesOptions.prefix,
                                             start: batesOptions.start,
                                             digits: batesOptions.digits,
                                             placement: batesOptions.placement,
                                             margin: CGFloat(batesOptions.margin),
                                             fontSize: CGFloat(batesOptions.fontSize))
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func applyCrop() {
        do {
            try controller.crop(inset: CGFloat(cropOptions.inset),
                                target: cropOptions.target)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func runOptimize() {
        do {
            let data = try controller.optimize()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            let baseName = controller.currentURL?.deletingPathExtension().lastPathComponent ?? "Optimized"
            panel.nameFieldStringValue = baseName + "-optimized.pdf"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

#if DEBUG
    private var debugHUD: some View {
        let info = controller.debugInfo
        return VStack(alignment: .trailing, spacing: 4) {
            Text("Pages: \(info.pageCount)")
            let large = info.isLargeDocument ? "yes" : "no"
            let massive = info.isMassiveDocument ? "yes" : "no"
            Text("Large: \(large)")
            Text("Massive: \(massive)")
            Text("Render queue: \(info.renderQueueOps)")
            Text("Tracked ops: \(info.renderTrackedOps)")
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .padding(6)
        .background(.black.opacity(0.65))
        .foregroundColor(.white)
        .cornerRadius(6)
        .padding()
    }
#endif
}

struct StudioPDFViewRepresented: NSViewRepresentable {
    var document: PDFDocument?
    var controller: StudioController
    var didCreate: (PDFView) -> Void

    func makeCoordinator() -> () {
    }

    func makeNSView(context: Context) -> PDFView {
        let view = StudioPDFView()
        view.controller = controller
        view.wantsLayer = true
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = false
        
        didCreate(view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            nsView.autoScales = true
        }
    }
}

class StudioPDFView: PDFView {
    weak var controller: StudioController?
    private var trackingArea: NSTrackingArea?
    private var isDraggingAnnotation: Bool = false

    override func mouseDown(with event: NSEvent) {
        if let controller = controller, controller.handleMouseDown(in: self, with: event) {
            isDraggingAnnotation = true
        } else {
            isDraggingAnnotation = false
            super.mouseDown(with: event)
        }
    }
    
    override func mouseDragged(with event: NSEvent) {
        if isDraggingAnnotation {
            controller?.handleMouseDragged(in: self, with: event)
        } else {
            super.mouseDragged(with: event)
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        if isDraggingAnnotation {
            controller?.handleMouseUp(in: self, with: event)
            isDraggingAnnotation = false
        } else {
            super.mouseUp(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .activeAlways]
        trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea!)
    }
    
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let cursor = controller?.cursor(for: point, in: self) {
            cursor.set()
        } else {
            super.mouseMoved(with: event)
        }
    }
    
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            controller?.deselectAnnotation()
        } else if event.keyCode == 51 || event.keyCode == 117 { // Delete or Forward Delete
            controller?.deleteSelectedAnnotation()
        } else {
            super.keyDown(with: event)
        }
    }
    
    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(delete(_:)) {
            return controller?.selectedAnnotation != nil
        }
        return super.responds(to: aSelector)
    }
    
    @IBAction func delete(_ sender: Any?) {
        controller?.deleteSelectedAnnotation()
    }
    

    @objc private func rotateLeft(_ sender: Any?) {
        controller?.rotateCurrentPageLeft()
    }
    
    @objc private func rotateRight(_ sender: Any?) {
        controller?.rotateCurrentPageRight()
    }
}

// MARK: - Option Models & Sheets

struct WatermarkOptions {
    var text: String = "CONFIDENTIAL"
    var fontSize: Double = 42
    var opacity: Double = 0.25
    var rotation: Double = -30
    var position: WatermarkPosition = .center
    var margin: Double = 48
    var color: Color = .red
}

struct HeaderFooterOptions {
    var header: String = "PDFQuickFix Studio"
    var footer: String = ""
    var margin: Double = 36
    var fontSize: Double = 11
}

struct BatesOptions {
    var prefix: String = "PQF-"
    var start: Int = 1
    var digits: Int = 6
    var placement: BatesPlacement = .footer
    var margin: Double = 24
    var fontSize: Double = 11
}

struct CropOptions {
    var inset: Double = 12
    var target: CropTarget = .allPages
}

private struct WatermarkSheet: View {
    @Binding var options: WatermarkOptions
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watermark")
                .font(.title3)
                .bold()

            TextField("Text", text: $options.text)
            ColorPicker("Color", selection: $options.color)

            HStack {
                Stepper("Font size \(Int(options.fontSize)) pt", value: $options.fontSize, in: 16...120, step: 4)
                Stepper("Opacity \(Int(options.opacity * 100))%", value: $options.opacity, in: 0.1...1, step: 0.05)
            }

            HStack {
                Stepper("Rotation \(Int(options.rotation))°", value: $options.rotation, in: -90...90, step: 5)
                Stepper("Margin \(Int(options.margin)) pt", value: $options.margin, in: 0...144, step: 8)
            }

            Picker("Position", selection: $options.position) {
                ForEach(WatermarkPosition.allCases) { position in
                    Text(position.rawValue).tag(position)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct HeaderFooterSheet: View {
    @Binding var options: HeaderFooterOptions
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Header & Footer")
                .font(.title3)
                .bold()

            TextField("Header", text: $options.header)
            TextField("Footer", text: $options.footer)

            HStack {
                Stepper("Font size \(Int(options.fontSize)) pt", value: $options.fontSize, in: 9...24, step: 1)
                Stepper("Margin \(Int(options.margin)) pt", value: $options.margin, in: 12...96, step: 6)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct BatesSheet: View {
    @Binding var options: BatesOptions
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bates Numbering")
                .font(.title3)
                .bold()

            TextField("Prefix", text: $options.prefix)

            HStack {
                Stepper("Start \(options.start)", value: $options.start, in: 0...999999)
                Stepper("Digits \(options.digits)", value: $options.digits, in: 3...8)
            }

            Picker("Placement", selection: $options.placement) {
                ForEach(BatesPlacement.allCases) { placement in
                    Text(placement.rawValue.capitalized).tag(placement)
                }
            }

            HStack {
                Stepper("Font size \(Int(options.fontSize)) pt", value: $options.fontSize, in: 8...18)
                Stepper("Margin \(Int(options.margin)) pt", value: $options.margin, in: 12...96, step: 6)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

private struct CropSheet: View {
    @Binding var options: CropOptions
    let onApply: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crop Pages")
                .font(.title3)
                .bold()

            Stepper("Inset \(Int(options.inset)) pt", value: $options.inset, in: 4...120, step: 4)

            Picker("Target Pages", selection: $options.target) {
                ForEach(CropTarget.allCases) { target in
                    Text(target.rawValue).tag(target)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Apply", action: onApply)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

// MARK: - Layout helper

private struct StudioLayout {
    let width: CGFloat

    var showsLeftColumn: Bool { true }
    var showsRightColumn: Bool { width > 1200 }

    var leftColumnWidth: CGFloat {
        max(220, min(260, width * 0.22))
    }

    var rightColumnWidth: CGFloat {
        width > 1200 ? 260 : 0
    }
}

// MARK: - Collapsible Outline Tree

struct OutlineTreeView: View {
    let rows: [OutlineRow]
    weak var pdfView: PDFView?
    
    @State private var expandedIds: Set<ObjectIdentifier> = []
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(topLevelItems, id: \.id) { item in
                    OutlineNodeView(
                        item: item,
                        allRows: rows,
                        expandedIds: $expandedIds,
                        pdfView: pdfView
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }
    
    private var topLevelItems: [OutlineRow] {
        rows.filter { $0.depth == 0 }
    }
}

private struct OutlineNodeView: View {
    let item: OutlineRow
    let allRows: [OutlineRow]
    @Binding var expandedIds: Set<ObjectIdentifier>
    weak var pdfView: PDFView?
    
    private var isExpanded: Bool {
        expandedIds.contains(item.id)
    }
    
    private var children: [OutlineRow] {
        // Find children: items that follow this one with depth = item.depth + 1
        // until we hit another item at same depth or lower
        guard let startIndex = allRows.firstIndex(where: { $0.id == item.id }) else { return [] }
        var result: [OutlineRow] = []
        for i in (startIndex + 1)..<allRows.count {
            let row = allRows[i]
            if row.depth <= item.depth { break }
            if row.depth == item.depth + 1 {
                result.append(row)
            }
        }
        return result
    }
    
    private var hasChildren: Bool {
        !children.isEmpty
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // Disclosure indicator
                if hasChildren {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if isExpanded {
                                expandedIds.remove(item.id)
                            } else {
                                expandedIds.insert(item.id)
                            }
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(AppTheme.Colors.secondaryText)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer().frame(width: 14)
                }
                
                // Label
                Text(item.outline.label ?? "Untitled")
                    .font(.caption)
                    .fontWeight(item.depth == 0 ? .semibold : .regular)
                    .foregroundColor(AppTheme.Colors.primaryText)
                    .lineLimit(2)
                
                Spacer()
                
                // Navigate button
                Button {
                    if let dest = item.outline.destination {
                        pdfView?.go(to: dest)
                    }
                } label: {
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.Colors.secondaryText)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(item.depth == 0 ? AppTheme.Colors.cardBackground : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if let dest = item.outline.destination {
                    pdfView?.go(to: dest)
                }
            }
            
            // Children (when expanded)
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(children, id: \.id) { child in
                        OutlineNodeView(
                            item: child,
                            allRows: allRows,
                            expandedIds: $expandedIds,
                            pdfView: pdfView
                        )
                        .padding(.leading, 16)
                    }
                }
            }
        }
    }
}
