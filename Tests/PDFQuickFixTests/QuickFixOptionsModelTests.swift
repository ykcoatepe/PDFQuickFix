@testable import PDFQuickFix
import XCTest

@MainActor
final class QuickFixOptionsModelTests: XCTestCase {
    func testMakeParametersThrowsForInvalidCustomRegex() throws {
        let suiteName = "QuickFixOptionsModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let model = QuickFixOptionsModel(defaults: defaults)
        model.customRegexText = "["

        XCTAssertThrowsError(try model.makeParameters()) { error in
            guard let quickFixError = error as? QuickFixOptionsError else {
                XCTFail("Expected QuickFixOptionsError")
                return
            }
            if case let QuickFixOptionsError.invalidCustomRegex(pattern) = quickFixError {
                XCTAssertEqual(pattern, "[")
            } else {
                XCTFail("Expected invalidCustomRegex error")
            }
        }
    }

    func testMakeAIImageOCRParametersIgnoresInvalidCustomRegex() throws {
        let suiteName = "QuickFixOptionsModelTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let model = QuickFixOptionsModel(defaults: defaults)
        model.customRegexText = "["
        model.doOCR = false
        model.langTR = false
        model.langEN = false

        let parameters = model.makeAIImageOCRParameters()

        XCTAssertFalse(parameters.options.doOCR)
        XCTAssertEqual(parameters.languages, ["en-US"])
    }

    func testQuickVerifyOutcomeMatchesOnlyWhenFixtureRecognized() {
        // Fixture text is the success case.
        XCTAssertEqual(QuickVerifyOCRSample.outcome(forText: QuickVerifyOCRSample.text), .matched)
        XCTAssertEqual(QuickVerifyOCRSample.outcome(forText: "the ocr layer works"), .matched)
    }

    func testQuickVerifyOutcomeWarnsWhenTextDetectedButWrong() {
        XCTAssertEqual(QuickVerifyOCRSample.outcome(forText: "totally unrelated words"), .textWithoutMatch)
    }

    func testQuickVerifyOutcomeFailsWhenNoText() {
        XCTAssertEqual(QuickVerifyOCRSample.outcome(forText: ""), .noText)
        XCTAssertEqual(QuickVerifyOCRSample.outcome(forText: "   \n  "), .noText)
    }
}
