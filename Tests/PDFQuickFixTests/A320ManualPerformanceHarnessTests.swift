import Combine
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class A320ManualPerformanceHarnessTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testA320ManualOpenAndOutlineLoadingHarness() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PDFQF_PERF_PDF"], !path.isEmpty else {
            throw XCTSkip("Set PDFQF_PERF_PDF to an A320 manual PDF path to run the large-document perf harness.")
        }

        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("PDFQF_PERF_PDF does not exist: \(url.path)")
        }

        let timeout = environment.doubleValue(for: "PDFQF_PERF_TIMEOUT", default: 45)
        let readerMax = environment.optionalDoubleValue(for: "PDFQF_READER_OPEN_MAX_SECONDS")
        let studioMax = environment.optionalDoubleValue(for: "PDFQF_STUDIO_OPEN_MAX_SECONDS")
        let outlineMax = environment.optionalDoubleValue(for: "PDFQF_OUTLINE_LOAD_MAX_SECONDS")

        let reader = ReaderControllerPro()
        reader.pdfView = PDFView()
        let readerOpenSeconds = openReader(reader, url: url, timeout: timeout)

        XCTAssertNotNil(reader.document)
        XCTAssertFalse(reader.isLoadingDocument)
        XCTAssertFalse(reader.hasLoadedOutline)

        let studio = StudioController()
        studio.attach(pdfView: PDFView())
        let studioOpenSeconds = openStudio(studio, url: url, timeout: timeout)

        XCTAssertNotNil(studio.document)
        XCTAssertFalse(studio.isDocumentLoading)
        XCTAssertTrue(studio.outlineRows.isEmpty)

        let outline = try measureOutlineLoad(url: url)
        let report = String(
            format: "PDFQF manual perf: file=%@ pages=%d readerOpen=%.3fs studioOpen=%.3fs outlineLoad=%.3fs outlineRows=%d truncated=%@",
            url.lastPathComponent,
            outline.pageCount,
            readerOpenSeconds,
            studioOpenSeconds,
            outline.duration,
            outline.rows,
            outline.truncated ? "yes" : "no"
        )
        print(report)

        if let readerMax {
            XCTAssertLessThanOrEqual(readerOpenSeconds, readerMax)
        }
        if let studioMax {
            XCTAssertLessThanOrEqual(studioOpenSeconds, studioMax)
        }
        if let outlineMax {
            XCTAssertLessThanOrEqual(outline.duration, outlineMax)
        }
    }

    private func openReader(_ controller: ReaderControllerPro, url: URL, timeout: TimeInterval) -> TimeInterval {
        let opened = expectation(description: "Reader opened large manual")
        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in opened.fulfill() }
            .store(in: &cancellables)

        let start = Date()
        controller.open(url: url)
        wait(for: [opened], timeout: timeout)
        return Date().timeIntervalSince(start)
    }

    private func openStudio(_ controller: StudioController, url: URL, timeout: TimeInterval) -> TimeInterval {
        let opened = expectation(description: "Studio opened large manual")
        controller.$document
            .compactMap(\.self)
            .first()
            .sink { _ in opened.fulfill() }
            .store(in: &cancellables)

        let start = Date()
        controller.open(url: url)
        wait(for: [opened], timeout: timeout)
        return Date().timeIntervalSince(start)
    }

    private func measureOutlineLoad(url: URL) throws -> (duration: TimeInterval, rows: Int, truncated: Bool, pageCount: Int) {
        let document = try XCTUnwrap(PDFDocument(url: url))
        let start = Date()
        let result = PDFOutlineLoader.rows(from: document.outlineRoot, limit: PDFOutlineLoader.massiveDocumentRowLimit)
        return (Date().timeIntervalSince(start), result.rows.count, result.isTruncated, document.pageCount)
    }
}

private extension Dictionary where Key == String, Value == String {
    func optionalDoubleValue(for key: String) -> Double? {
        guard let raw = self[key], !raw.isEmpty else { return nil }
        return Double(raw)
    }

    func doubleValue(for key: String, default defaultValue: Double) -> Double {
        optionalDoubleValue(for: key) ?? defaultValue
    }
}
