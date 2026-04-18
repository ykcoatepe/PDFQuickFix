import XCTest
import PDFCore

final class PDFCoreLexerTests: XCTestCase {
    func testHexStringTokenDecodesAscii() {
        let lexer = PDFCoreLexer(data: Data("<48656C6C6F>".utf8))

        guard let token = lexer.nextToken(), case .string(let value) = token else {
            return XCTFail("Expected string token")
        }

        XCTAssertEqual(value, "Hello")
    }

    func testHexStringTokenPadsOddLength() {
        let lexer = PDFCoreLexer(data: Data("<6162634>".utf8))

        guard let token = lexer.nextToken(), case .string(let value) = token else {
            return XCTFail("Expected string token")
        }

        XCTAssertEqual(value, "abc@")
    }

    func testParserDecodesHexStringInDictionary() throws {
        let header = "%PDF-1.4\n"
        let obj1 = "1 0 obj\n<< /Type /Catalog /Title <6162634> >>\nendobj\n"

        let offset1 = header.count
        var data = Data()
        data.append(header.data(using: .ascii)!)
        data.append(obj1.data(using: .ascii)!)

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
        data.append(xref.data(using: .ascii)!)

        let parser = PDFCoreParser(data: data)
        let doc = try parser.parseDocument()

        guard let catalog = doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)],
              case .dict(let dict) = catalog,
              let titleToken = dict["Title"],
              case .string(let title) = titleToken else {
            return XCTFail("Expected decoded Title string")
        }

        XCTAssertEqual(title, "abc@")
    }
}
