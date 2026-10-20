import Foundation
import PDFKit
@testable import PDFQuickFix
import XCTest

final class PDFFormBuilderTests: XCTestCase {
    private let bounds = CGRect(x: 20, y: 40, width: 24, height: 24)

    func testCheckboxPersistsOnOffStateWithoutRadioOrPushButtonFlags() throws {
        let checkbox = PDFFormBuilder.makeCheckbox(name: "Approved", rect: bounds)
        XCTAssertEqual(checkbox.widgetFieldType, .button)
        XCTAssertEqual(checkbox.widgetControlType, .checkBoxControl)
        XCTAssertEqual(checkbox.buttonWidgetState, .offState)
        let document = document(containing: checkbox)

        checkbox.buttonWidgetState = .onState
        let checked = try reloadedWidget(named: "Approved", from: document)
        XCTAssertEqual(checked.widgetControlType, .checkBoxControl)
        XCTAssertEqual(checked.buttonWidgetState, .onState)
        try assertSerializedFlags(checked, radio: false, pushButton: false)

        checkbox.buttonWidgetState = .offState
        let unchecked = try reloadedWidget(named: "Approved", from: document)
        XCTAssertEqual(unchecked.buttonWidgetState, .offState)
        try assertSerializedFlags(unchecked, radio: false, pushButton: false)
    }

    func testRadioPersistsSelectionWithRadioFlagAndWithoutPushButtonFlag() throws {
        let radio = PDFFormBuilder.makeRadio(name: "Priority", rect: bounds)
        XCTAssertEqual(radio.widgetFieldType, .button)
        XCTAssertEqual(radio.widgetControlType, .radioButtonControl)
        XCTAssertEqual(radio.buttonWidgetState, .offState)
        let document = document(containing: radio)

        radio.buttonWidgetState = .onState
        let restored = try reloadedWidget(named: "Priority", from: document)

        XCTAssertEqual(restored.widgetControlType, .radioButtonControl)
        XCTAssertEqual(restored.buttonWidgetState, .onState)
        try assertSerializedFlags(restored, radio: true, pushButton: false)
    }

    func testPushButtonHelperSerializesPushButtonFlagWithoutRadioFlag() throws {
        let button = PDFAnnotation(bounds: bounds, forType: .widget, withProperties: nil)
        button.widgetFieldType = .button
        button.fieldName = "Submit"
        button.widgetControlType = try XCTUnwrap(PDFWidgetControlType.pushButtonSafe)
        XCTAssertEqual(button.widgetControlType, .pushButtonControl)

        let restored = try reloadedWidget(named: "Submit", from: document(containing: button))

        XCTAssertEqual(restored.widgetControlType, .pushButtonControl)
        try assertSerializedFlags(restored, radio: false, pushButton: true)
    }

    private func document(containing annotation: PDFAnnotation) -> PDFDocument {
        let document = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 200, height: 200), for: .mediaBox)
        page.addAnnotation(annotation)
        document.insert(page, at: 0)
        return document
    }

    private func reloadedWidget(named name: String, from document: PDFDocument) throws -> PDFAnnotation {
        let data = try XCTUnwrap(document.dataRepresentation())
        let restored = try XCTUnwrap(PDFDocument(data: data))
        let page = try XCTUnwrap(restored.page(at: 0))
        return try XCTUnwrap(page.annotations.first { $0.fieldName == name })
    }

    private func assertSerializedFlags(_ annotation: PDFAnnotation,
                                       radio: Bool,
                                       pushButton: Bool,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) throws
    {
        // PDF button field flags: Radio is bit 16; Pushbutton is bit 17 (one-based).
        // Read persisted /Ff directly rather than deriving expectations from the helpers.
        let flags: Int
        if let value = annotation.value(forAnnotationKey: .widgetFieldFlags) {
            flags = try XCTUnwrap(value as? NSNumber, file: file, line: line).intValue
        } else {
            flags = 0 // Missing /Ff has the PDF default of zero.
        }
        XCTAssertEqual(flags & (1 << 15) != 0, radio, file: file, line: line)
        XCTAssertEqual(flags & (1 << 16) != 0, pushButton, file: file, line: line)
    }
}
