import PDFCore
import XCTest

final class PDFCoreLexerTests: XCTestCase {
    func testHexStringTokenDecodesAscii() {
        let lexer = PDFCoreLexer(data: Data("<48656C6C6F>".utf8))

        guard let token = lexer.nextToken(), case let .string(value) = token else {
            return XCTFail("Expected string token")
        }

        XCTAssertEqual(value, "Hello")
    }

    func testHexStringTokenPadsOddLength() {
        let lexer = PDFCoreLexer(data: Data("<6162634>".utf8))

        guard let token = lexer.nextToken(), case let .string(value) = token else {
            return XCTFail("Expected string token")
        }

        XCTAssertEqual(value, "abc@")
    }

    func testParserDecodesHexStringInDictionary() throws {
        let header = "%PDF-1.4\n"
        let obj1 = "1 0 obj\n<< /Type /Catalog /Title <6162634> >>\nendobj\n"

        let offset1 = header.count
        var data = Data()
        try data.append(XCTUnwrap(header.data(using: .ascii)))
        try data.append(XCTUnwrap(obj1.data(using: .ascii)))

        let xrefOffset = data.count
        let xref = """
        xref
        0 2
        0000000000 65535 f 
        \(String(format: "%010d", offset1)) 00000 n 
        trailer
        << /Size 2 /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF
        """
        try data.append(XCTUnwrap(xref.data(using: .ascii)))

        let parser = PDFCoreParser(data: data)
        let doc = try parser.parseDocument()

        guard let catalog = doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)],
              case let .dict(dict) = catalog,
              let titleToken = dict["Title"],
              case let .string(title) = titleToken
        else {
            return XCTFail("Expected decoded Title string")
        }

        XCTAssertEqual(title, "abc@")
    }
}
