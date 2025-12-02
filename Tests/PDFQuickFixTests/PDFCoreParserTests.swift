import XCTest
import PDFCore

final class PDFCoreParserTests: XCTestCase {
    
    func testParseSimplePDF() throws {
        let simplePDF = """
        %PDF-1.4
        1 0 obj
        << /Type /Catalog /Pages 2 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>
        endobj
        xref
        0 4
        0000000000 65535 f 
        0000000009 00000 n 
        0000000058 00000 n 
        0000000115 00000 n 
        trailer
        << /Size 4 /Root 1 0 R >>
        startxref
        186
        %%EOF
        """.data(using: .ascii)!
        
        let parser = PDFCoreParser(data: simplePDF)
        let doc = try parser.parseDocument()
        
        // Verify Root
        XCTAssertEqual(doc.rootRef, PDFCoreObjectRef(objectNumber: 1, generation: 0))
        
        // Verify Object Count
        // We expect objects 1, 2, 3. Object 0 is free.
        XCTAssertEqual(doc.objects.count, 3)
        
        // Verify Object 1 Content
        guard let obj1 = doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)],
              case .dict(let dict1) = obj1 else {
            XCTFail("Object 1 should be a dict")
            return
        }
        
        if case .name(let type) = dict1["Type"] {
            XCTAssertEqual(type, "Catalog")
        } else {
            XCTFail("Object 1 Type should be Name(Catalog)")
        }
        
        if case .indirectRef(let obj, let gen) = dict1["Pages"] {
            XCTAssertEqual(obj, 2)
            XCTAssertEqual(gen, 0)
        } else {
            XCTFail("Object 1 Pages should be Ref(2 0 R)")
        }
    }
    
    func testInvalidHeader() {
        let data = "Not a PDF".data(using: .ascii)!
        let parser = PDFCoreParser(data: data)
        XCTAssertThrowsError(try parser.parseDocument()) { error in
            guard let coreError = error as? PDFCoreError else {
                XCTFail("Expected PDFCoreError")
                return
            }
            XCTAssertEqual(coreError, .invalidHeader)
        }
    }
    
    func testParseXRefStream() throws {
        // Construct a PDF with XRef Stream
        // 0. Header
        let header = "%PDF-1.7\n"
        
        // 1. Object 1 (Catalog)
        let obj1 = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        
        // 2. Object 2 (Pages)
        let obj2 = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        
        // 3. Object 3 (Page)
        let obj3 = "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n"
        
        // Offsets
        let offset1 = header.count
        let offset2 = offset1 + obj1.count
        let offset3 = offset2 + obj2.count
        let offset4 = offset3 + obj3.count
        
        // XRef Stream Data
        // /W [1 2 2] -> 5 bytes per entry
        var streamBytes = Data()
        
        func appendEntry(type: UInt8, offset: Int, gen: UInt16) {
            streamBytes.append(type)
            let off16 = UInt16(offset).bigEndian
            withUnsafeBytes(of: off16) { streamBytes.append(contentsOf: $0) }
            let gen16 = gen.bigEndian
            withUnsafeBytes(of: gen16) { streamBytes.append(contentsOf: $0) }
        }
        
        // Entry 0: Free
        appendEntry(type: 0, offset: 0, gen: 65535)
        // Entry 1: Obj 1
        appendEntry(type: 1, offset: offset1, gen: 0)
        // Entry 2: Obj 2
        appendEntry(type: 1, offset: offset2, gen: 0)
        // Entry 3: Obj 3
        appendEntry(type: 1, offset: offset3, gen: 0)
        // Entry 4: Obj 4 (XRef Stream itself)
        appendEntry(type: 1, offset: offset4, gen: 0)
        
        let streamLen = streamBytes.count
        
        // 4. Object 4 (XRef Stream)
        let obj4Start = "4 0 obj\n<< /Type /XRef /Size 5 /W [1 2 2] /Root 1 0 R /Length \(streamLen) >>\nstream\n"
        let obj4End = "\nendstream\nendobj\n"
        
        var data = Data()
        data.append(header.data(using: .ascii)!)
        data.append(obj1.data(using: .ascii)!)
        data.append(obj2.data(using: .ascii)!)
        data.append(obj3.data(using: .ascii)!)
        
        // Verify offset4
        XCTAssertEqual(data.count, offset4)
        
        data.append(obj4Start.data(using: .ascii)!)
        data.append(streamBytes)
        data.append(obj4End.data(using: .ascii)!)
        
        let startXref = "startxref\n\(offset4)\n%%EOF"
        data.append(startXref.data(using: .ascii)!)
        
        // Parse
        let parser = PDFCoreParser(data: data)
        let doc = try parser.parseDocument()
        
        // Verify
        XCTAssertEqual(doc.objects.count, 4) // 1, 2, 3, 4
        XCTAssertEqual(doc.rootRef?.objectNumber, 1)
        
        // Check Obj 1
        if let o1 = doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)], case .dict(let d1) = o1 {
            if case .name(let t) = d1["Type"] {
                XCTAssertEqual(t, "Catalog")
            } else { XCTFail() }
        } else { XCTFail() }
    }
}
