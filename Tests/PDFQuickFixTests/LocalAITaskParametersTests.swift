@testable import PDFQuickFix
import XCTest

final class LocalAITaskParametersTests: XCTestCase {
    func testTargetLanguageDefaultsToEnglishWhenBlank() {
        let parameters = LocalAITaskParameters(targetLanguage: "   ", extractionFields: [])
        XCTAssertEqual(parameters.targetLanguage, "English")
    }

    func testExtractionFieldsTrimmedAndFiltered() {
        let parameters = LocalAITaskParameters(targetLanguage: "German", extractionFields: [" invoice_number ", "", " total "])
        XCTAssertEqual(parameters.extractionFields, ["invoice_number", "total"])
    }

    func testPIITaskRequestsJSON() {
        let prompt = LocalAITask.piiDetection.prompt(input: "Test", parameters: LocalAITaskParameters())
        XCTAssertTrue(prompt.expectsJSON)
    }
}
