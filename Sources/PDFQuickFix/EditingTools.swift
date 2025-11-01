import PDFKit
import AppKit

enum EditingTools {
    static func addFreeText(in view: PDFView?, text: String = "Text") {
        guard let page = view?.currentPage else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 100, y: bounds.midY - 18, width: 200, height: 36)
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        annotation.color = .black
        annotation.contents = text
        annotation.backgroundColor = NSColor.white.withAlphaComponent(0.0001)
        page.addAnnotation(annotation)
    }

    static func addRectangle(in view: PDFView?, filled: Bool = false) {
        guard let page = view?.currentPage else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 120, y: bounds.midY - 60, width: 240, height: 120)
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.color = NSColor.systemBlue
        if filled {
            annotation.interiorColor = NSColor.systemBlue.withAlphaComponent(0.15)
        }
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
    }

    static func addOval(in view: PDFView?, filled: Bool = false) {
        guard let page = view?.currentPage else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 80, y: bounds.midY - 80, width: 160, height: 160)
        let annotation = PDFAnnotation(bounds: rect, forType: .circle, withProperties: nil)
        annotation.color = NSColor.systemPink
        if filled {
            annotation.interiorColor = NSColor.systemPink.withAlphaComponent(0.15)
        }
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
    }

    static func addLine(in view: PDFView?) {
        guard let page = view?.currentPage else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: min(bounds.midX - 100, bounds.midX + 100),
                          y: min(bounds.midY - 20, bounds.midY + 20),
                          width: abs(200),
                          height: abs(40))
        let annotation = PDFAnnotation(bounds: rect, forType: .line, withProperties: nil)
        annotation.color = NSColor.systemRed
        annotation.startPoint = CGPoint(x: rect.minX, y: rect.minY)
        annotation.endPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
    }

    static func addArrow(in view: PDFView?) {
        guard let page = view?.currentPage else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 120, y: bounds.midY - 20, width: 240, height: 40)
        let annotation = PDFAnnotation(bounds: rect,
                                       forType: .line,
                                       withProperties: [PDFAnnotationKey.lineEndingStyles: [PDFAnnotationLineEndingStyle.none,
                                                                                            PDFAnnotationLineEndingStyle.closedArrow]])
        annotation.color = NSColor.systemGreen
        annotation.startPoint = CGPoint(x: rect.minX, y: rect.minY)
        annotation.endPoint = CGPoint(x: rect.maxX, y: rect.maxY)
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
    }

    static func addLink(in view: PDFView?, urlString: String = "https://example.com") {
        guard let page = view?.currentPage,
              let url = URL(string: urlString) else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 80, y: bounds.midY - 20, width: 160, height: 40)
        let annotation = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
        annotation.url = url
        annotation.color = NSColor.systemOrange
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
    }

    static func addSampleInk(in view: PDFView?) {
        guard let page = view?.currentPage else { return }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 120, y: bounds.midY - 60, width: 240, height: 120)
        let annotation = PDFAnnotation(bounds: rect, forType: .ink, withProperties: nil)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: rect.minX + 10, y: rect.minY + 10))
        path.curve(to: CGPoint(x: rect.maxX - 10, y: rect.maxY - 10),
                   controlPoint1: CGPoint(x: rect.midX - 40, y: rect.minY + 80),
                   controlPoint2: CGPoint(x: rect.midX + 40, y: rect.maxY - 80))
        annotation.add(path)
        annotation.color = NSColor.systemPurple
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
    }
}
