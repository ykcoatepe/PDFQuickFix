import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class PDFLinkOpenerTests: XCTestCase {
    func testOnlyWebAndMailLinksCanBeOpened() throws {
        let allowedLinks = [
            "https://example.com/a?b=c", "HTTP://Example.com", "mailto:someone@example.com",
            "https://xn--mnchen-3ya.de/", "http://[::1]:8080/", "http://192.168.1.10/", "https://example.com.:8443/",
            "mailto:someone@example.com?subject=Hello",
        ]
        for allowed in allowedLinks {
            XCTAssertEqual(PDFLinkPolicy.decision(for: try XCTUnwrap(URL(string: allowed))), .confirm, allowed)
        }
        let blocked = [
            "file:///Applications/Utilities/Terminal.app", "file:///etc/hosts", "smb://server/share",
            "ssh://host", "vnc://host", "afp://host", "x-apple.systempreferences:com.apple.preference.security",
            "tel:+15551234", "javascript:alert(1)", "data:text/html,hi", "ftp://host/file", "customapp://action",
            "https:///no-host", "relative/path.pdf", "https://%D0%B0pple.com/login", "mailto:?bcc=a@b.example",
            "mailto:", "http://0x7f.1/admin", "http://2130706433/", "http://127.1/", "http://0177.0.0.1/",
            "mailto:a@b.example?to=c@d.example", "mailto:a@b.example?subject=x&BCC=c@d.example",
        ]
        for refused in blocked {
            XCTAssertEqual(PDFLinkPolicy.decision(for: try XCTUnwrap(URL(string: refused))), .block, refused)
        }
    }

    func testConfirmationNamesTheRealHost() throws {
        let disguised = try XCTUnwrap(URL(string: "https://apple.com@evil.example/login"))
        XCTAssertEqual(PDFLinkPolicy.destinationSummary(for: disguised), "evil.example")
        let mail = try XCTUnwrap(URL(string: "mailto:a%40b.example?subject=x"))
        XCTAssertEqual(PDFLinkPolicy.destinationSummary(for: mail), "a@b.example")
        let international = try XCTUnwrap(URL(string: "https://xn--pple-43d.com/login"))
        XCTAssertEqual(PDFLinkPolicy.destinationSummary(for: international), "xn--pple-43d.com")
    }

    func testBlockedLinkIsNeverConfirmedOrOpened() throws {
        var asked = false, opened: [URL] = [], reported: [URL] = []
        let url = try XCTUnwrap(URL(string: "smb://attacker.example/share"))

        let outcome = PDFLinkOpener.handleClick(on: url,
                                                confirm: { _ in asked = true; return true },
                                                open: { opened.append($0) },
                                                reportBlocked: { reported.append($0) })

        XCTAssertEqual(outcome, .blocked)
        XCTAssertFalse(asked)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(reported, [url])
    }

    func testWebLinkOpensOnlyAfterConfirmation() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        var opened: [URL] = []

        XCTAssertEqual(PDFLinkOpener.handleClick(on: url, confirm: { _ in false }, open: { opened.append($0) },
                                                 reportBlocked: { _ in }), .declined)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(PDFLinkOpener.handleClick(on: url, confirm: { _ in true }, open: { opened.append($0) },
                                                 reportBlocked: { _ in }), .opened)
        XCTAssertEqual(opened, [url])
    }

    /// The delegate must be on every view the controller is given, not only on
    /// views configured after a document loads: a view without it lets PDFKit
    /// open document links itself.
    func testEveryAttachedViewGetsTheLinkDelegate() {
        let reader = ReaderControllerPro()
        let readerView = PDFView()
        reader.pdfView = readerView
        XCTAssertTrue(readerView.delegate === reader)
        let replacement = PDFView()
        reader.pdfView = replacement
        XCTAssertTrue(replacement.delegate === reader)

        let studio = StudioController()
        let studioView = PDFView()
        studio.attach(pdfView: studioView)
        XCTAssertTrue(studioView.delegate === studio)
    }

    /// Without these delegate methods PDFKit opens the link itself.
    func testReaderAndStudioTakeOverLinkClicks() {
        let click = #selector(PDFViewDelegate.pdfViewWillClick(onLink:with:))
        let remote = #selector(PDFViewDelegate.pdfViewOpenPDF(_:forRemoteGoToAction:))
        for controller in [ReaderControllerPro(), StudioController()] as [NSObject] {
            XCTAssertTrue(controller.responds(to: click), "\(type(of: controller))")
            XCTAssertTrue(controller.responds(to: remote), "\(type(of: controller))")
        }
    }
}
