import AppKit
@preconcurrency import PDFKit

enum DocumentPrintService {
    @MainActor
    static func makePrintOperation(for document: PDFDocument, jobTitle: String?) -> NSPrintOperation? {
        guard let operation = document.printOperation(for: NSPrintInfo.shared,
                                                      scalingMode: .pageScaleDownToFit,
                                                      autoRotate: true) else {
            return nil
        }
        operation.jobTitle = jobTitle ?? document.documentURL?.lastPathComponent ?? "PDFQuickFix"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    @MainActor
    @discardableResult
    static func print(document: PDFDocument?,
                      jobTitle: String?,
                      source: String,
                      showUnavailableAlert: Bool = false,
                      unavailableMessage: String = "Open a PDF in Reader or Studio, or select a printable PDF in QuickFix.") -> Bool {
        let hasDocument = (document != nil)
        debugLogInvocation(source: source, hasDocument: hasDocument)

        guard let document else {
            if showUnavailableAlert {
                presentUnavailableAlert(message: unavailableMessage)
            }
            return false
        }
        guard let operation = makePrintOperation(for: document, jobTitle: jobTitle) else {
            if showUnavailableAlert {
                presentUnavailableAlert(message: "Couldn't prepare this PDF for printing.")
            }
            return false
        }
        operation.run()
        return true
    }

    @MainActor
    static func presentUnavailableAlert(message: String = "Open a PDF in Reader or Studio, or select a printable PDF in QuickFix.") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Print Unavailable"
        alert.informativeText = message
        alert.runModal()
    }

    @MainActor
    private static func debugLogInvocation(source: String, hasDocument: Bool) {
        #if DEBUG
        let keyWindowTitle = NSApp.keyWindow?.title ?? "nil"
        NSLog("PDFPrint: source=%@ hasDocument=%@ keyWindow=%@",
              source,
              hasDocument ? "true" : "false",
              keyWindowTitle)
        #endif
    }
}

enum PrintDispatcher {
    @MainActor
    static func printActivePDFDocument(source: String) -> Bool {
        guard let (document, title) = activePrintableDocument() else { return false }
        return DocumentPrintService.print(document: document,
                                          jobTitle: title,
                                          source: source,
                                          showUnavailableAlert: false)
    }

    @MainActor
    private static func activePrintableDocument() -> (PDFDocument, String?)? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in candidates {
            if let pdfView = pdfView(from: window.firstResponder),
               let document = pdfView.document {
                return (document, document.documentURL?.lastPathComponent ?? "PDFQuickFix")
            }
            if let pdfView = findPDFView(in: window.contentView),
               let document = pdfView.document {
                return (document, document.documentURL?.lastPathComponent ?? "PDFQuickFix")
            }
        }
        return nil
    }

    private static func pdfView(from responder: NSResponder?) -> PDFView? {
        var current = responder
        while let responder = current {
            if let pdfView = responder as? PDFView {
                return pdfView
            }
            current = responder.nextResponder
        }
        return nil
    }

    private static func findPDFView(in root: NSView?) -> PDFView? {
        guard let root else { return nil }
        if let pdf = root as? PDFView {
            return pdf
        }
        for subview in root.subviews {
            if let hit = findPDFView(in: subview) {
                return hit
            }
        }
        return nil
    }
}
