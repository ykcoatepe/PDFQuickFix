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

struct StudioView: View {
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
        .onChange(of: controller.currentURL) { url in
            if documentHub.syncEnabled {
                documentHub.update(url: url, from: .studio)
            }
        }
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
              controller.currentURL != target else { return }
        controller.open(url: target)
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
                if let doc = controller.document, !controller.isMassiveDocument {
                    ZStack {
                        RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                            .fill(AppTheme.Colors.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous)
                                    .stroke(AppTheme.Colors.cardBorder, lineWidth: AppTheme.Metrics.cardBorderWidth)
                            )

                        StudioPDFViewRepresented(document: doc) { view in
                            controller.attach(pdfView: view)
                        }
                        .background(AppTheme.Colors.background)
                        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Metrics.cardCornerRadius, style: .continuous))

                        if selectedTool == .measure {
                            MeasureOverlay()
                                .padding()
                        }

                        if controller.isDocumentLoading {
                            Color.black.opacity(0.08)
                            LoadingOverlayView(status: controller.loadingStatus ?? "Loading…")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.isMassiveDocument, let url = controller.currentURL {
                    masssiveNotice(url: url)
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
            if let thumb = snapshot.thumbnail, !controller.isMassiveDocument {
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
            Text(controller.isMassiveDocument ? "Outline disabled for massive documents." : "No outline available.")
                .font(.caption)
                .foregroundColor(AppTheme.Colors.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.outlineRows) { row in
                        HStack(spacing: 8) {
                            Text(row.outline.label ?? "Untitled")
                                .foregroundColor(AppTheme.Colors.primaryText)
                            Spacer()
                            Button {
                                if let dest = row.outline.destination {
                                    controller.pdfView?.go(to: dest)
                                }
                            } label: {
                                Image(systemName: "arrow.uturn.down")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(AppTheme.Colors.cardBackground)
                        )
                        .padding(.leading, CGFloat(row.depth) * 12)
                    }
                }
            }
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

    private func masssiveNotice(url: URL) -> some View {
        VStack(spacing: 12) {
            Text("Studio is disabled for massive documents.")
                .font(.headline)
                .foregroundColor(AppTheme.Colors.primaryText)
            Text("Page count: \(controller.document?.pageCount ?? 0). Use the system viewer to browse this file.")
                .font(.subheadline)
                .foregroundColor(AppTheme.Colors.secondaryText)
            Button("Open in Preview") {
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    var didCreate: (PDFView) -> Void

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.applyPerformanceTuning(isLargeDocument: false,
                                    desiredDisplayMode: .singlePageContinuous,
                                    resetScale: true)
        didCreate(view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
        }
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
