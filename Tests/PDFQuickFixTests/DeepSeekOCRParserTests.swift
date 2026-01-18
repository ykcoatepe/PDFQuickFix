import XCTest
@testable import PDFQuickFix

final class DeepSeekOCRParserTests: XCTestCase {
    func testParseRunsExtractsTextAndRects() {
        let response = """
        <|ref|>text<|/ref|><|det|>[[30, 103, 280, 166]]<|/det|> Flight: TK1234
        <|ref|>text<|/ref|><|det|>[[30, 204, 422, 267]]<|/det|> Passenger: John Smith
        """

        let runs = DeepSeekOCRParser.parseRuns(response: response, imageSize: CGSize(width: 1000, height: 800))
        XCTAssertEqual(runs.count, 2)

        switch runs[0].kind {
        case .keep(let text):
            XCTAssertEqual(text, "Flight: TK1234")
        default:
            XCTFail("Expected keep run")
        }

        XCTAssertEqual(runs[0].rectInPixels.origin.x, 30, accuracy: 0.5)
        XCTAssertEqual(runs[0].rectInPixels.origin.y, 103.0 / 1000.0 * 800.0, accuracy: 0.5)
        XCTAssertEqual(runs[0].rectInPixels.size.width, (280.0 - 30.0) / 1000.0 * 1000.0, accuracy: 0.5)
        XCTAssertEqual(runs[0].rectInPixels.size.height, (166.0 - 103.0) / 1000.0 * 800.0, accuracy: 0.5)
    }
}
