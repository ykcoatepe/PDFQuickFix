import AppKit
import PDFKit

enum EditingTools {
    @discardableResult
    static func addFreeText(in view: PDFView?, text: String = "Text") -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
        let sanitizedText = PDFStringNormalizer.normalizedNonEmpty(text, context: "free text annotation") ?? "Text"
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 100, y: bounds.midY - 18, width: 200, height: 36)
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        annotation.color = .black
        annotation.contents = sanitizedText
        annotation.backgroundColor = NSColor.white.withAlphaComponent(0.0001)
        page.addAnnotation(annotation)
        return annotation
    }

    @MainActor
    static func addFreeTextWithPrompt(in view: PDFView?) -> PDFAnnotation? {
        guard view?.currentPage != nil else { return nil }
        let field = NSTextField(string: "")
        field.placeholderString = "Text"
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = "Add Free Text"
        alert.informativeText = "Enter the text to place on the current page."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return addFreeText(in: view, text: field.stringValue)
    }

    @discardableResult
    static func addNote(in view: PDFView?, text: String = "Note") -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
        let sanitizedText = PDFStringNormalizer.normalizedNonEmpty(text, context: "note annotation") ?? "Note"
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
        let annotation = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
        annotation.color = NSColor.systemYellow
        annotation.contents = sanitizedText
        page.addAnnotation(annotation)
        return annotation
    }

    @MainActor
    static func addNoteWithPrompt(in view: PDFView?) -> PDFAnnotation? {
        guard view?.currentPage != nil else { return nil }
        let field = NSTextField(string: "")
        field.placeholderString = "Note"
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = "Add Note"
        alert.informativeText = "Enter the note text for the current page."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return addNote(in: view, text: field.stringValue)
    }

    @discardableResult
    static func addRectangle(in view: PDFView?, filled: Bool = false) -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
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
        return annotation
    }

    @discardableResult
    static func addOval(in view: PDFView?, filled: Bool = false) -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
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
        return annotation
    }

    @discardableResult
    static func addLine(in view: PDFView?) -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
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
        return annotation
    }

    @discardableResult
    static func addArrow(in view: PDFView?) -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
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
        return annotation
    }

    @discardableResult
    static func addLink(in view: PDFView?, urlString: String = "https://example.com") -> PDFAnnotation? {
        guard let page = view?.currentPage,
              let url = URL(string: urlString) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        let rect = CGRect(x: bounds.midX - 80, y: bounds.midY - 20, width: 160, height: 40)
        let annotation = PDFAnnotation(bounds: rect, forType: .link, withProperties: nil)
        annotation.url = url
        annotation.color = NSColor.systemOrange
        let border = PDFBorder()
        border.lineWidth = 2
        annotation.border = border
        page.addAnnotation(annotation)
        return annotation
    }

    @MainActor
    static func addLinkWithPrompt(in view: PDFView?) -> PDFAnnotation? {
        guard view?.currentPage != nil else { return nil }
        let field = NSTextField(string: "https://")
        field.placeholderString = "https://example.com"
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = "Add Link"
        alert.informativeText = "Enter the URL for the new link annotation."
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return addLink(in: view, urlString: field.stringValue)
    }

    @discardableResult
    static func addSampleInk(in view: PDFView?) -> PDFAnnotation? {
        guard let page = view?.currentPage else { return nil }
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
        return annotation
    }
}
