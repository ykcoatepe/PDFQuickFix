import Combine
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class ReaderLoadingTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testReaderControllerOpenCompletes() throws {
        let controller = ReaderControllerPro()
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Reader")
        let expectation = expectation(description: "Reader controller finished loading PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL)
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(controller.document)
        XCTAssertFalse(controller.isLoadingDocument)
    }

    func testReaderControllerOpensEncryptedPDFWithPasswordProvider() throws {
        let controller = ReaderControllerPro(passwordProvider: { _ in "user-pass" })
        let pdfURL = try makeEncryptedPDF()
        let expectation = expectation(description: "Reader controller unlocked encrypted PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL)
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(controller.document)
        XCTAssertFalse(controller.document?.isLocked ?? true)
        XCTAssertFalse(controller.isLoadingDocument)
        XCTAssertTrue(controller.skippedQuickValidation)
        XCTAssertEqual(controller.documentHealthSummary?.shareReadiness, .reviewRecommended)
        XCTAssertTrue(controller.documentHealthSummary?.issues.contains(where: { $0.title == "Quick validation was skipped" }) ?? false)

        controller.validateFully()
        XCTAssertFalse(controller.isFullValidationRunning)
        XCTAssertTrue(controller.log.contains("Full validation skipped for encrypted PDF"))
    }

    func testReaderImageExportSnapshotKeepsEncryptedPagesRenderable() throws {
        let controller = ReaderControllerPro(passwordProvider: { _ in "user-pass" })
        let pdfURL = try makeEncryptedPDF()
        let expectation = expectation(description: "Reader controller unlocked encrypted PDF for image export")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL)
        }

        wait(for: [expectation], timeout: 5.0)

        let data = try controller.imageExportSnapshotData()
        let snapshot = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse(snapshot.isEncrypted)
        XCTAssertEqual(snapshot.pageCount, 1)
        XCTAssertNotNil(snapshot.page(at: 0))
    }

    func testReaderControllerClearsExistingDocumentWhenEncryptedUnlockFails() throws {
        let controller = ReaderControllerPro(passwordProvider: { _ in "wrong-pass" })
        let view = PDFView()
        controller.pdfView = view
        let initialURL = try TestPDFBuilder.makeSimplePDF(text: "Initial")
        let encryptedURL = try makeEncryptedPDF()
        let initialOpen = expectation(description: "Reader opened initial PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in initialOpen.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: initialURL)
        }

        wait(for: [initialOpen], timeout: 5.0)
        XCTAssertNotNil(controller.document)
        XCTAssertNotNil(view.document)
        XCTAssertNotNil(controller.currentURL)
        XCTAssertNotNil(controller.sourceURL)

        let failedOpen = expectation(description: "Reader cleared state after encrypted open failed")
        controller.$log
            .first { $0.contains("password required") }
            .sink { _ in failedOpen.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: encryptedURL)
        }

        wait(for: [failedOpen], timeout: 5.0)
        XCTAssertNil(controller.document)
        XCTAssertNil(view.document)
        XCTAssertNil(controller.currentURL)
        XCTAssertNil(controller.sourceURL)
        XCTAssertFalse(controller.isLoadingDocument)
    }

    func testStudioControllerOpenCompletes() throws {
        let controller = StudioController()
        controller.attach(pdfView: PDFView())
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Studio")
        let expectation = expectation(description: "Studio controller finished loading PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL)
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(controller.document)
        XCTAssertFalse(controller.isDocumentLoading)
    }

    func testStudioControllerOpensEncryptedPDFWithPasswordProvider() throws {
        let controller = StudioController(passwordProvider: { _ in "user-pass" })
        controller.attach(pdfView: PDFView())
        let pdfURL = try makeEncryptedPDF()
        let expectation = expectation(description: "Studio controller unlocked encrypted PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL)
        }

        wait(for: [expectation], timeout: 5.0)
        XCTAssertNotNil(controller.document)
        XCTAssertFalse(controller.document?.isLocked ?? true)
        XCTAssertFalse(controller.isDocumentLoading)
        XCTAssertTrue(controller.skippedQuickValidation)
        XCTAssertEqual(controller.documentHealthSummary?.shareReadiness, .reviewRecommended)
        XCTAssertTrue(controller.documentHealthSummary?.issues.contains(where: { $0.title == "Quick validation was skipped" }) ?? false)

        controller.runFullValidation()
        XCTAssertFalse(controller.isFullValidationRunning)
        XCTAssertTrue(controller.logMessages.contains { $0.contains("Full validation skipped for encrypted PDF") })
    }

    func testStudioImageExportSnapshotKeepsEncryptedPagesRenderable() throws {
        let controller = StudioController(passwordProvider: { _ in "user-pass" })
        controller.attach(pdfView: PDFView())
        let pdfURL = try makeEncryptedPDF()
        let expectation = expectation(description: "Studio controller unlocked encrypted PDF for image export")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: pdfURL)
        }

        wait(for: [expectation], timeout: 5.0)

        let data = try controller.imageExportSnapshotData()
        let snapshot = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse(snapshot.isEncrypted)
        XCTAssertEqual(snapshot.pageCount, 1)
        XCTAssertNotNil(snapshot.page(at: 0))
    }

    func testStudioControllerClearsExistingDocumentWhenEncryptedUnlockFails() throws {
        let controller = StudioController(passwordProvider: { _ in "wrong-pass" })
        let view = PDFView()
        controller.attach(pdfView: view)
        let initialURL = try TestPDFBuilder.makeSimplePDF(text: "Initial")
        let encryptedURL = try makeEncryptedPDF()
        let initialOpen = expectation(description: "Studio opened initial PDF")

        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in initialOpen.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: initialURL)
        }

        wait(for: [initialOpen], timeout: 5.0)
        XCTAssertNotNil(controller.document)
        XCTAssertNotNil(view.document)
        XCTAssertNotNil(controller.currentURL)
        XCTAssertNotNil(controller.sourceURL)

        let failedOpen = expectation(description: "Studio cleared state after encrypted open failed")
        controller.$logMessages
            .first { $0.contains { $0.contains("password required") } }
            .sink { _ in failedOpen.fulfill() }
            .store(in: &cancellables)

        DispatchQueue.main.async {
            controller.open(url: encryptedURL)
        }

        wait(for: [failedOpen], timeout: 5.0)
        XCTAssertNil(controller.document)
        XCTAssertNil(view.document)
        XCTAssertNil(controller.currentURL)
        XCTAssertNil(controller.sourceURL)
        XCTAssertFalse(controller.isDocumentLoading)
    }

    func testValidationRunnerCompletesWork() throws {
        let runner = DocumentValidationRunner()
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Runner")

        let openExpectation = expectation(description: "Open completes")
        DispatchQueue.main.async {
            runner.openDocument(at: pdfURL, quickValidationPageLimit: 0, completion: { result in
                switch result {
                case let .success(doc):
                    XCTAssertEqual(doc.pageCount, 1)
                case let .failure(error):
                    XCTFail("Open failed: \(error)")
                }
                openExpectation.fulfill()
            })
        }
        wait(for: [openExpectation], timeout: 5.0)

        let validationExpectation = expectation(description: "Validation completes")
        DispatchQueue.main.async {
            runner.validateDocument(at: pdfURL, pageLimit: 1, completion: { result in
                switch result {
                case let .success(doc):
                    XCTAssertEqual(doc.pageCount, 1)
                case let .failure(error):
                    XCTFail("Validation failed: \(error)")
                }
                validationExpectation.fulfill()
            })
        }
        wait(for: [validationExpectation], timeout: 5.0)
    }

    private func makeEncryptedPDF() throws -> URL {
        let sourceURL = try TestPDFBuilder.makeSimplePDF(text: "Encrypted")
        let document = try XCTUnwrap(PDFDocument(url: sourceURL))
        let data = try XCTUnwrap(PDFSecurity.encrypt(document: document, userPassword: "user-pass"))
        let encryptedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: encryptedURL, options: .atomic)
        return encryptedURL
    }
}
