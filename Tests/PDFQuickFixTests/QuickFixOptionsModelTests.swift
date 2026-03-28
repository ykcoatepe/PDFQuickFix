import XCTest
@testable import PDFQuickFix

@MainActor
final class QuickFixOptionsModelTests: XCTestCase {
    func testMakeParametersThrowsForInvalidCustomRegex() {
        let suiteName = "QuickFixOptionsModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
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
}
