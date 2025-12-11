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
    func testParseObjectStream() throws {
        // Construct a PDF with ObjStm
        // Header
        let header = "%PDF-1.7\n"
        
        // Obj 1: Catalog
        let obj1 = "1 0 obj\n<< /Type /Catalog /Pages 11 0 R >>\nendobj\n"
        
        // Obj 10: ObjStm
        // We need to compress the content of the object stream.
        // Content:
        // Obj 11: << /Type /Pages /Kids [12 0 R] /Count 1 >>
        // Obj 12: << /Type /Page /Parent 11 0 R >>
        
        let obj11Content = "<< /Type /Pages /Kids [12 0 R] /Count 1 >>"
        let obj12Content = "<< /Type /Page /Parent 11 0 R >>"
        
        // Index:
        // 11 0
        // 12 (obj11Content.count + 1)  (space separator)
        
        let offset11 = 0
        let offset12 = obj11Content.count + 1 // +1 for space
        
        let indexStr = "11 \(offset11) 12 \(offset12) "
        let bodyStr = "\(obj11Content) \(obj12Content)"
        let rawContent = indexStr + bodyStr
        let rawData = rawContent.data(using: .ascii)!
        
        // Compress using zlib
        let compressedData = try (rawData as NSData).compressed(using: .zlib) as Data
        
        let firstOffset = indexStr.count
        let n = 2
        
        let obj10Start = "10 0 obj\n<< /Type /ObjStm /N \(n) /First \(firstOffset) /Filter /FlateDecode /Length \(compressedData.count) >>\nstream\n"
        let obj10End = "\nendstream\nendobj\n"
        
        // Offsets will be recomputed when building data below
        // Header is 9 bytes (%PDF-1.7\n)
        // Obj 1 starts at 9.
        // Obj 1 length: "1 0 obj\n<< /Type /Catalog /Pages 11 0 R >>\nendobj\n".count
        // let obj1Str = "1 0 obj\n<< /Type /Catalog /Pages 11 0 R >>\nendobj\n"
        // 9 + obj1Str.count = start of Obj 10.
        
        var data = Data()
        data.append(header.data(using: .ascii)!)
        data.append(obj1.data(using: .ascii)!)
        let startObj10 = data.count
        
        data.append(obj10Start.data(using: .ascii)!)
        data.append(compressedData)
        data.append(obj10End.data(using: .ascii)!)
        
        let xrefOffset = data.count
        
        // Rebuild xref string with correct offsets
        let xrefStr = """
        xref
        0 11
        0000000000 65535 f 
        \(String(format: "%010d", 9)) 00000 n 
        0000000000 00000 f 
        0000000000 00000 f 
        0000000000 00000 f 
        0000000000 00000 f 
        0000000000 00000 f 
        0000000000 00000 f 
        0000000000 00000 f 
        0000000000 00000 f 
        \(String(format: "%010d", startObj10)) 00000 n 
        trailer
        << /Size 11 /Root 1 0 R >>
        startxref
        \(xrefOffset)
        %%EOF
        """
        
        data.append(xrefStr.data(using: .ascii)!)
        
        // Parse
        let parser = PDFCoreParser(data: data)
        let doc = try parser.parseDocument()
        
        // Verify
        // We expect objects 1, 10, 11, 12.
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)])
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 10, generation: 0)])
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 11, generation: 0)])
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 12, generation: 0)])
        
        // Verify Content of 11 (Pages)
        guard let o11 = doc.objects[PDFCoreObjectRef(objectNumber: 11, generation: 0)],
              case .dict(let d11) = o11 else {
            XCTFail("Obj 11 should be dict")
            return
        }
        if case .name(let t) = d11["Type"] {
            XCTAssertEqual(t, "Pages")
        } else { XCTFail() }
        
        // Verify Content of 12 (Page)
        guard let o12 = doc.objects[PDFCoreObjectRef(objectNumber: 12, generation: 0)],
              case .dict(let d12) = o12 else {
            XCTFail("Obj 12 should be dict")
            return
        }
        if case .name(let t) = d12["Type"] {
            XCTAssertEqual(t, "Page")
        } else { XCTFail() }
    }
    
    func testIncrementalUpdateClassic() throws {
        // Revision 1:
        // Obj 1: Catalog -> Pages 2
        // Obj 2: Pages -> Kids [3]
        // Obj 3: Page (MediaBox [0 0 100 100])
        
        let header = "%PDF-1.4\n"
        let obj1 = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        let obj2 = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        let obj3 = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] >>\nendobj\n"
        
        var rev1Data = Data()
        rev1Data.append(header.data(using: .ascii)!)
        rev1Data.append(obj1.data(using: .ascii)!)
        rev1Data.append(obj2.data(using: .ascii)!)
        rev1Data.append(obj3.data(using: .ascii)!)
        
        // Re-construct rev1 with exact offsets
        rev1Data = Data()
        rev1Data.append(header.data(using: .ascii)!)
        let off1 = rev1Data.count
        rev1Data.append(obj1.data(using: .ascii)!)
        let off2 = rev1Data.count
        rev1Data.append(obj2.data(using: .ascii)!)
        let off3 = rev1Data.count
        rev1Data.append(obj3.data(using: .ascii)!)
        
        let xrefOff1 = rev1Data.count
        let xref1Body = """
        xref
        0 4
        0000000000 65535 f 
        \(String(format: "%010d", off1)) 00000 n 
        \(String(format: "%010d", off2)) 00000 n 
        \(String(format: "%010d", off3)) 00000 n 
        trailer
        << /Size 4 /Root 1 0 R >>
        startxref
        \(xrefOff1)
        %%EOF
        """
        rev1Data.append(xref1Body.data(using: .ascii)!)
        
        // Revision 2:
        // Update Obj 3: MediaBox [0 0 200 200]
        // Add Obj 4: Info dict
        
        let rev2Obj3 = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] >>\nendobj\n"
        let rev2Obj4 = "4 0 obj\n<< /Title (Updated PDF) >>\nendobj\n"
        
        var data = rev1Data
        let offsetObj3 = data.count
        data.append(rev2Obj3.data(using: .ascii)!)
        
        let offsetObj4 = data.count
        data.append(rev2Obj4.data(using: .ascii)!)
        
        let xrefOffset2 = data.count
        let xref2 = """
        xref
        0 1
        0000000000 65535 f 
        3 2
        \(String(format: "%010d", offsetObj3)) 00000 n 
        \(String(format: "%010d", offsetObj4)) 00000 n 
        trailer
        << /Size 5 /Root 1 0 R /Info 4 0 R /Prev \(xrefOff1) >>
        startxref
        \(xrefOffset2)
        %%EOF
        """
        data.append(xref2.data(using: .ascii)!)
        
        // Parse
        let parser = PDFCoreParser(data: data)
        let doc = try parser.parseDocument()
        
        // Verify
        XCTAssertEqual(doc.rootRef?.objectNumber, 1)
        XCTAssertEqual(doc.infoRef?.objectNumber, 4)
        
        guard let o3 = doc.objects[PDFCoreObjectRef(objectNumber: 3, generation: 0)],
              case .dict(let d3) = o3,
              let mb = d3["MediaBox"],
              case .array(let mbArr) = mb,
              mbArr.count == 4,
              case .int(let w) = mbArr[2], w == 200 else {
            XCTFail("Obj 3 should be updated version")
            return
        }
        
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 4, generation: 0)])
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)])
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 2, generation: 0)])
    }
    
    func testIncrementalUpdateMixed() throws {
        // Base: Classic XRef
        // Update: XRef Stream
        
        let header = "%PDF-1.4\n"
        let obj1 = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"
        let obj2 = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"
        let obj3 = "3 0 obj\n<< /Type /Page /Parent 2 0 R >>\nendobj\n"
        
        var rev1Data = Data()
        rev1Data.append(header.data(using: .ascii)!)
        let off1 = rev1Data.count
        rev1Data.append(obj1.data(using: .ascii)!)
        let off2 = rev1Data.count
        rev1Data.append(obj2.data(using: .ascii)!)
        let off3 = rev1Data.count
        rev1Data.append(obj3.data(using: .ascii)!)
        
        let xrefOff1 = rev1Data.count
        let xref1Body = """
        xref
        0 4
        0000000000 65535 f 
        \(String(format: "%010d", off1)) 00000 n 
        \(String(format: "%010d", off2)) 00000 n 
        \(String(format: "%010d", off3)) 00000 n 
        trailer
        << /Size 4 /Root 1 0 R >>
        startxref
        \(xrefOff1)
        %%EOF
        """
        rev1Data.append(xref1Body.data(using: .ascii)!)
        
        var data = rev1Data
        let prevOffset = xrefOff1
        
        // Rev 2: Update Obj 3 using XRef Stream
        let obj3Updated = "3 0 obj\n<< /Type /Page /Parent 2 0 R /Rotate 90 >>\nendobj\n"
        let offsetObj3 = data.count
        data.append(obj3Updated.data(using: .ascii)!)
        
        // XRef Stream (Obj 4)
        var streamBytes = Data()
        func appendEntry(type: UInt8, offset: Int, gen: UInt16) {
            streamBytes.append(type)
            let off16 = UInt16(offset).bigEndian
            withUnsafeBytes(of: off16) { streamBytes.append(contentsOf: $0) }
            let gen16 = gen.bigEndian
            withUnsafeBytes(of: gen16) { streamBytes.append(contentsOf: $0) }
        }
        
        appendEntry(type: 1, offset: offsetObj3, gen: 0) // Obj 3
        
        let offsetObj4 = data.count
        appendEntry(type: 1, offset: offsetObj4, gen: 0) // Obj 4 (self)
        
        let streamLen = streamBytes.count
        let preStream = "4 0 obj\n<< /Type /XRef /Size 5 /W [1 2 2] /Root 1 0 R /Prev \(prevOffset) /Index [3 2] /Length \(streamLen) >>\nstream\n"
        let obj4End = "\nendstream\nendobj\n"
        
        data.append(preStream.data(using: .ascii)!)
        data.append(streamBytes)
        data.append(obj4End.data(using: .ascii)!)
        
        let startXref = "startxref\n\(offsetObj4)\n%%EOF"
        data.append(startXref.data(using: .ascii)!)
        
        // Parse
        let parser = PDFCoreParser(data: data)
        let doc = try parser.parseDocument()
        
        // Verify
        guard let o3 = doc.objects[PDFCoreObjectRef(objectNumber: 3, generation: 0)],
              case .dict(let d3) = o3,
              let rot = d3["Rotate"],
              case .int(let r) = rot, r == 90 else {
            XCTFail("Obj 3 should be updated with Rotate 90")
            return
        }
        
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 1, generation: 0)])
        XCTAssertNotNil(doc.objects[PDFCoreObjectRef(objectNumber: 2, generation: 0)])
    }
}
