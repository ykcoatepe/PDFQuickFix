import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class StudioControllerTests: XCTestCase {
    private func makeSolidColorDocument(colors: [NSColor], size: CGSize = CGSize(width: 80, height: 80)) -> PDFDocument {
        let document = PDFDocument()

        for (index, color) in colors.enumerated() {
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()

            if let page = PDFPage(image: image) {
                document.insert(page, at: index)
            }
        }

        return document
    }

    func testDuplicateSelectedPagesPreservesOriginalIndicesForMultipleSelections() {
        let controller = StudioController()
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        controller.document = makeSolidColorDocument(colors: colors)
        controller.selectedPageIDs = [1, 3]

        XCTAssertTrue(controller.duplicateSelectedPages())
        XCTAssertEqual(controller.document?.pageCount, 6)

        let expectedColors: [NSColor] = [.red, .green, .green, .blue, .yellow, .yellow]
        for (index, expectedColor) in expectedColors.enumerated() {
            guard let page = controller.document?.page(at: index),
                  let rendered = TestPDFRenderer.render(page, size: CGSize(width: 80, height: 80)),
                  let sampled = rendered.color(at: CGPoint(x: 40, y: 40))
            else {
                XCTFail("Missing rendered page at index \(index)")
                return
            }
            XCTAssertTrue(sampled.isApproximately(expectedColor), "Unexpected color at page index \(index)")
        }
    }
}

private extension NSColor {
    func isApproximately(_ other: NSColor, tolerance: CGFloat = 0.05) -> Bool {
        let lhs = usingColorSpace(.sRGB) ?? self
        let rhs = other.usingColorSpace(.sRGB) ?? other
        return abs(lhs.redComponent - rhs.redComponent) <= tolerance &&
            abs(lhs.greenComponent - rhs.greenComponent) <= tolerance &&
            abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }
}
