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

    func testShareReadinessReviewRequestsGroundedJSON() {
        let prompt = LocalAITask.shareReadinessReview.prompt(input: "Passport number AB123", parameters: LocalAITaskParameters())

        XCTAssertTrue(prompt.expectsJSON)
        XCTAssertTrue(prompt.text.contains("Do not override PDFQuickFix's deterministic health status."))
        XCTAssertTrue(prompt.text.contains("readiness_hint"))
        XCTAssertTrue(LocalAITask.shareReadinessReview.supportsPageSelection)
    }

    func testRedactionCandidatesTaskRequestsHumanReviewedJSON() {
        let prompt = LocalAITask.redactionCandidates.prompt(input: "SSN 123-45-6789", parameters: LocalAITaskParameters())

        XCTAssertTrue(prompt.expectsJSON)
        XCTAssertTrue(prompt.text.contains("propose redaction candidates for a human editor"))
        XCTAssertTrue(prompt.text.contains("Do not claim that text has been redacted."))
        XCTAssertTrue(prompt.text.contains("must_review_manually"))
        XCTAssertTrue(LocalAITask.redactionCandidates.supportsPageSelection)
    }
}
