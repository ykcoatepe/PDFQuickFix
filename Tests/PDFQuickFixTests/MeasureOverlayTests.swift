import CoreGraphics
import PDFKit
@testable import PDFQuickFix
import XCTest

final class MeasureOverlayTests: XCTestCase {
    func testMeasurementReadingCalculatesDistanceAndAngle() {
        let reading = PDFMeasurementReading(start: CGPoint(x: 10, y: 20),
                                            end: CGPoint(x: 82, y: 116))

        XCTAssertEqual(reading.dxPoints, 72, accuracy: 0.001)
        XCTAssertEqual(reading.dyPoints, 96, accuracy: 0.001)
        XCTAssertEqual(reading.distancePoints, 120, accuracy: 0.001)
        XCTAssertEqual(reading.angleDegrees, 53.130, accuracy: 0.01)
    }

    func testMeasurementUnitsFormatPDFPointDistances() {
        XCTAssertEqual(PDFMeasureUnit.points.format(72), "72.0 pt")
        XCTAssertEqual(PDFMeasureUnit.inches.format(72), "1.00 in")
        XCTAssertEqual(PDFMeasureUnit.millimeters.format(72), "25.4 mm")
    }

    func testMeasurementDetailsAreClipboardReady() {
        let reading = PDFMeasurementReading(start: .zero, end: CGPoint(x: 72, y: 0))

        let details = reading.details(unit: .inches)

        XCTAssertTrue(details.contains("Distance: 1.00 in"))
        XCTAssertTrue(details.contains("X: 1.00 in"))
        XCTAssertTrue(details.contains("Y: 0.00 in"))
        XCTAssertTrue(details.contains("Angle: 0.0 deg"))
    }

    @MainActor
    func testCoordinateMapperConvertsOverlayPointsIntoPDFPagePoints() throws {
        let document = PDFDocument()
        let image = NSImage(size: CGSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        image.unlockFocus()
        document.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)

        let pdfView = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        pdfView.document = document
        pdfView.displayMode = .singlePage
        pdfView.autoScales = false
        pdfView.scaleFactor = 2
        pdfView.layoutDocumentView()

        let reading = PDFMeasurementCoordinateMapper.reading(
            start: CGPoint(x: 100, y: 200),
            end: CGPoint(x: 300, y: 200),
            overlaySize: CGSize(width: 400, height: 400),
            pdfView: pdfView
        )

        XCTAssertEqual(reading.distancePoints, 100, accuracy: 2)
    }
}
