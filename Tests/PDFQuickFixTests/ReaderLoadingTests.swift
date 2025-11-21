import XCTest
import Combine
import PDFKit
@testable import PDFQuickFix

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
            .compactMap { $0 }
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

    func testStudioControllerOpenCompletes() throws {
        let controller = StudioController()
        controller.attach(pdfView: PDFView())
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Studio")
        let expectation = expectation(description: "Studio controller finished loading PDF")

        controller.$document
            .compactMap { $0 }
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

    func testValidationRunnerCompletesWork() throws {
        let runner = DocumentValidationRunner()
        let pdfURL = try TestPDFBuilder.makeSimplePDF(text: "Runner")

        let openExpectation = expectation(description: "Open completes")
        DispatchQueue.main.async {
            runner.openDocument(at: pdfURL, completion: { result in
                switch result {
                case .success(let doc):
                    XCTAssertEqual(doc.pageCount, 1)
                case .failure(let error):
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
                case .success(let doc):
                    XCTAssertEqual(doc.pageCount, 1)
                case .failure(let error):
                    XCTFail("Validation failed: \(error)")
                }
                validationExpectation.fulfill()
            })
        }
        wait(for: [validationExpectation], timeout: 5.0)
    }
}
