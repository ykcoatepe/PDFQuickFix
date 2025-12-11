import XCTest
import PDFCore

final class PDFCoreSmokeTests: XCTestCase {
    func testPDFCoreDocumentInit() {
        let doc = PDFCoreDocument()
        XCTAssertTrue(doc.objects.isEmpty)
        XCTAssertNil(doc.rootRef)
        XCTAssertNil(doc.infoRef)
    }
    
    func testPDFCoreObjectEnum() {
        let boolObj = PDFCoreObject.bool(true)
        if case .bool(let value) = boolObj {
            XCTAssertTrue(value)
        } else {
            XCTFail("Expected bool")
        }
        
        let intObj = PDFCoreObject.int(42)
        if case .int(let value) = intObj {
            XCTAssertEqual(value, 42)
        } else {
            XCTFail("Expected int")
        }
    }
}
