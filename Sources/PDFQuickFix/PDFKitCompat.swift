import PDFKit

extension PDFWidgetControlType {
    static var checkBoxSafe: PDFWidgetControlType? {
        // 3 çoğu SDK’da checkbox; yoksa 0 (unknown) ile fallback
        PDFWidgetControlType(rawValue: 3) ?? PDFWidgetControlType(rawValue: 0)
    }

    static var radioSafe: PDFWidgetControlType? {
        PDFWidgetControlType(rawValue: 2) ?? PDFWidgetControlType(rawValue: 0)
    }

    static var pushButtonSafe: PDFWidgetControlType? {
        PDFWidgetControlType(rawValue: 1) ?? PDFWidgetControlType(rawValue: 0)
    }
}

extension PDFWidgetCellState {
    static var offSafe: PDFWidgetCellState? {
        PDFWidgetCellState(rawValue: 0)
    }

    static var onSafe: PDFWidgetCellState? {
        PDFWidgetCellState(rawValue: 1)
    }
}

enum PDFFormBuilder {
    static func makeTextField(name: String, rect: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        annotation.widgetFieldType = .text
        annotation.fieldName = name
        annotation.backgroundColor = .white
        return annotation
    }

    static func makeCheckbox(name: String, rect: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        annotation.widgetFieldType = .button
        annotation.fieldName = name
        if let control = PDFWidgetControlType.checkBoxSafe {
            annotation.widgetControlType = control
        }
        if let offState = PDFWidgetCellState.offSafe {
            annotation.buttonWidgetState = offState
        }
        annotation.backgroundColor = .white.withAlphaComponent(0.85)
        return annotation
    }

    static func makeRadio(name: String, rect: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        annotation.widgetFieldType = .button
        annotation.fieldName = name
        if let control = PDFWidgetControlType.radioSafe {
            annotation.widgetControlType = control
        }
        if let offState = PDFWidgetCellState.offSafe {
            annotation.buttonWidgetState = offState
        }
        return annotation
    }

    static func makeChoice(name: String, rect: CGRect, isList: Bool) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        annotation.widgetFieldType = .choice
        annotation.fieldName = name
        annotation.isListChoice = isList
        return annotation
    }

    static func makeSignature(name: String, rect: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        annotation.widgetFieldType = .signature
        annotation.fieldName = name
        return annotation
    }
}
