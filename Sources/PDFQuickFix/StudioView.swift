import SwiftUI
import PDFKit
import UniformTypeIdentifiers

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
    @StateObject private var controller = StudioController()
    @State private var selectedTool: StudioTool = .organize
    @State private var showInspector: Bool = true
    @State private var showQuickFix: Bool = false
    @State private var quickFixURL: URL?

    @State private var showingWatermarkSheet = false
    @State private var showingHeaderFooterSheet = false
    @State private var showingBatesSheet = false
    @State private var showingCropSheet = false

    @State private var watermarkOptions = WatermarkOptions()
    @State private var headerFooterOptions = HeaderFooterOptions()
    @State private var batesOptions = BatesOptions()
    @State private var cropOptions = CropOptions()
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                HStack(spacing: 0) {
                    VStack(spacing: 12) {
                        ForEach(StudioTool.allCases) { tool in
                            Button {
                                selectedTool = tool
                                if tool == .measure {
                                    showInspector = false
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: tool.systemImage)
                                        .font(.system(size: 24))
                                    Text(tool.rawValue)
                                        .font(.caption2)
                                        .fontWeight(.medium)
                                }
                                .frame(width: 72, height: 72)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(selectedTool == tool ? AppColors.primary.opacity(0.1) : Color.clear)
                            .foregroundColor(selectedTool == tool ? AppColors.primary : .secondary)
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(selectedTool == tool ? AppColors.primary.opacity(0.2) : Color.clear, lineWidth: 1)
                            )
                        }
                        Spacer()
                    }
                    .padding(12)
                    .frame(width: 96)
                    .background(AppColors.surface)

                    Divider()

                    ZStack {
                        StudioPDFViewRepresented(document: controller.document) { view in
                            controller.attach(pdfView: view)
                        }
                        .background(Color(NSColor.textBackgroundColor))
                        .contentShape(Rectangle())

                        if selectedTool == .measure {
                            MeasureOverlay()
                                .padding()
                        }

                        if controller.isDocumentLoading {
                            ZStack {
                                Color.black.opacity(0.08)
                                LoadingOverlayView(status: controller.loadingStatus ?? "Loading…")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                        } else if controller.document == nil {
                            VStack(spacing: 16) {
                                Image(systemName: "doc.badge.gearshape")
                                    .font(.system(size: 48))
                                    .foregroundStyle(AppColors.primary.opacity(0.5))
                                Text("Open or drop a PDF to begin")
                                    .appFont(.title3)
                                    .foregroundStyle(.secondary)
                                Button("Open File", action: openFile)
                                    .buttonStyle(PrimaryButtonStyle())
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AppColors.background)
                        }
                    }

                    if showInspector && selectedTool != .measure {
                        Divider()
                        inspectorPanel
                            .frame(width: 320)
                            .background(Color(NSColor.underPageBackgroundColor))
                    }
                }
                FullscreenPDFDropView { url in
                    controller.open(url: url)
                }
            }

            if !controller.logMessages.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(controller.logMessages.enumerated().map({ $0 }), id: \.offset) { entry in
                            Text(entry.element)
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 140)
            }
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
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 0) {
                Button(action: openFile) {
                    Label("Open", systemImage: "folder")
                }
                .buttonStyle(GhostButtonStyle())
                
                Button(action: save) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(controller.document == nil)
                
                Button(action: saveAs) {
                    Label("Save As…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(controller.document == nil)
            }
            
            Divider().frame(height: 20)
            
            Button(action: {
                quickFixURL = controller.currentURL
                showQuickFix = true
            }) {
                Label("QuickFix…", systemImage: "wand.and.sparkles")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(controller.currentURL == nil)
            
            Menu {
                Button("Watermark…") { showingWatermarkSheet = true }
                    .disabled(controller.document == nil)
                Button("Header & Footer…") { showingHeaderFooterSheet = true }
                    .disabled(controller.document == nil)
                Button("Bates Numbering…") { showingBatesSheet = true }
                    .disabled(controller.document == nil)
                Button("Crop Pages…") { showingCropSheet = true }
                    .disabled(controller.document == nil)
                Divider()
                Button("Optimize…") {
                    runOptimize()
                }
                .disabled(controller.document == nil)
            } label: {
                Label("Tools", systemImage: "slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .frame(height: 28)
            
            Menu("Edit Tools") {
                Button("Add FreeText") { EditingTools.addFreeText(in: controller.pdfView) }
                Button("Add Rectangle") { EditingTools.addRectangle(in: controller.pdfView) }
                Button("Add Filled Rectangle") { EditingTools.addRectangle(in: controller.pdfView, filled: true) }
                Button("Add Oval") { EditingTools.addOval(in: controller.pdfView) }
                Button("Add Filled Oval") { EditingTools.addOval(in: controller.pdfView, filled: true) }
                Button("Add Line") { EditingTools.addLine(in: controller.pdfView) }
                Button("Add Arrow") { EditingTools.addArrow(in: controller.pdfView) }
                Button("Add Link…") {
                    let alert = NSAlert()
                    alert.messageText = "Enter link URL"
                    let textField = NSTextField(string: "https://example.com")
                    textField.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
                    alert.accessoryView = textField
                    alert.addButton(withTitle: "OK")
                    alert.addButton(withTitle: "Cancel")
                    if alert.runModal() == .alertFirstButtonReturn {
                        EditingTools.addLink(in: controller.pdfView, urlString: textField.stringValue)
                    }
                }
                Button("Add Ink (sample)") { EditingTools.addSampleInk(in: controller.pdfView) }
            }
            .menuStyle(.borderlessButton)
            .disabled(controller.pdfView == nil)
            .frame(height: 28)
            
            Button(action: {
                controller.runFullValidation()
            }) {
                Label("Validate", systemImage: "checkmark.shield")
            }
            .buttonStyle(GhostButtonStyle())
            .disabled(controller.document == nil || controller.isFullValidationRunning)
            .help("Run full validation/sanitization")
            
            if let status = controller.validationStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppColors.surface)
                    .cornerRadius(4)
            }
            
            Spacer()
            
            Toggle(isOn: $showInspector) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help("Toggle inspector")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(AppColors.surface)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(AppColors.border),
            alignment: .bottom
        )
    }

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
