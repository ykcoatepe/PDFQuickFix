import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

final class StudioImageExporterTests: XCTestCase {
    func testRepeatedExportsPreserveExistingImagesAndProduceCompleteDistinctSets() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("Page_1.png")
        let sentinel = Data("existing user image".utf8)
        try sentinel.write(to: existing)
        let snapshot = try makeSnapshot()

        let first = try StudioImageExporter.export(snapshot: snapshot, format: .png, to: directory, documentName: "Report")
        let second = try StudioImageExporter.export(snapshot: snapshot, format: .png, to: directory, documentName: "Report")

        XCTAssertNotEqual(first.directory, second.directory)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        for export in [first, second] {
            XCTAssertEqual(export.pageCount, 2)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: export.directory.path).sorted(), ["Page_1.png", "Page_2.png"])
            for index in 1 ... 2 {
                let data = try Data(contentsOf: export.directory.appendingPathComponent("Page_\(index).png"))
                XCTAssertNotNil(NSBitmapImageRep(data: data))
            }
        }
    }

    func testWriteFailureReportsPageAndRemovesOnlyIncompleteExport() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("keep.txt")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: existing)
        var writtenPages = 0

        XCTAssertThrowsError(try StudioImageExporter.export(snapshot: makeSnapshot(), format: .png, to: directory, documentName: "Report", write: { data, url in
            writtenPages += 1
            if writtenPages == 2 { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .withoutOverwriting)
        })) { error in
            guard case let StudioImageExporter.ExportError.pageFailed(page, underlying) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(page, 2)
            XCTAssertEqual((underlying as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }

        XCTAssertEqual(writtenPages, 2, "Exercise a failure after the first image was actually written")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["keep.txt"])
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }

    func testInvalidSnapshotCreatesNoOutput() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try StudioImageExporter.export(snapshot: Data("not a PDF".utf8), format: .png, to: directory, documentName: "Report"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testNonDirectoryDestinationFailsWithoutChangingExistingFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("destination")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: existing)
        XCTAssertThrowsError(try StudioImageExporter.export(snapshot: makeSnapshot(), format: .png, to: existing, documentName: "Report"))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["destination"])
    }

    func testJPEGAndTIFFExportEveryPageAsDecodableImages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (format, suffix) in [(NSBitmapImageRep.FileType.jpeg, "jpg"), (.tiff, "tiff")] {
            let export = try StudioImageExporter.export(snapshot: makeSnapshot(), format: format, to: directory, documentName: "Report")
            XCTAssertEqual(export.pageCount, 2)
            for index in 1 ... 2 {
                let data = try Data(contentsOf: export.directory.appendingPathComponent("Page_\(index).\(suffix)"))
                XCTAssertNotNil(NSBitmapImageRep(data: data))
            }
        }
    }

    func testCroppedRotatedExportPreservesVisiblePageAndExcludesHiddenMediaContent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 120, height: 180)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &media, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.red.cgColor)
        context.fill(media) // A red sentinel lies entirely outside the visible crop.
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 20, y: 30, width: 80, height: 60))
        context.setFillColor(NSColor.blue.cgColor)
        context.fill(CGRect(x: 20, y: 90, width: 80, height: 60))
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        let page = try XCTUnwrap(document.page(at: 0))
        page.setBounds(CGRect(x: 20, y: 30, width: 80, height: 120), for: .cropBox)
        page.rotation = 90
        let snapshot = try XCTUnwrap(document.dataRepresentation())

        let export = try StudioImageExporter.export(snapshot: snapshot, format: .png, to: directory, documentName: "Cropped")
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: export.directory.appendingPathComponent("Page_1.png"))))
        XCTAssertEqual(image.pixelsWide, 120)
        XCTAssertEqual(image.pixelsHigh, 80)
        var red = 0
        var green = 0
        var blue = 0
        for y in 0 ..< image.pixelsHigh {
            for x in 0 ..< image.pixelsWide {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent < 0.2 { red += 1 }
                if color.greenComponent > 0.8, color.redComponent < 0.2, color.blueComponent < 0.2 { green += 1 }
                if color.blueComponent > 0.8, color.redComponent < 0.2, color.greenComponent < 0.2 { blue += 1 }
            }
        }
        XCTAssertEqual(red, 0, "Pixels outside the visible crop must never be disclosed by image export")
        XCTAssertGreaterThan(green, 4000)
        XCTAssertGreaterThan(blue, 4000)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("studio-image-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSnapshot() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 80, height: 100)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        for color in [NSColor.red, .green] {
            context.beginPDFPage(nil)
            context.setFillColor(color.cgColor)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
