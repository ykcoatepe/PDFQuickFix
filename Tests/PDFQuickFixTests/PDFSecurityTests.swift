import AppKit
import CoreGraphics
import PDFKit
@testable import PDFQuickFix
import XCTest

final class PDFSecurityTests: XCTestCase {
    func testEncryptProducesPasswordProtectedPDF() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Secret")
        let document = try XCTUnwrap(PDFDocument(url: url))

        let data = try XCTUnwrap(PDFSecurity.encrypt(
            document: document,
            userPassword: "user-pass",
            ownerPassword: "owner-pass",
            keyLength: 128
        ))
        let encrypted = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertTrue(encrypted.isLocked)
        XCTAssertFalse(encrypted.unlock(withPassword: "wrong"))
        XCTAssertTrue(encrypted.unlock(withPassword: "user-pass"))
        XCTAssertEqual(encrypted.pageCount, 1)
    }

    func testEncryptDisablesCopyingPermission() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Secret")
        let document = try XCTUnwrap(PDFDocument(url: url))

        let data = try XCTUnwrap(PDFSecurity.encrypt(
            document: document,
            userPassword: "user-pass",
            ownerPassword: "owner-pass",
            keyLength: 128
        ))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let encrypted = try XCTUnwrap(CGPDFDocument(provider))

        XCTAssertTrue(encrypted.isEncrypted)
        XCTAssertTrue(encrypted.unlockWithPassword("user-pass"))
        XCTAssertFalse(encrypted.allowsCopying)
        XCTAssertTrue(encrypted.allowsPrinting)
    }

    func testEncryptRejectsUnsupportedKeyLength() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Secret")
        let document = try XCTUnwrap(PDFDocument(url: url))

        XCTAssertNil(PDFSecurity.encrypt(
            document: document,
            userPassword: "user-pass",
            ownerPassword: "owner-pass",
            keyLength: 256
        ))
    }

    func testEncryptPreservesWhitespaceInPassword() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Secret")
        let document = try XCTUnwrap(PDFDocument(url: url))

        let data = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: " pass "))
        let encrypted = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse(encrypted.unlock(withPassword: "pass"))
        XCTAssertTrue(encrypted.unlock(withPassword: " pass "))
    }

    func testEncryptPreservesVisibleInMemoryAnnotations() throws {
        let url = try TestPDFBuilder.makeSimplePDF(text: "Annotated secret")
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 0, y: 0, width: 240, height: 240),
                                      forType: .square,
                                      withProperties: nil)
        highlight.color = .systemRed
        highlight.interiorColor = .systemRed
        highlight.contents = "Keep visible edit"
        page.addAnnotation(highlight)

        let data = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encrypted = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(encrypted.unlock(withPassword: "user-pass"))

        let encryptedPage = try XCTUnwrap(encrypted.page(at: 0))
        XCTAssertTrue(encryptedPage.annotations.contains { $0.contents == "Keep visible edit" })
    }

    func testEncryptUsesPrivacyPreservingDocumentForReplacementText() throws {
        let document = try makeTextBackedDocument(text: "Secret encrypted text")
        let page = try XCTUnwrap(document.page(at: 0))
        let cover = PDFAnnotation(bounds: CGRect(x: 20, y: 110, width: 260, height: 40),
                                  forType: .square,
                                  withProperties: nil)
        cover.color = .white
        cover.interiorColor = .white
        cover.userName = PDFOps.replacementTextAnnotationUserName
        page.addAnnotation(cover)
        let replacement = PDFAnnotation(bounds: CGRect(x: 20, y: 110, width: 260, height: 40),
                                        forType: .freeText,
                                        withProperties: nil)
        replacement.contents = "Public encrypted text"
        replacement.userName = PDFOps.replacementTextAnnotationUserName
        page.addAnnotation(replacement)

        let exportDocument = try PDFOps.privacyPreservingDocumentForExport(document)
        let data = try XCTUnwrap(PDFSecurity.encrypt(document: exportDocument, userPassword: "user-pass"))
        let encrypted = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(encrypted.unlock(withPassword: "user-pass"))

        XCTAssertFalse((encrypted.string ?? "").contains("Secret encrypted text"))
        XCTAssertTrue(encrypted.page(at: 0)?.annotations.isEmpty ?? false)
    }

    private func makeTextBackedDocument(text: String) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFSecurityTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create PDF context",
            ])
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.white.setFill()
        mediaBox.fill()
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
        ).draw(in: CGRect(x: 24, y: 120, width: 272, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PDFDocument(data: data))
    }
}
