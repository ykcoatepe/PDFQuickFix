import SwiftUI
import PDFKit
import AppKit

enum AnnotationTool {
    case select
    case note
    case rect
    case highlightSelection
    case stamp
    case redactBox
}

extension Notification.Name {
    static let PDFQuickFixJumpToSelection = Notification.Name("PDFQuickFixJumpToSelection")
}

struct PDFKitContainerView: NSViewRepresentable {
    @Binding var pdfDocument: PDFDocument?
    @Binding var tool: AnnotationTool
    @Binding var signatureImage: NSImage?
    @Binding var manualRedactions: [Int:[CGRect]]
    var isLargeDocument: Bool
    @Binding var displayMode: PDFDisplayMode
    var didCreate: ((PDFCanvasView) -> Void)? = nil
    
    func makeNSView(context: Context) -> PDFCanvasView {
        let v = PDFCanvasView()
        v.autoScales = true
        v.displayMode = displayMode
        v.displaysPageBreaks = true
        v.backgroundColor = .windowBackgroundColor
        v.enableDataDetectors = false
        v.delegateProxy = context.coordinator
        v.applyPerformanceTuning(isLargeDocument: isLargeDocument,
                                 desiredDisplayMode: displayMode,
                                 resetScale: true)
        didCreate?(v)
        return v
    }
    func updateNSView(_ nsView: PDFCanvasView, context: Context) {
        let documentChanged = nsView.document !== pdfDocument
        if documentChanged {
            let sp = PerfLog.begin("PDFViewDocumentSet")
            nsView.document = pdfDocument
            PerfLog.end("PDFViewDocumentSet", sp)
        }
        nsView.applyPerformanceTuning(isLargeDocument: isLargeDocument,
                                      desiredDisplayMode: displayMode,
                                      resetScale: documentChanged)
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

extension PDFView {
    /// Keeps PDFView responsive when dealing with very large documents by reducing layout and scaling work.
    func applyPerformanceTuning(isLargeDocument: Bool,
                                desiredDisplayMode: PDFDisplayMode,
                                resetScale: Bool) {
        displayDirection = .vertical
        displaysPageBreaks = !isLargeDocument

        let modeToApply: PDFDisplayMode = isLargeDocument ? .singlePage : desiredDisplayMode
        if displayMode != modeToApply {
            displayMode = modeToApply
        }

        // Tests construct a bare PDFView (zero-sized) before attaching to a window.
        // When bounds are empty, PDFKit reports a scaleFactorForSizeToFit of 0, which
        // then gets clamped to the default 0.1 scale and fails expectations. Give the
        // view a minimal, page-sized frame so fitting math can produce a real value.
        if resetScale,
           (bounds.width == 0 || bounds.height == 0),
           let page = document?.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let fallbackSize = CGSize(width: max(box.width, 1),
                                      height: max(box.height, 1))
            setFrameSize(fallbackSize)
            layoutSubtreeIfNeeded()
        }

        if isLargeDocument {
            autoScales = false
            guard resetScale, document != nil else { return }
            let fitScale = scaleFactorForSizeToFit
            minScaleFactor = fitScale
            maxScaleFactor = max(maxScaleFactor, fitScale * 2)
            scaleFactor = fitScale
        } else {
            autoScales = true
            guard resetScale, document != nil else { return }
            scaleFactor = scaleFactorForSizeToFit
        }
    }
}

final class ImageStampAnnotation: PDFAnnotation {
    private let signatureImage: NSImage
    private static let imageKey = "ImageStampAnnotationData"
    
    init(bounds: CGRect, image: NSImage) {
        self.signatureImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.color = .clear
    }
    
    required init?(coder: NSCoder) {
        guard
            let data = coder.decodeObject(forKey: Self.imageKey) as? Data,
            let image = NSImage(data: data)
        else {
            return nil
        }
        self.signatureImage = image
        super.init(coder: coder)
    }
    
    override func encode(with coder: NSCoder) {
        super.encode(with: coder)
        if let data = signatureImage.tiffRepresentation {
            coder.encode(data, forKey: Self.imageKey)
        }
    }
    
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        guard let cgImage = signatureImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
    
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = ImageStampAnnotation(bounds: bounds, image: signatureImage)
        copy.border = border
        copy.color = color
        return copy
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
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
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
                let ann = ImageStampAnnotation(bounds: rect, image: img)
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
