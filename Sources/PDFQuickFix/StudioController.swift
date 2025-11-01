import Foundation
import PDFKit
import AppKit

struct PageSnapshot: Identifiable, Hashable {
    let id: Int
    let index: Int
    let thumbnail: NSImage
    let label: String
}

struct OutlineRow: Identifiable, Hashable {
    let outline: PDFOutline
    let depth: Int

    var id: ObjectIdentifier {
        ObjectIdentifier(outline)
    }
}

struct AnnotationRow: Identifiable, Hashable {
    let annotation: PDFAnnotation
    let pageIndex: Int

    var id: ObjectIdentifier {
        ObjectIdentifier(annotation)
    }

    var title: String {
        annotation.fieldName ?? annotation.userName ?? annotation.type ?? "Annotation"
    }
}

enum FormFieldKind: String, CaseIterable, Identifiable {
    case text = "Text Field"
    case checkbox = "Checkbox"
    case signature = "Signature"

    var id: String { rawValue }
}

@MainActor
final class StudioController: NSObject, ObservableObject, PDFViewDelegate {
    @Published var document: PDFDocument?
    @Published var currentURL: URL?
    @Published var pageSnapshots: [PageSnapshot] = []
    @Published var selectedPageIDs: Set<Int> = []
    @Published var outlineRows: [OutlineRow] = []
    @Published var annotationRows: [AnnotationRow] = []
    @Published var logMessages: [String] = []

    weak var pdfView: PDFView?

    func attach(pdfView: PDFView) {
        self.pdfView = pdfView
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.delegate = self
        pdfView.document = document
    }

    func open(url: URL) {
        guard let doc = PDFDocument(url: url) else { return }
        document = doc
        currentURL = url
        pdfView?.document = doc
        refreshAll()
        pushLog("Opened \(url.lastPathComponent)")
    }

    func setDocument(_ document: PDFDocument?, url: URL? = nil) {
        self.document = document
        if let url {
            currentURL = url
        }
        pdfView?.document = document
        refreshAll()
    }

    func refreshAll() {
        refreshPages()
        refreshOutline()
        refreshAnnotations()
    }

    func refreshPages() {
        guard let doc = document else {
            pageSnapshots = []
            return
        }

        var items: [PageSnapshot] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let thumbnail = page.thumbnail(of: NSSize(width: 140, height: 180), for: .mediaBox)
            items.append(PageSnapshot(id: index,
                                      index: index,
                                      thumbnail: thumbnail,
                                      label: "Page \(index + 1)"))
        }
        pageSnapshots = items
    }

    func refreshOutline() {
        guard let doc = document else {
            outlineRows = []
            return
        }
        guard let root = doc.outlineRoot else {
            outlineRows = []
            return
        }

        var rows: [OutlineRow] = []
        func walk(item: PDFOutline, depth: Int) {
            rows.append(OutlineRow(outline: item, depth: depth))
            for childIndex in 0..<item.numberOfChildren {
                if let child = item.child(at: childIndex) {
                    walk(item: child, depth: depth + 1)
                }
            }
        }

        for childIndex in 0..<root.numberOfChildren {
            if let child = root.child(at: childIndex) {
                walk(item: child, depth: 0)
            }
        }
        outlineRows = rows
    }

    func refreshAnnotations() {
        guard let doc = document else {
            annotationRows = []
            return
        }
        var rows: [AnnotationRow] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            for annotation in page.annotations {
                rows.append(AnnotationRow(annotation: annotation, pageIndex: index))
            }
        }
        annotationRows = rows
    }

    func goTo(page index: Int) {
        guard let page = document?.page(at: index) else { return }
        pdfView?.go(to: page)
    }

    func movePages(from source: IndexSet, to destination: Int) {
        guard let doc = document else { return }
        let pages = source.sorted().compactMap { doc.page(at: $0) }
        for index in source.sorted(by: >) {
            doc.removePage(at: index)
        }
        var insertIndex = destination
        for page in pages {
            if insertIndex > doc.pageCount {
                insertIndex = doc.pageCount
            }
            doc.insert(page, at: insertIndex)
            insertIndex += 1
        }
        selectedPageIDs = []
        refreshPages()
        pushLog("Reordered \(pages.count) page(s)")
    }

    func movePage(at index: Int, to newIndex: Int) {
        guard let doc = document,
              let page = doc.page(at: index),
              index != newIndex else { return }
        doc.removePage(at: index)
        let destination = max(0, min(newIndex, doc.pageCount))
        doc.insert(page, at: destination)
        selectedPageIDs = Set([destination])
        refreshPages()
        pushLog("Moved page \(index + 1) to \(destination + 1)")
    }

    @discardableResult
    func deleteSelectedPages() -> Bool {
        guard let doc = document else { return false }
        let targets = selectedPageIDs.sorted(by: >)
        guard !targets.isEmpty else { return false }
        for index in targets {
            guard index < doc.pageCount else { continue }
            doc.removePage(at: index)
        }
        selectedPageIDs = []
        refreshPages()
        pushLog("Deleted \(targets.count) page(s)")
        return true
    }

    @discardableResult
    func duplicateSelectedPages() -> Bool {
        guard let doc = document else { return false }
        let targets = selectedPageIDs.sorted()
        guard !targets.isEmpty else { return false }
        for index in targets {
            guard let page = doc.page(at: index),
                  let clone = page.copy() as? PDFPage else { continue }
            doc.insert(clone, at: index + 1)
        }
        refreshPages()
        pushLog("Duplicated \(targets.count) page(s)")
        return true
    }

    func exportSelectedPages() {
        guard let doc = document else { return }
        let targets = selectedPageIDs.sorted()
        guard !targets.isEmpty else { return }

        let exportDocument = PDFDocument()
        for (offset, index) in targets.enumerated() {
            if let page = doc.page(at: index),
               let copy = page.copy() as? PDFPage {
                exportDocument.insert(copy, at: offset)
            }
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Selection.pdf"
        if panel.runModal() == .OK, let url = panel.url {
            exportDocument.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            pushLog("Exported \(targets.count) page(s) to \(url.lastPathComponent)")
        }
    }

    func renameOutline(_ row: OutlineRow, title: String) {
        row.outline.label = title
        refreshOutline()
        pushLog("Renamed bookmark to \"\(title)\"")
    }

    func deleteOutline(_ row: OutlineRow) {
        row.outline.removeFromParent()
        refreshOutline()
        pushLog("Removed bookmark")
    }

    func addOutline(title: String) {
        guard let doc = document,
              let page = pdfView?.currentPage else { return }
        let destination = PDFDestination(page: page, at: CGPoint(x: 0, y: page.bounds(for: .mediaBox).maxY))
        let outline = PDFOutline()
        outline.label = title.isEmpty ? "Untitled" : title
        outline.destination = destination

        if let root = doc.outlineRoot {
            root.insertChild(outline, at: root.numberOfChildren)
        } else {
            let root = PDFOutline()
            root.label = doc.documentURL?.lastPathComponent ?? "Bookmarks"
            root.insertChild(outline, at: 0)
            doc.outlineRoot = root
        }
        refreshOutline()
        pushLog("Added bookmark \"\(outline.label ?? "Untitled")\"")
    }

    func focus(annotation row: AnnotationRow) {
        guard let page = row.annotation.page else { return }
        let bounds = row.annotation.bounds
        let destination = PDFDestination(page: page,
                                         at: CGPoint(x: bounds.midX, y: bounds.midY))
        pdfView?.go(to: destination)
    }

    func delete(annotation row: AnnotationRow) {
        row.annotation.page?.removeAnnotation(row.annotation)
        refreshAnnotations()
        pushLog("Removed annotation")
    }

    func addFormField(kind: FormFieldKind, name: String, rect: CGRect) {
        guard let page = pdfView?.currentPage else { return }
        let fieldName = name.isEmpty ? kind.rawValue : name
        let annotation: PDFAnnotation
        switch kind {
        case .text:
            annotation = PDFFormBuilder.makeTextField(name: fieldName, rect: rect)
            annotation.font = NSFont.systemFont(ofSize: 12)
            annotation.widgetStringValue = ""
            annotation.widgetDefaultStringValue = ""
        case .checkbox:
            annotation = PDFFormBuilder.makeCheckbox(name: fieldName, rect: rect)
        case .signature:
            annotation = PDFFormBuilder.makeSignature(name: fieldName, rect: rect)
            annotation.backgroundColor = NSColor.clear
            annotation.border?.style = .dashed
        }
        if annotation.border == nil {
            let border = PDFBorder()
            border.lineWidth = 1
            border.style = .solid
            annotation.border = border
        }
        page.addAnnotation(annotation)
        refreshAnnotations()
        pushLog("Added \(kind.rawValue)")
    }

    func applyWatermark(text: String,
                        fontSize: CGFloat,
                        color: NSColor,
                        opacity: CGFloat,
                        rotation: CGFloat,
                        position: WatermarkPosition,
                        margin: CGFloat) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.applyWatermark(document: document,
                              text: text,
                              fontSize: fontSize,
                              color: color,
                              opacity: opacity,
                              rotation: rotation,
                              position: position,
                              margin: margin)
        refreshAnnotations()
        pushLog("Watermark applied")
    }

    func applyHeaderFooter(header: String,
                           footer: String,
                           margin: CGFloat,
                           fontSize: CGFloat) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.applyHeaderFooter(document: document,
                                 header: header,
                                 footer: footer,
                                 margin: margin,
                                 fontSize: fontSize)
        refreshAnnotations()
        pushLog("Header/Footer applied")
    }

    func applyBatesNumbers(prefix: String,
                           start: Int,
                           digits: Int,
                           placement: BatesPlacement,
                           margin: CGFloat,
                           fontSize: CGFloat) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.applyBatesNumbers(document: document,
                                 prefix: prefix,
                                 start: start,
                                 digits: digits,
                                 placement: placement,
                                 margin: margin,
                                 fontSize: fontSize)
        refreshAnnotations()
        pushLog("Bates numbers applied")
    }

    func crop(inset: CGFloat, target: CropTarget) throws {
        guard let document else { throw PDFOpsError.missingDocument }
        PDFOps.crop(document: document, inset: inset, target: target)
        refreshPages()
        pushLog("Cropped pages")
    }

    func optimize() throws -> Data {
        guard let document,
              let data = PDFOps.optimize(document: document) else {
            throw PDFOpsError.missingDocument
        }
        pushLog("Optimized document (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))")
        return data
    }

    func pushLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logMessages.append("[\(timestamp)] \(message)")
    }
}
