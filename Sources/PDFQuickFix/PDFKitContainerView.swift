import SwiftUI
import PDFKit
import AppKit

struct PDFKitContainerView: NSViewRepresentable {
    @Binding var pdfDocument: PDFDocument?
    @Binding var tool: AnnotationTool
    @Binding var signatureImage: NSImage?
    @Binding var manualRedactions: [Int:[CGRect]]
    
    func makeNSView(context: Context) -> PDFCanvasView {
        let v = PDFCanvasView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = .windowBackgroundColor
        v.delegateProxy = context.coordinator
        return v
    }
    func updateNSView(_ nsView: PDFCanvasView, context: Context) {
        nsView.document = pdfDocument
        nsView.currentTool = tool
        nsView.signatureImage = signatureImage
        nsView.manualRedactionsBinding = $manualRedactions
    }
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    final class Coordinator: NSObject, PDFCanvasDelegate {
        func jumpTo(selection: PDFSelection, on view: PDFCanvasView, page: PDFPage) {
            view.go(to: selection)
            view.setCurrentSelection(selection, animate: true)
        }
    }
}

protocol PDFCanvasDelegate: AnyObject {
    func jumpTo(selection: PDFSelection, on view: PDFCanvasView, page: PDFPage)
}

final class PDFCanvasView: PDFView {
    weak var delegateProxy: PDFCanvasDelegate?
    var currentTool: AnnotationTool = .select
    var signatureImage: NSImage?
    var manualRedactionsBinding: Binding<[Int:[CGRect]]>?
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(onJumpToSelection(_:)), name: .PDFQuickFixJumpToSelection, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    
    @objc private func onJumpToSelection(_ n: Notification) {
        guard let sel = n.object as? PDFSelection else { return }
        guard let page = n.userInfo?["page"] as? PDFPage else { return }
        delegateProxy?.jumpTo(selection: sel, on: self, page: page)
    }
    
    override func mouseDown(with event: NSEvent) {
        guard let page = self.page(for: convert(event.locationInWindow, from: nil), nearest: true) else {
            super.mouseDown(with: event); return
        }
        let pt = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(pt, to: page)
        
        switch currentTool {
        case .select:
            super.mouseDown(with: event)
        case .note:
            let ann = PDFAnnotation(bounds: CGRect(x: pagePoint.x, y: pagePoint.y, width: 24, height: 24), forType: .text, withProperties: nil)
            ann.color = .systemYellow
            ann.iconType = .note
            page.addAnnotation(ann)
        case .rect:
            let w: CGFloat = 140, h: CGFloat = 60
            let rect = CGRect(x: pagePoint.x - w/2, y: pagePoint.y - h/2, width: w, height: h)
            let ann = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            ann.color = NSColor.systemRed.withAlphaComponent(0.2)
            ann.border = PDFBorder()
            ann.border?.lineWidth = 2
            page.addAnnotation(ann)
        case .highlightSelection:
            if let sel = self.currentSelection {
                for p in sel.pages {
                    let b = sel.bounds(for: p)
                    let h = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                    h.color = NSColor.systemYellow.withAlphaComponent(0.5)
                    p.addAnnotation(h)
                }
            }
        case .stamp:
            if let img = signatureImage {
                let w: CGFloat = 180
                let aspect = img.size.height / img.size.width
                let rect = CGRect(x: pagePoint.x - w/2, y: pagePoint.y - w*aspect/2, width: w, height: w*aspect)
                let ann = PDFAnnotation(bounds: rect, forType: .stamp, withProperties: nil)
                ann.image = img
                ann.color = .clear
                page.addAnnotation(ann)
            }
        case .redactBox:
            let w: CGFloat = 180, h: CGFloat = 50
            let rect = CGRect(x: pagePoint.x - w/2, y: pagePoint.y - h/2, width: w, height: h)
            let preview = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            preview.color = .black
            page.addAnnotation(preview)
            if let doc = self.document, let pageIndex = doc.index(for: page) as Int? {
                var store = manualRedactionsBinding?.wrappedValue ?? [:]
                var arr = store[pageIndex] ?? []
                arr.append(rect)
                store[pageIndex] = arr
                manualRedactionsBinding?.wrappedValue = store
            }
        }
    }
}
