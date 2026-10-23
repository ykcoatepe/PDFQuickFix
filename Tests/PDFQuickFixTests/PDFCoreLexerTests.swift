import PDFCore
import CoreGraphics
import PDFQuickFixKit
import XCTest

final class PDFCoreLexerTests: XCTestCase {
    func testLiteralEscapesDecodeContentAndPreserveNesting() {
        let cases = [
            (#"left \) right"#, "left ) right"),
            (#"left \( right"#, "left ( right"),
            (#"left \\ tail"#, "left \\ tail"),
            (#"nested (inner) \) and \\ end"#, "nested (inner) ) and \\ end"),
            (#"\101\12\0"#, "A\n\0"),
            (#"line\nnext\r\t\b\f\\\(\)"#, "line\nnext\r\t\u{08}\u{0C}\\()"),
            ("first\\\nsecond\\\r\nthird\\\rfourth", "firstsecondthirdfourth"),
            ("one\r\ntwo\rthree\nfour", "one\ntwo\nthree\nfour"),
        ]
        for (content, decoded) in cases {
            let lexer = PDFCoreLexer(data: Data(("(" + content + ") /Next").utf8))
            XCTAssertEqual(lexer.nextToken(), .string(decoded))
            XCTAssertEqual(lexer.nextToken(), .name("Next"))
        }
    }

    func testNonASCIIByteStringsKeepLiteralAndHexBytes() {
        let bytes = Data([0x41, 0x0A, 0x00, 0xFF, 0xFF])
        for source in [#"(\101\12\0\377\777)"#, "<410A00FFFF>"] {
            XCTAssertEqual(PDFCoreLexer(data: Data(source.utf8)).nextToken(), .byteString(bytes))
        }
    }

    func testParsedStringBytesSurviveCoreAndRepairRoundTrips() throws {
        let cases: [(Data, Data)] = [
            (Data(#"(\200\201\376\377)"#.utf8), Data([0x80, 0x81, 0xFE, 0xFF])),
            (Data("<8081FEFF>".utf8), Data([0x80, 0x81, 0xFE, 0xFF])),
            (Data(#"(\376\377\000A\000\050\000\351\000\051)"#.utf8), Data([0xFE, 0xFF, 0, 0x41, 0, 0x28, 0, 0xE9, 0, 0x29])),
            (Data("<FEFF0041002800E90029>".utf8), Data([0xFE, 0xFF, 0, 0x41, 0, 0x28, 0, 0xE9, 0, 0x29])),
            (Data("(é)".utf8), Data("é".utf8)),
            (Data(#"(A\000B\377C)"#.utf8), Data([0x41, 0, 0x42, 0xFF, 0x43])),
            (Data(#"(A\000B)"#.utf8), Data([0x41, 0, 0x42])),
        ]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, item) in cases.enumerated() {
            let (encoded, expected) = item
            let inputData = makeStringDocument(encoded)
            let input = directory.appendingPathComponent("input-\(index).pdf")
            let output = directory.appendingPathComponent("output-\(index).pdf")
            try inputData.write(to: input)
            let parsed = try PDFCoreParser(data: inputData).parseDocument()
            let rewritten = try PDFCoreWriter.write(document: parsed)
            let result = PDFRepairService().repairForCLI(inputURL: input, outputURL: output)
            XCTAssertEqual(result.outcome, .repaired)
            for data in [inputData, rewritten, try Data(contentsOf: output)] {
                let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
                var title: CGPDFStringRef?
                XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(document.info), "Title", &title))
                let string = try XCTUnwrap(title)
                let bytes = Data(bytes: try XCTUnwrap(CGPDFStringGetBytePtr(string)), count: CGPDFStringGetLength(string))
                XCTAssertEqual(bytes, expected)
                XCTAssertEqual(document.numberOfPages, 1)
                if expected.starts(with: [0xFE, 0xFF]) {
                    XCTAssertEqual(CGPDFStringCopyTextString(string) as String?, "A(é)")
                }
                let reparsed = try PDFCoreParser(data: data).parseDocument()
                XCTAssertNoThrow(try PDFCoreWriter.write(document: reparsed))
            }
        }
    }

    private func makeStringDocument(_ encoded: Data) -> Data {
        var info = Data("<< /Title ".utf8)
        info.append(encoded)
        info.append(Data(" >>".utf8))
        let objects = [
            Data("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8),
            Data("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] >>".utf8),
            info,
        ]
        var data = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n".utf8))
            data.append(body)
            data.append(Data("\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for offset in offsets {
            data.append(Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        data.append(Data("trailer\n<< /Size 5 /Root 1 0 R /Info 4 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

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
